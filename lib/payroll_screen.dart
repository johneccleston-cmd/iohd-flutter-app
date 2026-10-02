import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'config/api_config.dart';
import 'payroll_sample_data.dart';
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

/// Shows the Live / Sample switch so the screen can be previewed with made-up data.
/// Set to false after go-live (and delete payroll_sample_data.dart).
const bool _showSampleToggle = true;

class _P {
  static const wash = Color(0xFFF8FAFC);
  static const goodBg = Color(0xFFECFDF5);
  static const goodFg = Color(0xFF047857);
  static const toggleActive = Color(0xFF1D4ED8);
  static const badBg = Color(0xFFFEF2F2);
  static const badFg = Color(0xFFB91C1C);
  static const sampleBg = Color(0xFFFFFBEB);
  static const sampleFg = Color(0xFF92400E);
}

const List<FontFeature> _figures = [FontFeature.tabularFigures()];

double _d(dynamic v) {
  if (v is num) return v.toDouble();
  return double.tryParse(v?.toString() ?? '') ?? 0.0;
}

String _s(dynamic v) => v?.toString() ?? '';

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

int _daysBetween(DateTime a, DateTime b) =>
    DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

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
      share = _d(j['share']),
      retainage = _d(j['retainage']),
      advancesRepaid = _d(j['advancesRepaid']),
      net = _d(j['net']),
      lines = ((j['lines'] as List?) ?? const []).map((e) => _Line(Map<String, dynamic>.from(e as Map))).toList();
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

class _Week {
  final String weekStart;
  final String weekEnd;
  final double jobNet;
  final double advancesPaid;
  final double callbackPay;
  final double otherAdjustments;
  final double weeklyGross;
  final double hurdleApplied;
  final double hurdleRule;
  final double cashPay;
  final double advanceShortfall;
  final List<_Job> jobs;
  final List<_DayItem> advances;
  final List<_DayItem> callbacks;

  _Week(Map<String, dynamic> j)
    : weekStart = _s(j['weekStart']),
      weekEnd = _s(j['weekEnd']),
      jobNet = _d(j['jobNet']),
      advancesPaid = _d(j['advancesPaid']),
      callbackPay = _d(j['callbackPay']),
      otherAdjustments = _d(j['otherAdjustments']),
      weeklyGross = _d(j['weeklyGross']),
      hurdleApplied = _d(j['hurdleApplied']),
      hurdleRule = _d(j['hurdleRule']),
      cashPay = _d(j['cashPay']),
      advanceShortfall = _d(j['advanceShortfall']),
      jobs = ((j['jobs'] as List?) ?? const []).map((e) => _Job(Map<String, dynamic>.from(e as Map))).toList(),
      advances = ((j['advances'] as List?) ?? const [])
          .map((e) => _DayItem(Map<String, dynamic>.from(e as Map)))
          .toList(),
      callbacks = ((j['callbacks'] as List?) ?? const [])
          .map((e) => _DayItem(Map<String, dynamic>.from(e as Map)))
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
  final bool isSales;
  final bool isCallbackOnly;
  final _Totals totals;
  final List<_Week> weeks;
  final List<_Release> releases;

  _Tech(Map<String, dynamic> j)
    : userId = _d(j['userId']).round(),
      name = _s(j['name']),
      role = _s(j['role']),
      isSales = j['isSales'] == true,
      isCallbackOnly = j['isCallbackOnly'] == true,
      totals = _Totals(Map<String, dynamic>.from((j['totals'] as Map?) ?? const {})),
      weeks = ((j['weeks'] as List?) ?? const []).map((e) => _Week(Map<String, dynamic>.from(e as Map))).toList(),
      releases = ((j['retainageReleases'] as List?) ?? const [])
          .map((e) => _Release(Map<String, dynamic>.from(e as Map)))
          .toList();

  int get jobCount => weeks.fold<int>(0, (n, w) => n + w.jobs.length);

  double get jobNet => weeks.fold<double>(0, (s, w) => s + w.jobNet);

  String get kindLabel {
    if (isCallbackOnly) return 'Callback pay only';
    if (isSales) return 'Sales';
    return role;
  }
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
      techs = ((j['techs'] as List?) ?? const []).map((e) => _Tech(Map<String, dynamic>.from(e as Map))).toList();
}

class _Opt {
  final String key;
  final String label;
  const _Opt(this.key, this.label);
}

/// The scorecards that open a log of the entries behind their number.
enum _Metric {
  totalDue('Total Due', 'Weekly cash pay and retainage released', DashUi.emeraldDeep),
  commission('Closed-Job Commission', 'Net to the tech from every closed job', DashUi.ink),
  retainage('Retainage Held', 'Commercial retainage held back on closed jobs', DashUi.indigo),
  pool('Company Pool', 'Pool contribution taken from each closed job', DashUi.slate),
  advCallbacks('Advances & Callbacks', 'Flat advance days and callback pay', DashUi.amber);

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
  _Opt('last2', 'Last 2 Weeks'),
  _Opt('thisMonth', 'This Month'),
  _Opt('lastMonth', 'Last Month'),
  _Opt('ytd', 'Year to Date'),
  _Opt('custom', 'Custom'),
];

DateTimeRange _rangeFor(String key) {
  final t = _today();
  final monday = _addDays(t, -(t.weekday - 1));
  switch (key) {
    case 'thisWeek':
      return DateTimeRange(start: monday, end: _addDays(monday, 6));
    case 'last2':
      return DateTimeRange(start: _addDays(monday, -14), end: _addDays(monday, -1));
    case 'thisMonth':
      return DateTimeRange(start: DateTime(t.year, t.month, 1), end: t);
    case 'lastMonth':
      return DateTimeRange(start: DateTime(t.year, t.month - 1, 1), end: DateTime(t.year, t.month, 0));
    case 'ytd':
      return DateTimeRange(start: DateTime(t.year, 1, 1), end: t);
    default:
      return DateTimeRange(start: _addDays(monday, -7), end: _addDays(monday, -1));
  }
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class PayrollScreen extends StatefulWidget {
  const PayrollScreen({super.key});

  @override
  State<PayrollScreen> createState() => _PayrollScreenState();
}

class _PayrollScreenState extends State<PayrollScreen> {
  DateTimeRange _range = _rangeFor('lastWeek');
  _Report? _report;
  bool _loading = false;
  String? _error;
  int _requestId = 0;
  bool _sample = false;
  int? _selectedId; // null = everyone (the register)
  _Metric? _metric; // scorecard whose log is open
  bool _exporting = false;
  String? _weekStart; // which pay week is open for the selected technician
  final Set<String> _collapsedJobs = {}; // jobs the user has folded away

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  // ---- Range ---------------------------------------------------------------

  DateTimeRange get _shownRange {
    final r = _report;
    if (_sample && r != null) {
      final s = _parseDay(r.start);
      final e = _parseDay(r.end);
      if (s != null && e != null) return DateTimeRange(start: s, end: e);
    }
    return _range;
  }

  String get _activeKey {
    for (final p in _kPresets) {
      if (p.key == 'custom') continue;
      final r = _rangeFor(p.key);
      if (r.start == _range.start && r.end == _range.end) return p.key;
    }
    return 'custom';
  }

  bool get _canStep =>
      !_sample && _range.start.weekday == DateTime.monday && (_daysBetween(_range.start, _range.end) + 1) % 7 == 0;

  void _step(int dir) {
    if (!_canStep) return;
    final days = _daysBetween(_range.start, _range.end) + 1;
    setState(() {
      _range = DateTimeRange(start: _addDays(_range.start, dir * days), end: _addDays(_range.end, dir * days));
    });
    _load();
  }

  Future<void> _selectPreset(String key) async {
    if (_sample) return;
    if (key == 'custom') {
      await _pickCustom();
      return;
    }
    setState(() => _range = _rangeFor(key));
    _load();
  }

  Future<void> _pickCustom() async {
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: _range,
      firstDate: DateTime(2020),
      lastDate: _addDays(_today(), 30),
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
    setState(() => _range = picked);
    _load();
  }

  // ---- Data ----------------------------------------------------------------

  void _selectTech(int? id) => setState(() {
    _selectedId = id;
    _weekStart = null;
    _metric = null;
  });

  void _toggleMetric(_Metric m) => setState(() => _metric = _metric == m ? null : m);

  void _setSample(bool on) {
    if (on == _sample) return;
    setState(() {
      _sample = on;
      _selectedId = null;
      _weekStart = null;
      _metric = null;
      _report = null;
      _error = null;
    });
    _load();
  }

  void _applySample() {
    _requestId++; // ignore any live request still in flight
    final report = _Report(json.decode(kPayrollSampleJson) as Map<String, dynamic>);
    setState(() {
      _report = report;
      _loading = false;
      _error = null;
    });
  }

  Future<void> _load() async {
    if (_sample) {
      _applySample();
      return;
    }
    final id = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final uri = Uri.parse('$kApiBaseUrl/api/payroll/commission-detail')
          .replace(queryParameters: {'start': _ymd(_range.start), 'end': _ymd(_range.end)});
      final response = await http
          .get(
            uri,
            headers: {
              'Content-Type': 'application/json',
              if (kAuthToken.isNotEmpty) 'Authorization': 'Bearer $kAuthToken',
            },
          )
          .timeout(const Duration(seconds: 90)); // the hosted server can be slow to wake up

      if (!mounted || id != _requestId) return;

      if (response.statusCode == 200) {
        final report = _Report(json.decode(response.body) as Map<String, dynamic>);
        setState(() {
          _report = report;
          _loading = false;
          if (_selectedId != null && !report.techs.any((t) => t.userId == _selectedId)) {
            _selectedId = null;
          }
        });
      } else {
        String message = 'The server returned status ${response.statusCode}.';
        try {
          final body = json.decode(response.body);
          if (body is Map && body['error'] != null) message = body['error'].toString();
        } catch (_) {}
        if (response.statusCode == 401 || response.statusCode == 403) {
          message = 'You do not have access to payroll reports. Sign in with an office account and try again.';
        }
        setState(() {
          _error = message;
          _loading = false;
        });
      }
    } on TimeoutException {
      if (!mounted || id != _requestId) return;
      setState(() {
        _error = 'The server took too long to respond. Try again in a moment.';
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _error = 'Could not reach the server. Check the connection and try again.';
        _loading = false;
      });
    }
  }

  List<_Tech> _visibleTechs(_Report r) {
    if (_selectedId == null) return r.techs;
    return r.techs.where((t) => t.userId == _selectedId).toList();
  }

  _Totals _totalsFor(List<_Tech> techs) {
    double sum(double Function(_Totals) f) => techs.fold<double>(0, (s, t) => s + f(t.totals));
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
      final bytes = await _buildPayrollPdf(r, sample: _sample);
      if (!mounted) return;
      await Printing.layoutPdf(
        name: 'Payroll ${r.start} to ${r.end}.pdf',
        format: PdfPageFormat.a4.landscape,
        onLayout: (_) async => bytes,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not create the PDF. Try again.')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ---- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Material(
      color: DashUi.faint,
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          final pad = w < 600 ? 12.0 : (w < 1000 ? 16.0 : 20.0);
          return SingleChildScrollView(
            padding: EdgeInsets.all(pad),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1600),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _toolbar(),
                    const SizedBox(height: 12),
                    _results(wide: w - pad * 2 >= 1000),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ---- Toolbar -------------------------------------------------------------

  Widget _toolbar() {
    final range = _shownRange;
    final label = '${DateFormat('MMM d').format(range.start)} – ${DateFormat('MMM d, yyyy').format(range.end)}';
    final r = _report;
    final widened = !_sample && r != null && (r.start != _ymd(_range.start) || r.end != _ymd(_range.end));
    final String? note = widened ? 'Showing whole pay weeks, ${_day(r.start)} to ${_day(r.end, year: true)}.' : null;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: DashUi.panel(radius: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _toolbarControls(label)),
              const SizedBox(width: 12),
              _toolbarActions(),
            ],
          ),
          if (note != null) ...[
            const SizedBox(height: 6),
            Text(
              note,
              style: const TextStyle(fontSize: 12, color: DashUi.muted, fontWeight: FontWeight.w500),
            ),
          ],
        ],
      ),
    );
  }

  Widget _toolbarActions() {
    final hasData = _report != null && _report!.techs.isNotEmpty;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        OutlinedButton.icon(
          icon: _exporting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: DashUi.slate),
                )
              : const Icon(Icons.picture_as_pdf_outlined, size: 18),
          label: const Text('Export PDF'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 40),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            foregroundColor: DashUi.ink,
            backgroundColor: Colors.white,
            side: const BorderSide(color: DashUi.line),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
          ),
          onPressed: hasData && !_exporting ? _exportPdf : null,
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'Refresh',
          iconSize: 20,
          color: DashUi.slate,
          icon: const Icon(Icons.refresh_rounded),
          onPressed: _loading ? null : _load,
        ),
      ],
    );
  }

  Widget _toolbarControls(String label) {
    return Wrap(
      spacing: 14,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _stepper(label),
        Opacity(
          opacity: _sample ? 0.45 : 1,
          child: IgnorePointer(
            ignoring: _sample,
            child: _pillGroup(items: _kPresets, active: _activeKey, onSelected: _selectPreset),
          ),
        ),
        if (_showSampleToggle)
          _pillGroup(
            items: const [_Opt('live', 'Live Data'), _Opt('sample', 'Sample Data')],
            active: _sample ? 'sample' : 'live',
            onSelected: (k) => _setSample(k == 'sample'),
          ),
        if (_loading)
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: DashUi.slate)),
      ],
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
          btn(Icons.chevron_left_rounded, 'Previous pay weeks', can ? () => _step(-1) : null),
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
          btn(Icons.chevron_right_rounded, 'Next pay weeks', can ? () => _step(1) : null),
        ],
      ),
    );
  }

  Widget _pillGroup({required List<_Opt> items, required String active, required ValueChanged<String> onSelected}) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(10)),
      child: Wrap(
        spacing: 2,
        runSpacing: 2,
        children: [for (final o in items) _pill(o.label, o.key == active, () => onSelected(o.key))],
      ),
    );
  }

  Widget _pill(String text, bool selected, VoidCallback onTap) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.white.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: selected ? DashUi.line : DashUi.line.withValues(alpha: 0)),
          ),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              color: selected ? _P.toggleActive : DashUi.slate,
            ),
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
      if (_loading) {
        return _centered(const CircularProgressIndicator(color: DashUi.slate));
      }
      if (_error != null) {
        return _centered(
          _stateMessage(
            icon: Icons.cloud_off_rounded,
            title: 'Could not load the report',
            message: _error!,
            action: OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42)),
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
          action: _showSampleToggle && !_sample
              ? OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42)),
                  icon: const Icon(Icons.science_outlined, size: 18),
                  label: const Text('Preview with sample data'),
                  onPressed: () => _setSample(true),
                )
              : null,
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
        : (selected == null ? <Widget>[_register(report)] : _techDetail(selected, report));

    final banner = _error == null ? <Widget>[] : <Widget>[_errorBanner(), const SizedBox(height: 12)];

    final scorecards = _scorecards(totals, jobNet, report.companyPoolRate, wide);

    if (wide) {
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
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _spaced(detail)),
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

  List<Widget> _spaced(List<Widget> items) {
    final out = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      if (i > 0) out.add(const SizedBox(height: 12));
      out.add(items[i]);
    }
    return out;
  }

  Widget _stateMessage({required IconData icon, required String title, required String message, Widget? action}) {
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
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: DashUi.ink),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: DashUi.slate, height: 1.4),
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
        color: _P.badBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, size: 18, color: _P.badFg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _error ?? '',
              style: const TextStyle(fontSize: 13, color: _P.badFg, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(onPressed: _loading ? null : _load, child: const Text('Try again')),
        ],
      ),
    );
  }

  // ---- Scorecards ----------------------------------------------------------

  Widget _scorecards(_Totals t, double jobNet, double poolRate, bool wide) {
    Widget tappable(_Metric m, Widget card) {
      final on = _metric == m;
      return Tooltip(
        message: on ? 'Close the log' : 'See every entry behind ${m.label}',
        waitDuration: const Duration(milliseconds: 500),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _toggleMetric(m),
            child: Stack(
              children: [
                Positioned.fill(child: card),
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: on ? m.color : m.color.withValues(alpha: 0), width: 2),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final cards = <Widget>[
      tappable(
        _Metric.totalDue,
        AnimatedMetricCard(title: 'Total Due', value: t.totalDue, valueColor: DashUi.emeraldDeep, index: 0),
      ),
      tappable(
        _Metric.commission,
        AnimatedMetricCard(title: 'Closed-Job Commission', value: jobNet, valueColor: DashUi.ink, index: 1),
      ),
      tappable(
        _Metric.retainage,
        AnimatedMetricCard(title: 'Retainage Held', value: t.retainage, valueColor: DashUi.indigo, index: 2),
      ),
      tappable(
        _Metric.pool,
        AnimatedMetricCard(
          title: 'Company Pool (${_pct(poolRate * 100)})',
          value: t.companyPool,
          valueColor: DashUi.slate,
          index: 3,
        ),
      ),
      tappable(
        _Metric.advCallbacks,
        AnimatedMetricCard(
          title: 'Advances & Callbacks',
          value: t.advancesPaid + t.callbackPay,
          valueColor: DashUi.amber,
          index: 4,
        ),
      ),
    ];

    if (wide) {
      final row = <Widget>[];
      for (var i = 0; i < cards.length; i++) {
        if (i > 0) row.add(const SizedBox(width: 8));
        row.add(Expanded(child: cards[i]));
      }
      return SizedBox(height: 88, child: Row(children: row));
    }

    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth >= 620 ? 2 : 1;
        const gap = 8.0;
        final width = (c.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final card in cards) SizedBox(width: width, height: 88, child: card)],
        );
      },
    );
  }

  // ---- Scorecard log ---------------------------------------------------------

  List<_LogRow> _logRows(_Metric m, List<_Tech> techs) {
    final rows = <_LogRow>[];
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
              rows.add(_LogRow(j.closedOn, t.name, _jobTitle(j), 'Held from pool share ${_fmt(j.share)}', j.retainage));
            }
          case _Metric.pool:
            for (final j in w.jobs) {
              for (final l in j.lines.where((l) => l.isPool)) {
                rows.add(
                  _LogRow(
                    j.closedOn,
                    t.name,
                    _jobTitle(j),
                    'On job total ${_fmt(j.jobRevenue)}, split ${_pct(j.splitPct)}',
                    l.techShare,
                  ),
                );
              }
            }
          case _Metric.advCallbacks:
            for (final a in w.advances) {
              rows.add(_LogRow(a.date, t.name, 'Advance day', _itemTitle(a), a.amount));
            }
            for (final c in w.callbacks) {
              rows.add(_LogRow(c.date, t.name, 'Callback', _itemTitle(c), c.amount));
            }
        }
      }
      if (m == _Metric.totalDue) {
        for (final r in t.releases) {
          rows.add(
            _LogRow(
              r.releasedOn,
              t.name,
              r.type == 'callback_deduction' ? 'Callback charge against retainage' : 'Retainage released',
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

  String _jobTitle(_Job j) => 'Job ${j.jobId}${j.customer.isEmpty ? '' : '  ${j.customer}'}';

  String _itemTitle(_DayItem i) => 'Job ${i.jobId}${i.customer.isEmpty ? '' : '  ${i.customer}'}';

  Widget _metricLog(_Metric m, List<_Tech> techs, _Report report) {
    final rows = _logRows(m, techs);
    final total = rows.fold<double>(0, (s, r) => s + r.amount);
    final showTech = techs.length > 1;
    final scope = techs.length == 1 ? techs.first.name : 'Everyone';
    final range = '${_day(report.start)} – ${_day(report.end, year: true)}';

    Color amountColor(double v) => v < 0 ? DashUi.red : DashUi.ink;

    return Container(
      decoration: DashUi.panel(radius: 12),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, c) {
          final narrow = c.maxWidth < 680;

          final header = Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 12),
            child: Row(
              children: [
                Padding(padding: const EdgeInsets.only(right: 10), child: _dot(m.color, size: 10)),
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
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: DashUi.ink),
                          ),
                          _chip('${rows.length} ${rows.length == 1 ? 'entry' : 'entries'}', DashUi.slate, DashUi.faint),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${m.blurb}  ·  $scope  ·  $range',
                        style: const TextStyle(fontSize: 12.5, color: DashUi.muted, fontWeight: FontWeight.w500),
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
                      style: TextStyle(fontSize: 12, color: DashUi.slate, fontWeight: FontWeight.w600),
                    ),
                    Text(_fmt(total), style: _num(22, FontWeight.w800, m.color)),
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

          const head = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.slate);
          final columns = narrow
              ? null
              : Container(
                  color: DashUi.faint,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                  child: Row(
                    children: [
                      const SizedBox(width: 72, child: Text('Date', style: head)),
                      if (showTech) const Expanded(flex: 3, child: Text('Technician', style: head)),
                      const Expanded(flex: 5, child: Text('Entry', style: head)),
                      const Expanded(flex: 5, child: Text('Detail', style: head)),
                      const SizedBox(
                        width: 110,
                        child: Text('Amount', textAlign: TextAlign.right, style: head),
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
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
                            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink),
                          ),
                          Text(
                            [_day(r.date), if (showTech) r.tech, if (r.detail.isNotEmpty) r.detail].join('  ·  '),
                            style: const TextStyle(fontSize: 12, color: DashUi.muted, fontWeight: FontWeight.w500),
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
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.slate),
                    ),
                  ),
                  if (showTech)
                    Expanded(
                      flex: 3,
                      child: Row(
                        children: [
                          DashAvatar(name: r.tech, imageUrl: '', size: 22),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              r.tech,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13, color: DashUi.ink),
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
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink),
                    ),
                  ),
                  Expanded(
                    flex: 5,
                    child: Text(
                      r.detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: DashUi.muted, fontWeight: FontWeight.w500),
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
                    child: Text('Nothing logged for these dates.', style: TextStyle(fontSize: 14, color: DashUi.slate)),
                  ),
                )
              else
                for (final r in rows) rowFor(r),
              if (rows.isNotEmpty)
                Container(
                  color: DashUi.faint,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Total  ·  ${rows.length} ${rows.length == 1 ? 'entry' : 'entries'}',
                          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: DashUi.ink),
                        ),
                      ),
                      Text(_fmt(total), style: _num(14.5, FontWeight.w800, m.color)),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  // ---- Technician list -----------------------------------------------------

  Widget _techList(_Report report) {
    return Container(
      decoration: DashUi.panel(),
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
            child: Row(
              children: [
                const Text(
                  'Technicians',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: DashUi.ink),
                ),
                const SizedBox(width: 8),
                Text(
                  '${report.techs.length}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.muted),
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
                  decoration: const BoxDecoration(color: DashUi.ink, shape: BoxShape.circle),
                  child: const Icon(Icons.groups_rounded, size: 18, color: Colors.white),
                ),
                name: 'Everyone',
                subtitle: 'Payroll register',
                due: report.techs.fold<double>(0, (s, t) => s + t.totals.totalDue),
                selected: _selectedId == null,
                onTap: () => _selectTech(null),
              ),
              for (final t in report.techs)
                _techRow(
                  leading: DashAvatar(name: t.name, imageUrl: '', size: 34),
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
                          fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
                          color: DashUi.ink,
                        ),
                      ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11.5, color: DashUi.muted, fontWeight: FontWeight.w500),
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
                    color: due < 0 ? DashUi.red : DashUi.emeraldDeep,
                    fontFeatures: _figures,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _techChips(_Report report) {
    final items = <_Opt>[const _Opt('all', 'Everyone'), for (final t in report.techs) _Opt('${t.userId}', t.name)];
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

  static const List<int> _regFlex = [34, 8, 14, 13, 12, 14, 12, 14, 15, 15];

  Widget _registerCell(int i, Widget child) => Expanded(flex: _regFlex[i], child: child);

  Widget _registerText(int i, String text, {Color color = DashUi.ink, FontWeight weight = FontWeight.w600}) {
    return _registerCell(
      i,
      Text(
        text,
        textAlign: TextAlign.right,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 13.5, fontWeight: weight, color: color, fontFeatures: _figures),
      ),
    );
  }

  Widget _register(_Report report) {
    const heads = [
      'Technician',
      'Jobs',
      'Closed-Job Net',
      'Advances',
      'Callbacks',
      'Gross',
      'Hurdle',
      'Cash Pay',
      'Retainage Released',
      'Total Due',
    ];
    const minWidth = 980.0;

    double sum(double Function(_Tech) f) => report.techs.fold<double>(0, (s, t) => s + f(t));

    final headRow = Container(
      color: DashUi.faint,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          for (var i = 0; i < heads.length; i++)
            _registerCell(
              i,
              Text(
                heads[i],
                textAlign: i == 0 ? TextAlign.left : TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.slate),
              ),
            ),
        ],
      ),
    );

    Widget techRow(_Tech t) {
      return InkWell(
        onTap: () => _selectTech(t.userId),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: DashUi.line)),
          ),
          child: Row(
            children: [
              _registerCell(
                0,
                Row(
                  children: [
                    DashAvatar(name: t.name, imageUrl: '', size: 30),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink),
                          ),
                          Text(
                            t.kindLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11.5, color: DashUi.muted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              _registerText(1, '${t.jobCount}'),
              _registerText(2, _fmt(t.jobNet)),
              _registerText(3, _fmt(t.totals.advancesPaid), color: DashUi.amber),
              _registerText(4, _fmt(t.totals.callbackPay), color: DashUi.amber),
              _registerText(5, _fmt(t.totals.weeklyGross)),
              _registerText(6, _fmt(-t.totals.hurdleApplied), color: DashUi.slate),
              _registerText(7, _fmt(t.totals.cashPay), color: DashUi.emeraldDeep),
              _registerText(8, _fmt(t.totals.retainageReleased), color: DashUi.indigo),
              _registerText(9, _fmt(t.totals.totalDue), color: DashUi.emeraldDeep, weight: FontWeight.w800),
            ],
          ),
        ),
      );
    }

    final totalRow = Container(
      color: DashUi.faint,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          _registerCell(
            0,
            const Text(
              'Total',
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: DashUi.ink),
            ),
          ),
          _registerText(1, '${report.techs.fold<int>(0, (n, t) => n + t.jobCount)}', weight: FontWeight.w800),
          _registerText(2, _fmt(sum((t) => t.jobNet)), weight: FontWeight.w800),
          _registerText(3, _fmt(sum((t) => t.totals.advancesPaid)), color: DashUi.amber, weight: FontWeight.w800),
          _registerText(4, _fmt(sum((t) => t.totals.callbackPay)), color: DashUi.amber, weight: FontWeight.w800),
          _registerText(5, _fmt(sum((t) => t.totals.weeklyGross)), weight: FontWeight.w800),
          _registerText(6, _fmt(-sum((t) => t.totals.hurdleApplied)), color: DashUi.slate, weight: FontWeight.w800),
          _registerText(7, _fmt(sum((t) => t.totals.cashPay)), color: DashUi.emeraldDeep, weight: FontWeight.w800),
          _registerText(8, _fmt(sum((t) => t.totals.retainageReleased)), color: DashUi.indigo, weight: FontWeight.w800),
          _registerText(9, _fmt(sum((t) => t.totals.totalDue)), color: DashUi.emeraldDeep, weight: FontWeight.w800),
        ],
      ),
    );

    final table = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [headRow, for (final t in report.techs) techRow(t), totalRow],
    );

    return Container(
      decoration: DashUi.panel(),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Payroll register',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: DashUi.ink),
                ),
                SizedBox(height: 2),
                Text(
                  'One line per person for these pay weeks. Select a technician for the full line-item breakdown.',
                  style: TextStyle(fontSize: 12.5, color: DashUi.muted, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
          LayoutBuilder(
            builder: (context, c) {
              if (c.maxWidth >= minWidth) return table;
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(width: minWidth, child: table),
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
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(
        text,
        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: fg),
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

  TextStyle _num(double size, FontWeight weight, Color color) =>
      TextStyle(fontSize: size, fontWeight: weight, color: color, fontFeatures: _figures);

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
      panels.add(_weekSummary(w));
      if (w.jobs.isNotEmpty) panels.add(_jobsSection(t, w, report));
      final days = _dayCards(w);
      if (days != null) panels.add(days);
    }

    if (t.releases.isNotEmpty) panels.add(_releasesPanel(t));

    if (t.weeks.isEmpty && t.releases.isEmpty) {
      panels.add(
        Container(
          padding: const EdgeInsets.all(20),
          decoration: DashUi.panel(),
          child: const Text(
            'Nothing to report for this person in these dates.',
            style: TextStyle(color: DashUi.slate, fontSize: 14),
          ),
        ),
      );
    }

    panels.add(_footnote(report));
    return panels;
  }

  // ---- Hero: who and how much -------------------------------------------------

  Widget _techHero(_Tech t) {
    final tot = t.totals;
    final parts = <(String, double, Color)>[
      ('Closed-job net', t.jobNet, DashUi.emeraldDeep),
      ('Advances', tot.advancesPaid, DashUi.sky),
      ('Callbacks', tot.callbackPay, DashUi.amber),
      ('Retainage released', tot.retainageReleased, DashUi.indigo),
      ('Weekly hurdle kept', -tot.hurdleApplied, DashUi.muted),
    ].where((p) => p.$2.abs() > 0.004).toList();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: DashUi.panel(radius: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              DashAvatar(name: t.name, imageUrl: '', size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          t.name,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: DashUi.ink),
                        ),
                        if (t.kindLabel.isNotEmpty) _chip(t.kindLabel, DashUi.slate, DashUi.faint),
                        if (_sample) _chip('Sample', _P.sampleFg, _P.sampleBg),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${t.weeks.length} ${t.weeks.length == 1 ? 'pay week' : 'pay weeks'}, '
                      '${t.jobCount} ${t.jobCount == 1 ? 'job' : 'jobs'} closed',
                      style: const TextStyle(fontSize: 12.5, color: DashUi.muted, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text(
                    'Total Due',
                    style: TextStyle(fontSize: 12, color: DashUi.slate, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    _fmt(tot.totalDue),
                    style: _num(26, FontWeight.w800, tot.totalDue < 0 ? DashUi.red : DashUi.emeraldDeep),
                  ),
                ],
              ),
            ],
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
                        style: const TextStyle(fontSize: 12.5, color: DashUi.slate, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: 6),
                      Text(_fmt(p.$2), style: _num(12.5, FontWeight.w800, DashUi.ink)),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: Row(
            children: [
              const Text(
                'Pay Weeks',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: DashUi.ink),
              ),
              const SizedBox(width: 8),
              Text(
                '${t.weeks.length}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.muted),
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final w in t.weeks)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: _weekChip(w, w.weekStart == active.weekStart),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _weekChip(_Week w, bool selected) {
    final under = w.hurdleRule > 0 && w.weeklyGross < w.hurdleRule;
    final String flag;
    final Color flagColor;
    if (w.advanceShortfall > 0) {
      flag = 'Advance shortfall';
      flagColor = DashUi.red;
    } else if (under) {
      flag = 'Under hurdle';
      flagColor = DashUi.amber;
    } else {
      flag = '${w.jobs.length} ${w.jobs.length == 1 ? 'job' : 'jobs'} closed';
      flagColor = DashUi.muted;
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setState(() => _weekStart = w.weekStart),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          width: 160,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? DashUi.ink : DashUi.line, width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${_day(w.weekStart)} – ${_day(w.weekEnd)}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: DashUi.ink),
              ),
              const SizedBox(height: 4),
              Text(
                _fmt(w.cashPay),
                style: _num(16, FontWeight.w800, w.cashPay > 0 ? DashUi.emeraldDeep : DashUi.muted),
              ),
              const SizedBox(height: 2),
              Text(
                flag,
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: flagColor),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Week summary: the ledger --------------------------------------------

  Widget _weekSummary(_Week w) {
    final underHurdle = w.hurdleRule > 0 && w.weeklyGross < w.hurdleRule;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: DashUi.panel(radius: 12),
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
                      style: TextStyle(fontSize: 12, color: DashUi.slate, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '${_day(w.weekStart)} – ${_day(w.weekEnd, year: true)}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: DashUi.ink),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text(
                    'Cash Pay',
                    style: TextStyle(fontSize: 12, color: DashUi.slate, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    _fmt(w.cashPay),
                    style: _num(22, FontWeight.w800, w.cashPay > 0 ? DashUi.emeraldDeep : DashUi.muted),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(height: 1, color: DashUi.line),
          const SizedBox(height: 4),
          _ledgerRow('Closed-job commission (net to tech)', w.jobNet, dot: DashUi.emeraldDeep),
          if (w.advancesPaid != 0) _ledgerRow('Advances paid this week', w.advancesPaid, dot: DashUi.sky, plus: true),
          if (w.callbackPay != 0) _ledgerRow('Callback pay', w.callbackPay, dot: DashUi.amber, plus: true),
          if (w.otherAdjustments != 0)
            _ledgerRow(
              'Other adjustments',
              w.otherAdjustments,
              color: DashUi.muted,
              note: 'Counted in the weekly total but not one of the lines above',
            ),
          const Divider(height: 14, color: DashUi.line),
          _ledgerRow('Weekly gross', w.weeklyGross, bold: true),
          if (w.hurdleRule > 0)
            _ledgerRow(
              underHurdle ? 'Under the ${_fmt(w.hurdleRule)} hurdle, no cash pay' : 'Weekly hurdle',
              -w.hurdleApplied,
              color: DashUi.slate,
            ),
          if (w.advanceShortfall > 0)
            _ledgerRow(
              'Advance shortfall',
              w.advanceShortfall,
              color: DashUi.red,
              note: 'Job commission did not cover the advances. Recovered from a later payroll run.',
            ),
          const Divider(height: 14, color: DashUi.line),
          _ledgerRow(
            'Cash pay for the week',
            w.cashPay,
            color: w.cashPay > 0 ? DashUi.emeraldDeep : DashUi.muted,
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
            child: dot == null ? null : Padding(padding: const EdgeInsets.only(top: 6), child: _dot(dot)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: style),
                if (note != null) Text(note, style: const TextStyle(fontSize: 12, color: DashUi.muted)),
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
    final keys = [for (final j in w.jobs) '${t.userId}|${w.weekStart}|${j.jobId}'];
    final allOpen = keys.every((k) => !_collapsedJobs.contains(k));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
          child: Row(
            children: [
              const Text(
                'Closed Jobs',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: DashUi.ink),
              ),
              const SizedBox(width: 8),
              Text(
                '${w.jobs.length}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.muted),
              ),
              const Spacer(),
              if (w.jobs.length > 1)
                TextButton.icon(
                  icon: Icon(allOpen ? Icons.unfold_less : Icons.unfold_more, size: 18),
                  label: Text(allOpen ? 'Collapse all' : 'Expand all'),
                  style: TextButton.styleFrom(
                    foregroundColor: DashUi.slate,
                    textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                  ),
                  onPressed: () => setState(() {
                    if (allOpen) {
                      _collapsedJobs.addAll(keys);
                    } else {
                      _collapsedJobs.removeAll(keys);
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
    final open = !_collapsedJobs.contains(key);
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
            child: InkWell(
              onTap: () => setState(() {
                if (open) {
                  _collapsedJobs.add(key);
                } else {
                  _collapsedJobs.remove(key);
                }
              }),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 16, 14),
                child: Row(
                  children: [
                    AnimatedRotation(
                      turns: open ? 0.25 : 0,
                      duration: const Duration(milliseconds: 160),
                      child: const Icon(Icons.chevron_right_rounded, size: 22, color: DashUi.muted),
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
                            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: DashUi.ink),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            [
                              if (j.closedOn.isNotEmpty) 'Closed ${_day(j.closedOn, year: true)}',
                              if (j.status.isNotEmpty) j.status,
                              if (worked.isNotEmpty) '$worked (${j.daysWorked} ${j.daysWorked == 1 ? 'day' : 'days'})',
                              if (j.jobRevenue > 0) 'Job total ${_fmt(j.jobRevenue)}',
                            ].join('   '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12.5, color: DashUi.muted, fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    _chip('Split ${_pct(j.splitPct)}', _P.goodFg, _P.goodBg),
                    const SizedBox(width: 16),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Text(
                          'Net to Tech',
                          style: TextStyle(fontSize: 11.5, color: DashUi.muted, fontWeight: FontWeight.w600),
                        ),
                        Text(_fmt(j.net), style: _num(16, FontWeight.w800, DashUi.emeraldDeep)),
                      ],
                    ),
                  ],
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
    const head = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.slate);
    final hairline = BoxDecoration(
      border: Border(top: BorderSide(color: DashUi.line.withValues(alpha: 0.7))),
    );

    Widget cell(String text, {TextAlign align = TextAlign.left, TextStyle? style, double top = 9, double bottom = 9}) {
      return Padding(
        padding: EdgeInsets.fromLTRB(16, top, 16, bottom),
        child: Text(
          text,
          textAlign: align,
          style: style ?? const TextStyle(fontSize: 13.5, color: DashUi.ink, fontFeatures: _figures),
        ),
      );
    }

    TableRow headerRow() => TableRow(
      decoration: BoxDecoration(color: DashUi.faint.withValues(alpha: 0.6)),
      children: [
        cell('Line Item', style: head, top: 8, bottom: 8),
        cell('Category', style: head, top: 8, bottom: 8),
        cell('Job Line', align: TextAlign.right, style: head, top: 8, bottom: 8),
        cell('Tech %', align: TextAlign.right, style: head, top: 8, bottom: 8),
        cell('Tech Share', align: TextAlign.right, style: head, top: 8, bottom: 8),
      ],
    );

    TableRow lineRow(_Line l) {
      final color = l.isPool ? DashUi.red : DashUi.ink;
      final base = TextStyle(fontSize: 13.5, color: color, fontFeatures: _figures);
      return TableRow(
        decoration: hairline,
        children: [
          cell(l.isPool ? 'Company pool (${_pct(report.companyPoolRate * 100)} of revenue)' : l.name, style: base),
          cell(
            l.isPool ? '' : l.category,
            style: const TextStyle(fontSize: 12.5, color: DashUi.muted, fontWeight: FontWeight.w500),
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

    final adjust = TextStyle(fontSize: 13.5, color: DashUi.muted, fontFeatures: _figures);
    final rows = <TableRow>[
      headerRow(),
      for (final l in j.lines) lineRow(l),
      if (j.adjustment != 0)
        TableRow(
          decoration: hairline,
          children: [
            cell('Adjustment', style: adjust),
            cell(''),
            cell(''),
            cell(''),
            cell(_fmt(j.adjustment), align: TextAlign.right, style: adjust),
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
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: DashUi.muted),
    );

    Widget chip(String label, double value, Color color, {bool strong = false}) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: strong ? _P.goodBg : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: strong ? const Color(0xFFA7F3D0) : DashUi.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 11.5, color: DashUi.slate, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 1),
            Text(_fmt(value), style: _num(14.5, FontWeight.w800, color)),
          ],
        ),
      );
    }

    return Container(
      color: _P.wash,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          chip('Net Pool Share', j.share, DashUi.ink),
          if (j.retainage != 0) ...[
            op('−'),
            chip('Retainage Held (${_pct(report.retainageRate * 100)})', j.retainage, DashUi.indigo),
          ],
          if (j.advancesRepaid != 0) ...[op('−'), chip('Advances Repaid', j.advancesRepaid, DashUi.amber)],
          op('='),
          chip('Net to Tech', j.net, DashUi.emeraldDeep, strong: true),
        ],
      ),
    );
  }

  // ---- Advance days and callbacks -------------------------------------------

  Widget? _dayCards(_Week w) {
    final cards = <Widget>[
      if (w.advances.isNotEmpty)
        _dayCard('Advance Days', 'Flat daily advance. Counts toward the weekly hurdle.', w.advances, DashUi.sky),
      if (w.callbacks.isNotEmpty)
        _dayCard('Callbacks', 'Flat callback pay, outside any job pool.', w.callbacks, DashUi.amber),
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
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _spaced(cards));
      },
    );
  }

  Widget _dayCard(String title, String subtitle, List<_DayItem> items, Color color) {
    final total = items.fold<double>(0, (s, i) => s + i.amount);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: DashUi.panel(radius: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 5), child: _dot(color, size: 9)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: DashUi.ink),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(fontSize: 12.5, color: DashUi.muted, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
              Text(_fmt(total), style: _num(15, FontWeight.w800, color)),
            ],
          ),
          const SizedBox(height: 10),
          for (final i in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(6)),
                    child: Text(
                      _day(i.date),
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.slate),
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
                  Text(_fmt(i.amount), style: _num(13.5, FontWeight.w700, DashUi.ink)),
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
      padding: const EdgeInsets.all(16),
      decoration: DashUi.panel(radius: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 5), child: _dot(DashUi.indigo, size: 9)),
              const SizedBox(width: 8),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Commercial Retainage Released',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: DashUi.ink),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Paid out in these dates. Callback charges against retainage are netted in.',
                      style: TextStyle(fontSize: 12.5, color: DashUi.muted, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
              Text(
                _fmt(t.totals.retainageReleased),
                style: _num(15, FontWeight.w800, t.totals.retainageReleased < 0 ? DashUi.red : DashUi.indigo),
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
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(6)),
                    child: Text(
                      _day(r.releasedOn),
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.slate),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${r.jobId.isEmpty ? 'No job' : 'Job ${r.jobId}'}   '
                      '${r.type == 'callback_deduction' ? 'Callback charge' : 'Retainage held'}',
                      style: const TextStyle(fontSize: 13.5, color: DashUi.ink),
                    ),
                  ),
                  Text(_fmt(r.amount), style: _num(13.5, FontWeight.w700, r.amount < 0 ? DashUi.red : DashUi.ink)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _footnote(_Report report) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        'Amounts show what each pay week is worth before any advance shortfall is carried forward. '
        'This report does not record or pay a payroll run. A job pays in the week it is closed. '
        'Advances are ${_fmt(report.dailyAdvance)} per day on multi-week jobs, callbacks pay ${_fmt(report.callbackPay)}, '
        'and the weekly hurdle is ${_fmt(report.weeklyThreshold)}. Line amounts are rounded to the cent.',
        style: const TextStyle(fontSize: 12, color: DashUi.muted, height: 1.45, fontWeight: FontWeight.w500),
      ),
    );
  }
}
