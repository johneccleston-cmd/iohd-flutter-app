import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme/app_theme.dart';

import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart' hide TextDirection;
import 'package:shared_preferences/shared_preferences.dart';

import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'utils/status_colors.dart';
import 'widgets/dashboard_data.dart' show DashClock;
import 'widgets/dashboard_kit.dart' show DashUi, SkeletonPulse;
import 'widgets/dashboard_panels.dart' show DashPressable;

// Kept public and unchanged in behavior: other screens may import it.
Color getStatusColor(String? status) => statusColor(status);

// =============================================================================
// THEME + HELPERS
// =============================================================================

// Integrity's own palette: deep navy for text and "selected", a neutral (not blue-grey) page, white cards and
// controls, slate hairlines, and the brand red kept for one job: marking today.

/// Deep navy: headings, customer names and every selected control.
const _ink = Color(0xFF17233F);
const _slate = DashUi.slate;

/// Decoration only (other months' day numbers, chevrons): about 2.6:1 on white.
const _muted = DashUi.muted;

/// For muted text people actually read (counts, empty-state notes, field labels).
const _mutedText = DashUi.subtle;

/// Hairlines on cards, menus and the weekday header.
const _line = DashUi.line;

/// Gridlines and control borders: a step darker than [_line], so the days and the toolbar read as distinct pieces.
const _grid = Color(0xFFD9DFE7);

/// Hover fills and tracks (the segmented controls), on the neutral page.
const _faint = Color(0xFFEEF1F5);
const _faintLight = Color(0xFFF8F9FB);
const _brand = AppTheme.brandRed;

/// Integrity red, restrained: today's date and weekday, nothing else.
const _todayRed = Color(0xFFC62828);

/// The selected view and type and Retry: the navy the rest of the office screens use for "selected".
const _accent = _ink;

/// Today's square: white, lifted off the neutral page, with a red rule along its top (see [_monthCell]).
const _todayBg = Colors.white;

// The grid is laid out like the dashboards at small scale: white cards with a hairline border on a quiet page.
/// A weekday of the period on screen.
const _cellBg = Color(0xFFF5F7FA);

/// Saturdays and Sundays: a touch deeper, so the working week reads as one block.
const _weekendBg = Color(0xFFF0F2F6);

/// A day from the neighbouring month, a step darker again so the period on screen stands out.
const _otherMonthBg = Color(0xFFE9ECF1);

/// The calendar's six appointment colours. Service Fusion has ~40 statuses in a dozen saturated hues (lime, cyan,
/// magenta...), which turned a busy day into a patchwork; here each status falls into one of six families with one
/// meaning each, chosen from the status itself, so a card is the same colour on every render.
enum _Tone {
  green(DashUi.emeraldDeep, Color(0xFF047857)), // on the schedule: booked visits
  blue(DashUi.blue, Color(0xFF1D4ED8)), // in progress: parts, projects, deliveries
  amber(DashUi.amber, DashUi.amberText), // needs attention: delayed, partial, still to schedule
  purple(Color(0xFF7C3AED), Color(0xFF6D28D9)), // estimates
  red(Color(0xFFC0443C), Color(0xFFA3332C)), // money: deposits, invoices, notices
  slate(Color(0xFF8391A7), DashUi.slate); // done, closed, cancelled, or a status we don't know

  /// The bar, dot and tint.
  final Color color;

  /// The status name drawn in this colour (darker, for 4.5:1 on white).
  final Color text;
  const _Tone(this.color, this.text);
}

const _toneByStatus = <String, _Tone>{
  'site check': _Tone.green,
  'scheduled': _Tone.green,
  'warranty work': _Tone.green,
  'callback': _Tone.green,
  'appointment': _Tone.green,
  'need to order': _Tone.blue,
  'part ordered': _Tone.blue,
  'manage project': _Tone.blue,
  'verify delivery': _Tone.blue,
  'need to sell': _Tone.blue,
  'need to schedule': _Tone.amber,
  'delayed': _Tone.amber,
  'need to warranty': _Tone.amber,
  'partially complete': _Tone.amber,
  'estimate requested': _Tone.purple,
  'estimate follow up': _Tone.purple,
  'estimate accepted': _Tone.purple,
  'estimate provided': _Tone.purple,
  'estimate won': _Tone.purple,
  'need deposit': _Tone.red,
  'final invoice sent': _Tone.red,
  'write-off': _Tone.red,
  '14 day notice': _Tone.red,
  '30 day notice': _Tone.red,
  '60 day notice': _Tone.red,
  '90 day notice': _Tone.red,
  'check on payment': _Tone.red,
  'complete': _Tone.slate,
  'close job': _Tone.slate,
  'paid & closed': _Tone.slate,
  'google review sent': _Tone.slate,
  'cancelled': _Tone.slate,
  'lost': _Tone.slate,
};

/// The family for [status]. Sub-variants ("Scheduled - Full Day") take the status before the dash, as in
/// [knownStatusColor]; an estimate whose status isn't listed is still purple, anything else unknown is slate.
_Tone _toneFor(String status, {bool estimate = false}) {
  final t = status.trim().toLowerCase();
  final dash = t.indexOf(' - ');
  return _toneByStatus[t] ??
      (dash > 0 ? _toneByStatus[t.substring(0, dash).trim()] : null) ??
      (estimate ? _Tone.purple : _Tone.slate);
}

/// Height of every toolbar control, so buttons, menus and toggles line up.
const _ctlH = 36.0;

/// How often the schedule is re-read while the page is on screen.
const _refreshEvery = Duration(minutes: 5);

/// Today, from the clock tests can pin (DashClock), so month and year edges can be tested on purpose.
DateTime _now() => DashClock.now();

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Calendar-safe day math. (Adding Duration(days: 1) to a local DateTime repeats a day
/// when clocks fall back for daylight saving.)
DateTime _addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

DateTime _dayKey(DateTime d) => DateTime.utc(d.year, d.month, d.day);
bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
String _ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

String _titleCase(String s) =>
    s.split(RegExp(r'\s+')).map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');

bool _truthy(dynamic v) => v == true || v == 1 || (v is String && (v.toLowerCase() == 'true' || v == 't' || v == '1'));

class _ChipStyle {
  final Color bg;
  final Color fg;
  final Color bar;
  final Color accent; // status color, for badges and tech dots
  final Color border;
  const _ChipStyle(this.bg, this.fg, this.bar, this.accent, this.border);
}

/// Event cards are white with a hairline border, like the dashboards' panels; the status colour is the bar down the
/// left edge (and the dot), never a fill, so sixteen jobs on a day read as one calm column instead of a patchwork.
/// [dimmed] (days from the neighbouring months) fades the card without a costly Opacity layer per chip.
_ChipStyle _styleFor(Color c, {bool dimmed = false}) {
  return dimmed
      ? _ChipStyle(Color.lerp(Colors.white, _otherMonthBg, 0.4)!, _mutedText, c.withValues(alpha: 0.45), c, _line)
      : _ChipStyle(Colors.white, _ink, c, c, _line);
}

// =============================================================================
// MODEL
// =============================================================================

/// A load failure whose message is already fit to show. Anything else (a dropped connection, a malformed reply) is
/// described in plain words instead of printing the raw exception, which includes the request URL.
class _CalendarError implements Exception {
  final String message;

  /// No access (403): trying again cannot help, so no Retry is offered.
  final bool forbidden;
  const _CalendarError(this.message, {this.forbidden = false});
}

class _CalEvent {
  final Map<String, dynamic> raw;
  final DateTime day; // UTC midnight of the calendar day
  final String status;
  final String customer;
  final String techs;
  final List<String> techList;
  final bool isEstimate;

  const _CalEvent({
    required this.raw,
    required this.day,
    required this.status,
    required this.customer,
    required this.techs,
    required this.techList,
    required this.isEstimate,
  });

  String get statusKey => status.trim().toLowerCase();

  /// What the status filter matches on. Jobs and estimates keep separate lists of statuses, so a status that
  /// exists on both (say "Scheduled") is two filters, one per kind.
  String get filterKey => '${isEstimate ? 'estimate' : 'job'}|$statusKey';

  String get statusLabel {
    final s = status.trim();
    if (s.isEmpty) return 'No status';
    return s == s.toLowerCase() ? _titleCase(s) : s;
  }

  _Tone get tone => _toneFor(status, estimate: isEstimate);
  Color get color => tone.color;

  /// "9:00 AM" / "9:00 AM - 11:00 AM" from the visit's promised time frame, or null for an all-day job.
  String? get timeLabel {
    String? fmt(dynamic v) {
      final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(v?.toString() ?? '');
      if (m == null) return null;
      final h = int.parse(m.group(1)!), min = m.group(2)!;
      if (h > 23) return null;
      final h12 = h % 12 == 0 ? 12 : h % 12;
      return '$h12:$min ${h < 12 ? 'AM' : 'PM'}';
    }

    final start = fmt(raw['time_start']);
    if (start == null) return null;
    final end = fmt(raw['time_end']);
    if (end == null || end == start) return start;
    // "9:30–11:00 AM" when both fall in the same half of the day: short enough never to wrap awkwardly.
    if (start.endsWith('AM') == end.endsWith('AM')) {
      return '${start.substring(0, start.length - 3)}–$end';
    }
    return '$start – $end';
  }

  /// Minutes after midnight of the visit's start, or null for an all-day job (sorts first).
  int? get startMinutes {
    final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(raw['time_start']?.toString() ?? '');
    if (m == null) return null;
    final h = int.parse(m.group(1)!);
    return h > 23 ? null : h * 60 + int.parse(m.group(2)!);
  }

  /// "9a" / "9:30p" for the tight month chips; null for an all-day job.
  String? get shortTime {
    final s = startMinutes;
    if (s == null) return null;
    final h = s ~/ 60, min = s % 60;
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12${min == 0 ? '' : ':${min.toString().padLeft(2, '0')}'}${h < 12 ? 'a' : 'p'}';
  }

  /// "Brett, Marcus": first names only, for the month chips; the full names are in the tooltip and the day view.
  /// A first name shared by two people on the schedule ([ambiguous]) gets the last initial ("Brett H.").
  String shortTechs(Set<String> ambiguous) => techList
      .map((t) {
        final parts = t.split(RegExp(r'\s+'));
        final first = parts.first;
        if (parts.length > 1 && ambiguous.contains(first.toLowerCase())) return '$first ${parts.last[0]}.';
        return first;
      })
      .join(', ');

  String get tooltip => [
    customer,
    statusLabel + (isEstimate ? ' (estimate)' : ''),
    timeLabel ?? 'All day',
    if (techs.isNotEmpty) 'Techs: $techs' else 'No tech assigned',
  ].join('\n');

  /// Reads the date straight from the yyyy-mm-dd prefix, so a timestamp or timezone suffix
  /// from the server can never shift the event onto a neighboring day.
  static DateTime? _parseDay(dynamic v) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(v?.toString() ?? '');
    if (m == null) return null;
    return DateTime.utc(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
  }

  static _CalEvent? tryParse(Map<String, dynamic> m) {
    final day = _parseDay(m['event_date']);
    if (day == null) return null;
    var techs = (m['techs'] ?? '').toString().trim();
    // The server writes "Unassigned" when a job has no tech; that is the absence of a name, not a person called that.
    if (techs.toLowerCase() == 'unassigned') techs = '';
    // Two visits on one day each list their techs, so a name can come twice ("Brett Hall, Marcus Lee, Brett Hall").
    final techList = techs.isEmpty
        ? const <String>[]
        : {...techs.split(RegExp(r'\s*[,;&/]\s*')).map((t) => t.trim()).where((t) => t.isNotEmpty)}.toList();
    final customer = (m['customer_name'] ?? '').toString().trim();
    return _CalEvent(
      raw: m,
      day: day,
      status: (m['status'] ?? '').toString(),
      customer: customer.isEmpty ? 'Unknown Customer' : customer,
      techs: techList.join(', '),
      techList: techList,
      isEstimate: _truthy(m['is_estimate']),
    );
  }
}

enum _CalView { month, week }

enum _TypeFilter { all, jobs, estimates }

/// Stands in for "no tech assigned" in the tech filter, so unstaffed jobs can be found.
const _unassigned = 'Unassigned';

// =============================================================================
// SCREEN
// =============================================================================

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  bool _loading = true;
  Timer? _slowTimer;
  Timer? _refreshTimer;
  bool _slowLoad = false; // still loading after a few seconds: the free-tier server is probably waking up
  String? _error;
  bool _forbidden = false; // the error is "no access": no Retry
  int _requestId = 0;

  DateTime _focused = _dateOnly(_now());
  _CalView _view = _CalView.month;

  Map<DateTime, List<_CalEvent>> _byDay = {};
  DateTime? _loadedStart; // window currently held in memory: [start, end)
  DateTime? _loadedEnd;

  final FocusNode _focusNode = FocusNode();
  // The filter buttons share their focus with their menus, so the keyboard can go into a menu and back.
  final FocusNode _techButtonFocus = FocusNode(debugLabel: 'Tech filter');
  final FocusNode _statusButtonFocus = FocusNode(debugLabel: 'Status filter');
  final Set<String> _techs = {};
  _TypeFilter _type = _TypeFilter.all;
  final Set<String> _statusFilter = {};

  /// First names shared by more than one tech on the loaded schedule; month chips add a last initial for them.
  Set<String> _ambiguous = const {};

  /// A background refresh failed, so what is on screen may be out of date (and when it was last good).
  bool _stale = false;
  DateTime? _loadedAt;

  /// False while another page of the app is in front: the shell keeps this page alive behind it (an indexed stack
  /// with tickers off), and there is no point re-reading a schedule nobody is looking at.
  bool _visible = true;

  /// A 5-minute refresh came round while the page was hidden; coming back makes up for it once.
  bool _missedRefresh = false;

  /// Scroll the month to the week with today in it once that week is drawn with its events (first load, Today).
  bool _wantToday = true;

  @override
  void initState() {
    super.initState();
    _restoreTechs();
    _ensureLoaded();
    // Pick up changes made elsewhere (new jobs, rescheduled visits) and roll "today" over at midnight, without a spinner.
    _refreshTimer = Timer.periodic(_refreshEvery, (_) {
      if (!mounted) return;
      if (!_visible) {
        _missedRefresh = true; // caught up on return (didChangeDependencies)
        return;
      }
      if (!_loading) _ensureLoaded(force: true, quiet: true);
      setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible == _visible) return;
    _visible = visible;
    if (visible && _missedRefresh) {
      _missedRefresh = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_loading) _ensureLoaded(force: true, quiet: true);
      });
    }
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    _refreshTimer?.cancel();
    _focusNode.dispose();
    _techButtonFocus.dispose();
    _statusButtonFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Date ranges
  // ---------------------------------------------------------------------------

  DateTime get _monthStart => DateTime(_focused.year, _focused.month, 1);
  DateTime get _gridStart => _addDays(_monthStart, -(_monthStart.weekday % 7)); // weeks start Sunday
  int get _weeksInGrid {
    final daysInMonth = DateTime(_focused.year, _focused.month + 1, 0).day;
    return ((_monthStart.weekday % 7) + daysInMonth + 6) ~/ 7;
  }

  DateTime get _weekStart => _addDays(_focused, -(_focused.weekday % 7));
  DateTime get _visibleStart => _view == _CalView.month ? _gridStart : _weekStart;
  DateTime get _visibleEnd => _addDays(_visibleStart, _view == _CalView.month ? _weeksInGrid * 7 : 7);

  // A day outside the loaded window is not loaded yet (or failed to load): it must never read as "nothing scheduled".

  /// Whether [day] lies in the loaded window.
  bool _dayLoaded(DateTime day) {
    final s = _loadedStart, e = _loadedEnd;
    return s != null && e != null && !day.isBefore(s) && day.isBefore(e);
  }

  /// Whether every day on screen is loaded.
  bool get _covered {
    final s = _loadedStart, e = _loadedEnd;
    return s != null && e != null && !_visibleStart.isBefore(s) && !_visibleEnd.isAfter(e);
  }

  /// Whether any day on screen is loaded (moving one month on, most of the new month usually already is).
  bool get _anyLoaded {
    final s = _loadedStart, e = _loadedEnd;
    return s != null && e != null && _visibleStart.isBefore(e) && _visibleEnd.isAfter(s);
  }

  // ---------------------------------------------------------------------------
  // Data
  // ---------------------------------------------------------------------------

  /// Fetches a 3-month window around the focused month, and only when the visible range
  /// isn't already inside the loaded window, so flipping between neighboring months is instant.
  ///
  /// [quiet] is for the background refresh: no loading indicator, and a failure keeps what is on screen.
  Future<void> _ensureLoaded({bool force = false, bool quiet = false}) async {
    if (!force && _covered) {
      // Already held. Drop any request still in flight for a window we no longer need: if it landed it would
      // replace the data with a window that does not cover this view and leave the grid empty.
      if (_loading || _error != null) {
        _requestId++;
        setState(() {
          _loading = false;
          _error = null;
          _forbidden = false;
        });
      }
      return;
    }

    final id = ++_requestId;
    if (!quiet) {
      setState(() {
        _loading = true;
        _slowLoad = false;
        _error = null;
        _forbidden = false;
      });
      _slowTimer?.cancel();
      _slowTimer = Timer(const Duration(seconds: 8), () {
        if (mounted && id == _requestId && _loading) setState(() => _slowLoad = true);
      });
    }

    final windowStart = DateTime(_focused.year, _focused.month - 1, 1);
    final windowEnd = DateTime(_focused.year, _focused.month + 2, 1);

    try {
      final uri = Uri.parse('$kApiBaseUrl/api/calendar/sync')
          .replace(queryParameters: {'start': _ymd(windowStart), 'end': _ymd(windowEnd)});
      final response = await http
          .get(uri, headers: AuthSession.instance.headers())
          .timeout(const Duration(seconds: 60)); // free-tier hosts can take ~30s+ to wake up

      if (!mounted || id != _requestId) {
        return; // a newer request superseded this one
      }
      if (response.statusCode == 401) {
        AuthSession.instance.logout(); // session expired: back to the sign-in screen
        return;
      }
      if (response.statusCode == 403) {
        throw const _CalendarError("Your account doesn't have access to the calendar.", forbidden: true);
      }
      if (response.statusCode != 200) {
        throw _CalendarError('The server returned status ${response.statusCode}.');
      }

      final dynamic body = json.decode(response.body);
      final dynamic rawList = body is Map ? body['events'] : body;
      final List<dynamic> list = rawList is List ? rawList : const [];

      final grouped = <DateTime, List<_CalEvent>>{};
      for (final item in list) {
        if (item is! Map) continue;
        final e = _CalEvent.tryParse(Map<String, dynamic>.from(item));
        if (e == null) continue;
        (grouped[e.day] ??= []).add(e);
      }
      for (final l in grouped.values) {
        l.sort((a, b) {
          // All-day first, then by start time, then jobs before estimates, then by name.
          final ta = a.startMinutes ?? -1, tb = b.startMinutes ?? -1;
          if (ta != tb) return ta.compareTo(tb);
          if (a.isEstimate != b.isEstimate) {
            return a.isEstimate ? 1 : -1;
          }
          return a.customer.toLowerCase().compareTo(b.customer.toLowerCase());
        });
      }

      final firstNames = <String, Set<String>>{};
      for (final l in grouped.values) {
        for (final e in l) {
          for (final t in e.techList) {
            (firstNames[t.split(RegExp(r'\s+')).first.toLowerCase()] ??= {}).add(t.toLowerCase());
          }
        }
      }
      setState(() {
        _byDay = grouped;
        _ambiguous = {
          for (final k in firstNames.entries)
            if (k.value.length > 1) k.key,
        };
        _loadedStart = windowStart;
        _loadedEnd = windowEnd;
        _loadedAt = DateTime.now(); // wall-clock time, for "Showing the schedule from 10:42 AM"
        _loading = false;
        _error = null;
        _forbidden = false;
        _stale = false;
      });
      // The window is centred on the month that was focused when this request started. If you moved on within the old
      // window while it ran (a background refresh does this), what is on screen may now fall outside the new one.
      if (!_covered) _ensureLoaded();
    } on TimeoutException {
      _fail(id, 'The server took too long to respond.', quiet: quiet);
    } on _CalendarError catch (e) {
      _fail(id, e.message, quiet: quiet, forbidden: e.forbidden);
    } on FormatException {
      _fail(id, 'The server sent a reply the calendar could not read.', quiet: quiet);
    } catch (_) {
      _fail(id, "Couldn't reach the server. Check your connection and try again.", quiet: quiet);
    }
  }

  void _fail(int id, String message, {bool quiet = false, bool forbidden = false}) {
    if (!mounted || id != _requestId) return;
    if (quiet) {
      // The background refresh failed: keep what is on screen, but say it may be out of date.
      setState(() => _stale = true);
      return;
    }
    setState(() {
      _error = message;
      _forbidden = forbidden;
      _loading = false;
    });
  }

  /// The Refresh and Retry buttons. While a load is already on its way a second request would only race it.
  void _reload() {
    if (_loading) return;
    _ensureLoaded(force: true);
  }

  // ---------------------------------------------------------------------------
  // Filtering
  // ---------------------------------------------------------------------------

  bool _passes(_CalEvent e, {bool ignoreStatus = false}) {
    if (_type == _TypeFilter.jobs && e.isEstimate) return false;
    if (_type == _TypeFilter.estimates && !e.isEstimate) return false;
    if (_techs.isNotEmpty && !(e.techList.isEmpty ? const [_unassigned] : e.techList).any(_techs.contains)) {
      return false;
    }
    // Each kind is narrowed only by the statuses picked for that kind: choosing a job status leaves estimates alone.
    if (!ignoreStatus && _kindFiltered(e.isEstimate) && !_statusFilter.contains(e.filterKey)) return false;
    return true;
  }

  bool _kindFiltered(bool estimate) => _statusFilter.any((k) => k.startsWith(estimate ? 'estimate|' : 'job|'));

  List<_CalEvent> _eventsFor(DateTime day, {bool ignoreStatus = false}) {
    final list = _byDay[_dayKey(day)];
    if (list == null) return const [];
    return list.where((e) => _passes(e, ignoreStatus: ignoreStatus)).toList();
  }

  List<String> get _allTechs {
    // A tech saved from an earlier visit stays listed even with nothing in these months, so it can be unticked.
    final set = <String>{..._techs}..remove(_unassigned);
    var anyUnassigned = false;
    for (final l in _byDay.values) {
      for (final e in l) {
        set.addAll(e.techList);
        if (e.techList.isEmpty) anyUnassigned = true;
      }
    }
    return set.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()))
      ..addAll([if (anyUnassigned || _techs.contains(_unassigned)) _unassigned]);
  }

  /// Button label style from the app theme (a bare TextStyle would drop the theme's font on these buttons).
  TextStyle _buttonText(BuildContext context) =>
      (Theme.of(context).textTheme.labelLarge ?? const TextStyle()).copyWith(fontSize: 13, fontWeight: FontWeight.w700);

  /// The tech menu's checkboxes in black rather than the app's red accent.
  ThemeData _blackChecks(BuildContext context) => Theme.of(context).copyWith(
    // The app's red seed tints popup surfaces pink; the filter menus are plain white.
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(Colors.white),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        side: const WidgetStatePropertyAll(BorderSide(color: _line)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? _ink : Colors.transparent),
      checkColor: const WidgetStatePropertyAll(Colors.white),
      side: const BorderSide(color: _slate, width: 1.5),
    ),
  );

  // The techs you pick stay picked: a page reload or reopening the app brings the same selection back. It is kept per
  // person on this device (the other filters are quick toggles and reset).
  String get _techsKey => 'calendar_techs_${AuthSession.instance.name}';

  Future<void> _restoreTechs() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getStringList(_techsKey);
      if (saved == null || saved.isEmpty || !mounted) return;
      setState(() => _techs.addAll(saved));
    } catch (_) {
      // storage unavailable: start with every tech
    }
  }

  Future<void> _saveTechs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_techs.isEmpty) {
        await prefs.remove(_techsKey);
      } else {
        await prefs.setStringList(_techsKey, _techs.toList());
      }
    } catch (_) {}
  }

  bool get _filtersActive => _techs.isNotEmpty || _type != _TypeFilter.all || _statusFilter.isNotEmpty;

  void _clearFilters() => setState(() {
    _techs.clear();
    _saveTechs();
    _statusFilter.clear();
    _type = _TypeFilter.all;
  });

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  void _go(int dir) {
    setState(() {
      _wantToday = false;
      _focused = _view == _CalView.month
          ? DateTime(_focused.year, _focused.month + dir, 1)
          : _addDays(_focused, 7 * dir);
    });
    _ensureLoaded();
  }

  void _goToday() {
    setState(() {
      _focused = _dateOnly(_now());
      _wantToday = true;
    });
    _ensureLoaded();
  }

  void _setView(_CalView v) {
    if (v == _view) return;
    setState(() {
      _view = v;
      _wantToday = false;
      final today = _dateOnly(_now());
      // Month -> week: land on today's week when viewing the current month, else the 1st.
      if (v == _CalView.week && today.year == _focused.year && today.month == _focused.month) {
        _focused = today;
      }
    });
    _ensureLoaded();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _focused,
      firstDate: DateTime(2015),
      lastDate: DateTime(2100),
      helpText: 'JUMP TO DATE',
      // The picker paints its selected day, header and buttons in the theme's primary (the app's red): use black here.
      builder: (context, child) {
        final theme = Theme.of(context);
        return Theme(
          data: theme.copyWith(
            colorScheme: theme.colorScheme.copyWith(
              primary: _ink,
              onPrimary: Colors.white,
              // The red seed also tints the dialog's surface pink; plain white instead.
              surface: Colors.white,
              surfaceTint: Colors.transparent,
              surfaceContainerHigh: Colors.white,
              surfaceContainerHighest: _faint,
              onSurface: _ink,
              onSurfaceVariant: _slate,
              outline: _muted,
              outlineVariant: _line,
            ),
            datePickerTheme: const DatePickerThemeData(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
            ),
            textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: _ink)),
          ),
          child: child!,
        );
      },
    );
    if (picked == null || !mounted) return;
    setState(() {
      _focused = _dateOnly(picked);
      _wantToday = false;
    });
    _ensureLoaded();
  }

  bool _isTyping() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx?.findAncestorWidgetOfExactType<EditableText>() != null || ctx?.widget is EditableText;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _isTyping()) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _go(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _go(1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyT) {
      _goToday();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String get _periodTitle {
    if (_view == _CalView.month) {
      return DateFormat('MMMM yyyy').format(_focused);
    }
    final s = _weekStart;
    final e = _addDays(s, 6);
    if (s.month == e.month) {
      return '${DateFormat('MMM d').format(s)} – ${e.day}, ${e.year}';
    }
    // The week of New Year names both years ("Dec 27, 2026 – Jan 2, 2027"), or it would read as December 2027.
    if (s.year != e.year) {
      return '${DateFormat('MMM d, y').format(s)} – ${DateFormat('MMM d, y').format(e)}';
    }
    return '${DateFormat('MMM d').format(s)} – ${DateFormat('MMM d, y').format(e)}';
  }

  // ---------------------------------------------------------------------------
  // Dialogs
  // ---------------------------------------------------------------------------

  void _openEvent(_CalEvent e) {
    final jobId = (e.raw['job_number'] ?? '').toString().trim();
    if (jobId.isNotEmpty) {
      // An estimate opens under Estimates so that menu item stays lit, a job under Jobs.
      context.go(
        '/${e.isEstimate ? 'estimates' : 'jobs'}/${Uri.encodeComponent(jobId)}',
        extra: <String, dynamic>{
          'job_id': jobId,
          'customer_name': e.raw['customer_name'],
          'status': e.status,
          'is_estimate': e.isEstimate,
          'techs_assigned': e.techs,
        },
      );
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460, maxHeight: 640),
          child: _EventDetails(event: e, onClose: () => Navigator.of(ctx).pop()),
        ),
      ),
    );
  }

  void _openDay(DateTime day) {
    final events = _eventsFor(day);
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 660),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 18, 10, 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            DateFormat('EEEE').format(day).toUpperCase(),
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: _mutedText,
                              letterSpacing: 1,
                            ),
                          ),
                          Text(
                            DateFormat('MMMM d, y').format(day),
                            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: _ink),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            events.isEmpty
                                ? 'Nothing scheduled'
                                : '${events.length} ${events.length == 1 ? 'event' : 'events'}',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _slate),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(ctx).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: _line),
              if (events.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(36),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.event_available_rounded, size: 40, color: _line),
                        SizedBox(height: 8),
                        Text(
                          'Nothing on the schedule',
                          style: TextStyle(color: _mutedText, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(16),
                    itemCount: events.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _EventCard(
                      event: events[i],
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _openEvent(events[i]);
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        // One full-bleed screen, not a card floating on a grey page.
        backgroundColor: Colors.white,
        body: _panel(),
      ),
    );
  }

  /// Hands the keyboard back to the page after a click on a control, so the arrow keys and T keep working.
  void _refocus() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && !_isTyping()) _focusNode.requestFocus();
  });

  Widget _panel() {
    return Container(
      color: Colors.white,
      child: Column(
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 14, 20, 12), child: _toolbar()),
          SizedBox(
            height: 2,
            child: _loading
                ? const LinearProgressIndicator(color: _slate, backgroundColor: Colors.transparent, minHeight: 2)
                : null,
          ),
          if (_loading && _slowLoad)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              color: _faint,
              child: const Text(
                'Waking up the server, this can take up to a minute.',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _slate),
              ),
            ),
          // A failure over days that ARE loaded is a banner (the grid is still right, maybe old); a failure for days that
          // never loaded is said on the grid itself (see _withStatus), where an empty month would otherwise be.
          if (_error != null && _anyLoaded) _errorBanner() else if (_stale && _error == null) _staleBanner(),
          const Divider(height: 1, color: _grid),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                // Phone-width: a day-by-day list reads better than seven squeezed columns.
                final agenda = c.maxWidth < 700;
                final body = agenda ? _agenda() : (_view == _CalView.month ? _monthGrid() : _weekGrid());
                return _withStatus(
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 160),
                    layoutBuilder: (current, previous) =>
                        Stack(fit: StackFit.expand, children: [...previous, ?current]),
                    child: KeyedSubtree(key: ValueKey('$_view|$agenda|${_ymd(_visibleStart)}'), child: body),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// A note over the grid when there is nothing to show, so a quiet period, a filter that hides everything or a period
  /// that failed to load never looks like a broken (or an empty) page.
  Widget _withStatus(Widget grid) {
    final failed = _error != null && !_anyLoaded;
    var visible = 0;
    for (var d = _visibleStart; d.isBefore(_visibleEnd); d = _addDays(d, 1)) {
      visible += _eventsFor(d).length;
    }
    final empty = !_loading && _error == null && _covered && visible == 0;

    Widget? note;
    if (failed) {
      note = _note(
        icon: Icons.cloud_off_rounded,
        iconColor: _brand,
        title: _loadedStart == null ? "Couldn't load the calendar" : "Couldn't load $_periodTitle",
        message: _error,
        action: _forbidden ? null : ('Retry', _reload),
      );
    } else if (empty) {
      note = _note(
        icon: Icons.event_available_rounded,
        iconColor: _muted,
        title: _filtersActive
            ? 'Nothing matches these filters'
            : 'Nothing scheduled this ${_view == _CalView.month ? 'month' : 'week'}',
        action: _filtersActive ? ('Clear filters', _clearFilters) : null,
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        grid,
        // Only a note with a button takes clicks; otherwise the days behind it stay clickable.
        if (note != null) Center(child: note),
      ],
    );
  }

  Widget _note({
    required IconData icon,
    required Color iconColor,
    required String title,
    String? message,
    (String, VoidCallback)? action,
  }) {
    return IgnorePointer(
      ignoring: action == null,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _line),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 30, color: iconColor),
            const SizedBox(height: 8),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: _ink, height: 1.3),
            ),
            if (message != null) ...[
              const SizedBox(height: 4),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: _slate, height: 1.35),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: () {
                  action.$2();
                  _refocus();
                },
                style: TextButton.styleFrom(foregroundColor: _accent, textStyle: _buttonText(context)),
                child: Text(action.$1),
              ),
            ] else
              const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Toolbar: navigation, period, filters and view in one row
  // ---------------------------------------------------------------------------

  Widget _toolbar() {
    // ‹ Today ›: one bordered group, as the dashboards' year selector groups its arrows with the year.
    const divider = SizedBox(height: 18, child: VerticalDivider(width: 1, thickness: 1, color: _grid));
    final nav = Container(
      height: _ctlH,
      // The border is drawn over the buttons, so they keep the full control height inside it.
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _grid),
      ),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ToolButton(
            tooltip: _view == _CalView.month ? 'Previous month (←)' : 'Previous week (←)',
            plain: true,
            width: _ctlH,
            onTap: () {
              _go(-1);
              _refocus();
            },
            child: const Icon(Icons.chevron_left_rounded, size: 22, color: _ink),
          ),
          divider,
          _ToolButton(
            tooltip: 'Jump to today (T)',
            label: 'Today',
            plain: true,
            onTap: () {
              _goToday();
              _refocus();
            },
            child: Text('Today', style: _buttonText(context).copyWith(color: _ink)),
          ),
          divider,
          _ToolButton(
            tooltip: _view == _CalView.month ? 'Next month (→)' : 'Next week (→)',
            plain: true,
            width: _ctlH,
            onTap: () {
              _go(1);
              _refocus();
            },
            child: const Icon(Icons.chevron_right_rounded, size: 22, color: _ink),
          ),
        ],
      ),
    );

    final title = Semantics(
      header: true,
      child: DashPressable(
        onTap: _pickDate,
        label: 'Jump to a date. Showing $_periodTitle',
        radius: BorderRadius.circular(8),
        builder: (hover) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.fromLTRB(8, 3, 4, 3),
          decoration: BoxDecoration(
            color: hover ? _faint : _faint.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(_periodTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: _titleStyle),
              ),
              const SizedBox(width: 2),
              Icon(Icons.expand_more_rounded, color: hover ? _slate : _muted),
            ],
          ),
        ),
      ),
    );

    final clear = _ToolButton(
      tooltip: 'Show every tech, status and type',
      label: 'Clear filters',
      quiet: true,
      plain: true,
      onTap: () {
        _clearFilters();
        _refocus();
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.filter_alt_off_outlined, size: 17, color: _slate),
          const SizedBox(width: 6),
          Text('Clear filters', style: _buttonText(context).copyWith(color: _slate)),
        ],
      ),
    );

    final filters = <Widget>[
      _techMenu(),
      _statusMenu(),
      _Segmented<_TypeFilter>(
        label: 'Show',
        options: const [(_TypeFilter.all, 'All'), (_TypeFilter.jobs, 'Jobs'), (_TypeFilter.estimates, 'Estimates')],
        value: _type,
        onChanged: (v) {
          setState(() => _type = v);
          _refocus();
        },
      ),
      _Segmented<_CalView>(
        label: 'View',
        options: const [(_CalView.month, 'Month'), (_CalView.week, 'Week')],
        value: _view,
        onChanged: (v) {
          _setView(v);
          _refocus();
        },
      ),
      _ToolButton(
        tooltip: 'Refresh',
        width: _ctlH,
        onTap: () {
          _reload();
          _refocus();
        },
        // Greyed while a load is on its way (a second press would do nothing).
        child: Icon(Icons.refresh_rounded, size: 19, color: _loading ? _muted : _slate),
      ),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth >= _oneRowWidth(context)) {
          // Everything on one line. "Clear filters" sits at the left of the right-aligned group, so showing or
          // hiding it never moves the controls the user is clicking.
          return Row(
            children: [
              nav,
              const SizedBox(width: 12),
              Flexible(
                child: Align(alignment: Alignment.centerLeft, child: title),
              ),
              const SizedBox(width: 12),
              if (_filtersActive) ...[clear, const SizedBox(width: 6)],
              for (var i = 0; i < filters.length; i++) ...[if (i > 0) const SizedBox(width: 8), filters[i]],
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                nav,
                const SizedBox(width: 8),
                Flexible(child: title),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [...filters, if (_filtersActive) clear],
            ),
          ],
        );
      },
    );
  }

  static const _titleStyle = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
    height: 1.3,
    color: _ink,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Width of one filter button: fixed, so ticking names never resizes it and shifts the open menu under it.
  static const _filterW = 150.0;

  /// How wide the toolbar must be to hold everything on one line at the current text size: the controls, the longest
  /// usual title for this view, and room for "Clear filters" whether it shows or not (so ticking a filter never
  /// flips the layout and moves the button under the pointer).
  double _oneRowWidth(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final base = DefaultTextStyle.of(context).style; // the app's font, as the Text widgets get it
    double w(String s, TextStyle style) => (TextPainter(
      text: TextSpan(text: s, style: base.merge(style)),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout()).width;
    final button = _buttonText(context);
    final seg = _Segmented.textStyle(true);
    double segW(List<String> labels) => 8 + labels.fold(0.0, (a, l) => a + w(l, seg) + 24);
    final nav = _ctlH * 2 + 2 + w('Today', button) + 24;
    final title = w(_view == _CalView.month ? 'September 2026' : 'Sep 27 – Oct 3, 2026', _titleStyle) + 12 + 24;
    final clear = 17 + 6 + w('Clear filters', button) + 20 + 6;
    final filters = _filterW * 2 + segW(['All', 'Jobs', 'Estimates']) + segW(['Month', 'Week']) + _ctlH + 8 * 4;
    return nav + 12 + title + 12 + clear + filters;
  }

  /// What a filter button shows: its icon, the current choice and an open/closed chevron.
  Widget _filterContent({required IconData icon, required String label, required bool active, required bool open}) {
    return Row(
      children: [
        Icon(icon, size: 18, color: active ? _ink : _slate),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: active ? FontWeight.w700 : FontWeight.w600,
              color: active ? _ink : _slate,
            ),
          ),
        ),
        const SizedBox(width: 2),
        Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18, color: _mutedText),
      ],
    );
  }

  Widget _techMenu() {
    final label = _techs.isEmpty ? 'All techs' : (_techs.length == 1 ? _techs.first : '${_techs.length} techs');
    return Theme(
      data: _blackChecks(context),
      child: MenuAnchor(
        onClose: _refocus,
        childFocusNode: _techButtonFocus,
        menuChildren: [
          MenuItemButton(
            onPressed: _techs.isEmpty
                ? null
                : () => setState(() {
                    _techs.clear();
                    _saveTechs();
                  }),
            child: const Text('All techs'),
          ),
          ..._allTechs.map(
            (t) => CheckboxMenuButton(
              closeOnActivate: false,
              value: _techs.contains(t),
              onChanged: (on) => setState(() {
                if (on == true) {
                  _techs.add(t);
                } else {
                  _techs.remove(t);
                }
                _saveTechs();
              }),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  t == _unassigned
                      ? const Icon(Icons.person_off_outlined, size: 22, color: _slate)
                      : _Initials(name: t, size: 22, color: _slate),
                  const SizedBox(width: 8),
                  Text(t),
                ],
              ),
            ),
          ),
        ],
        builder: (context, controller, _) => _ToolButton(
          tooltip: 'Filter by tech (select several)',
          label: 'Tech filter: $label',
          focusNode: _techButtonFocus,
          width: _filterW,
          active: _techs.isNotEmpty,
          onTap: () => controller.isOpen ? controller.close() : controller.open(),
          child: _filterContent(
            icon: Icons.person_outline_rounded,
            label: label,
            active: _techs.isNotEmpty,
            open: controller.isOpen,
          ),
        ),
      ),
    );
  }

  /// Status counts for the period on screen. Jobs and estimates keep separate lists, so "Scheduled" can appear in
  /// both.
  ({Map<String, int> counts, Map<String, String> labels}) _statusCounts() {
    final counts = <String, int>{};
    final labels = <String, String>{};
    for (var d = _visibleStart; d.isBefore(_visibleEnd); d = _addDays(d, 1)) {
      // The greyed days from the neighbouring months are not this month's, so they are not counted either.
      if (_view == _CalView.month && d.month != _focused.month) continue;
      for (final e in _eventsFor(d, ignoreStatus: true)) {
        counts[e.filterKey] = (counts[e.filterKey] ?? 0) + 1;
        labels[e.filterKey] = e.statusLabel;
      }
    }
    // A status picked earlier stays listed (at 0) after you move to a period without it, so the filter that is
    // hiding everything can always be switched off here.
    for (final k in _statusFilter) {
      counts.putIfAbsent(k, () => 0);
      labels.putIfAbsent(k, () => _titleCase(k.split('|').last));
    }
    return (counts: counts, labels: labels);
  }

  Widget _statusMenu() {
    final data = _statusCounts();
    final counts = data.counts, labels = data.labels;
    List<String> keysOf(String kind) =>
        counts.keys.where((k) => k.startsWith('$kind|')).toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));

    Widget heading(String text, {bool first = false}) => Padding(
      padding: EdgeInsets.fromLTRB(16, first ? 6 : 14, 16, 4),
      child: Text(
        text,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: _mutedText, letterSpacing: 0.8),
      ),
    );

    final children = <Widget>[];
    if (counts.isEmpty) {
      children.add(
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Nothing to filter in this period', style: TextStyle(fontSize: 13, color: _mutedText)),
        ),
      );
    } else {
      children.add(
        MenuItemButton(
          onPressed: _statusFilter.isEmpty ? null : () => setState(_statusFilter.clear),
          child: const Text('All statuses'),
        ),
      );
      var first = true;
      for (final g in [('JOB STATUS', 'job'), ('ESTIMATE STATUS', 'estimate')]) {
        final keys = keysOf(g.$2);
        if (keys.isEmpty) continue;
        children.add(heading(g.$1, first: first));
        first = false;
        for (final k in keys) {
          children.add(
            CheckboxMenuButton(
              closeOnActivate: false,
              value: _statusFilter.contains(k),
              onChanged: (_) => setState(() {
                if (!_statusFilter.remove(k)) _statusFilter.add(k);
              }),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 190),
                child: Row(
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: _toneFor(k.split('|').last, estimate: k.startsWith('estimate|')).color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(labels[k]!)),
                    const SizedBox(width: 12),
                    Text(
                      '${counts[k]}',
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: _slate),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
      }
    }

    final label = _statusFilter.isEmpty
        ? 'All statuses'
        : (_statusFilter.length == 1 ? (labels[_statusFilter.first] ?? 'Status') : '${_statusFilter.length} statuses');
    return Theme(
      data: _blackChecks(context),
      child: MenuAnchor(
        onClose: _refocus,
        childFocusNode: _statusButtonFocus,
        menuChildren: children,
        builder: (context, controller, _) => _ToolButton(
          tooltip: 'Filter by status (select several)',
          label: 'Status filter: $label',
          focusNode: _statusButtonFocus,
          width: _filterW,
          active: _statusFilter.isNotEmpty,
          onTap: () => controller.isOpen ? controller.close() : controller.open(),
          child: _filterContent(
            icon: Icons.filter_list_rounded,
            label: label,
            active: _statusFilter.isNotEmpty,
            open: controller.isOpen,
          ),
        ),
      ),
    );
  }

  /// A load failed while some or all of the period on screen is loaded: what is shown is real (maybe old), and the
  /// days the load did not reach say "Not loaded" themselves.
  Widget _errorBanner() {
    final red = _brand;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: red.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: red.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off_rounded, size: 18, color: red),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _covered
                  ? "Couldn't refresh the calendar. ${_error ?? ''} Showing the last loaded data."
                  : "Couldn't load all of $_periodTitle. ${_error ?? ''}",
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _ink),
            ),
          ),
          if (!_forbidden)
            TextButton(
              onPressed: _reload,
              style: TextButton.styleFrom(foregroundColor: _accent, textStyle: _buttonText(context)),
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }

  /// The 5-minute background refresh failed. Nothing was lost, but the schedule on screen may be out of date.
  Widget _staleBanner() {
    final at = _loadedAt == null ? '' : ' from ${DateFormat('h:mm a').format(_loadedAt!)}';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(color: _faint, borderRadius: BorderRadius.circular(10)),
      child: Row(
        children: [
          const Icon(Icons.sync_problem_rounded, size: 18, color: _slate),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              "Couldn't refresh in the background. Showing the schedule$at.",
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _slate),
            ),
          ),
          TextButton(
            onPressed: _reload,
            style: TextButton.styleFrom(foregroundColor: _accent, textStyle: _buttonText(context)),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Agenda (narrow screens)
  // ---------------------------------------------------------------------------

  Widget _agenda() {
    final days = <DateTime>[];
    for (var d = _visibleStart; d.isBefore(_visibleEnd); d = _addDays(d, 1)) {
      if (_view == _CalView.month && d.month != _focused.month) continue;
      if (_shownFor(d).isNotEmpty) days.add(d);
    }
    if (days.isEmpty) return const SizedBox.expand(); // _withStatus puts the "nothing scheduled" note over it

    // With today in this period the list opens on it (or on the next day with work, or the last one): a busy month
    // is dozens of screens long. The days before it are built upwards from there, a scroll up away, and Today comes
    // back to it. Otherwise the list starts at the top.
    final today = _dateOnly(_now());
    var split = 0;
    if (!today.isBefore(_visibleStart) && today.isBefore(_visibleEnd)) {
      final next = days.indexWhere((d) => !d.isBefore(today));
      split = next >= 0 ? next : days.length - 1;
    }
    const center = ValueKey('agenda-center');

    Widget dayBlock(DateTime day) {
      final events = _eventsFor(day);
      final isToday = _sameDay(day, _now());
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Row(
                children: [
                  _DayNumber(day: day.day, isToday: isToday, size: 32, fontSize: 15),
                  const SizedBox(width: 10),
                  Text(
                    DateFormat('EEEE, MMM d').format(day),
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: _ink),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${events.length} ${events.length == 1 ? 'event' : 'events'}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _mutedText),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            for (final e in events)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _EventCard(event: e, onTap: () => _openEvent(e)),
              ),
          ],
        ),
      );
    }

    return _VScroll(
      jumpTo: _wantToday ? 0 : null, // the centre: today's day
      onJumped: () => _wantToday = false,
      builder: (controller) => CustomScrollView(
        controller: controller,
        center: center,
        slivers: [
          // Laid out upwards from the centre, so the nearest earlier day comes first.
          SliverList.builder(itemCount: split, itemBuilder: (_, i) => dayBlock(days[split - 1 - i])),
          SliverPadding(
            key: center,
            padding: const EdgeInsets.only(bottom: 16),
            sliver: SliverList.builder(
              itemCount: days.length - split,
              itemBuilder: (_, i) => dayBlock(days[split + i]),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Month view
  // ---------------------------------------------------------------------------

  static const _minRowH = 104.0;
  static const _chipGap = 3.0;
  static const _dayHeaderH = 26.0;

  /// The events to draw on [day]: none while it is not loaded, where the day shows placeholders (loading) or says
  /// "Not loaded" (the load failed) instead.
  List<_CalEvent> _shownFor(DateTime day) => _dayLoaded(day) ? _eventsFor(day) : const [];

  /// A day the last load did not reach, while nothing is loading: said in the day itself, so it never reads as quiet.
  /// (When no day on screen loaded at all, the note over the grid says it once instead.)
  bool _notLoaded(DateTime day) => !_loading && _anyLoaded && !_dayLoaded(day);

  static const _notLoadedStyle = TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _mutedText);

  /// Weekday header stays put. Every event on a day is shown (never "+N more"): each week is as tall as its busiest
  /// day needs, and at least tall enough to fill the window, so a quiet month fits and a busy one scrolls. A busy
  /// month is several screens tall, so it opens (and Today returns) on the week with today in it.
  Widget _monthGrid() {
    const days = ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'];
    const headerH = 34.0;

    return LayoutBuilder(
      builder: (context, c) {
        final weeks = _weeksInGrid;
        final start = _gridStart;
        final twoLine = c.maxWidth / 7 >= 170; // roomy cells show the tech names under the customer
        // Chip and day-number heights follow the text size, so a larger system font is not clipped.
        final f = MediaQuery.textScalerOf(context).scale(14) / 14;
        final grow = f.clamp(1.0, 1.8);
        final chipH = (twoLine ? 36.0 : 22.0) * grow;
        final dayH = _dayHeaderH * grow;
        final fill = math.max(_minRowH, ((c.maxHeight - headerH) / weeks).floorToDouble());

        final heights = [
          for (var w = 0; w < weeks; w++)
            // top and bottom padding (4 + 3), the day number, then a chip and its gap per event
            math.max(
              fill,
              4 +
                  3 +
                  dayH +
                  [for (var d = 0; d < 7; d++) _shownFor(_addDays(start, w * 7 + d)).length].reduce(math.max) *
                      (chipH + _chipGap) +
                  2,
            ),
        ];

        // Where today's week starts, once the month is loaded with today in it.
        double? todayAt;
        // Whole days, rounded: across a daylight-saving change four weeks are 671 or 673 hours, not 672.
        final todayIndex = (_dateOnly(_now()).difference(start).inHours / 24).round();
        if (_wantToday && _covered && todayIndex >= 0 && todayIndex < weeks * 7) {
          todayAt = heights.take(todayIndex ~/ 7).fold<double>(0, (a, h) => a + h);
        }

        return Column(
          children: [
            Container(
              height: headerH,
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(bottom: BorderSide(color: _grid)),
              ),
              child: Row(
                children: [
                  for (var i = 0; i < 7; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: Align(
                          // Lined up with the day numbers under it.
                          alignment: Alignment.centerLeft,
                          child: Text(
                            days[i],
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              // Today's weekday in red, like its date below.
                              color: _covered && _now().weekday % 7 == i && _focused.month == _now().month
                                  ? _todayRed
                                  : _mutedText,
                              letterSpacing: 1.1,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              // The scrollbar stays visible whenever a busy month runs past the window, so it is clear there is more.
              child: _VScroll(
                jumpTo: todayAt,
                onJumped: () => _wantToday = false,
                builder: (controller) => SingleChildScrollView(
                  controller: controller,
                  child: Column(
                    children: [
                      for (var w = 0; w < weeks; w++)
                        SizedBox(
                          height: heights[w],
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var d = 0; d < 7; d++)
                                Expanded(
                                  child: _monthCell(
                                    _addDays(start, w * 7 + d),
                                    d == 6,
                                    twoLine: twoLine,
                                    chipH: chipH,
                                    dayH: dayH,
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _monthCell(DateTime day, bool lastCol, {required bool twoLine, required double chipH, required double dayH}) {
    final inMonth = day.month == _focused.month;
    final isToday = _sameDay(day, _now());
    final events = _shownFor(day);
    // This period is still on its way: faint placeholder bars (a different number per day) instead of empty days.
    final skeleton = _loading && !_dayLoaded(day);

    final weekend = day.weekday == DateTime.saturday || day.weekday == DateTime.sunday;
    final bg = isToday ? _todayBg : (!inMonth ? _otherMonthBg : (weekend ? _weekendBg : _cellBg));

    return Semantics(
      button: events.isNotEmpty,
      label:
          '${DateFormat('EEEE, MMMM d').format(day)}${isToday ? ', today' : ''}, '
          '${!_dayLoaded(day)
              ? 'not loaded'
              : events.isEmpty
              ? 'nothing scheduled'
              : '${events.length} ${events.length == 1 ? 'event' : 'events'}'}',
      child: Material(
        color: bg,
        child: InkWell(
          onTap: events.isEmpty ? null : () => _openDay(day), // an empty day has nothing to show
          hoverColor: events.isEmpty ? Colors.transparent : _ink.withValues(alpha: 0.035),
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                right: lastCol ? BorderSide.none : const BorderSide(color: _grid),
                bottom: const BorderSide(color: _grid),
              ),
            ),
            // Today: a red rule across the top of a white square. Painted over the cell, so it takes no layout room.
            foregroundDecoration: isToday
                ? const BoxDecoration(
                    border: Border(top: BorderSide(color: _todayRed, width: 2.5)),
                  )
                : null,
            padding: const EdgeInsets.fromLTRB(5, 4, 5, 3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: dayH,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _DayNumber(
                      day: day.day,
                      label: day.day == 1 ? '${DateFormat('MMM').format(day)} 1' : null,
                      isToday: isToday,
                      muted: !inMonth,
                      size: dayH - 4,
                      fontSize: 13.5,
                    ),
                  ),
                ),
                if (skeleton)
                  SkeletonPulse(
                    child: Column(
                      children: [
                        for (var i = 0; i < (day.day * 7 % 3); i++)
                          Container(
                            height: 14,
                            margin: const EdgeInsets.only(bottom: 4),
                            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6)),
                          ),
                      ],
                    ),
                  ),
                if (_notLoaded(day)) const Text('Not loaded', style: _notLoadedStyle),
                if (!skeleton)
                  for (final e in events)
                    Padding(
                      padding: const EdgeInsets.only(bottom: _chipGap),
                      child: SizedBox(
                        height: chipH,
                        child: _EventChip(
                          event: e,
                          twoLine: twoLine,
                          dimmed: !inMonth,
                          ambiguous: _ambiguous,
                          onTap: () => _openEvent(e),
                        ),
                      ),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Week view
  // ---------------------------------------------------------------------------

  Widget _weekGrid() {
    return LayoutBuilder(
      builder: (context, c) {
        final colW = math.max(140.0, c.maxWidth / 7); // seven days fit a 1280 window without sideways scrolling
        final start = _weekStart;
        final row = SizedBox(
          width: colW * 7,
          height: c.maxHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (var i = 0; i < 7; i++) Expanded(child: _weekColumn(_addDays(start, i), i == 6))],
          ),
        );
        if (colW * 7 > c.maxWidth + 0.5) {
          return SingleChildScrollView(scrollDirection: Axis.horizontal, child: row);
        }
        return row;
      },
    );
  }

  Widget _weekColumn(DateTime day, bool last) {
    final isToday = _sameDay(day, _now());
    final events = _shownFor(day);
    final pending = !_dayLoaded(day); // this week is still loading, or failed to: never "No events"
    final weekend = day.weekday == DateTime.saturday || day.weekday == DateTime.sunday;
    return Container(
      decoration: BoxDecoration(
        color: isToday ? _todayBg : (weekend ? _weekendBg : _cellBg),
        border: Border(right: last ? BorderSide.none : const BorderSide(color: _grid)),
      ),
      foregroundDecoration: isToday
          ? const BoxDecoration(
              border: Border(top: BorderSide(color: _todayRed, width: 2.5)),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: events.isNotEmpty,
            label:
                '${DateFormat('EEEE, MMMM d').format(day)}${isToday ? ', today' : ''}, '
                '${pending
                    ? 'not loaded'
                    : events.isEmpty
                    ? 'nothing scheduled'
                    : '${events.length} ${events.length == 1 ? 'event' : 'events'}'}',
            excludeSemantics: true,
            // The day's header is a white strip over the slate column (tinted for today), like a panel's title row.
            child: Material(
              color: Colors.white,
              child: InkWell(
                onTap: events.isEmpty ? null : () => _openDay(day),
                hoverColor: _ink.withValues(alpha: 0.035),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: _grid)),
                  ),
                  child: Row(
                    children: [
                      _DayNumber(day: day.day, isToday: isToday, size: 34, fontSize: 16, rounded: true),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              DateFormat('EEE').format(day).toUpperCase(),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: isToday ? _todayRed : _slate,
                                letterSpacing: 1.1,
                              ),
                            ),
                            Text(
                              _notLoaded(day)
                                  ? 'Not loaded'
                                  : pending
                                  ? ' '
                                  : events.isEmpty
                                  ? 'No events'
                                  : '${events.length} ${events.length == 1 ? 'event' : 'events'}',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _mutedText),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // An empty day says "No events" once, in its header; the column below is simply left quiet.
          Expanded(
            child: pending && _loading
                ? Padding(
                    padding: const EdgeInsets.all(10),
                    child: SkeletonPulse(
                      child: Column(
                        children: [
                          for (var i = 0; i < 1 + day.day % 3; i++)
                            Container(
                              height: 72,
                              margin: const EdgeInsets.only(bottom: 8),
                              decoration: BoxDecoration(color: _faint, borderRadius: BorderRadius.circular(10)),
                            ),
                        ],
                      ),
                    ),
                  )
                : events.isEmpty
                ? const SizedBox.expand()
                : ListView.separated(
                    padding: const EdgeInsets.all(10),
                    itemCount: events.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _EventCard(event: events[i], onTap: () => _openEvent(events[i])),
                  ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// EVENT WIDGETS
// =============================================================================

/// Compact chip for the month grid: one line (time + customer), or two (customer, then time and techs) in roomy cells.
class _EventChip extends StatefulWidget {
  final _CalEvent event;
  final bool twoLine;
  final bool dimmed; // days outside the focused month
  final Set<String> ambiguous; // first names shared by two techs, which get a last initial
  final VoidCallback onTap;
  const _EventChip({
    required this.event,
    required this.twoLine,
    required this.onTap,
    this.dimmed = false,
    this.ambiguous = const {},
  });

  @override
  State<_EventChip> createState() => _EventChipState();
}

class _EventChipState extends State<_EventChip> {
  bool _hover = false;

  _CalEvent get event => widget.event;
  bool get twoLine => widget.twoLine;

  @override
  Widget build(BuildContext context) {
    final st = _styleFor(event.color, dimmed: widget.dimmed);
    final techs = event.techs.isEmpty ? 'No tech' : event.shortTechs(widget.ambiguous);

    return _HoverPreview(
      event: event,
      // Hovered: the border firms up and the card lifts a hair off the day; no fill, so the column stays calm.
      child: Material(
        color: st.bg,
        elevation: _hover ? 1.5 : 0,
        shadowColor: _ink.withValues(alpha: 0.35),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: _hover ? _muted.withValues(alpha: 0.7) : st.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onTap,
          onHover: (h) => setState(() => _hover = h),
          hoverColor: Colors.transparent,
          focusColor: _accent.withValues(alpha: 0.1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusBar(color: st.bar, inset: twoLine ? 5 : 4),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, c) => Padding(
                    padding: const EdgeInsets.only(left: 6, right: 6),
                    // Phone-width cells are ~60px: just the name, the rest is in the tooltip and the day view.
                    child: _text(st, techs, micro: c.maxWidth < 96),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _text(_ChipStyle st, String techs, {required bool micro}) {
    final time = micro ? null : event.shortTime;
    return micro
        ? Align(
            alignment: Alignment.centerLeft,
            child: Text(
              event.customer,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: st.fg),
            ),
          )
        : twoLine
        ? Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      event.customer,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: st.fg,
                        height: 1.15,
                        letterSpacing: -0.1,
                      ),
                    ),
                  ),
                  if (event.isEstimate) ...[const SizedBox(width: 4), const _EstBadge(color: _mutedText)],
                ],
              ),
              const SizedBox(height: 1),
              Text(
                [event.timeLabel ?? 'All day', techs].join('  ·  '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: widget.dimmed ? _muted : _mutedText,
                  height: 1.2,
                ),
              ),
            ],
          )
        : Row(
            children: [
              if (time != null) ...[
                Text(
                  time,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _mutedText,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(
                  event.customer,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: st.fg),
                ),
              ),
              if (event.isEstimate) ...[const SizedBox(width: 4), const _EstBadge(color: _mutedText)],
            ],
          );
  }
}

/// The preview a month chip shows on hover: a white card on the overlay (so it is never clipped by its day or the
/// scroll area), customer first, then the status in its colour, when, and who. Its plain text is [_CalEvent.tooltip],
/// so screen readers hear exactly what they did before.
class _HoverPreview extends StatelessWidget {
  final _CalEvent event;
  final Widget child;
  const _HoverPreview({required this.event, required this.child});

  @override
  Widget build(BuildContext context) {
    final base = (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
      fontSize: 12.5,
      fontWeight: FontWeight.w500,
      color: _slate,
      height: 1.5,
    );
    return Tooltip(
      richMessage: TextSpan(
        children: [
          TextSpan(
            text: event.customer,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _ink, height: 1.35),
          ),
          TextSpan(
            text: '\n${event.statusLabel}${event.isEstimate ? ' (estimate)' : ''}',
            style: TextStyle(fontWeight: FontWeight.w700, color: event.tone.text),
          ),
          TextSpan(text: '\n${event.timeLabel ?? 'All day'}'),
          TextSpan(
            text: '\n${event.techs.isNotEmpty ? 'Techs: ${event.techs}' : 'No tech assigned'}',
            style: TextStyle(fontStyle: event.techs.isEmpty ? FontStyle.italic : null),
          ),
        ],
      ),
      textStyle: base,
      padding: const EdgeInsets.fromLTRB(14, 10, 16, 11),
      margin: const EdgeInsets.symmetric(horizontal: 12),
      verticalOffset: 18,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _line),
        boxShadow: [
          BoxShadow(color: _ink.withValues(alpha: 0.12), blurRadius: 18, offset: const Offset(0, 6)),
          BoxShadow(color: _ink.withValues(alpha: 0.06), blurRadius: 3, offset: const Offset(0, 1)),
        ],
      ),
      waitDuration: const Duration(milliseconds: 450),
      child: child,
    );
  }
}

/// Larger card used in the week view, the day dialog and the narrow-screen agenda. When first, then who, then the
/// status as a small dot and plain words (a solid, shouted pill cut off in narrow columns).
class _EventCard extends StatefulWidget {
  final _CalEvent event;
  final VoidCallback onTap;
  const _EventCard({required this.event, required this.onTap});

  @override
  State<_EventCard> createState() => _EventCardState();
}

class _EventCardState extends State<_EventCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final st = _styleFor(event.color);

    // Hover as on the month chips: a firmer border and a slight lift, never a fill.
    return Material(
      color: st.bg,
      elevation: _hover ? 2 : 0,
      shadowColor: _ink.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: _hover ? _muted.withValues(alpha: 0.7) : st.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onTap,
        onHover: (h) => setState(() => _hover = h),
        hoverColor: Colors.transparent,
        focusColor: _accent.withValues(alpha: 0.1),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusBar(color: st.bar, inset: 8, width: 4),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(9, 9, 10, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // When the visit is; all-day jobs say so, so every card answers "when" the same way.
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              event.timeLabel ?? 'All day',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: _mutedText,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                          if (event.isEstimate) ...[const SizedBox(width: 6), const _EstBadge(color: _mutedText)],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        event.customer,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: st.fg,
                          height: 1.25,
                          letterSpacing: -0.15,
                        ),
                      ),
                      const SizedBox(height: 7),
                      _StatusBadge(label: event.statusLabel, tone: event.tone),
                      const SizedBox(height: 8),
                      if (event.techs.isEmpty)
                        const Text(
                          'No tech assigned',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            fontStyle: FontStyle.italic,
                            color: _mutedText,
                          ),
                        )
                      else
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _InitialsStack(names: event.techList, color: _slate),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                event.techs,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: _slate,
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tech's initials in a small circle ("BH"), so who is on a job can be spotted at a glance.
class _Initials extends StatelessWidget {
  final String name;
  final double size;
  final Color color;
  const _Initials({required this.name, required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    final text = parts.isEmpty
        ? '?'
        : (parts.length == 1 ? parts.first[0] : parts.first[0] + parts.last[0]).toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 1.5),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: math.max(10, size * 0.45), fontWeight: FontWeight.w800, color: color, height: 1),
      ),
    );
  }
}

/// Overlapping initials for up to three techs, with "+N" for the rest.
class _InitialsStack extends StatelessWidget {
  final List<String> names;
  final Color color;
  const _InitialsStack({required this.names, required this.color});

  @override
  Widget build(BuildContext context) {
    const size = 24.0, step = 17.0;
    final shown = names.take(3).toList();
    final extra = names.length - shown.length;
    final count = shown.length + (extra > 0 ? 1 : 0);
    return ExcludeSemantics(
      child: SizedBox(
        width: size + step * (count - 1),
        height: size,
        child: Stack(
          children: [
            for (var i = 0; i < shown.length; i++)
              Positioned(
                left: i * step,
                child: _Initials(name: shown[i], size: size, color: color),
              ),
            if (extra > 0)
              Positioned(
                left: shown.length * step,
                child: Container(
                  width: size,
                  height: size,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: Text(
                    '+$extra',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: color, height: 1),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The day number. Today's is red on a soft red tag (a pill, or a rounded square in the week view), matched by the red
/// rule across the top of its day.
class _DayNumber extends StatelessWidget {
  final int day;
  final String? label; // "Oct 1" on the first of a month
  final bool isToday;
  final bool muted; // a day from the neighbouring month
  final double size;
  final double fontSize;
  final bool rounded;
  const _DayNumber({
    required this.day,
    required this.isToday,
    required this.size,
    required this.fontSize,
    this.label,
    this.muted = false,
    this.rounded = false,
  });

  @override
  Widget build(BuildContext context) {
    // Today is a soft red tag with a red number: found at a glance, without a heavy filled circle.
    final fg = isToday ? _todayRed : (muted ? _mutedText : _ink);
    return Container(
      constraints: BoxConstraints(minWidth: size),
      height: size,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: isToday ? _todayRed.withValues(alpha: 0.09) : (rounded ? _faint : null),
        borderRadius: BorderRadius.circular(rounded ? 9 : size / 2),
      ),
      child: Center(
        widthFactor: 1,
        child: FittedBox(
          fit: BoxFit.scaleDown, // "Oct 1" must shrink, not overflow, in phone-width cells
          child: Text(
            label ?? '$day',
            maxLines: 1,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: isToday ? FontWeight.w800 : FontWeight.w600,
              color: fg,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}

/// A vertical scroll area with an always-visible scrollbar. It owns its controller, so two of them can exist at once
/// while the grid cross-fades between months. Given [jumpTo], it scrolls there after the frame (as far as the content
/// allows) and reports it with [onJumped], so the request is used once.
class _VScroll extends StatefulWidget {
  final Widget Function(ScrollController controller) builder;
  final double? jumpTo;
  final VoidCallback? onJumped;
  const _VScroll({required this.builder, this.jumpTo, this.onJumped});

  @override
  State<_VScroll> createState() => _VScrollState();
}

class _VScrollState extends State<_VScroll> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _scheduleJump();
  }

  @override
  void didUpdateWidget(_VScroll old) {
    super.didUpdateWidget(old);
    _scheduleJump();
  }

  void _scheduleJump() {
    final to = widget.jumpTo;
    if (to == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      _controller.jumpTo(to.clamp(0.0, _controller.position.maxScrollExtent));
      widget.onJumped?.call();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(controller: _controller, thumbVisibility: true, child: widget.builder(_controller));
  }
}

/// The status colour down the left edge of an event card: a short rounded bar set in from the edges.
class _StatusBar extends StatelessWidget {
  final Color color;
  final double inset; // gap above and below
  final double width;
  const _StatusBar({required this.color, required this.inset, this.width = 3});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      margin: EdgeInsets.fromLTRB(4, inset, 0, inset),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(width)),
    );
  }
}

/// A status as the design system draws one: a tinted pill, a dot in the status colour and the name in dark text
/// (several status colours are too light to read as text).
class _StatusBadge extends StatelessWidget {
  final String label;
  final _Tone tone;
  const _StatusBadge({required this.label, required this.tone});

  @override
  Widget build(BuildContext context) {
    final color = tone.color;
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 2, 9, 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.09), borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: tone.text, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}

class _EstBadge extends StatelessWidget {
  final Color color;
  const _EstBadge({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'EST',
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: color, letterSpacing: 0.4, height: 1.2),
      ),
    );
  }
}

// =============================================================================
// EVENT DETAILS DIALOG
// =============================================================================

class _EventDetails extends StatelessWidget {
  final _CalEvent event;
  final VoidCallback onClose;
  const _EventDetails({required this.event, required this.onClose});

  static const _known = {'event_date', 'status', 'is_estimate', 'customer_name', 'techs', 'job_number'};

  /// Fields that are shown properly elsewhere in the dialog (the time) or are only ids and timestamps.
  static final _internal = RegExp(
    r'(^|_)(id|ids|uuid)$|^time_(start|end)$|(^|_)(created|updated|synced)(_at)?$|^raw',
    caseSensitive: false,
  );

  static String _prettyKey(String k) => _titleCase(k.replaceAll(RegExp(r'[_\-]+'), ' ').trim());

  @override
  Widget build(BuildContext context) {
    final c = event.color;

    final extras = <MapEntry<String, String>>[];
    event.raw.forEach((k, v) {
      if (_known.contains(k) || v == null || v is Map || v is List) return;
      if (_internal.hasMatch(k)) return; // ids, raw time columns and bookkeeping are not for people
      final s = v.toString().trim();
      if (s.isEmpty) return;
      extras.add(MapEntry(_prettyKey(k), s));
    });

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A thin strip in the status colour, then a plain header: a full block of lime or pink was garish.
        Container(height: 6, color: c),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: c.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          event.statusLabel,
                          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: _ink),
                        ),
                      ],
                    ),
                  ),
                  if (event.isEstimate) ...[const SizedBox(width: 8), const _EstBadge(color: _slate)],
                ],
              ),
              const SizedBox(height: 12),
              Text(
                event.customer,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: _ink, height: 1.15),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: _line),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DetailRow(
                  icon: Icons.event_rounded,
                  label: 'Date',
                  value: DateFormat('EEEE, MMMM d, y').format(event.day),
                ),
                _DetailRow(icon: Icons.schedule_rounded, label: 'Time', value: event.timeLabel ?? 'All day'),
                _DetailRow(
                  icon: Icons.assignment_outlined,
                  label: 'Type',
                  value: event.isEstimate ? 'Estimate' : 'Job',
                ),
                _DetailRow(
                  icon: Icons.engineering_outlined,
                  label: event.techList.length > 1 ? 'Techs' : 'Tech',
                  value: event.techs.isEmpty ? 'Unassigned' : event.techs,
                ),
                for (final x in extras) _DetailRow(icon: Icons.notes_rounded, label: x.key, value: x.value),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: onClose, child: const Text('Close')),
          ),
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _DetailRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 30, child: Icon(icon, size: 18, color: _muted)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: _mutedText,
                    letterSpacing: 0.7,
                  ),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  value,
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: _ink),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// CONTROLS
// =============================================================================

/// A toolbar button built like the dashboards' controls (DashPressable): one height, a hover shade, the blue ring for
/// keyboard focus only, and a single screen-reader button. White with a hairline border by default; [quiet] is a grey
/// fill without a border (the ‹ › arrows), [plain] has no fill until hovered (Clear filters), and [active] marks a
/// filter that is narrowing the calendar.
class _ToolButton extends StatelessWidget {
  final String tooltip;
  final String? label; // read by screen readers; the tooltip when not given
  final VoidCallback onTap;
  final Widget child;
  final double? width;
  final bool active;
  final bool quiet;
  final bool plain;
  final FocusNode? focusNode;
  const _ToolButton({
    required this.tooltip,
    required this.onTap,
    required this.child,
    this.label,
    this.width,
    this.active = false,
    this.quiet = false,
    this.plain = false,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(8);
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true, // the button already has its name
      waitDuration: const Duration(milliseconds: 400),
      child: DashPressable(
        onTap: onTap,
        label: label ?? tooltip,
        focusNode: focusNode,
        radius: radius,
        builder: (hover) {
          final Color fill;
          final Color border;
          if (plain) {
            fill = hover ? _faint : _faint.withValues(alpha: 0);
            border = Colors.transparent;
          } else if (quiet) {
            fill = hover ? _line : _faint;
            border = Colors.transparent;
          } else {
            // Every bordered control shares one border; an active filter takes the navy edge and a soft fill.
            fill = active ? _faintLight : (hover ? _faintLight : Colors.white);
            border = active ? _ink.withValues(alpha: 0.55) : (hover ? _muted : _grid);
          }
          return AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: width,
            height: _ctlH,
            padding: width == _ctlH ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: radius,
              border: Border.all(color: border),
            ),
            // widthFactor: as wide as the label (an `alignment` would stretch the button across a Wrap's whole run).
            child: Center(widthFactor: 1, child: child),
          );
        },
      ),
    );
  }
}

/// A row of choices with one selected, styled as the dashboards' DashSegmented (the selected one white, its label in
/// dark ink) at the toolbar's height. Each choice is a button reachable with Tab; screen readers hear
/// "[label]: Month, selected".
class _Segmented<T> extends StatelessWidget {
  final String label;
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;
  const _Segmented({required this.label, required this.options, required this.value, required this.onChanged});

  static TextStyle textStyle(bool on) => TextStyle(
    fontSize: 12.5,
    height: 1.3,
    fontWeight: on ? FontWeight.w700 : FontWeight.w600,
    color: on ? _accent : _slate,
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _ctlH,
      padding: const EdgeInsets.all(3),
      // The same border as the buttons beside it, so the whole toolbar reads as one set of controls.
      decoration: BoxDecoration(
        color: _faint,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _grid),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final o in options)
            DashPressable(
              onTap: o.$1 == value ? () {} : () => onChanged(o.$1),
              label: '$label: ${o.$2}',
              selected: o.$1 == value,
              radius: BorderRadius.circular(6),
              builder: (hover) {
                final on = o.$1 == value;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: on
                        ? Colors.white
                        : (hover ? Colors.white.withValues(alpha: 0.6) : Colors.white.withValues(alpha: 0)),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: on ? _grid : _grid.withValues(alpha: 0)),
                    boxShadow: [
                      BoxShadow(
                        color: _ink.withValues(alpha: on ? 0.08 : 0),
                        blurRadius: 2,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  child: Text(o.$2, maxLines: 1, style: textStyle(on)),
                );
              },
            ),
        ],
      ),
    );
  }
}
