// How the dashboards load their data, and the date rules they share.
//
//   DashClock          "now" for everything period-related, so tests can pin the date.
//   DashRequests       one GET at a time per screen: a newer request makes older answers be ignored, 60 s timeout,
//                      401 signs out, 403 is "no access", everything else becomes a typed DashLoadException.
//   DashboardLoading   the State mixin every dashboard uses on top of DashRequests (loading, refresh, failure).
//   DashFreshness      how old the figures are, shown with a Refresh button in the dashboard header.
//   dashCompleteMonths / dashMonthChange / dashPeriodLabel
//                      the period rules: a month still in progress is never compared with a finished one.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../config/auth_session.dart';

// =============================================================================
// CLOCK
// =============================================================================

/// The dashboards' "now". Tests pin it with [debugOverride]; the app always uses the device clock.
abstract final class DashClock {
  static DateTime Function()? _override;

  static DateTime now() => _override?.call() ?? DateTime.now();

  @visibleForTesting
  static set debugOverride(DateTime Function()? now) => _override = now;
}

// =============================================================================
// PERIOD RULES
// =============================================================================

const dashMonthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// How many months of [year] are over: all 12 for a past year, none for a future one, and for this year every month
/// before the current one (the current month is still in progress).
int dashCompleteMonths(int year) {
  final now = DashClock.now();
  if (year < now.year) return 12;
  if (year > now.year) return 0;
  return now.month - 1;
}

/// Plain words for the stretch of [year] a year-to-date figure covers: "Jan 1 – today", "all of 2025".
String dashPeriodLabel(int year) {
  final now = DashClock.now();
  if (year < now.year) return 'all of $year';
  if (year > now.year) return '$year (not started)';
  return 'Jan 1 – today';
}

/// "Oct 5" for a server date such as "2026-10-05" (the text itself if it isn't one).
String dashShortDate(String iso) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(iso);
  if (m == null) return iso;
  final month = int.parse(m.group(2)!);
  if (month < 1 || month > 12) return iso;
  return '${dashMonthNames[month - 1]} ${int.parse(m.group(3)!)}';
}

/// A short date range for a caption: "Oct 5–18" within one month, "Sep 28 – Oct 11" across two.
String dashDateRange(String fromIso, String toIso) {
  final from = dashShortDate(fromIso);
  final to = dashShortDate(toIso);
  final sameMonth = fromIso.length >= 7 && toIso.length >= 7 && fromIso.substring(0, 7) == toIso.substring(0, 7);
  if (sameMonth && from != fromIso && to != toIso) return '$from–${to.split(' ').last}';
  return '$from – $to';
}

/// A month-over-month change and what it compares, e.g. 12.5 and "Sep vs Aug".
class DashChange {
  final double pct;
  final String label;
  const DashChange(this.pct, this.label);
}

/// Change between the last two COMPLETE months of [monthly] (12 values, January first) in [year].
///
/// The month in progress is never used: a few days of a month against a whole one always looks like a collapse.
/// The two months are always next to each other. Null when there aren't two complete months yet, or the earlier
/// month is zero (a percentage of nothing means nothing).
DashChange? dashMonthChange(List<double> monthly, int year) {
  final n = math.min(dashCompleteMonths(year), math.min(monthly.length, 12));
  if (n < 2) return null;
  final prev = monthly[n - 2];
  final cur = monthly[n - 1];
  if (prev <= 0) return null;
  return DashChange((cur - prev) / prev * 100, '${dashMonthNames[n - 1]} vs ${dashMonthNames[n - 2]}');
}

// =============================================================================
// FAILURES
// =============================================================================

enum DashFailure {
  /// No answer within the timeout (the hosted server can take a while to wake up).
  timeout,

  /// The request never got an answer (no connection, server unreachable).
  offline,

  /// 401: the session is over; the app has signed out.
  signedOut,

  /// 403: signed in, but this person may not see this dashboard.
  noAccess,

  /// Any other status from the server.
  server,

  /// The server answered 200 but not with data this screen understands.
  badData,
}

class DashLoadException implements Exception {
  final DashFailure kind;
  final int? status;
  const DashLoadException(this.kind, {this.status});

  /// Whether trying again could help (a missing permission or an ended session won't fix itself).
  bool get canRetry => kind != DashFailure.noAccess && kind != DashFailure.signedOut;

  String title(String what) => switch (kind) {
    DashFailure.timeout => 'Loading $what is taking too long',
    DashFailure.offline => "Couldn't reach the server",
    DashFailure.signedOut => 'Your session ended',
    DashFailure.noAccess => 'No access to $what',
    DashFailure.server => "Couldn't load $what",
    DashFailure.badData => "Couldn't read $what",
  };

  String get message => switch (kind) {
    DashFailure.timeout => "The server didn't answer within a minute. It may be waking up, so try again.",
    DashFailure.offline => 'Check your internet connection, then try again.',
    DashFailure.signedOut => 'Sign in again to keep going.',
    DashFailure.noAccess => 'Ask an admin to switch this dashboard on for you on the Team screen.',
    DashFailure.server => 'The server had a problem${status == null ? '' : ' (error $status)'}. Try again in a moment.',
    DashFailure.badData => "The server's answer wasn't what this page expects. Try again; if it keeps happening, tell an admin.",
  };

  @override
  String toString() => 'DashLoadException($kind${status == null ? '' : ', $status'})';
}

// =============================================================================
// REQUESTS
// =============================================================================

class DashPayload {
  final Map<String, dynamic> body;

  /// When the server computed these figures (its cache can hand out copies up to 10 minutes old). Null from a server
  /// that doesn't say yet; then [receivedAt] is the best we know.
  final DateTime? generatedAt;
  final DateTime receivedAt;

  const DashPayload(this.body, {required this.generatedAt, required this.receivedAt});
}

/// One dashboard's GETs. Only the newest request counts: an older one that answers late resolves to null, so a slow
/// answer for last year can never replace this year's figures.
class DashRequests {
  final Duration timeout;
  DashRequests({this.timeout = const Duration(seconds: 60)});

  int _latest = 0;

  /// Makes every request in flight resolve to null (call from dispose).
  void cancel() => _latest++;

  /// GET `kApiBaseUrl + path` with [query]; `fresh` asks the server to skip its cache.
  Future<DashPayload?> get(String path, {Map<String, String> query = const {}, bool fresh = false}) {
    final params = {...query, if (fresh) 'fresh': '1'};
    return getUri(Uri.parse('$kApiBaseUrl$path').replace(queryParameters: params.isEmpty ? null : params));
  }

  Future<DashPayload?> getUri(Uri uri) async {
    final id = ++_latest;
    http.Response res;
    try {
      res = await http.get(uri, headers: AuthSession.instance.headers()).timeout(timeout);
    } on TimeoutException {
      if (id != _latest) return null;
      throw const DashLoadException(DashFailure.timeout);
    } catch (_) {
      if (id != _latest) return null;
      throw const DashLoadException(DashFailure.offline);
    }
    // An ended session ends it everywhere, even when this answer is no longer wanted.
    if (res.statusCode == 401) {
      AuthSession.instance.logout();
      if (id != _latest) return null;
      throw const DashLoadException(DashFailure.signedOut, status: 401);
    }
    if (id != _latest) return null;
    if (res.statusCode == 403) throw const DashLoadException(DashFailure.noAccess, status: 403);
    if (res.statusCode != 200) throw DashLoadException(DashFailure.server, status: res.statusCode);
    final Object? decoded;
    try {
      decoded = json.decode(res.body);
    } on FormatException {
      throw const DashLoadException(DashFailure.badData);
    }
    if (decoded is! Map<String, dynamic>) throw const DashLoadException(DashFailure.badData);
    final stamp = decoded['generatedAt'];
    return DashPayload(
      decoded,
      generatedAt: stamp is String ? DateTime.tryParse(stamp)?.toLocal() : null,
      receivedAt: DashClock.now(),
    );
  }
}

// =============================================================================
// FRESHNESS (shown in the dashboard header)
// =============================================================================

/// What the header shows about the figures on screen: when they were computed, whether a refresh is running or
/// failed, and how to refresh. The dashboard content reports into it; DashboardLayout listens.
class DashFreshness extends ChangeNotifier {
  Object? _owner;
  DateTime? _updatedAt;
  bool _computedTime = false;
  bool _busy = false;
  DashLoadException? _refreshFailure;
  VoidCallback? _onRefresh;

  DateTime? get updatedAt => _updatedAt;

  /// True when [updatedAt] is the server's own "computed at" time, false when it is only when the answer arrived.
  bool get isComputedTime => _computedTime;
  bool get busy => _busy;
  DashLoadException? get refreshFailure => _refreshFailure;
  VoidCallback? get onRefresh => _onRefresh;

  void report(
    Object owner, {
    DateTime? updatedAt,
    bool computedTime = false,
    required bool busy,
    DashLoadException? refreshFailure,
    VoidCallback? onRefresh,
  }) {
    _owner = owner;
    _updatedAt = updatedAt;
    _computedTime = computedTime;
    _busy = busy;
    _refreshFailure = refreshFailure;
    _onRefresh = onRefresh;
    notifyListeners();
  }

  /// Clears what [owner] reported, unless someone newer (the next year's content) has reported since.
  void release(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _updatedAt = null;
    _busy = false;
    _refreshFailure = null;
    _onRefresh = null;
    notifyListeners();
  }
}

/// Hands the header's [DashFreshness] to the dashboard content below it.
class DashFreshnessScope extends InheritedWidget {
  final DashFreshness freshness;
  const DashFreshnessScope({super.key, required this.freshness, required super.child});

  static DashFreshness? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DashFreshnessScope>()?.freshness;

  @override
  bool updateShouldNotify(DashFreshnessScope old) => !identical(old.freshness, freshness);
}

// =============================================================================
// THE STATE MIXIN EVERY DASHBOARD USES
// =============================================================================

/// Loading, refreshing and failure for one dashboard screen.
///
/// The first load (and a year change) shows the screen's skeleton. A refresh keeps the figures on screen while it
/// runs, and if it fails the figures stay and the header says the refresh failed. A failed first load shows
/// [dashFailure]. Implement [dashReload]; call [dashLoad] from it.
mixin DashboardLoading<W extends StatefulWidget> on State<W> {
  final DashRequests dashRequests = DashRequests();

  /// True until the first answer (or failure) arrives: show the skeleton.
  bool dashLoading = true;

  /// Why the figures couldn't be loaded; show it instead of the content.
  DashLoadException? dashFailure;

  bool _dashHasData = false;
  DashFreshness? _freshness;

  /// When the figures on screen were computed (or arrived), kept through a refresh.
  DateTime? _dashUpdatedAt;
  bool _dashComputedTime = false;

  /// Loads the screen's data; `fresh` means the person asked for a refresh.
  Future<void> dashReload({bool fresh = false});

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _freshness = DashFreshnessScope.maybeOf(context);
  }

  @override
  void dispose() {
    dashRequests.cancel();
    _freshness?.release(this);
    super.dispose();
  }

  /// GET [path] and hand the body to [apply], which runs inside setState. A refresh ([fresh]) with figures already on
  /// screen keeps them visible while it runs.
  Future<void> dashLoad(
    String path, {
    Map<String, String> query = const {},
    bool fresh = false,
    required void Function(Map<String, dynamic> body) apply,
  }) async {
    final keep = fresh && _dashHasData && dashFailure == null;
    setState(() {
      if (!keep) dashLoading = true;
      dashFailure = null;
    });
    _report(busy: true);
    try {
      final payload = await dashRequests.get(path, query: query, fresh: fresh);
      if (payload == null || !mounted) return; // a newer request took over, or the screen is gone
      try {
        setState(() {
          apply(payload.body);
          dashLoading = false;
          _dashHasData = true;
        });
      } catch (_) {
        throw const DashLoadException(DashFailure.badData);
      }
      _dashUpdatedAt = payload.generatedAt ?? payload.receivedAt;
      _dashComputedTime = payload.generatedAt != null;
      _report(busy: false);
    } on DashLoadException catch (e) {
      if (!mounted) return;
      if (keep) {
        // The figures on screen are still the last good ones; the header says the refresh failed.
        _report(busy: false, refreshFailure: e);
        return;
      }
      setState(() {
        dashFailure = e;
        dashLoading = false;
        _dashHasData = false;
      });
      _dashUpdatedAt = null;
      _report(busy: false);
    }
  }

  void _report({required bool busy, DashLoadException? refreshFailure}) {
    _freshness?.report(
      this,
      updatedAt: _dashHasData ? _dashUpdatedAt : null,
      computedTime: _dashComputedTime,
      busy: busy,
      refreshFailure: refreshFailure,
      onRefresh: busy ? null : () => dashReload(fresh: true),
    );
  }
}
