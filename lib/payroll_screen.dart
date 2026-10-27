import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'payroll_history_dialog.dart';
import 'payroll_pending_panel.dart';
import 'payroll_run_dialog.dart';
import 'widgets/dashboard_kit.dart';

part 'payroll_pdf.dart';

// ---------------------------------------------------------------------------
// Payroll: commission detail by pay week (office use).
//
// Built on the same pieces as the finished dashboards (DashUi, AnimatedMetricCard and DashAvatar from
// dashboard_kit.dart), without the dashboard header bar: the page name already lives in the app navigation.
//
// Click any scorecard to see every log behind that number for the dates. Export PDF writes every
// technician's breakdown.
//
// Pick dates, then pick "Everyone" for a one-line-per-person register, or a technician for the
// full breakdown: every pay week, every closed job, every commission line item, the 1% company
// pool, commercial retainage, advances, callbacks and the weekly hurdle.
//
// Data: GET /api/payroll/commission-detail. Pay weeks run Monday to Sunday, so the server widens
// any range to whole pay weeks and reports the dates it used. This screen only reports. It does
// not record or pay a payroll run.
// ---------------------------------------------------------------------------

// Tints are built from the DashUi tokens, so a palette change reaches this screen too.
final Color _goodBg = DashUi.emeraldDeep.withValues(alpha: 0.08);
final Color _goodBorder = DashUi.emeraldDeep.withValues(alpha: 0.3);
final Color _badBg = DashUi.red.withValues(alpha: 0.08);
final Color _badBorder = DashUi.red.withValues(alpha: 0.3);

const List<FontFeature> _figures = [FontFeature.tabularFigures()];

/// A section of the page: no card, just a hairline under it.
const BoxDecoration _flat = BoxDecoration(
  border: Border(bottom: BorderSide(color: DashUi.line)),
);

double _d(dynamic v) {
  if (v is num) return v.toDouble();
  return double.tryParse(v?.toString() ?? '') ?? 0.0;
}

String _s(dynamic v) => v?.toString() ?? '';

Color _cashColor(double v) =>
    v < 0 ? DashUi.red : (v > 0 ? DashUi.emeraldText : DashUi.subtle);

/// Payroll runs asked for at once (the server's maximum).
const int _runsLimit = 200;

/// How many log entries show before "Show more". A year of closed jobs is thousands of rows, and building them all at
/// once took over a second.
const int _logPage = 100;

String _fmt(double v) => dashMoney(v.abs() < 0.005 ? 0 : v);

String _pct(double v) {
  final whole = v == v.roundToDouble();
  return '${v.toStringAsFixed(whole ? 0 : 2)}%';
}

DateTime? _parseDay(String? iso) {
  if (iso == null || iso.length < 10) return null;
  return DateTime.tryParse(iso.substring(0, 10));
}

String _day(String? iso, {bool year = false}) {
  final d = _parseDay(iso);
  if (d == null) return '';
  return DateFormat(year ? 'MMM d, yyyy' : 'MMM d').format(d);
}

// Calendar math on dates (never add a Duration to a local date: daylight saving breaks it).
DateTime _addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

int _daysBetween(DateTime a, DateTime b) => DateTime.utc(
  b.year,
  b.month,
  b.day,
).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

String _ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

DateTime _today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

class _Line {
  final String name;
  final String category;
  final bool isPool;
  final double jobAmount;
  final double techShare;

  _Line(Map<String, dynamic> j)
    : name = _s(j['name']),
      category = _s(j['category']),
      isPool = j['kind'] == 'company_pool',
      jobAmount = _d(j['jobAmount']),
      techShare = _d(j['techShare']);
}

class _Job {
  final String jobId;
  final String customer;
  final String status;
  final String closedOn;
  final String firstWorked;
  final String lastWorked;
  final int daysWorked;
  final double jobRevenue;
  final double splitPct;
  final double adjustment;

  /// Everything the sync sent to the company pool from this job (the 1% only), whoever's statement it is on.
  final double toCompanyPool;

  /// Everyone who worked the job, including people who are in the split but not on payroll.
  final List<String> workers;
  final double share;
  final double retainage;
  final double advancesRepaid;
  final double net;
  final List<_Line> lines;

  _Job(Map<String, dynamic> j)
    : jobId = _s(j['jobId']),
      customer = _s(j['customer']),
      status = _s(j['status']),
      closedOn = _s(j['closedOn']),
      firstWorked = _s(j['firstWorked']),
      lastWorked = _s(j['lastWorked']),
      daysWorked = _d(j['daysWorked']).round(),
      jobRevenue = _d(j['jobRevenue']),
      splitPct = _d(j['splitPct']),
      adjustment = _d(j['adjustment']),
      toCompanyPool = _d(j['toCompanyPool']),
      workers = ((j['workers'] as List?) ?? const [])
          .map((e) => _s(e))
          .where((e) => e.isNotEmpty)
          .toList(),
      share = _d(j['share']),
      retainage = _d(j['retainage']),
      advancesRepaid = _d(j['advancesRepaid']),
      net = _d(j['net']),
      lines = ((j['lines'] as List?) ?? const [])
          .map((e) => _Line(Map<String, dynamic>.from(e as Map)))
          .toList();

  /// The job's whole commission pool before the tech split: every line, with the company pool taken off.
  double get poolTotal => lines.fold(0.0, (sum, l) => sum + l.jobAmount);
}

class _DayItem {
  final String jobId;
  final String customer;
  final String date;
  final double amount;

  _DayItem(Map<String, dynamic> j)
    : jobId = _s(j['jobId']),
      customer = _s(j['customer']),
      date = _s(j['date']),
      amount = _d(j['amount']);
}

/// A Won estimate a sales rep is paid on: labor x rate, in the week the estimate became Won.
class _RepItem {
  final String jobId;
  final String customer;
  final String wonOn;
  final String closedOn;
  final String basisLabel;
  final double labor;
  final double ratePct;
  final double amount;

  _RepItem(Map<String, dynamic> j)
    : jobId = _s(j['jobId']),
      customer = _s(j['customer']),
      wonOn = _s(j['wonOn']),
      closedOn = _s(j['closedOn']),
      basisLabel = _s(j['basisLabel']),
      labor = _d(j['labor']),
      ratePct = _d(j['ratePct']),
      amount = _d(j['amount']);
}

class _Week {
  final String weekStart;
  final String weekEnd;
  final double jobNet;
  final double advancesPaid;
  final double callbackPay;
  final double repPay;
  final double otherAdjustments;
  final double weeklyGross;
  final double hurdleApplied;
  final double hurdleRule;
  final double hurdleCredit; // retainage held this week; counts toward the hurdle but is not paid
  final double cashPay;
  final double advanceShortfall;
  final double advanceRecovered; // shortfall taken out of this week's other pay
  final List<_Job> jobs;
  final List<_DayItem> advances;
  final List<_DayItem> callbacks;
  final List<_RepItem> repCommissions;

  _Week(Map<String, dynamic> j)
    : weekStart = _s(j['weekStart']),
      weekEnd = _s(j['weekEnd']),
      jobNet = _d(j['jobNet']),
      advancesPaid = _d(j['advancesPaid']),
      callbackPay = _d(j['callbackPay']),
      repPay = _d(j['repPay']),
      otherAdjustments = _d(j['otherAdjustments']),
      weeklyGross = _d(j['weeklyGross']),
      hurdleApplied = _d(j['hurdleApplied']),
      hurdleRule = _d(j['hurdleRule']),
      hurdleCredit = _d(j['hurdleCredit']),
      cashPay = _d(j['cashPay']),
      advanceShortfall = _d(j['advanceShortfall']),
      advanceRecovered = _d(j['advanceRecovered']),
      jobs = ((j['jobs'] as List?) ?? const [])
          .map((e) => _Job(Map<String, dynamic>.from(e as Map)))
          .toList(),
      advances = ((j['advances'] as List?) ?? const [])
          .map((e) => _DayItem(Map<String, dynamic>.from(e as Map)))
          .toList(),
      callbacks = ((j['callbacks'] as List?) ?? const [])
          .map((e) => _DayItem(Map<String, dynamic>.from(e as Map)))
          .toList(),
      repCommissions = ((j['repCommissions'] as List?) ?? const [])
          .map((e) => _RepItem(Map<String, dynamic>.from(e as Map)))
          .toList();
}

class _Release {
  final String jobId;
  final String type;
  final double amount;
  final String releasedOn;

  _Release(Map<String, dynamic> j)
    : jobId = _s(j['jobId']),
      type = _s(j['type']),
      amount = _d(j['amount']),
      releasedOn = _s(j['releasedOn']);
}

class _Totals {
  final double companyPool;
  final double retainage;
  final double advancesPaid;
  final double callbackPay;
  final double weeklyGross;
  final double hurdleApplied;
  final double cashPay;
  final double retainageReleased;
  final double totalDue;

  _Totals(Map<String, dynamic> j)
    : companyPool = _d(j['companyPool']),
      retainage = _d(j['retainage']),
      advancesPaid = _d(j['advancesPaid']),
      callbackPay = _d(j['callbackPay']),
      weeklyGross = _d(j['weeklyGross']),
      hurdleApplied = _d(j['hurdleApplied']),
      cashPay = _d(j['cashPay']),
      retainageReleased = _d(j['retainageReleased']),
      totalDue = _d(j['totalDue']);
}

class _Tech {
  final int userId;
  final String name;
  final String role;
  final String imageUrl;
  final bool isSales;
  final bool isCallbackOnly;
  final _Totals totals;
  final List<_Week> weeks;
  final List<_Release> releases;

  _Tech(Map<String, dynamic> j)
    : userId = _d(j['userId']).round(),
      name = _s(j['name']),
      role = _s(j['role']),
      imageUrl = _s(j['imageUrl']),
      isSales = j['isSales'] == true,
      isCallbackOnly = j['isCallbackOnly'] == true,
      totals = _Totals(
        Map<String, dynamic>.from((j['totals'] as Map?) ?? const {}),
      ),
      weeks = ((j['weeks'] as List?) ?? const [])
          .map((e) => _Week(Map<String, dynamic>.from(e as Map)))
          .toList(),
      releases = ((j['retainageReleases'] as List?) ?? const [])
          .map((e) => _Release(Map<String, dynamic>.from(e as Map)))
          .toList();

  int get jobCount => weeks.fold<int>(0, (n, w) => n + w.jobs.length);

  double get jobNet => weeks.fold<double>(0, (s, w) => s + w.jobNet);

  /// Sales commission across the weeks. The server's totals don't carry it, so it is summed from the weeks.
  double get repPay => weeks.fold<double>(0, (s, w) => s + w.repPay);

  String get kindLabel {
    // A rep who also gets callback pay is still a rep; check sales before callback-only.
    if (isSales || repPay != 0) return 'Sales';
    if (isCallbackOnly) return 'Callback pay only';
    return role;
  }

  /// True when any pay week finished under its weekly hurdle, so no cash pay was earned for it.
  bool get underHurdle =>
      weeks.any((w) => w.hurdleRule > 0 && w.weeklyGross < w.hurdleRule);
}

class _Report {
  final String start;
  final String end;
  final double weeklyThreshold;
  final double dailyAdvance;
  final double callbackPay;
  final double companyPoolRate;
  final double retainageRate;
  final List<_Tech> techs;

  _Report(Map<String, dynamic> j)
    : start = _s((j['range'] as Map?)?['start']),
      end = _s((j['range'] as Map?)?['end']),
      weeklyThreshold = _d((j['rules'] as Map?)?['weeklyThreshold']),
      dailyAdvance = _d((j['rules'] as Map?)?['dailyAdvance']),
      callbackPay = _d((j['rules'] as Map?)?['callbackPay']),
      companyPoolRate = _d((j['rules'] as Map?)?['companyPoolRate']),
      retainageRate = _d((j['rules'] as Map?)?['retainageRate']),
      techs = ((j['techs'] as List?) ?? const [])
          .map((e) => _Tech(Map<String, dynamic>.from(e as Map)))
          .toList();
}

/// A finalized payroll run for one pay week (from GET /api/payroll/runs). Weeks can have several runs when late
/// corrections are paid as adjustments; [count] is how many are still in effect.
class _WeekRun {
  final int id;
  final int count;
  final DateTime? at;
  final double paid;

  const _WeekRun(this.id, this.count, this.at, this.paid);
}

class _Opt {
  final String key;
  final String label;
  const _Opt(this.key, this.label);
}

/// A figure column in the payroll register.
class _RegCol {
  final String head;
  final double Function(_Tech) value;
  final bool count; // a whole number (jobs), not money
  const _RegCol(this.head, this.value, {this.count = false});
}

/// The scorecards that open a log of the entries behind their number.
enum _Metric {
  totalDue(
    'Total Due',
    'Weekly cash pay and retainage released',
    DashUi.emeraldDeep,
  ),
  commission(
    'Closed-Job Commission',
    'Net to the tech from every closed job',
    DashUi.ink,
  ),
  retainage(
    'Retainage Held',
    'Commercial retainage held back on closed jobs',
    DashUi.indigo,
  ),
  pool(
    'Company Pool',
    'Pool contribution taken from each closed job',
    DashUi.slate,
  ),
  sales('Sales Commission', 'Percent of labor on won estimates', DashUi.indigo),
  advCallbacks(
    'Advances & Callbacks',
    'Flat advance days and callback pay',
    DashUi.amber,
  );

  final String label;
  final String blurb;
  final Color color;
  const _Metric(this.label, this.blurb, this.color);
}

class _LogRow {
  final String date;
  final String tech;
  final String title;
  final String detail;
  final double amount;
  const _LogRow(this.date, this.tech, this.title, this.detail, this.amount);
}

const List<_Opt> _kPresets = [
  _Opt('thisWeek', 'This Week'),
  _Opt('lastWeek', 'Last Week'),
  _Opt('thisMonth', 'This Month'),
  _Opt('lastMonth', 'Last Month'),
  _Opt('ytd', 'Year to Date'),
  _Opt('custom', 'Custom'),
  _Opt(
    'pending',
    'Pending',
  ), // its own tab: the projected commission on jobs not closed yet
];

DateTimeRange _rangeFor(String key) {
  final t = _today();
  final monday = _addDays(t, -(t.weekday - 1));
  switch (key) {
    case 'thisWeek':
      return DateTimeRange(start: monday, end: _addDays(monday, 6));
    case 'last2':
      return DateTimeRange(
        start: _addDays(monday, -14),
        end: _addDays(monday, -1),
      );
    case 'thisMonth':
      return DateTimeRange(start: DateTime(t.year, t.month, 1), end: t);
    case 'lastMonth':
      return DateTimeRange(
        start: DateTime(t.year, t.month - 1, 1),
        end: DateTime(t.year, t.month, 0),
      );
    case 'ytd':
      return DateTimeRange(start: DateTime(t.year, 1, 1), end: t);
    default:
      return DateTimeRange(
        start: _addDays(monday, -7),
        end: _addDays(monday, -1),
      );
  }
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class PayrollScreen extends StatefulWidget {
  /// Optional starting view, so a link (`/hr/payroll?start=2026-10-05&end=2026-10-11&tech=12`) opens exactly what the
  /// sender was looking at. The screen keeps the address bar in step with the dates and person it shows.
  final String? initialStart;
  final String? initialEnd;
  final String? initialTech;

  const PayrollScreen({
    super.key,
    this.initialStart,
    this.initialEnd,
    this.initialTech,
  });

  @override
  State<PayrollScreen> createState() => _PayrollScreenState();
}

class _PayrollScreenState extends State<PayrollScreen> {
  late DateTimeRange _range = _initialRange();
  _Report? _report;
  bool _loading = true; // the first load starts right after the first frame; don't flash "No report yet"
  String? _error;
  int _requestId = 0;
  int _pendingRefresh =
      0; // bumped after a payroll run so the pending panel reloads
  bool _sortByDue =
      false; // register order: false = by name, true = biggest Total Due first
  Map<String, _WeekRun> _runs =
      const {}; // latest finalized payroll run per pay-week start (yyyy-MM-dd)
  // The run list is capped at [_runsLimit]. When a full page comes back, older runs may exist that it didn't include,
  // so weeks before this one (yyyy-MM-dd) have an unknown status rather than "Not run yet". Null = complete history.
  String? _runsKnownFrom;
  late int? _selectedId = int.tryParse(
    widget.initialTech ?? '',
  ); // null = everyone (the register)
  _Metric? _metric; // scorecard whose log is open
  bool _exporting = false;
  bool _showPending = false; // the Pending commission tab is open (instead of a pay-week report)
  String? _weekStart; // which pay week is open for the selected technician
  final Set<String> _expandedJobs =
      {}; // closed-job cards the user has opened (collapsed by default)
  int _logLimit = _logPage; // log entries shown; "Show more" raises it
  bool _forbidden =
      false; // the last load was refused (403): retrying cannot help
  bool _slow = false; // the first load has taken long enough to say the server may be waking up
  Timer? _slowTimer;
  final ValueNotifier<int?> _regHover = ValueNotifier(
    null,
  ); // register row under the mouse or keyboard focus
  final ScrollController _regScroll =
      ScrollController(); // the register's middle columns on narrow windows
  final ScrollController _weekScroll = ScrollController(); // the pay-week strip
  String? _weekRevealed; // the strip already brought this tech/week into view; don't fight the user's scrolling

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    _regHover.dispose();
    _regScroll.dispose();
    _weekScroll.dispose();
    super.dispose();
  }

  // ---- Range ---------------------------------------------------------------

  DateTimeRange _initialRange() {
    final a = _parseDay(widget.initialStart);
    final b = _parseDay(widget.initialEnd);
    if (a != null && b != null && !b.isBefore(a))
      return DateTimeRange(start: a, end: b);
    return _rangeFor('lastWeek');
  }

  /// Mirrors the dates and person into the address bar (replacing, so Back does not step through every click).
  void _syncUrl() {
    final router = GoRouter.maybeOf(context);
    if (router == null) return;
    // /hr/kpis, /hr/team and /hr/corrections are stacked above this screen, which stays mounted underneath. A
    // late load finishing there must not rewrite the address and yank the user back to Payroll.
    if (router.routeInformationProvider.value.uri.path != '/hr/payroll') return;
    final uri = Uri(
      path: '/hr/payroll',
      queryParameters: {
        'start': _ymd(_range.start),
        'end': _ymd(_range.end),
        if (_selectedId != null) 'tech': '$_selectedId',
      },
    );
    if (router.routeInformationProvider.value.uri.toString() != uri.toString())
      router.replace(uri.toString());
  }

  DateTimeRange get _shownRange {
    return _range;
  }

  String get _activeKey {
    for (final p in _kPresets) {
      if (p.key == 'custom' || p.key == 'pending') continue;
      final r = _rangeFor(p.key);
      if (r.start == _range.start && r.end == _range.end) return p.key;
    }
    return 'custom';
  }

  bool get _canStep =>
      _range.start.weekday == DateTime.monday &&
      (_daysBetween(_range.start, _range.end) + 1) % 7 == 0;

  void _step(int dir) {
    if (!_canStep) return;
    final days = _daysBetween(_range.start, _range.end) + 1;
    setState(() {
      _range = DateTimeRange(
        start: _addDays(_range.start, dir * days),
        end: _addDays(_range.end, dir * days),
      );
    });
    _load();
  }

  Future<void> _selectPreset(String key) async {
    if (key == 'pending') {
      setState(() => _showPending = true);
      return;
    }
    if (key == 'custom') {
      await _pickCustom();
      return;
    }
    setState(() {
      _showPending = false;
      _range = _rangeFor(key);
    });
    _load();
  }

  Future<void> _pickCustom() async {
    // The arrows can step past today + 30 days; the picker asserts if the current range is outside its bounds.
    final limit = _addDays(_today(), 30);
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: _range,
      firstDate: _range.start.isBefore(DateTime(2020))
          ? _range.start
          : DateTime(2020),
      lastDate: _range.end.isAfter(limit) ? _range.end : limit,
      builder: (context, child) => Theme(
        data: ThemeData.light().copyWith(
          colorScheme: const ColorScheme.light(
            primary: DashUi.ink,
            onPrimary: Colors.white,
            surface: Colors.white,
            onSurface: DashUi.ink,
          ),
        ),
        child: child!,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _showPending = false;
      _range = picked;
    });
    _load();
  }

  // ---- Data ----------------------------------------------------------------

  void _selectTech(int? id) => setState(() {
    _selectedId = id;
    _weekStart = null;
    _regHover.value =
        null; // the row that was clicked never gets its mouse-exit
    _metric = null;
    _logLimit = _logPage;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncUrl();
    });
  });

  void _toggleMetric(_Metric m) => setState(() {
    _metric = _metric == m ? null : m;
    _logLimit = _logPage;
  });

  /// Which pay weeks already have a finalized payroll run. Best effort: if it fails the report still works and the
  /// weeks simply show no paid status.
  Future<void> _loadRuns() async {
    try {
      final res = await http
          .get(
            Uri.parse('$kApiBaseUrl/api/payroll/runs')
                .replace(queryParameters: {'limit': '$_runsLimit'}),
            headers: AuthSession.instance.headers(),
          )
          .timeout(const Duration(seconds: 60));
      if (!mounted || res.statusCode != 200) return;
      final body = json.decode(res.body);
      final byWeek = <String, List<Map<String, dynamic>>>{};
      final all = (body is Map ? body['runs'] as List? : null) ?? const [];
      String? oldest;
      for (final r in all) {
        final m = Map<String, dynamic>.from(r as Map);
        final week = _s(m['week_start']);
        if (week.length >= 10 &&
            (oldest == null || week.substring(0, 10).compareTo(oldest) < 0)) {
          oldest = week.substring(0, 10);
        }
        if (_s(m['status']) == 'voided') continue;
        final key = week;
        if (key.length >= 10) (byWeek[key.substring(0, 10)] ??= []).add(m);
      }
      final runs = <String, _WeekRun>{};
      byWeek.forEach((week, list) {
        list.sort((a, b) => _d(b['id']).compareTo(_d(a['id'])));
        final latest = list.first;
        runs[week] = _WeekRun(
          _d(latest['id']).round(),
          list.length,
          DateTime.tryParse(_s(latest['created_at']))?.toLocal(),
          list.fold<double>(0, (s, m) => s + _d(m['total_amount_paid'])),
        );
      });
      if (mounted) {
        setState(() {
          _runs = runs;
          _runsKnownFrom = all.length >= _runsLimit ? oldest : null;
        });
      }
    } catch (_) {
      // Leave the previous statuses; the report itself does not depend on them.
    }
  }

  /// "Paid", "Not run yet" or null (week still in progress or status unknown) for one pay week.
  ({String label, Color color})? _weekStatus(_Week w) {
    final run =
        _runs[w.weekStart.length >= 10
            ? w.weekStart.substring(0, 10)
            : w.weekStart];
    if (run != null) {
      final when = run.at == null
          ? ''
          : ' · ${DateFormat('MMM d').format(run.at!)}';
      final extra = run.count > 1 ? ' (${run.count} runs)' : '';
      return (
        label: 'Paid · run #${run.id}$when$extra',
        color: DashUi.emeraldText,
      );
    }
    // Older than the runs we were sent: there may be a run we can't see, so say nothing rather than "Not run yet".
    final known = _runsKnownFrom;
    if (known != null && w.weekStart.compareTo(known) < 0) return null;
    final end = _parseDay(w.weekEnd);
    if (end != null && end.isBefore(_today()))
      return (label: 'Not run yet', color: DashUi.amberText);
    return null;
  }

  /// [fresh] skips the server's response cache (the Refresh button, and after a payroll run). Other loads may be
  /// answered from it, which is what makes the screen open instantly.
  Future<void> _load({bool fresh = false}) async {
    final id = ++_requestId;
    _loadRuns();
    _syncUrl();
    // The hosted server sleeps when idle and can take most of a minute to answer the first request. With nothing on
    // screen yet, say so after a few seconds instead of leaving a silent placeholder.
    _slowTimer?.cancel();
    if (_report == null) {
      _slowTimer = Timer(const Duration(seconds: 8), () {
        if (mounted && _loading && _report == null)
          setState(() => _slow = true);
      });
    }
    setState(() {
      _loading = true;
      _error = null;
      _forbidden = false;
    });

    try {
      final uri = Uri.parse('$kApiBaseUrl/api/payroll/commission-detail')
          .replace(
            queryParameters: {
              'start': _ymd(_range.start),
              'end': _ymd(_range.end),
              if (fresh) 'fresh': '1',
            },
          );
      final response = await http
          .get(uri, headers: AuthSession.instance.headers())
          .timeout(
            const Duration(seconds: 90),
          ); // the hosted server can be slow to wake up

      if (!mounted || id != _requestId) return;
      _slowTimer?.cancel();
      _slow = false;

      if (response.statusCode == 200) {
        final report = _Report(
          json.decode(response.body) as Map<String, dynamic>,
        );
        setState(() {
          _report = report;
          _loading = false;
          _logLimit = _logPage;
          if (_selectedId != null &&
              !report.techs.any((t) => t.userId == _selectedId)) {
            _selectedId = null;
          }
        });
      } else {
        String message = 'The server returned status ${response.statusCode}.';
        try {
          final body = json.decode(response.body);
          if (body is Map && body['error'] != null)
            message = body['error'].toString();
        } catch (_) {}
        if (response.statusCode == 401) {
          AuthSession.instance
              .logout(); // sends the app back to the sign-in screen
          return;
        }
        if (response.statusCode == 403) {
          message = 'Your account does not have access to payroll reports. Sign in with an office account.';
        }
        setState(() {
          _error = message;
          _forbidden = response.statusCode == 403;
          _loading = false;
        });
      }
    } on TimeoutException {
      if (!mounted || id != _requestId) return;
      _slowTimer?.cancel();
      setState(() {
        _error = 'The server took too long to respond. Try again in a moment.';
        _slow = false;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      _slowTimer?.cancel();
      _slow = false;
      final unreadable = e is FormatException || e is TypeError;
      setState(() {
        _error = unreadable
            ? 'The server sent a report this screen could not read. Try again, and tell support if it keeps happening.'
            : 'Could not reach the server. Check the connection and try again.';
        _loading = false;
      });
    }
  }

  List<_Tech> _visibleTechs(_Report r) {
    if (_selectedId == null) return r.techs;
    return r.techs.where((t) => t.userId == _selectedId).toList();
  }

  _Totals _totalsFor(List<_Tech> techs) {
    double sum(double Function(_Totals) f) =>
        techs.fold<double>(0, (s, t) => s + f(t.totals));
    return _Totals({
      'companyPool': sum((t) => t.companyPool),
      'retainage': sum((t) => t.retainage),
      'advancesPaid': sum((t) => t.advancesPaid),
      'callbackPay': sum((t) => t.callbackPay),
      'weeklyGross': sum((t) => t.weeklyGross),
      'hurdleApplied': sum((t) => t.hurdleApplied),
      'cashPay': sum((t) => t.cashPay),
      'retainageReleased': sum((t) => t.retainageReleased),
      'totalDue': sum((t) => t.totalDue),
    });
  }

  // ---- PDF export ----------------------------------------------------------

  Future<void> _exportPdf() async {
    final r = _report;
    if (r == null || r.techs.isEmpty || _exporting) return;
    setState(() => _exporting = true);
    try {
      final meta = _PdfMeta(
        generatedAt: DateTime.now(),
        generatedBy: AuthSession.instance.name,
        weekStatus: {
          for (final t in r.techs)
            for (final w in t.weeks)
              if (_weekStatus(w) case final s?)
                w.weekStart: (
                  label: s.label,
                  paid: s.color == DashUi.emeraldText,
                ),
        },
      );
      final bytes = await _buildPayrollPdf(r, meta);
      if (!mounted) return;
      await Printing.layoutPdf(
        name: 'payroll-${r.start}_${r.end}.pdf',
        format: _pdfPageFormat,
        onLayout: (_) async => bytes,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not create the PDF. Try again.')),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ---- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          final pad = w < 600 ? 12.0 : (w < 1000 ? 16.0 : 24.0);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _toolbar(),
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(pad, 14, pad, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_showPending)
                        PayrollPendingPanel(
                          asPage: true,
                          refreshToken: _pendingRefresh,
                        )
                      else
                        // While a new range loads, the old numbers stay but are dimmed and locked so they are not
                        // mistaken for the dates in the toolbar.
                        AnimatedOpacity(
                          duration: const Duration(milliseconds: 160),
                          opacity: _loading && _report != null ? 0.45 : 1,
                          child: IgnorePointer(
                            ignoring: _loading && _report != null,
                            child: _results(wide: w - pad * 2 >= 1000),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ---- Toolbar -------------------------------------------------------------

  Widget _toolbar() {
    final range = _shownRange;
    final label =
        '${DateFormat('MMM d').format(range.start)} – ${DateFormat('MMM d').format(range.end)}';
    final r = _report;
    final differs =
        r != null &&
        (r.start != _ymd(_range.start) || r.end != _ymd(_range.end));
    final String? note = _showPending || !differs || _loading
        ? null
        : (_error != null
              ? 'Still showing the previous report, ${_day(r.start)} to ${_day(r.end, year: true)}.'
              : 'Showing whole pay weeks, ${_day(r.start)} to ${_day(r.end, year: true)}.');

    final title = Semantics(
      header: true,
      child: const Text(
        'PAYROLL',
        style: TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, c) {
        final side = c.maxWidth < 600 ? 12.0 : 24.0;
        final inner = c.maxWidth - side * 2;
        // What the controls and buttons need side by side, measured at normal text size and scaled with it.
        final k = MediaQuery.textScalerOf(context).scale(100) / 100;
        final oneRow = inner >= 1100 * k;
        final allPills =
            inner >=
            1500 * k; // every range as its own pill instead of one menu

        final Widget body;
        if (oneRow) {
          body = Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              title,
              const SizedBox(width: 28),
              Expanded(child: _toolbarControls(label, compact: !allPills)),
              const SizedBox(width: 12),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: _toolbarActions(),
              ),
            ],
          );
        } else {
          // Narrow: the title shares its line with the buttons (or sits above them on a phone-sized window), and
          // the buttons wrap rather than run off the edge.
          final actions = Wrap(
            alignment: inner >= 520 ? WrapAlignment.end : WrapAlignment.start,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 8,
            children: _toolbarActions(),
          );
          body = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (inner >= 520)
                Row(
                  children: [
                    title,
                    const SizedBox(width: 12),
                    Expanded(child: actions),
                  ],
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 8),
                  child: title,
                ),
                actions,
              ],
              const SizedBox(height: 10),
              _toolbarControls(label, compact: true),
            ],
          );
        }

        return Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: EdgeInsets.fromLTRB(side, 8, side, 8),
          decoration: const BoxDecoration(
            color: DashUi.ink, // the header banner colour every dashboard uses
            boxShadow: [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              body,
              if (note != null) ...[
                const SizedBox(height: 4),
                Text(
                  note,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white70,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// Run payroll is the one solid button; the rest are outlined so it stands out on the dark banner. Text only,
  /// no icons, to keep the toolbar narrow.
  List<Widget> _toolbarActions() {
    final hasData = _report != null && _report!.techs.isNotEmpty;
    const text = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );
    final ghost = OutlinedButton.styleFrom(
      minimumSize: const Size(0, 40),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      foregroundColor: Colors.white,
      disabledForegroundColor: Colors.white38,
      side: BorderSide(color: Colors.white.withValues(alpha: 0.35)),
      shape: shape,
      textStyle: text,
    );

    Widget secondary({
      required String label,
      required String tip,
      required VoidCallback? onPressed,
      bool busy = false,
    }) {
      return Tooltip(
        message: tip,
        child: OutlinedButton(
          style: ghost,
          onPressed: onPressed,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy) ...[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Text(label),
            ],
          ),
        ),
      );
    }

    return [
      FilledButton(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          backgroundColor: Colors
              .white, // the usual dark button would vanish into the dark banner
          foregroundColor: DashUi.ink,
          shape: shape,
          textStyle: text,
        ),
        // Open on the last week of the range, which is the week most likely being paid, not the first.
        onPressed: () => showPayrollRunDialog(
          context,
          initialDate: _range.end,
          onChanged: () {
            _load(fresh: true);
            if (mounted) setState(() => _pendingRefresh++);
          },
        ),
        child: const Text('Run payroll'),
      ),
      const SizedBox(width: 8),
      secondary(
        label: 'Export PDF',
        tip: 'Exports every technician for these dates',
        busy: _exporting,
        onPressed: hasData && !_exporting ? _exportPdf : null,
      ),
      const SizedBox(width: 8),
      secondary(
        label: 'Payroll history',
        tip: 'Every payroll run so far',
        onPressed: () => showPayrollHistoryDialog(context),
      ),
      if (AuthSession.instance.canView('hr_corrections')) ...[
        const SizedBox(width: 8),
        secondary(
          label: 'Fix commissions',
          tip: 'Fix a wrong day, callback or closed job that changes commissions',
          onPressed: () => context.go('/hr/corrections'),
        ),
      ],
    ];
  }

  Widget _toolbarControls(String label, {bool compact = false}) {
    return Wrap(
      spacing: 14,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (!_showPending) _stepper(label),
        if (compact) ...[
          _presetMenu(),
          _pillGroup(
            items: const [_Opt('pending', 'Pending')],
            active: _showPending ? 'pending' : '',
            onSelected: _selectPreset,
          ),
        ] else
          _pillGroup(
            items: _kPresets,
            active: _showPending ? 'pending' : _activeKey,
            onSelected: _selectPreset,
          ),
        if (_loading)
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          ),
      ],
    );
  }

  /// The seven range pills collapse into one menu when the toolbar is too narrow to hold them on a single line.
  Widget _presetMenu() {
    // The Pending tab is not a date range, so it is never in this menu; it stays beside it as its own tab.
    final active = _kPresets.firstWhere((p) => p.key == _activeKey);
    return PopupMenuButton<String>(
      tooltip: 'Choose a date range',
      onSelected: _selectPreset,
      itemBuilder: (_) => [
        for (final o in _kPresets)
          if (o.key != 'pending')
            CheckedPopupMenuItem<String>(
              value: o.key,
              checked: !_showPending && o.key == active.key,
              child: Text(o.label),
            ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: DashUi.faint,
          borderRadius: BorderRadius.circular(10),
        ),
        child: SelectionContainer.disabled(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                active.label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: _showPending ? DashUi.slate : DashUi.blue,
                ),
              ),
              const SizedBox(width: 4),
              const Icon(
                Icons.arrow_drop_down_rounded,
                size: 20,
                color: DashUi.slate,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stepper(String label) {
    final can = _canStep;
    Widget btn(IconData icon, String tip, VoidCallback? onTap) => IconButton(
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      iconSize: 20,
      color: DashUi.slate,
      icon: Icon(icon),
      onPressed: onTap,
    );

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DashUi.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          btn(
            Icons.chevron_left_rounded,
            can
                ? 'Previous pay weeks'
                : 'Stepping needs a range of whole Monday-to-Sunday weeks',
            can ? () => _step(-1) : null,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w800,
                color: DashUi.ink,
                fontFeatures: _figures,
              ),
            ),
          ),
          btn(
            Icons.chevron_right_rounded,
            can
                ? 'Next pay weeks'
                : 'Stepping needs a range of whole Monday-to-Sunday weeks',
            can ? () => _step(1) : null,
          ),
        ],
      ),
    );
  }

  Widget _pillGroup({
    required List<_Opt> items,
    required String active,
    required ValueChanged<String> onSelected,
  }) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: DashUi.faint,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Wrap(
        spacing: 2,
        runSpacing: 2,
        children: [
          for (final o in items)
            _pill(o.label, o.key == active, () => onSelected(o.key)),
        ],
      ),
    );
  }

  Widget _pill(String text, bool selected, VoidCallback onTap) {
    return _Pressable(
      label: text,
      selected: selected,
      radius: BorderRadius.circular(8),
      onTap: onTap,
      builder: (hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? Colors.white
              : (hover
                    ? Colors.white.withValues(alpha: 0.6)
                    : Colors.white.withValues(alpha: 0)),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? DashUi.line : DashUi.line.withValues(alpha: 0),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            color: selected ? DashUi.blue : (hover ? DashUi.ink : DashUi.slate),
          ),
        ),
      ),
    );
  }

  // ---- Results -------------------------------------------------------------

  Widget _centered(Widget child) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Center(child: child),
  );

  Widget _results({required bool wide}) {
    final report = _report;

    if (report == null) {
      if (_loading) return _skeleton(wide: wide);
      if (_error != null) {
        return _centered(
          _stateMessage(
            icon: _forbidden
                ? Icons.lock_outline_rounded
                : Icons.cloud_off_rounded,
            title: _forbidden
                ? 'No access to payroll'
                : 'Could not load the report',
            message: _error!,
            action: _forbidden
                ? null
                : OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 42),
                    ),
                    onPressed: _load,
                    child: const Text('Try again'),
                  ),
          ),
        );
      }
      return _centered(
        _stateMessage(
          icon: Icons.request_quote_outlined,
          title: 'No report yet',
          message: 'Choose the dates above to load the report.',
        ),
      );
    }

    if (report.techs.isEmpty) {
      return _centered(
        _stateMessage(
          icon: Icons.event_busy_rounded,
          title: 'No commission activity for these dates',
          message:
              'Nothing was settled or paid from ${_day(report.start, year: true)} to ${_day(report.end, year: true)}. '
              'Commission starts counting on the Oct 5 go-live, and a job pays in the week it is closed.',
        ),
      );
    }

    final visible = _visibleTechs(report);
    final totals = _totalsFor(visible);
    final jobNet = visible.fold<double>(0, (s, t) => s + t.jobNet);

    _Tech? selected;
    for (final t in report.techs) {
      if (t.userId == _selectedId) selected = t;
    }
    final metric = _metric;
    final detail = metric != null
        ? <Widget>[_metricLog(metric, visible, report)]
        : (selected == null
              ? <Widget>[_register(report)]
              : _techDetail(selected, report));

    final banner = _error == null
        ? <Widget>[]
        : <Widget>[_errorBanner(), const SizedBox(height: 12)];

    final repTotal = visible.fold<double>(0, (s, t) => s + t.repPay);
    // Everything the jobs in view sent to the company pool (each job once, even when several techs worked it).
    final poolByJob = <String, double>{
      for (final t in visible)
        for (final w in t.weeks)
          for (final j in w.jobs) j.jobId: j.toCompanyPool,
    };
    final poolTotal = poolByJob.values.fold<double>(0, (s, v) => s + v);
    final scorecards = _scorecards(totals, jobNet, repTotal, poolTotal, wide);

    if (wide) {
      // On the Everyone register the technician list only repeats the table, so the table gets the full width.
      final showList = metric != null || selected != null;
      if (!showList) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...banner,
            scorecards,
            const SizedBox(height: 12),
            ..._spaced(detail),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...banner,
          scorecards,
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 280, child: _techList(report)),
              Expanded(
                // The edge line sits on the person's side: their page is the taller of the two.
                child: Container(
                  padding: const EdgeInsets.only(left: 20),
                  decoration: const BoxDecoration(
                    border: Border(left: BorderSide(color: DashUi.line)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _spaced(detail),
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...banner,
        scorecards,
        const SizedBox(height: 12),
        _techChips(report),
        const SizedBox(height: 12),
        ..._spaced(detail),
      ],
    );
  }

  /// First load: the shape of the scorecards and register, so the page doesn't jump when the numbers arrive.
  Widget _skeleton({required bool wide}) {
    Widget row() => Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: DashUi.line)),
      ),
      child: const Row(
        children: [
          SkeletonBox(h: 40, w: 40, r: 10),
          SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Align(
              alignment: Alignment.centerLeft,
              child: SkeletonBox(h: 12, w: 150),
            ),
          ),
          Expanded(
            flex: 7,
            child: Align(
              alignment: Alignment.centerRight,
              child: SkeletonBox(h: 12, w: 320),
            ),
          ),
          SizedBox(width: 32),
          SkeletonBox(h: 14, w: 84),
        ],
      ),
    );

    return Semantics(
      label: 'Loading the payroll report',
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_slow)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: DashUi.slate,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Waking up the server. The first report of the day can take up to a minute.',
                      style: TextStyle(
                        fontSize: 13,
                        color: DashUi.slate,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          SkeletonPulse(
            child: ExcludeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LayoutBuilder(
                    builder: (context, c) {
                      final cols = wide ? 5 : (c.maxWidth >= 700 ? 3 : 2);
                      const gap = 8.0;
                      final w = (c.maxWidth - gap * (cols - 1)) / cols;
                      return Wrap(
                        spacing: gap,
                        runSpacing: gap,
                        children: [
                          for (var i = 0; i < 5; i++)
                            Container(
                              width: w,
                              height: 88,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 16,
                              ),
                              decoration: DashUi.panel(radius: 12),
                              child: const Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  SkeletonBox(h: 10, w: 90),
                                  SizedBox(height: 12),
                                  SkeletonBox(h: 20, w: 120),
                                ],
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 28),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SkeletonBox(h: 18, w: 180),
                    ),
                  ),
                  Container(height: 44, color: DashUi.faint),
                  for (var i = 0; i < 6; i++) row(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _spaced(List<Widget> items) {
    final out = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      if (i > 0) out.add(const SizedBox(height: 12));
      out.add(items[i]);
    }
    return out;
  }

  Widget _stateMessage({
    required IconData icon,
    required String title,
    required String message,
    Widget? action,
  }) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: DashUi.line),
            ),
            child: Icon(icon, size: 44, color: DashUi.muted),
          ),
          const SizedBox(height: 20),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: DashUi.ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14,
              color: DashUi.slate,
              height: 1.4,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 18), action],
        ],
      ),
    );
  }

  Widget _errorBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: _badBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _badBorder),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, size: 18, color: DashUi.red),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _error ?? '',
              style: const TextStyle(
                fontSize: 13,
                color: DashUi.red,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (!_forbidden)
            TextButton(
              onPressed: _loading ? null : _load,
              child: const Text('Try again'),
            ),
        ],
      ),
    );
  }

  // ---- Scorecards ----------------------------------------------------------

  Widget _scorecards(
    _Totals t,
    double jobNet,
    double repTotal,
    double poolTotal,
    bool wide,
  ) {
    // A zero figure is greyed so the cards that have something to say stand out.
    Color tone(double v, Color c) => v.abs() < 0.005 ? DashUi.subtle : c;

    Widget tappable(_Metric m, double value, Widget card) {
      final on = _metric == m;
      return DecoratedBox(
        // A soft shadow, so the tile stands up from the white page instead of sitting flat on it.
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1A0F172A),
              blurRadius: 14,
              offset: Offset(0, 5),
            ),
            BoxShadow(
              color: Color(0x0F0F172A),
              blurRadius: 3,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: _Pressable(
          label: '${m.label}, ${_fmt(value)}',
          selected: on,
          radius: BorderRadius.circular(12),
          tooltip: on ? 'Close the log' : 'See every entry behind ${m.label}',
          onTap: () => _toggleMetric(m),
          builder: (_) => Stack(
            children: [
              Positioned.fill(child: card),
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: on ? m.color : m.color.withValues(alpha: 0),
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final advCallbacks = t.advancesPaid + t.callbackPay;
    final cards = <Widget>[
      tappable(
        _Metric.totalDue,
        t.totalDue,
        AnimatedMetricCard(
          title: 'Total Due',
          value: t.totalDue,
          valueColor: tone(t.totalDue, DashUi.emeraldDeep),
          index: 0,
          verticalPadding: 9,
        ),
      ),
      tappable(
        _Metric.commission,
        jobNet,
        AnimatedMetricCard(
          title: 'Closed-Job Commission',
          value: jobNet,
          valueColor: tone(jobNet, DashUi.ink),
          index: 1,
          verticalPadding: 9,
        ),
      ),
      tappable(
        _Metric.retainage,
        t.retainage,
        AnimatedMetricCard(
          title: 'Retainage Held',
          value: t.retainage,
          valueColor: tone(t.retainage, DashUi.indigo),
          index: 2,
          verticalPadding: 9,
        ),
      ),
      // Sales pay is not part of any other card, so when someone earned it the card takes the pool's slot.
      if (repTotal != 0)
        tappable(
          _Metric.sales,
          repTotal,
          AnimatedMetricCard(
            title: 'Sales Commission',
            value: repTotal,
            valueColor: DashUi.indigo,
            index: 3,
            verticalPadding: 9,
          ),
        )
      else
        tappable(
          _Metric.pool,
          poolTotal,
          AnimatedMetricCard(
            title: 'Company Pool',
            value: poolTotal,
            valueColor: tone(poolTotal, DashUi.slate),
            index: 3,
            verticalPadding: 9,
          ),
        ),
      tappable(
        _Metric.advCallbacks,
        advCallbacks,
        AnimatedMetricCard(
          title: 'Advances & Callbacks',
          value: advCallbacks,
          valueColor: tone(advCallbacks, DashUi.amber),
          index: 4,
          verticalPadding: 9,
        ),
      ),
    ];

    // The cards are a fixed height so a row lines up; it grows with the text size so big text isn't cut off.
    final ts = MediaQuery.textScalerOf(context);
    final height = math.max(80.0, 31 + ts.scale(17.5) + ts.scale(31));

    if (wide) {
      final row = <Widget>[];
      for (var i = 0; i < cards.length; i++) {
        if (i > 0) row.add(const SizedBox(width: 8));
        row.add(Expanded(child: cards[i]));
      }
      return SizedBox(
        height: height,
        child: Row(children: row),
      );
    }

    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth >= 700 ? 3 : 2;
        const gap = 8.0;
        final width = (c.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final card in cards)
              SizedBox(width: width, height: height, child: card),
          ],
        );
      },
    );
  }

  // ---- Scorecard log ---------------------------------------------------------

  List<_LogRow> _logRows(_Metric m, List<_Tech> techs) {
    final rows = <_LogRow>[];
    final poolSeen = <String>{};
    for (final t in techs) {
      for (final w in t.weeks) {
        switch (m) {
          case _Metric.totalDue:
            if (w.cashPay != 0 || w.weeklyGross != 0) {
              rows.add(
                _LogRow(
                  w.weekEnd,
                  t.name,
                  'Pay week ${_day(w.weekStart)} – ${_day(w.weekEnd)}',
                  'Gross ${_fmt(w.weeklyGross)}, hurdle ${_fmt(-w.hurdleApplied)}',
                  w.cashPay,
                ),
              );
            }
          case _Metric.commission:
            for (final j in w.jobs) {
              rows.add(
                _LogRow(
                  j.closedOn,
                  t.name,
                  _jobTitle(j),
                  'Split ${_pct(j.splitPct)}${j.status.isEmpty ? '' : '  ·  ${j.status}'}',
                  j.net,
                ),
              );
            }
          case _Metric.retainage:
            for (final j in w.jobs.where((j) => j.retainage != 0)) {
              rows.add(
                _LogRow(
                  j.closedOn,
                  t.name,
                  _jobTitle(j),
                  'Held from pool share ${_fmt(j.share)}',
                  j.retainage,
                ),
              );
            }
          case _Metric.pool:
            for (final j in w.jobs) {
              if (j.toCompanyPool <= 0 || !poolSeen.add(j.jobId)) continue;
              rows.add(
                _LogRow(
                  j.closedOn,
                  j.workers.isEmpty ? t.name : j.workers.join(', '),
                  _jobTitle(j),
                  '1% of job commission on job total ${_fmt(j.jobRevenue)}',
                  j.toCompanyPool,
                ),
              );
            }
          case _Metric.sales:
            for (final rc in w.repCommissions) {
              rows.add(
                _LogRow(
                  rc.closedOn,
                  t.name,
                  'Est ${rc.jobId}${rc.customer.isEmpty ? '' : '  ${rc.customer}'}',
                  '${_fmt(rc.labor)} labor × ${_pct(rc.ratePct)}${rc.basisLabel.isEmpty ? '' : ', ${rc.basisLabel}'}',
                  rc.amount,
                ),
              );
            }
          case _Metric.advCallbacks:
            for (final a in w.advances) {
              rows.add(
                _LogRow(a.date, t.name, 'Advance day', _itemTitle(a), a.amount),
              );
            }
            for (final c in w.callbacks) {
              rows.add(
                _LogRow(c.date, t.name, 'Callback', _itemTitle(c), c.amount),
              );
            }
        }
      }
      if (m == _Metric.totalDue) {
        for (final r in t.releases) {
          rows.add(
            _LogRow(
              r.releasedOn,
              t.name,
              r.type == 'callback_deduction'
                  ? 'Callback charge against retainage'
                  : 'Retainage released',
              r.jobId.isEmpty ? '' : 'Job ${r.jobId}',
              r.amount,
            ),
          );
        }
      }
    }
    rows.sort((a, b) {
      final c = a.date.compareTo(b.date);
      return c != 0 ? c : a.tech.compareTo(b.tech);
    });
    return rows;
  }

  String _jobTitle(_Job j) =>
      'Job ${j.jobId}${j.customer.isEmpty ? '' : '  ${j.customer}'}';

  String _itemTitle(_DayItem i) =>
      'Job ${i.jobId}${i.customer.isEmpty ? '' : '  ${i.customer}'}';

  Widget _metricLog(_Metric m, List<_Tech> techs, _Report report) {
    final rows = _logRows(m, techs);
    final total = rows.fold<double>(0, (s, r) => s + r.amount);
    final showTech = techs.length > 1;
    final photos = {for (final t in techs) t.name: t.imageUrl};
    final scope = techs.length == 1 ? techs.first.name : 'Everyone';
    final range = '${_day(report.start)} – ${_day(report.end, year: true)}';

    Color amountColor(double v) => v < 0 ? DashUi.red : DashUi.ink;

    return Container(
      decoration: _flat,
      child: LayoutBuilder(
        builder: (context, c) {
          final narrow = c.maxWidth < 680;

          final header = Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 12),
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: _dot(m.color, size: 10),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            m.label,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: DashUi.ink,
                            ),
                          ),
                          _chip(
                            '${rows.length} ${rows.length == 1 ? 'entry' : 'entries'}',
                            DashUi.slate,
                            DashUi.faint,
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${m.blurb}  ·  $scope  ·  $range',
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: DashUi.subtle,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text(
                      'Total',
                      style: TextStyle(
                        fontSize: 12,
                        color: DashUi.slate,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      _fmt(total),
                      style: _num(22, FontWeight.w800, m.color),
                    ),
                  ],
                ),
                IconButton(
                  tooltip: 'Close',
                  iconSize: 20,
                  color: DashUi.slate,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => setState(() => _metric = null),
                ),
              ],
            ),
          );

          const head = TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: DashUi.slate,
          );
          final columns = narrow
              ? null
              : Container(
                  color: DashUi.faint,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 9,
                  ),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 72,
                        child: Text('Date', style: head),
                      ),
                      if (showTech)
                        const Expanded(
                          flex: 3,
                          child: Text('Technician', style: head),
                        ),
                      const Expanded(
                        flex: 5,
                        child: Text('Entry', style: head),
                      ),
                      const Expanded(
                        flex: 5,
                        child: Text('Detail', style: head),
                      ),
                      const SizedBox(
                        width: 110,
                        child: Text(
                          'Amount',
                          textAlign: TextAlign.right,
                          style: head,
                        ),
                      ),
                    ],
                  ),
                );

          Widget rowFor(_LogRow r) {
            final amount = Text(
              _fmt(r.amount),
              textAlign: TextAlign.right,
              style: _num(13.5, FontWeight.w800, amountColor(r.amount)),
            );
            if (narrow) {
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: DashUi.line)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            r.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                              color: DashUi.ink,
                            ),
                          ),
                          Text(
                            [
                              _day(r.date),
                              if (showTech) r.tech,
                              if (r.detail.isNotEmpty) r.detail,
                            ].join('  ·  '),
                            style: const TextStyle(
                              fontSize: 12,
                              color: DashUi.subtle,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    amount,
                  ],
                ),
              );
            }
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: DashUi.line)),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 72,
                    child: Text(
                      _day(r.date),
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: DashUi.slate,
                      ),
                    ),
                  ),
                  if (showTech)
                    Expanded(
                      flex: 3,
                      child: Row(
                        children: [
                          DashAvatar(
                            name: r.tech,
                            imageUrl: photos[r.tech] ?? '',
                            size: 22,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              r.tech,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                color: DashUi.ink,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    flex: 5,
                    child: Text(
                      r.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: DashUi.ink,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 5,
                    child: Text(
                      r.detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: DashUi.subtle,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  SizedBox(width: 110, child: amount),
                ],
              ),
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              ?columns,
              if (rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 36),
                  child: Center(
                    child: Text(
                      'Nothing logged for these dates.',
                      style: TextStyle(fontSize: 14, color: DashUi.slate),
                    ),
                  ),
                )
              else
                for (final r in rows.take(_logLimit)) rowFor(r),
              if (rows.length > _logLimit)
                _moreRow(shown: _logLimit, of: rows.length),
              if (rows.isNotEmpty)
                Container(
                  color: DashUi.faint,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 11,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Total  ·  ${rows.length} ${rows.length == 1 ? 'entry' : 'entries'}',
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                            color: DashUi.ink,
                          ),
                        ),
                      ),
                      Text(
                        _fmt(total),
                        style: _num(14.5, FontWeight.w800, m.color),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// The rest of a long log stays unbuilt until asked for; the total row below still counts every entry.
  Widget _moreRow({required int shown, required int of}) {
    final next = math.min(_logPage, of - shown);
    final count = NumberFormat.decimalPattern();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: DashUi.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Showing ${count.format(shown)} of ${count.format(of)} entries',
              style: const TextStyle(
                fontSize: 13,
                color: DashUi.slate,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton.icon(
            icon: const Icon(Icons.expand_more_rounded, size: 18),
            label: Text('Show ${count.format(next)} more'),
            style: TextButton.styleFrom(
              foregroundColor: DashUi.blue,
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            onPressed: () => setState(() => _logLimit += _logPage),
          ),
        ],
      ),
    );
  }

  // ---- Technician list -----------------------------------------------------

  Widget _techList(_Report report) {
    return Container(
      padding: const EdgeInsets.fromLTRB(0, 4, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
            child: Row(
              children: [
                const Text(
                  'Technicians',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: DashUi.ink,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${report.techs.length}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: DashUi.subtle,
                  ),
                ),
              ],
            ),
          ),
          Column(
            children: [
              _techRow(
                leading: Container(
                  width: 34,
                  height: 34,
                  decoration: const BoxDecoration(
                    color: DashUi.ink,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.groups_rounded,
                    size: 18,
                    color: Colors.white,
                  ),
                ),
                name: 'Everyone',
                subtitle: 'Payroll Register',
                due: report.techs.fold<double>(
                  0,
                  (s, t) => s + t.totals.totalDue,
                ),
                selected: _selectedId == null,
                onTap: () => _selectTech(null),
              ),
              for (final t in report.techs)
                _techRow(
                  leading: DashAvatar(
                    name: t.name,
                    imageUrl: t.imageUrl,
                    size: 44,
                  ),
                  name: t.name,
                  subtitle: t.kindLabel,
                  due: t.totals.totalDue,
                  selected: _selectedId == t.userId,
                  onTap: () => _selectTech(t.userId),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _techRow({
    required Widget leading,
    required String name,
    required String subtitle,
    required double due,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Semantics(
        selected: selected,
        child: Material(
          color: selected ? DashUi.faint : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  leading,
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: selected
                                ? FontWeight.w800
                                : FontWeight.w700,
                            color: DashUi.ink,
                          ),
                        ),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: DashUi.subtle,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _fmt(due),
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      color: _cashColor(due),
                      fontFeatures: _figures,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _techChips(_Report report) {
    final items = <_Opt>[
      const _Opt('all', 'Everyone'),
      for (final t in report.techs) _Opt('${t.userId}', t.name),
    ];
    return Align(
      alignment: Alignment.centerLeft,
      child: _pillGroup(
        items: items,
        active: _selectedId == null ? 'all' : '$_selectedId',
        onSelected: (k) => _selectTech(k == 'all' ? null : int.tryParse(k)),
      ),
    );
  }

  // ---- Everyone: payroll register -----------------------------------------

  /// Thin progress bar of the latest pay week's gross toward the weekly hurdle. Nothing for techs with no hurdle.
  Widget _hurdleBar(_Tech t) =>
      t.weeks.isEmpty ? const SizedBox.shrink() : _hurdleBarFor(t.weeks.last);

  Widget _hurdleBarFor(_Week w, {double height = 5}) {
    if (w.hurdleRule <= 0) return const SizedBox.shrink();
    final met = w.weeklyGross >= w.hurdleRule;
    final pct = (w.weeklyGross / w.hurdleRule).clamp(0.0, 1.0);
    return Tooltip(
      message:
          'Week of ${_day(w.weekStart)}: ${_fmt(w.weeklyGross)} of the ${_fmt(w.hurdleRule)} hurdle'
          '${met ? ' (cleared)' : ''}',
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        // Too narrow for the figures beside the bar: the bar alone, with the figures in the tooltip.
        child: LayoutBuilder(
          builder: (context, c) => Row(
            children: [
              Expanded(
                child: met
                    ? _LiquidBar(height: height)
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(height / 2),
                        child: LinearProgressIndicator(
                          value: pct,
                          minHeight: height,
                          backgroundColor: DashUi.line,
                          valueColor: const AlwaysStoppedAnimation(
                            DashUi.amber,
                          ),
                        ),
                      ),
              ),
              const SizedBox(width: 6),
              if (met)
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: MediaQuery.of(context).disableAnimations
                      ? Duration.zero
                      : const Duration(milliseconds: 600),
                  curve: Curves.elasticOut,
                  builder: (context, v, child) =>
                      Transform.scale(scale: v, child: child),
                  child: Icon(
                    Icons.check_circle_rounded,
                    size: math.max(16, height + 6),
                    color: DashUi.emeraldDeep,
                    semanticLabel: 'Hurdle cleared',
                  ),
                )
              else if (c.maxWidth >= 160)
                Text(
                  '${_fmt(w.weeklyGross)} / ${_fmt(w.hurdleRule)}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: DashUi.amberText,
                    fontFeatures: _figures,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// One line per person. Every column has a set width, worked out from the room available. When the figures don't
  /// all fit, the name and Total Due stay put at the edges and only the columns between them scroll, so the amount
  /// owed is never pushed off screen. The three blocks share fixed row heights so their rows line up.
  Widget _register(_Report report) {
    final showRep = report.techs.any((t) => t.repPay != 0);
    // The $750 hurdle is judged one pay week at a time, so its bar and flag only make sense on a one-week report.
    final weekly = _isSingleWeek(report);

    // Name order by default; the Total Due header flips to biggest payout first.
    final techs = [...report.techs];
    if (_sortByDue)
      techs.sort((a, b) => b.totals.totalDue.compareTo(a.totals.totalDue));

    // The figures between the name and Total Due.
    final cols = <_RegCol>[
      _RegCol('Jobs', (t) => t.jobCount.toDouble(), count: true),
      _RegCol('Closed-Job Net', (t) => t.jobNet),
      _RegCol('Advances', (t) => t.totals.advancesPaid),
      _RegCol('Callbacks', (t) => t.totals.callbackPay),
      if (showRep) _RegCol('Sales Commission', (t) => t.repPay),
      _RegCol('Gross', (t) => t.totals.weeklyGross),
      _RegCol('Cash Pay', (t) => t.totals.cashPay),
      _RegCol('Retainage Released', (t) => t.totals.retainageReleased),
    ];
    double sum(double Function(_Tech) f) =>
        report.techs.fold<double>(0, (s, t) => s + f(t));

    const head = TextStyle(
      fontSize: 13.5,
      fontWeight: FontWeight.w700,
      color: DashUi.slate,
      height: 1.25,
    );
    const figure = TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w500,
      color: DashUi.ink,
      fontFeatures: _figures,
    );
    const gutter = 12.0; // space between right-aligned figures, so neighbouring headers don't run together

    // A zero shows as a quiet dash so the figures that matter stand out.
    Widget amount(
      double v, {
      bool count = false,
      TextStyle style = figure,
      Color? color,
    }) {
      final zero = v.abs() < 0.005;
      return Text(
        zero ? '—' : (count ? '${v.round()}' : _fmt(v)),
        textAlign: TextAlign.right,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style.copyWith(
          color: zero
              ? DashUi.muted
              : (v < 0 ? DashUi.red : color ?? style.color),
        ),
      );
    }

    return Container(
      decoration: _flat,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Semantics(
              header: true,
              child: const Text(
                'Payroll Register',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: DashUi.ink,
                ),
              ),
            ),
          ),
          LayoutBuilder(
            builder: (context, c) {
              final ts = MediaQuery.textScalerOf(context);
              final k = ts.scale(100) / 100;
              final headH = math.max(52.0, 20 + ts.scale(36));
              final rowH = math.max(
                84.0,
                24 + ts.scale(22) + ts.scale(17) + (weekly ? 11 : 0),
              );
              final totalH = math.max(50.0, 26 + ts.scale(20));

              final countW = 64 * k;
              final moneyW = 112 * k;
              final midNeed = cols.fold<double>(
                0,
                (s, col) => s + (col.count ? countW : moneyW),
              );
              final nameMin = 16 + 260 * k;
              var dueW = 16 + 112 * k;
              final fits = c.maxWidth >= nameMin + midNeed + dueW;

              // Spare room goes first to the name (up to a point), then evenly to the figures.
              var nameW = nameMin;
              var colBonus = 0.0;
              if (fits) {
                final extra = c.maxWidth - nameMin - midNeed - dueW;
                nameW += math.min(extra, 140 * k);
                final rest = extra - (nameW - nameMin);
                colBonus = rest / (cols.length + 1);
                dueW += colBonus;
              } else {
                nameW = (c.maxWidth * 0.36).clamp(150.0, nameMin);
                // A very narrow window with very large text: the pinned columns must still leave a sliver to scroll.
                nameW = math.min(nameW, math.max(96.0, c.maxWidth - dueW - 48));
              }
              final midW = midNeed + colBonus * cols.length;
              double colW(_RegCol col) =>
                  (col.count ? countW : moneyW) + colBonus;

              // One block's part of a row. Hover and taps are shared by a row's three blocks, so the row lights up
              // as one line.
              Widget cell(
                _Tech? t,
                double height,
                Widget child, {
                Color fill = Colors.white,
                bool top = true,
              }) {
                Widget box(Color bg, Widget? content) => Container(
                  height: height,
                  decoration: BoxDecoration(
                    color: bg,
                    border: top
                        ? const Border(top: BorderSide(color: DashUi.line))
                        : null,
                  ),
                  child: content,
                );
                if (t == null) return box(fill, child);
                return MouseRegion(
                  cursor: SystemMouseCursors.click,
                  onEnter: (_) => _regHover.value = t.userId,
                  onExit: (_) {
                    if (_regHover.value == t.userId) _regHover.value = null;
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    excludeFromSemantics:
                        true, // the name cell is the row's one button
                    onTap: () => _selectTech(t.userId),
                    child: ValueListenableBuilder<int?>(
                      valueListenable: _regHover,
                      builder: (context, hover, content) =>
                          box(hover == t.userId ? DashUi.faint : fill, content),
                      child: child,
                    ),
                  ),
                );
              }

              Widget sortHead(
                String text, {
                required bool byDue,
                required TextAlign align,
              }) {
                final active = _sortByDue == byDue;
                return _Pressable(
                  label: byDue
                      ? 'Total Due, sort highest first'
                      : 'Technician, sort by name',
                  selected: active,
                  radius: BorderRadius.circular(6),
                  tooltip: byDue
                      ? 'Sort by amount due, highest first'
                      : 'Sort by name',
                  onTap: () => setState(() => _sortByDue = byDue),
                  builder: (hover) => Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: text),
                        // An icon, not an arrow character: the default font has no arrow glyph and falls back to another face.
                        if (active)
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: Icon(
                                byDue
                                    ? Icons.arrow_downward
                                    : Icons.arrow_upward,
                                size: 14,
                                color: DashUi.ink,
                              ),
                            ),
                          ),
                      ],
                    ),
                    textAlign: align,
                    maxLines: 2,
                    style: head.copyWith(
                      color: active || hover ? DashUi.ink : DashUi.slate,
                    ),
                  ),
                );
              }

              Widget nameCell(_Tech t) {
                final under = weekly && t.underHurdle;
                return _Pressable(
                  label:
                      '${t.name}${under ? ', under hurdle' : ''}, '
                      'Total Due ${_fmt(t.totals.totalDue)}. Opens their breakdown',
                  radius: BorderRadius.circular(8),
                  onTap: () => _selectTech(t.userId),
                  builder: (_) => Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
                    child: Row(
                      children: [
                        // On a narrow window the name needs the room more than the photo does.
                        if (nameW >= 230) ...[
                          DashAvatar(
                            name: t.name,
                            imageUrl: t.imageUrl,
                            size: 60,
                            square: true,
                          ),
                          const SizedBox(width: 14),
                        ],
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                t.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                  color: DashUi.ink,
                                ),
                              ),
                              if (weekly) _hurdleBar(t),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }

              Widget figuresRow(List<Widget> cells) => Row(
                children: [
                  for (var i = 0; i < cols.length; i++)
                    SizedBox(
                      width: colW(cols[i]),
                      child: Padding(
                        padding: const EdgeInsets.only(left: gutter),
                        child: cells[i],
                      ),
                    ),
                ],
              );

              final bold = figure.copyWith(fontWeight: FontWeight.w800);
              final dueStyle = figure.copyWith(
                fontSize: 17,
                fontWeight: FontWeight.w800,
              );

              final nameBlock = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  cell(
                    null,
                    headH,
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: sortHead(
                          'Technician',
                          byDue: false,
                          align: TextAlign.left,
                        ),
                      ),
                    ),
                    fill: DashUi.faint,
                    top: false,
                  ),
                  for (final t in techs) cell(t, rowH, nameCell(t)),
                  cell(
                    null,
                    totalH,
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Total',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: DashUi.ink,
                          ),
                        ),
                      ),
                    ),
                    fill: DashUi.faint,
                  ),
                ],
              );

              final midBlock = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  cell(
                    null,
                    headH,
                    figuresRow([
                      for (final col in cols)
                        Text(
                          col.head,
                          textAlign: TextAlign.right,
                          maxLines: 2,
                          style: head,
                        ),
                    ]),
                    fill: DashUi.faint,
                    top: false,
                  ),
                  for (final t in techs)
                    cell(
                      t,
                      rowH,
                      figuresRow([
                        for (final col in cols)
                          amount(col.value(t), count: col.count),
                      ]),
                    ),
                  cell(
                    null,
                    totalH,
                    figuresRow([
                      for (final col in cols)
                        amount(sum(col.value), count: col.count, style: bold),
                    ]),
                    fill: DashUi.faint,
                  ),
                ],
              );

              Widget dueCell(Widget child) => Padding(
                padding: const EdgeInsets.fromLTRB(gutter, 0, 16, 0),
                child: Align(alignment: Alignment.centerRight, child: child),
              );

              final dueBlock = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  cell(
                    null,
                    headH,
                    dueCell(
                      sortHead(
                        'Total Due',
                        byDue: true,
                        align: TextAlign.right,
                      ),
                    ),
                    fill: DashUi.faint,
                    top: false,
                  ),
                  for (final t in techs)
                    cell(
                      t,
                      rowH,
                      dueCell(
                        amount(
                          t.totals.totalDue,
                          style: dueStyle,
                          color: DashUi.emeraldText,
                        ),
                      ),
                    ),
                  cell(
                    null,
                    totalH,
                    dueCell(
                      amount(
                        sum((t) => t.totals.totalDue),
                        style: dueStyle,
                        color: DashUi.emeraldText,
                      ),
                    ),
                    fill: DashUi.faint,
                  ),
                ],
              );

              if (fits) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: nameW, child: nameBlock),
                    SizedBox(width: midW, child: midBlock),
                    SizedBox(width: dueW, child: dueBlock),
                  ],
                );
              }

              // Too narrow: the middle scrolls sideways under a visible scrollbar; a hairline marks each pinned edge.
              const edge = BorderSide(color: DashUi.line);
              const barRoom = 14.0; // below the total row, so the scrollbar doesn't cover the totals
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: nameW,
                    padding: const EdgeInsets.only(bottom: barRoom),
                    decoration: const BoxDecoration(
                      border: Border(right: edge),
                    ),
                    child: nameBlock,
                  ),
                  Expanded(
                    child: Scrollbar(
                      controller: _regScroll,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _regScroll,
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.only(bottom: barRoom),
                        child: SizedBox(width: midW, child: midBlock),
                      ),
                    ),
                  ),
                  Container(
                    width: dueW,
                    padding: const EdgeInsets.only(bottom: barRoom),
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      border: Border(left: edge),
                      // The figures slide under this column; a soft edge says there is more to the left of it.
                      boxShadow: [
                        BoxShadow(
                          color: Color(0x140F172A),
                          blurRadius: 8,
                          offset: Offset(-3, 0),
                        ),
                      ],
                    ),
                    child: dueBlock,
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  // ---- One technician -------------------------------------------------------

  Widget _chip(String text, Color fg, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }

  Widget _dot(Color color, {double size = 8}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  TextStyle _num(double size, FontWeight weight, Color color) => TextStyle(
    fontSize: size,
    fontWeight: weight,
    color: color,
    fontFeatures: _figures,
  );

  _Week _activeWeek(_Tech t) {
    for (final w in t.weeks) {
      if (w.weekStart == _weekStart) return w;
    }
    return t.weeks.last;
  }

  List<Widget> _techDetail(_Tech t, _Report report) {
    final panels = <Widget>[_techHero(t)];

    if (t.weeks.isNotEmpty) {
      final w = _activeWeek(t);
      if (t.weeks.length > 1) panels.add(_weekStrip(t, w));
      panels.add(_weekSummary(w, showCashPay: t.weeks.length > 1));
      final days = _dayCards(w);
      if (days != null) panels.add(days);
      if (w.jobs.isNotEmpty) panels.add(_jobsSection(t, w, report));
    }

    if (t.releases.isNotEmpty) panels.add(_releasesPanel(t));

    if (t.weeks.isEmpty && t.releases.isEmpty) {
      panels.add(
        Container(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: const Text(
            'Nothing to report for this person in these dates.',
            style: TextStyle(color: DashUi.slate, fontSize: 14),
          ),
        ),
      );
    }

    return panels;
  }

  // ---- Hero: who and how much -------------------------------------------------

  /// True when the report covers one pay week (Last Week, This Week), where the weekly hurdle can be shown.
  bool _isSingleWeek(_Report r) {
    final a = _parseDay(r.start);
    final b = _parseDay(r.end);
    return a != null && b != null && _daysBetween(a, b) + 1 <= 7;
  }

  Widget _techHero(_Tech t) {
    final tot = t.totals;
    final parts = <(String, double, Color)>[
      ('Closed-job net', t.jobNet, DashUi.emeraldDeep),
      ('Advances', tot.advancesPaid, DashUi.sky),
      ('Callbacks', tot.callbackPay, DashUi.amber),
      ('Sales commission', t.repPay, DashUi.indigo),
      ('Retainage released', tot.retainageReleased, DashUi.indigo),
      ('Weekly hurdle kept', -tot.hurdleApplied, DashUi.muted),
    ].where((p) => p.$2.abs() > 0.004).toList();
    // With one pay week the ledger below already itemises the same figures; the chips only add
    // value as a cross-week rollup.
    if (t.weeks.length <= 1) parts.clear();

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: _flat,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, c) {
              // A phone-width window: a smaller photo, and Total Due under the name instead of squeezing it.
              final narrow = c.maxWidth < 520;
              final who = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        t.name,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: DashUi.ink,
                        ),
                      ),
                      if (t.underHurdle &&
                          _report != null &&
                          _isSingleWeek(_report!))
                        _chip('Under hurdle', DashUi.amberText, DashUi.faint),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${t.weeks.length} ${t.weeks.length == 1 ? 'pay week' : 'pay weeks'}, '
                    '${t.jobCount} ${t.jobCount == 1 ? 'job' : 'jobs'} closed',
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: DashUi.subtle,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              );
              final due = Column(
                crossAxisAlignment: narrow
                    ? CrossAxisAlignment.start
                    : CrossAxisAlignment.end,
                children: [
                  const Text(
                    'Total Due',
                    style: TextStyle(
                      fontSize: 12,
                      color: DashUi.slate,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    _fmt(tot.totalDue),
                    style: _num(26, FontWeight.w800, _cashColor(tot.totalDue)),
                  ),
                ],
              );
              final photo = DashAvatar(
                name: t.name,
                imageUrl: t.imageUrl,
                size: narrow ? 64 : 104,
                square: true,
              );
              if (narrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        photo,
                        const SizedBox(width: 14),
                        Expanded(child: who),
                      ],
                    ),
                    const SizedBox(height: 12),
                    due,
                  ],
                );
              }
              return Row(
                children: [
                  photo,
                  const SizedBox(width: 20),
                  Expanded(child: who),
                  const SizedBox(width: 12),
                  due,
                ],
              );
            },
          ),
          if (parts.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(height: 1, color: DashUi.line),
            const SizedBox(height: 10),
            Wrap(
              spacing: 24,
              runSpacing: 6,
              children: [
                for (final p in parts)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _dot(p.$3),
                      const SizedBox(width: 7),
                      Text(
                        p.$1,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: DashUi.slate,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _fmt(p.$2),
                        style: _num(12.5, FontWeight.w800, DashUi.ink),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ---- Pay week picker ------------------------------------------------------

  Widget _weekStrip(_Tech t, _Week active) {
    final ts = MediaQuery.textScalerOf(context);
    final chipW = ts.scale(160);
    // Every chip is the same height: its four lines of text, measured in the page's font at the current text size,
    // plus padding, gaps and border.
    final base = DefaultTextStyle.of(context).style;
    double line(double size, FontWeight weight) {
      final tp = TextPainter(
        text: TextSpan(
          text: 'Ag',
          style: base.merge(TextStyle(fontSize: size, fontWeight: weight)),
        ),
        textDirection: Directionality.of(context),
        textScaler: ts,
      )..layout();
      final h = tp.height;
      tp.dispose();
      return h;
    }

    final chipH =
        29 +
        line(13, FontWeight.w800) +
        line(16, FontWeight.w800) +
        line(12, FontWeight.w600) +
        line(12, FontWeight.w700);
    const gap = 10.0;

    // The open week starts as the last one, at the far right of a long strip. Bring it into view once each time a
    // different person, week or report is shown; after that the strip stays where the user scrolled it.
    final reveal = '${t.userId}|${active.weekStart}|${_report?.start}';
    if (_weekRevealed != reveal) {
      _weekRevealed = reveal;
      final index = t.weeks.indexWhere((w) => w.weekStart == active.weekStart);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_weekScroll.hasClients || index < 0) return;
        final pos = _weekScroll.position;
        final left = index * (chipW + gap);
        final right = left + chipW;
        double? to;
        if (left < pos.pixels) {
          to = left;
        } else if (right > pos.pixels + pos.viewportDimension) {
          to = right - pos.viewportDimension;
        }
        if (to != null) _weekScroll.jumpTo(to.clamp(0.0, pos.maxScrollExtent));
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: Row(
            children: [
              const Text(
                'Pay Weeks',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: DashUi.ink,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${t.weeks.length}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: DashUi.subtle,
                ),
              ),
            ],
          ),
        ),
        // Built lazily: a year is 52 chips, and only the handful on screen need to exist.
        SizedBox(
          height: chipH,
          child: ListView.builder(
            controller: _weekScroll,
            scrollDirection: Axis.horizontal,
            itemExtent: chipW + gap,
            itemCount: t.weeks.length,
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.only(right: gap),
              child: _weekChip(
                t.weeks[i],
                t.weeks[i].weekStart == active.weekStart,
                chipW,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _weekChip(_Week w, bool selected, double width) {
    final under = w.hurdleRule > 0 && w.weeklyGross < w.hurdleRule;
    final String flag;
    final Color flagColor;
    if (w.advanceShortfall > 0) {
      flag = 'Advance shortfall';
      flagColor = DashUi.red;
    } else if (under) {
      flag = 'Under hurdle';
      flagColor = DashUi.amberText;
    } else {
      flag = '${w.jobs.length} ${w.jobs.length == 1 ? 'job' : 'jobs'} closed';
      flagColor = DashUi.subtle;
    }
    final status = _weekStatus(w);

    return _Pressable(
      label:
          'Pay week ${_day(w.weekStart)} to ${_day(w.weekEnd)}, cash pay ${_fmt(w.cashPay)}, $flag'
          '${status == null ? '' : ', ${status.label}'}',
      selected: selected,
      radius: BorderRadius.circular(12),
      onTap: () => setState(() => _weekStart = w.weekStart),
      builder: (hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        width: width,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? DashUi.ink : (hover ? DashUi.muted : DashUi.line),
            width: 1.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_day(w.weekStart)} – ${_day(w.weekEnd)}',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: DashUi.ink,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _fmt(w.cashPay),
              style: _num(16, FontWeight.w800, _cashColor(w.cashPay)),
            ),
            const SizedBox(height: 2),
            Text(
              flag,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: flagColor,
              ),
            ),
            if (status != null)
              Text(
                status.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: status.color,
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---- Week summary: the ledger --------------------------------------------

  /// [showCashPay] puts the week's cash pay in the header. With a single pay week it would repeat the hero's
  /// Total Due and the last ledger row, so it is hidden.
  Widget _weekSummary(_Week w, {bool showCashPay = true}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: _flat,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Pay Week',
                      style: TextStyle(
                        fontSize: 12,
                        color: DashUi.slate,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${_day(w.weekStart)} – ${_day(w.weekEnd, year: true)}',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: DashUi.ink,
                      ),
                    ),
                    if (_weekStatus(w) case final s?)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _dot(s.color),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                s.label,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: s.color,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              if (showCashPay)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text(
                      'Cash Pay',
                      style: TextStyle(
                        fontSize: 12,
                        color: DashUi.slate,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      _fmt(w.cashPay),
                      style: _num(22, FontWeight.w800, _cashColor(w.cashPay)),
                    ),
                  ],
                ),
            ],
          ),
          _hurdleBarFor(w, height: 14),
          const SizedBox(height: 10),
          const Divider(height: 1, color: DashUi.line),
          const SizedBox(height: 4),
          _ledgerRow(
            'Closed-job commission (net to tech)',
            w.jobNet,
            dot: DashUi.emeraldDeep,
          ),
          if (w.hurdleCredit > 0)
            _ledgerRow(
              'Retainage held this week',
              w.hurdleCredit,
              dot: DashUi.indigo,
              plus: true,
              note: 'Held back, not paid now, but it counts toward the weekly gross and the hurdle',
            ),
          if (w.advancesPaid != 0)
            _ledgerRow(
              'Advances paid this week',
              w.advancesPaid,
              dot: DashUi.sky,
              plus: true,
            ),
          if (w.callbackPay != 0)
            _ledgerRow(
              'Callback pay',
              w.callbackPay,
              dot: DashUi.amber,
              plus: true,
            ),
          if (w.repPay != 0)
            _ledgerRow(
              'Sales commission (closed jobs)',
              w.repPay,
              dot: DashUi.indigo,
              plus: true,
            ),
          if (w.otherAdjustments != 0)
            _ledgerRow(
              'Other adjustments',
              w.otherAdjustments,
              color: DashUi.subtle,
              note:
                  'Counted in the weekly total but not one of the lines above',
            ),
          const Divider(height: 14, color: DashUi.line),
          _ledgerRow('Weekly gross', w.weeklyGross, bold: true),
          if (w.hurdleRule > 0)
            _ledgerRow(
              'Weekly hurdle',
              -w.hurdleApplied,
              color: DashUi.slate,
            ),
          if (w.advanceRecovered > 0)
            _ledgerRow(
              'Advances recovered',
              -w.advanceRecovered,
              color: DashUi.red,
              note: 'Job commission did not cover advances paid in an earlier week. Taken from this week\'s other pay.',
            ),
          if (w.advanceShortfall > 0)
            _ledgerRow(
              'Advance shortfall',
              w.advanceShortfall,
              color: DashUi.red,
              note: 'Still owed after this week\'s pay. Recovered from a later payroll run.',
            ),
          const Divider(height: 14, color: DashUi.line),
          _ledgerRow(
            'Cash pay for the week',
            w.cashPay,
            color: _cashColor(w.cashPay),
            bold: true,
          ),
        ],
      ),
    );
  }

  Widget _ledgerRow(
    String label,
    double amount, {
    Color color = DashUi.ink,
    Color? dot,
    bool bold = false,
    String? note,
    bool plus = false,
  }) {
    final style = TextStyle(
      fontSize: 13.5,
      color: color,
      fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
      fontFeatures: _figures,
    );
    final text = plus && amount > 0 ? '+${_fmt(amount)}' : _fmt(amount);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 20,
            child: dot == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: _dot(dot),
                  ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: style),
                if (note != null)
                  Text(
                    note,
                    style: const TextStyle(fontSize: 12, color: DashUi.subtle),
                  ),
              ],
            ),
          ),
          Text(text, style: style),
        ],
      ),
    );
  }

  // ---- Closed jobs ----------------------------------------------------------

  Widget _jobsSection(_Tech t, _Week w, _Report report) {
    final keys = [
      for (final j in w.jobs) '${t.userId}|${w.weekStart}|${j.jobId}',
    ];
    final allOpen = keys.every(_expandedJobs.contains);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
          child: Row(
            children: [
              const Flexible(
                child: Text(
                  'Closed Jobs',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: DashUi.ink,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${w.jobs.length}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: DashUi.subtle,
                ),
              ),
              const Spacer(),
              if (w.jobs.length > 1)
                TextButton.icon(
                  icon: Icon(
                    allOpen ? Icons.unfold_less : Icons.unfold_more,
                    size: 18,
                  ),
                  label: Text(allOpen ? 'Collapse all' : 'Expand all'),
                  style: TextButton.styleFrom(
                    foregroundColor: DashUi.slate,
                    textStyle: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  onPressed: () => setState(() {
                    if (allOpen) {
                      _expandedJobs.removeAll(keys);
                    } else {
                      _expandedJobs.addAll(keys);
                    }
                  }),
                ),
            ],
          ),
        ),
        for (var i = 0; i < w.jobs.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          _jobCard(t, w, w.jobs[i], report),
        ],
      ],
    );
  }

  Widget _jobCard(_Tech t, _Week w, _Job j, _Report report) {
    final key = '${t.userId}|${w.weekStart}|${j.jobId}';
    final open = _expandedJobs.contains(key);
    final worked = j.firstWorked.isEmpty
        ? ''
        : (j.firstWorked == j.lastWorked
              ? 'Worked ${_day(j.firstWorked)}'
              : 'Worked ${_day(j.firstWorked)} – ${_day(j.lastWorked)}');

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DashUi.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: Colors.transparent,
            child: Semantics(
              expanded: open,
              child: InkWell(
                onTap: () => setState(() {
                  if (open) {
                    _expandedJobs.remove(key);
                  } else {
                    _expandedJobs.add(key);
                  }
                }),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 14, 16, 14),
                  child: Row(
                    children: [
                      AnimatedRotation(
                        turns: open ? 0.25 : 0,
                        duration: const Duration(milliseconds: 160),
                        child: const Icon(
                          Icons.chevron_right_rounded,
                          size: 22,
                          color: DashUi.subtle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Job ${j.jobId}${j.customer.isEmpty ? '' : '  ${j.customer}'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w800,
                                color: DashUi.ink,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              [
                                if (j.closedOn.isNotEmpty)
                                  'Closed ${_day(j.closedOn, year: true)}',
                                if (j.status.isNotEmpty) j.status,
                                if (worked.isNotEmpty)
                                  '$worked (${j.daysWorked} ${j.daysWorked == 1 ? 'day' : 'days'})',
                                if (j.jobRevenue > 0)
                                  'Job total ${_fmt(j.jobRevenue)}',
                                if (j.lines.isNotEmpty)
                                  'Commission pool ${_fmt(j.poolTotal)}',
                              ].join('   '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12.5,
                                color: DashUi.subtle,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      _chip(
                        'Split ${_pct(j.splitPct)}',
                        DashUi.emeraldText,
                        _goodBg,
                      ),
                      const SizedBox(width: 16),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          const Text(
                            'Net to Tech',
                            style: TextStyle(
                              fontSize: 12,
                              color: DashUi.subtle,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            _fmt(j.net),
                            style: _num(16, FontWeight.w800, _cashColor(j.net)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (open) ...[
            const Divider(height: 1, color: DashUi.line),
            LayoutBuilder(
              builder: (context, c) {
                const minWidth = 720.0;
                final table = _lineTable(j, report);
                if (c.maxWidth >= minWidth) return table;
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(width: minWidth, child: table),
                );
              },
            ),
            _payoutStrip(j, report),
          ],
        ],
      ),
    );
  }

  Widget _lineTable(_Job j, _Report report) {
    const head = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      color: DashUi.slate,
    );
    final hairline = BoxDecoration(
      border: Border(
        top: BorderSide(color: DashUi.line.withValues(alpha: 0.7)),
      ),
    );

    Widget cell(
      String text, {
      TextAlign align = TextAlign.left,
      TextStyle? style,
      double top = 9,
      double bottom = 9,
    }) {
      return Padding(
        padding: EdgeInsets.fromLTRB(16, top, 16, bottom),
        child: Text(
          text,
          textAlign: align,
          style:
              style ??
              const TextStyle(
                fontSize: 13.5,
                color: DashUi.ink,
                fontFeatures: _figures,
              ),
        ),
      );
    }

    TableRow headerRow() => TableRow(
      decoration: BoxDecoration(color: DashUi.faint.withValues(alpha: 0.6)),
      children: [
        cell('Line Item', style: head, top: 8, bottom: 8),
        cell('Category', style: head, top: 8, bottom: 8),
        cell(
          'Job Line',
          align: TextAlign.right,
          style: head,
          top: 8,
          bottom: 8,
        ),
        cell('Tech %', align: TextAlign.right, style: head, top: 8, bottom: 8),
        cell(
          'Tech Share',
          align: TextAlign.right,
          style: head,
          top: 8,
          bottom: 8,
        ),
      ],
    );

    TableRow lineRow(_Line l) {
      final color = l.isPool ? DashUi.red : DashUi.ink;
      final base = TextStyle(
        fontSize: 13.5,
        color: color,
        fontFeatures: _figures,
      );
      return TableRow(
        decoration: hairline,
        children: [
          cell(
            l.isPool
                ? 'Company pool (${_pct(report.companyPoolRate * 100)} of job commission)'
                : l.name,
            style: base,
          ),
          cell(
            l.isPool ? '' : l.category,
            style: const TextStyle(
              fontSize: 12.5,
              color: DashUi.subtle,
              fontWeight: FontWeight.w500,
            ),
          ),
          cell(_fmt(l.jobAmount), align: TextAlign.right, style: base),
          cell(_pct(j.splitPct), align: TextAlign.right, style: base),
          cell(
            _fmt(l.techShare),
            align: TextAlign.right,
            style: base.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      );
    }

    const adjust = TextStyle(
      fontSize: 13.5,
      color: DashUi.subtle,
      fontFeatures: _figures,
    );
    final rows = <TableRow>[
      headerRow(),
      for (final l in j.lines) lineRow(l),
      if (j.adjustment != 0)
        TableRow(
          decoration: hairline,
          children: [
            cell(
              j.adjustment < 0
                  ? 'Pool cap: held back, not paid out'
                  : 'Adjustment',
              style: adjust,
            ),
            cell(''),
            cell(''),
            cell(''),
            cell(_fmt(j.adjustment), align: TextAlign.right, style: adjust),
          ],
        ),
      if (j.toCompanyPool > 0)
        TableRow(
          decoration: hairline,
          children: [
            cell('Sent to company pool from this job', style: adjust),
            cell(''),
            cell(''),
            cell(''),
            cell(_fmt(j.toCompanyPool), align: TextAlign.right, style: adjust),
          ],
        ),
    ];

    return Table(
      columnWidths: const {
        0: FlexColumnWidth(5),
        1: FlexColumnWidth(3.2),
        2: FlexColumnWidth(1.8),
        3: FlexColumnWidth(1.2),
        4: FlexColumnWidth(1.8),
      },
      children: rows,
    );
  }

  /// Net pool share, minus what is held back, equals what the tech keeps from this job.
  Widget _payoutStrip(_Job j, _Report report) {
    Widget op(String s) => Text(
      s,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: DashUi.subtle,
      ),
    );

    Widget chip(
      String label,
      double value,
      Color color, {
      bool strong = false,
    }) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: strong ? _goodBg : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: strong ? _goodBorder : DashUi.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 11.5,
                color: DashUi.slate,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 1),
            Text(_fmt(value), style: _num(14.5, FontWeight.w800, color)),
          ],
        ),
      );
    }

    // Nothing comes off the share (no retainage, no advances to repay): Net to Tech equals Net Pool Share and is
    // already in the job header, so the equation would only repeat one number.
    if (j.retainage == 0 && j.advancesRepaid == 0)
      return const SizedBox.shrink();

    return Container(
      color: DashUi.faint,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          chip('Net Pool Share', j.share, DashUi.ink),
          if (j.retainage != 0) ...[
            op('−'),
            chip(
              'Retainage Held (${_pct(report.retainageRate * 100)})',
              j.retainage,
              DashUi.ink,
            ),
          ],
          if (j.advancesRepaid != 0) ...[
            op('−'),
            chip('Advances Repaid', j.advancesRepaid, DashUi.ink),
          ],
          op('='),
          chip('Net to Tech', j.net, _cashColor(j.net), strong: true),
        ],
      ),
    );
  }

  // ---- Advance days and callbacks -------------------------------------------

  Widget? _dayCards(_Week w) {
    final cards = <Widget>[
      if (w.advances.isNotEmpty)
        _dayCard('Advance Days', w.advances, DashUi.sky),
      if (w.callbacks.isNotEmpty)
        _dayCard('Callbacks', w.callbacks, DashUi.amber),
      if (w.repCommissions.isNotEmpty) _repCard(w.repCommissions),
    ];
    if (cards.isEmpty) return null;

    return LayoutBuilder(
      builder: (context, c) {
        if (cards.length == 2 && c.maxWidth >= 720) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: cards[0]),
              const SizedBox(width: 16),
              Expanded(child: cards[1]),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _spaced(cards),
        );
      },
    );
  }

  Widget _dayCard(String title, List<_DayItem> items, Color color) {
    final total = items.fold<double>(0, (s, i) => s + i.amount);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: _flat,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: _dot(color, size: 9),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: DashUi.ink,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                _fmt(total),
                style: _num(
                  15,
                  FontWeight.w800,
                  total < 0 ? DashUi.red : DashUi.ink,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final i in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: DashUi.faint,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _day(i.date),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: DashUi.slate,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Job ${i.jobId}${i.customer.isEmpty ? '' : '  ${i.customer}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13.5, color: DashUi.ink),
                    ),
                  ),
                  Text(
                    _fmt(i.amount),
                    style: _num(13.5, FontWeight.w700, DashUi.ink),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _repCard(List<_RepItem> items) {
    final total = items.fold<double>(0, (s, i) => s + i.amount);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: _flat,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: _dot(DashUi.indigo, size: 9),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Sales Commission',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: DashUi.ink,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Percent of labor on won estimates, paid once the job closes (first payroll of the next month).',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: DashUi.subtle,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              Text(_fmt(total), style: _num(15, FontWeight.w800, DashUi.ink)),
            ],
          ),
          const SizedBox(height: 10),
          for (final i in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: DashUi.faint,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _day(i.closedOn),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: DashUi.slate,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Est ${i.jobId}${i.customer.isEmpty ? '' : '  ${i.customer}'}  ·  '
                      '${_fmt(i.labor)} labor × ${_pct(i.ratePct)}${i.basisLabel.isEmpty ? '' : ', ${i.basisLabel}'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13.5, color: DashUi.ink),
                    ),
                  ),
                  Text(
                    _fmt(i.amount),
                    style: _num(13.5, FontWeight.w700, DashUi.ink),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ---- Retainage released ---------------------------------------------------

  Widget _releasesPanel(_Tech t) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: _flat,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: _dot(DashUi.indigo, size: 9),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Commercial Retainage Released',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: DashUi.ink,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Paid out in these dates. Callback charges against retainage are netted in.',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: DashUi.subtle,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                _fmt(t.totals.retainageReleased),
                style: _num(
                  15,
                  FontWeight.w800,
                  t.totals.retainageReleased < 0 ? DashUi.red : DashUi.ink,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final r in t.releases)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: DashUi.faint,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _day(r.releasedOn),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: DashUi.slate,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${r.jobId.isEmpty ? 'No job' : 'Job ${r.jobId}'}  ·  '
                      '${r.type == 'callback_deduction' ? 'Callback charge' : 'Retainage released'}',
                      style: const TextStyle(fontSize: 13.5, color: DashUi.ink),
                    ),
                  ),
                  Text(
                    _fmt(r.amount),
                    style: _num(
                      13.5,
                      FontWeight.w700,
                      r.amount < 0 ? DashUi.red : DashUi.ink,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A cleared weekly hurdle: a full bar of green "liquid" with two waves drifting across it. The waves slow to a stop
/// after a few seconds and the bar then holds still, so a page of cleared hurdles doesn't keep redrawing forever.
/// Starts still when the OS asks for reduced motion.
class _LiquidBar extends StatefulWidget {
  final double height;
  const _LiquidBar({required this.height});

  @override
  State<_LiquidBar> createState() => _LiquidBarState();
}

class _LiquidBarState extends State<_LiquidBar>
    with SingleTickerProviderStateMixin {
  static const _cycles = 2.0; // wave periods drifted before coming to rest
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );
  late final CurvedAnimation _drift = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOutCubic,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Called again on every window resize; only the first call starts the drift.
    if (MediaQuery.of(context).disableAnimations) {
      _c.value = 1;
    } else if (!_c.isAnimating && !_c.isCompleted) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    _c.dispose();
    return super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.height / 2),
        child: SizedBox(
          height: widget.height,
          child: AnimatedBuilder(
            animation: _drift,
            builder: (context, _) => CustomPaint(
              painter: _LiquidPainter(_drift.value * _cycles),
              size: Size.infinite,
            ),
          ),
        ),
      ),
    );
  }
}

class _LiquidPainter extends CustomPainter {
  final double t;
  _LiquidPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          colors: [
            DashUi.emeraldDeep,
            Color.lerp(DashUi.emeraldDeep, Colors.white, 0.18)!,
          ],
        ).createShader(Offset.zero & size),
    );
    void wave(double phase, double amp, double level, Color color) {
      final path = Path()..moveTo(0, size.height);
      for (var x = 0.0; x <= size.width; x += 2) {
        final y =
            size.height * level +
            amp * math.sin((x / size.width) * 2 * math.pi * 3 + phase);
        path.lineTo(x, y);
      }
      path
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(path, Paint()..color = color);
    }

    final a = t * 2 * math.pi;
    wave(a, size.height * 0.16, 0.42, Colors.white.withValues(alpha: 0.22));
    wave(
      -a * 1.3 + 1.5,
      size.height * 0.12,
      0.6,
      Colors.white.withValues(alpha: 0.16),
    );
  }

  @override
  bool shouldRepaint(_LiquidPainter old) => old.t != t;
}

/// Mouse, keyboard and screen-reader access for a custom tile (scorecards, range pills, pay-week chips): click
/// cursor, Tab focus with a visible ring, Enter or Space to press, and one button node named [label]. [builder] gets
/// whether the mouse is over the tile, for its hover look.
class _Pressable extends StatefulWidget {
  final String label;
  final bool selected;
  final BorderRadius radius;
  final String? tooltip;
  final VoidCallback onTap;
  final Widget Function(bool hover) builder;

  const _Pressable({
    required this.label,
    required this.onTap,
    required this.builder,
    this.selected = false,
    this.radius = const BorderRadius.all(Radius.circular(10)),
    this.tooltip,
  });

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    Widget tile = FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      onShowHoverHighlight: (v) => setState(() => _hover = v),
      onShowFocusHighlight: (v) => setState(() => _focus = v),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // The tap is already on the node above. A second one here would split the focus state off into an
        // unlabelled node of its own.
        excludeFromSemantics: true,
        onTap: widget.onTap,
        child: ExcludeSemantics(
          child: Container(
            // The ring only shows for keyboard focus, not after a click.
            foregroundDecoration: _focus
                ? BoxDecoration(
                    borderRadius: widget.radius,
                    border: Border.all(color: DashUi.blue, width: 2),
                  )
                : null,
            // Not selectable text: its I-beam cursor would replace the click cursor over the tile.
            child: SelectionContainer.disabled(child: widget.builder(_hover)),
          ),
        ),
      ),
    );
    final tip = widget.tooltip;
    // Inside the button node, so a screen reader hears the tooltip as this button's hint.
    if (tip != null)
      tile = Tooltip(
        message: tip,
        waitDuration: const Duration(milliseconds: 500),
        child: tile,
      );
    return Semantics(
      container: true,
      button: true,
      selected: widget.selected,
      label: widget.label,
      onTap: widget.onTap,
      child: tile,
    );
  }
}
