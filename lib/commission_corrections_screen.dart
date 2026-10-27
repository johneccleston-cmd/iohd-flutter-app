import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'widgets/app_dialog.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/status_pill.dart';

// Fixes for commission data that Service Fusion statuses cannot undo on their own:
// a day marked Completed by mistake, a visit stuck as a callback, a wrong day weight, or a job that
// was closed by accident. Every change needs a reason and is logged on the server.
//
// A fix REPLACES a value, it is not an amount added on top: the server saves it as an override on the work day and the
// 3-minute sync keeps it until the fix is removed. Money only moves through the job's split by verified day weight,
// which the payroll engine works out, so this screen never calculates pay.
//
// Backend: /api/admin/commission/... (src/commission_corrections.js), plus GET /api/payroll/runs to tell which pay
// weeks already have a finalized run (a fix that touches one of those is settled by an adjustment run).

const _ink = DashUi.ink;
const _slate = DashUi.slate;
const _subtle = DashUi.subtle;
const _line = DashUi.line;
const _faint = DashUi.faint;
const _red = DashUi.red;
const _redText = DashUi.redText;
const _amber = DashUi.amber;
const _amberText = DashUi.amberText;
const _green = DashUi.emeraldDeep;
const _greenText = DashUi.emeraldText;
const _figures = [FontFeature.tabularFigures()];

const _base = '/api/admin/commission';
const _searchLimit = 25; // the server returns at most this many jobs
const _historyLimit = 30; // ...and this many corrections for one job
const _runLimit = 200; // ...and this many payroll runs
const _minReason = 5;

class _ApiError implements Exception {
  final String message;
  const _ApiError(this.message);
  @override
  String toString() => message;
}

Future<Map<String, dynamic>> _call(String method, String path, {Map<String, dynamic>? body}) async {
  final uri = Uri.parse('$kApiBaseUrl$path');
  final headers = AuthSession.instance.headers();
  final http.Response res;
  try {
    res =
        await (method == 'POST'
                ? http.post(uri, headers: headers, body: json.encode(body ?? const {}))
                : http.get(uri, headers: headers))
            .timeout(const Duration(seconds: 60));
  } on TimeoutException {
    throw const _ApiError('The server took too long to respond. Try again in a moment.');
  } catch (_) {
    throw const _ApiError("Couldn't reach the server. Check your connection.");
  }

  Map<String, dynamic> data = const {};
  try {
    data = json.decode(res.body) as Map<String, dynamic>;
  } catch (_) {}

  if (res.statusCode == 401) {
    AuthSession.instance.logout();
    throw const _ApiError('Your session expired. Please sign in again.');
  }
  if (res.statusCode == 403) throw const _ApiError('Your account does not have access to commission corrections.');
  if (res.statusCode != 200) throw _ApiError(data['error']?.toString() ?? 'Server error (${res.statusCode}).');
  return data;
}

double? _num(dynamic v) => v == null ? null : double.tryParse(v.toString());

String _day(String? iso) {
  if (iso == null || iso.isEmpty) return '—';
  final d = DateTime.tryParse(iso);
  return d == null ? iso : DateFormat('MMM d, yyyy').format(d.toLocal());
}

String _stamp(dynamic iso) {
  final d = DateTime.tryParse(iso?.toString() ?? '');
  return d == null ? '—' : DateFormat('MMM d, yyyy h:mm a').format(d.toLocal());
}

String _weightText(dynamic v) {
  final n = _num(v);
  if (n == null) return '—';
  return n == n.roundToDouble() ? n.toStringAsFixed(0) : n.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
}

final _money = NumberFormat.currency(symbol: r'$');
String _moneyText(dynamic v) {
  final n = _num(v);
  return n == null ? '—' : _money.format(n);
}

String _ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

/// The Monday that starts [d]'s pay week (pay weeks run Monday to Sunday, as on the Payroll screen).
DateTime _mondayOf(DateTime d) => DateTime(d.year, d.month, d.day - (d.weekday - 1));

/// "Oct 12 – 18, 2026", or "Sep 28 – Oct 4, 2026" across a month end.
String _weekRange(DateTime start, {bool year = true}) {
  final end = DateTime(start.year, start.month, start.day + 6);
  final range =
      '${DateFormat('MMM d').format(start)} – ${DateFormat(start.month == end.month ? 'd' : 'MMM d').format(end)}';
  return year ? '$range, ${end.year}' : range;
}

/// "Payroll has already been run for the week of Oct 5 – 11, 2026. ..." for the fix and unlock dialogs.
String _paidWeeksNotice(List<DateTime> weeks, String then) {
  final names = [for (final w in weeks) _weekRange(w)];
  final list = names.length == 1
      ? 'the week of ${names.first}'
      : 'the weeks of ${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  return 'Payroll has already been run for $list. $then';
}

String _actionLabel(String? a) => switch (a) {
  'set_verified' => 'Verified changed',
  'clear_verified' => 'Verified fix removed',
  'set_callback' => 'Callback changed',
  'clear_callback' => 'Callback fix removed',
  'set_weight' => 'Weight changed',
  'clear_weight' => 'Weight fix removed',
  'unlock_job' => 'Job unlocked',
  _ => a ?? 'Change',
};

IconData _actionIcon(String? a) => switch (_fieldOf(a)) {
  'verified' => Icons.task_alt_rounded,
  'callback' => Icons.replay_rounded,
  'weight' => Icons.balance_rounded,
  _ => a == 'unlock_job' ? Icons.lock_open_rounded : Icons.edit_rounded,
};

/// The field a correction is about: 'verified', 'callback' or 'weight' (null for an unlock).
String? _fieldOf(String? action) {
  for (final f in const ['verified', 'callback', 'weight']) {
    if (action == 'set_$f' || action == 'clear_$f') return f;
  }
  return null;
}

/// "Daniel Baty · 2026-10-15" -> "Daniel Baty · Oct 15, 2026".
String _prettyTarget(String? t) {
  if (t == null || t.isEmpty) return '';
  return t.replaceAllMapped(RegExp(r'\d{4}-\d{2}-\d{2}'), (m) => _day(m[0]));
}

/// Old/new values are stored as raw text ("true", "0.00", "back to sync"); show them in words.
String _prettyValue(String? action, dynamic raw) {
  if (raw == null) return '—';
  final s = raw.toString();
  if (s == 'back to sync') return 'Sync decides';
  final isTrue = s == 'true';
  final isFalse = s == 'false';
  if (action != null && action.endsWith('verified') && (isTrue || isFalse)) return isTrue ? 'Verified' : 'Not verified';
  if (action != null && action.endsWith('callback') && (isTrue || isFalse)) {
    return isTrue ? 'Callback' : 'Not a callback';
  }
  if (action != null && action.endsWith('weight')) return _weightText(s);
  if (isTrue) return 'Yes';
  if (isFalse) return 'No';
  return s;
}

/// What a correction did in one line, e.g. "Weight 0 → 1.5" or "Verified → Not verified".
String _changeLine(Map<String, dynamic> c) {
  final action = c['action']?.toString();
  final field = _fieldOf(action);
  if (field == null || action!.startsWith('clear_') || c['old_value'] == null || c['new_value'] == null) {
    return _actionLabel(action);
  }
  final change = '${_prettyValue(action, c['old_value'])} → ${_prettyValue(action, c['new_value'])}';
  return field == 'weight' ? 'Weight $change' : change;
}

/// What each field of one visit was before the office first fixed it, read from the job's history (newest first).
/// Walks back through the fixes still in effect, stopping at a "fix removed" entry, to the first one: its old value is
/// what the sync had. A field is left out when the history may be cut off before that point, so it is never a guess.
Map<String, String> _valuesBeforeFix(List<Map<String, dynamic>> history, String target, {required bool complete}) {
  final first = <String, Map<String, dynamic>>{};
  final closed = <String>{};
  for (final c in history) {
    if (c['target']?.toString() != target) continue;
    final action = c['action']?.toString();
    final f = _fieldOf(action);
    if (f == null || closed.contains(f)) continue;
    if (action!.startsWith('clear_')) {
      closed.add(f);
    } else {
      first[f] = c; // the list runs newest first, so the last one seen is the first fix
    }
  }
  return {
    for (final e in first.entries)
      if (closed.contains(e.key) || complete) e.key: _prettyValue('set_${e.key}', e.value['old_value']),
  };
}

/// Whether payroll has been run for a pay week.
enum _WeekState { paid, notRun, unknown }

typedef _PayWeek = ({DateTime start, _WeekState state});

/// One work day as the table shows it.
class _Visit {
  final Map<String, dynamic> day;
  final bool verified, callback, fixedV, fixedC, fixedW, before;
  final String weight;

  /// Field -> its value before the office fixed it (only for fields that are fixed now, see [_valuesBeforeFix]).
  final Map<String, String> was;

  /// Why this visit can't be fixed, or null when it can.
  final String? blocked;

  /// Shown when the visit's weight is 0 and nothing explains it.
  final String? zeroWeightHint;

  _Visit(this.day, {required this.was, required this.blocked})
    : verified = day['is_verified'] == true,
      callback = day['is_callback'] == true,
      fixedV = day['override_verified'] != null,
      fixedC = day['override_callback'] != null,
      fixedW = day['override_weight'] != null,
      before = day['beforeGoLive'] == true,
      weight = _weightText(day['day_weight']),
      zeroWeightHint =
          ((_num(day['day_weight']) ?? 0) == 0 && day['is_callback'] != true && day['override_weight'] == null)
          ? 'Weight 0 means this visit earns nothing. The Service Fusion visit had no "full day", "half day" or '
                '"appointment" wording, or it was a callback, verify delivery or manage project visit. '
                'Use Fix to set a weight if it should pay.'
          : null;

  int? get id => day['id'] is int ? day['id'] as int : int.tryParse('${day['id']}');
  String get tech => day['tech_name']?.toString() ?? '';
  String get date => _day(day['work_date']?.toString());
  String get techStatus {
    final s = day['tech_status']?.toString();
    return s == null || s.isEmpty ? 'No status' : s;
  }

  /// "weight 0 · Verified": what the fixed fields were before, for the narrow layout.
  String get wasLine => [
    if (was['weight'] != null) 'weight ${was['weight']}',
    if (was['verified'] != null) was['verified']!,
    if (was['callback'] != null) was['callback']!,
  ].join(' · ');
}

class CommissionCorrectionsScreen extends StatefulWidget {
  const CommissionCorrectionsScreen({super.key});

  @override
  State<CommissionCorrectionsScreen> createState() => _CommissionCorrectionsScreenState();
}

class _CommissionCorrectionsScreenState extends State<CommissionCorrectionsScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  int _searchSeq = 0;

  List<Map<String, dynamic>> _results = [];
  bool _searching = false;
  bool _searched = false;
  String? _searchError;

  String? _jobId;
  Map<String, dynamic>? _detail;
  bool _loadingDetail = false;
  String? _detailError;
  int _detailSeq = 0; // a job load only lands if nothing newer (another load or a save) came after it

  List<Map<String, dynamic>> _recent = [];
  bool _recentLoading = true;
  String? _recentError;

  /// Mondays ('yyyy-MM-dd') that have a finalized payroll run; null until loaded, or when that failed.
  Set<String>? _paidWeeks;

  /// When the run list was full, weeks before its oldest one may have runs it didn't include.
  String? _runsKnownFrom;

  /// The visit that was just saved, highlighted for a moment so it is clear what changed.
  int? _flashDay;
  int _flashSeq = 0;

  @override
  void initState() {
    super.initState();
    _loadRecent();
    _loadRuns();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadRecent({bool quiet = false}) async {
    if (!quiet) {
      setState(() {
        _recentLoading = true;
        _recentError = null;
      });
    }
    try {
      final data = await _call('GET', '$_base/corrections?limit=30');
      if (!mounted) return;
      setState(() {
        _recent = List<Map<String, dynamic>>.from(data['corrections'] ?? const []);
        _recentLoading = false;
        _recentError = null;
      });
    } catch (e) {
      if (!mounted || quiet) return; // a background refresh keeps the list it has
      setState(() {
        _recentLoading = false;
        _recentError = e.toString();
      });
    }
  }

  /// Which pay weeks were already paid. Failing only hides the "already paid" notes; corrections still work.
  Future<void> _loadRuns() async {
    try {
      final data = await _call('GET', '/api/payroll/runs?limit=$_runLimit');
      final runs = List<Map<String, dynamic>>.from(data['runs'] ?? const []);
      final weeks = [for (final r in runs) r['week_start']?.toString() ?? '']..removeWhere((w) => w.isEmpty);
      if (!mounted) return;
      setState(() {
        _paidWeeks = {
          for (final r in runs)
            if (r['status'] == 'finalized' && r['week_start'] != null) r['week_start'].toString(),
        };
        _runsKnownFrom = runs.length >= _runLimit && weeks.isNotEmpty ? (weeks..sort()).first : null;
      });
    } catch (_) {
      // Keep what an earlier load found (still true a moment ago); with nothing loaded, weeks read as "not checked".
    }
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    setState(() {}); // keeps the clear button in step
    _debounce = Timer(const Duration(milliseconds: 350), _runSearch);
  }

  Future<void> _runSearch() async {
    final q = _search.text.trim();
    final seq = ++_searchSeq; // any earlier request is now stale
    if (q.length < 2) {
      setState(() {
        _results = [];
        _searching = false;
        _searched = false;
        _searchError = null;
      });
      return;
    }
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final data = await _call('GET', '$_base/jobs?q=${Uri.encodeQueryComponent(q)}');
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _results = List<Map<String, dynamic>>.from(data['jobs'] ?? const []);
        _searching = false;
        _searched = true;
      });
    } catch (e) {
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _searching = false;
        _searched = true;
        _searchError = e.toString();
      });
    }
  }

  void _clearSearch() {
    _debounce?.cancel();
    _search.clear();
    _runSearch();
  }

  /// [keepContent] keeps the current detail on screen while it reloads (Refresh).
  Future<void> _openJob(String jobId, {bool keepContent = false}) async {
    final seq = ++_detailSeq;
    setState(() {
      if (!keepContent || _jobId != jobId) _detail = null;
      _jobId = jobId;
      _loadingDetail = true;
      _detailError = null;
    });
    unawaited(_loadRuns()); // a payroll run may have been finalized since the screen opened
    try {
      final data = await _call('GET', '$_base/jobs/${Uri.encodeComponent(jobId)}');
      if (!mounted || seq != _detailSeq) return;
      setState(() {
        _applyDetail(data);
        _loadingDetail = false;
      });
    } catch (e) {
      if (!mounted || seq != _detailSeq) return;
      setState(() {
        _loadingDetail = false;
        _detailError = e.toString();
      });
    }
  }

  /// Stores a fresh detail and keeps the Locked / Paid tags in the left list in step with it.
  void _applyDetail(Map<String, dynamic> data) {
    _detail = data;
    final job = data['job'];
    if (job is! Map) return;
    final id = job['job_id']?.toString();
    _results = [
      for (final r in _results)
        if (r['job_id']?.toString() == id)
          {
            ...r,
            'locked': data['lock'] != null,
            'is_commission_paid': job['is_commission_paid'],
            'status': job['status'],
          }
        else
          r,
    ];
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), backgroundColor: error ? _red : _ink, behavior: SnackBarBehavior.floating),
      );
  }

  /// Runs a save from inside a dialog. Returns an error message, or null once it worked.
  /// The dialog stays open (with a spinner, and it can't be dismissed) until then, so a failed save never loses what
  /// was typed and is always reported.
  Future<String?> _save(String path, Map<String, dynamic> body, {String done = 'Correction saved.', int? dayId}) async {
    final jobId = _jobId;
    if (jobId == null) return 'No job is open.';
    try {
      final data = await _call('POST', '$_base/jobs/${Uri.encodeComponent(jobId)}$path', body: body);
      if (mounted) {
        if (_jobId == jobId) {
          setState(() {
            _detailSeq++; // a reload that was still running was asked for before this save: drop it
            _loadingDetail = false;
            _detailError = null;
            _applyDetail(data);
            _flashDay = dayId;
            _flashSeq++;
          });
        }
        final warnings = List<String>.from(data['warnings'] ?? const []);
        _toast(warnings.isEmpty ? done : '$done ${warnings.first}');
        _loadRecent(quiet: true);
      }
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<void> _fixDay(Map<String, dynamic> day, {required bool jobLocked, required List<DateTime> paidWeeks}) async {
    final id = day['id'];
    await showDialog<void>(
      context: context,
      builder: (_) => _FixDayDialog(
        day: day,
        jobLocked: jobLocked,
        paidWeeks: paidWeeks,
        onSave: (body) => _save('/day', {'dayId': id, ...body}, dayId: id is int ? id : int.tryParse('$id')),
      ),
    );
  }

  Future<void> _unlock(Map<String, dynamic> job, Map<String, dynamic> lock, List<DateTime> paidWeeks) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _UnlockDialog(
        job: job,
        lock: lock,
        paidWeeks: paidWeeks,
        onSave: (reason) => _save('/unlock', {'reason': reason}, done: 'Job unlocked.'),
      ),
    );
  }

  // ---- Pay weeks ------------------------------------------------------------

  _WeekState _stateOf(String week, {required bool lockSaysPaid}) {
    if (lockSaysPaid) return _WeekState.paid; // the job's own answer, read with the job
    final paid = _paidWeeks;
    if (paid == null) return _WeekState.unknown;
    if (paid.contains(week)) return _WeekState.paid;
    final from = _runsKnownFrom;
    if (from != null && week.compareTo(from) < 0) return _WeekState.unknown;
    return _WeekState.notRun;
  }

  /// The pay weeks a fix on this job can change: each week a visit was worked (daily advances and callback pay land
  /// there, and so does a quick-close job's commission) and the week the job closed (its commission). Only facts:
  /// which of those a fix really changes is up to the payroll engine.
  List<_PayWeek> _payWeeks(Map<String, dynamic> d) {
    final job = d['job'] is Map ? d['job'] as Map : const {};
    if (job['inScope'] != true) return const [];
    final lock = d['lock'] is Map ? d['lock'] as Map : null;
    final lockWeek = lock?['pay_week']?.toString();
    final today = DateTime.now();
    final weeks = <String>{if (lockWeek != null && lockWeek.isNotEmpty) lockWeek};
    for (final day in (d['days'] as List? ?? const [])) {
      if (day is! Map || day['beforeGoLive'] == true) continue;
      final date = DateTime.tryParse(day['work_date']?.toString() ?? '');
      if (date == null || date.isAfter(today)) continue; // a scheduled visit pays nothing yet
      weeks.add(_ymd(_mondayOf(date)));
    }
    return [
      for (final w in weeks.toList()..sort())
        (start: DateTime.parse(w), state: _stateOf(w, lockSaysPaid: w == lockWeek && lock?['week_paid'] == true)),
    ];
  }

  // ---- UI -----------------------------------------------------------------
  // A flat full page like Payroll: the dark banner on top, then the job list and the open job split by one hairline.
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      child: LayoutBuilder(
        builder: (context, c) {
          final narrow = c.maxWidth < 820;
          final sideWidth = c.maxWidth < 1100 ? 300.0 : 340.0;
          final detailOnly = narrow && _jobId != null;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _banner(narrow),
              Expanded(
                child: narrow
                    ? (detailOnly
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                                  child: TextButton.icon(
                                    onPressed: () => setState(() => _jobId = null),
                                    icon: const Icon(Icons.arrow_back_rounded, size: 18),
                                    label: const Text('Back to search'),
                                    style: TextButton.styleFrom(foregroundColor: _slate),
                                  ),
                                ),
                                const Divider(height: 1, color: _line),
                                Expanded(child: _buildDetailPanel()),
                              ],
                            )
                          : _buildSearchPanel())
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          DecoratedBox(
                            decoration: const BoxDecoration(
                              border: Border(right: BorderSide(color: _line)),
                            ),
                            child: SizedBox(width: sideWidth, child: _buildSearchPanel()),
                          ),
                          Expanded(child: _buildDetailPanel()),
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// The same dark banner every HR page uses.
  Widget _banner(bool narrow) {
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: EdgeInsets.symmetric(horizontal: narrow ? 12 : 24, vertical: 8),
      alignment: Alignment.centerLeft,
      decoration: const BoxDecoration(
        color: DashUi.ink,
        boxShadow: [BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 2))],
      ),
      child: Semantics(
        header: true,
        child: const Text(
          'COMMISSION CORRECTIONS',
          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.2),
        ),
      ),
    );
  }

  // ---- Left: search and recent corrections -----------------------------------

  Widget _buildSearchPanel() {
    final q = _search.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: TextField(
            controller: _search,
            onChanged: _onSearchChanged,
            onSubmitted: (_) => _runSearch(),
            textInputAction: TextInputAction.search,
            decoration: appFieldDecoration(hint: 'Job number or customer').copyWith(
              prefixIcon: const Icon(Icons.search_rounded, size: 20, color: _slate),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close_rounded, size: 18, color: _subtle),
                      onPressed: _clearSearch,
                    ),
            ),
          ),
        ),
        Expanded(child: _buildSearchBody(q)),
      ],
    );
  }

  Widget _buildSearchBody(String q) {
    if (_searchError != null) return _inlineError(_searchError!, _runSearch);
    if (q.isEmpty) return _buildRecent();
    if (q.length < 2) return _hint('Type at least 2 characters.');
    if (_results.isEmpty) {
      if (_searching || !_searched) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 2.5, color: _ink));
      }
      return _hint('No jobs match "$q".\nTry a job number or part of the customer name. Estimates are not listed.');
    }
    // While a new search runs, the last results stay with a thin bar on top instead of flashing to a spinner.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _railHeading(
          _searching ? 'Searching…' : 'Jobs',
          _results.length >= _searchLimit ? 'First $_searchLimit' : '${_results.length}',
        ),
        SizedBox(
          height: 2,
          child: _searching ? const LinearProgressIndicator(minHeight: 2, color: _ink, backgroundColor: _faint) : null,
        ),
        Expanded(
          child: ListView.builder(itemCount: _results.length, itemBuilder: (_, i) => _resultTile(_results[i])),
        ),
        if (_results.length >= _searchLimit)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text(
              'Showing the first 25 matches. Type more to narrow the list.',
              style: TextStyle(fontSize: 12, color: _subtle),
            ),
          ),
      ],
    );
  }

  Widget _railHeading(String title, String meta) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              title,
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: _ink),
            ),
          ),
        ),
        Text(meta, style: const TextStyle(fontSize: 12, color: _subtle)),
      ],
    ),
  );

  Widget _hint(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: _subtle, fontSize: 13, height: 1.4),
      ),
    ),
  );

  Widget _inlineError(String message, VoidCallback retry) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded, color: _red, size: 22),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _redText, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: retry, child: const Text('Try again')),
        ],
      ),
    ),
  );

  /// A row in the left list: the open job is marked with a dark bar on its left edge as well as a tint.
  Widget _railTile({required bool selected, required VoidCallback onTap, required Widget child}) => Semantics(
    selected: selected,
    button: true,
    child: Material(
      color: selected ? _faint : Colors.white,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(13, 10, 16, 11),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: selected ? _ink : Colors.transparent, width: 3),
              bottom: const BorderSide(color: _line),
            ),
          ),
          child: child,
        ),
      ),
    ),
  );

  Widget _resultTile(Map<String, dynamic> j) {
    final locked = j['locked'] == true;
    final paid = j['is_commission_paid'] == true;
    return _railTile(
      selected: j['job_id']?.toString() == _jobId,
      onTap: () => _openJob(j['job_id'].toString()),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            j['customer_name']?.toString() ?? 'Unknown',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _ink),
          ),
          const SizedBox(height: 2),
          Text(
            '#${j['job_id']} · ${j['status'] ?? 'No status'} · ${_day(j['start_date']?.toString())}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5, color: _subtle, fontFeatures: _figures),
          ),
          if (locked || paid)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (locked) _tag('Locked', _amber, text: _amberText, icon: Icons.lock_rounded),
                  if (paid) _tag('Commission paid', _red, text: _redText),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRecent() {
    if (_recentLoading) return const Center(child: CircularProgressIndicator(strokeWidth: 2.5, color: _ink));
    if (_recentError != null) return _inlineError("Couldn't load recent corrections.\n$_recentError", _loadRecent);
    if (_recent.isEmpty) return _hint('Search for a job to see its visits.\nCorrections you make will be listed here.');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _railHeading('Recent corrections', 'Newest first'),
        const Divider(height: 1, color: _line),
        Expanded(
          child: ListView.builder(itemCount: _recent.length, itemBuilder: (_, i) => _recentTile(_recent[i])),
        ),
      ],
    );
  }

  Widget _recentTile(Map<String, dynamic> c) {
    final action = c['action']?.toString();
    final reason = c['reason']?.toString() ?? '';
    return _railTile(
      selected: c['job_id']?.toString() == _jobId,
      onTap: () => _openJob(c['job_id'].toString()),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            margin: const EdgeInsets.only(top: 1, right: 10),
            decoration: BoxDecoration(
              color: action == 'unlock_job' ? _amber.withValues(alpha: 0.12) : _faint,
              shape: BoxShape.circle,
            ),
            child: Icon(_actionIcon(action), size: 15, color: action == 'unlock_job' ? _amberText : _slate),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _changeLine(c),
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: _ink),
                ),
                const SizedBox(height: 1),
                Text(
                  '${c['customer_name'] ?? 'Unknown'} · #${c['job_id']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: _slate),
                ),
                Text(
                  '${c['changed_by_name'] ?? ''} · ${_stamp(c['changed_at'])}',
                  style: const TextStyle(fontSize: 12, color: _subtle),
                ),
                if (reason.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      reason,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: _subtle, fontStyle: FontStyle.italic, height: 1.3),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---- Right: the open job ------------------------------------------------------

  Widget _buildDetailPanel() {
    if (_jobId == null) return _pickAJob();
    if (_detailError != null) {
      return DashErrorPanel(title: "Couldn't load this job", message: _detailError!, onRetry: () => _openJob(_jobId!));
    }
    if (_detail == null) return _detailSkeleton();

    _k = (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1.0, 1.6);
    final d = _detail!;
    final job = Map<String, dynamic>.from(d['job'] as Map);
    final lock = d['lock'] == null ? null : Map<String, dynamic>.from(d['lock'] as Map);
    final days = List<Map<String, dynamic>>.from(d['days'] ?? const []);
    final corrections = List<Map<String, dynamic>>.from(d['corrections'] ?? const []);
    final paid = job['is_commission_paid'] == true;
    final closing = job['statusIsClosing'] == true;
    final inScope = job['inScope'] == true;
    final weeks = _payWeeks(d);
    final paidWeeks = [
      for (final w in weeks)
        if (w.state == _WeekState.paid) w.start,
    ];
    final complete = corrections.length < _historyLimit;

    final visits = [
      for (final day in days)
        _Visit(
          day,
          was: {
            for (final e in _valuesBeforeFix(
              corrections,
              '${day['tech_name']} · ${day['work_date']}',
              complete: complete,
            ).entries)
              if (day['override_${e.key}'] != null) e.key: e.value, // only for a value that is fixed now
          },
          blocked: paid
              ? 'This job is marked commission paid, so its visits are frozen.'
              : day['beforeGoLive'] == true
              ? 'This visit is before go-live, so it is ignored for commission.'
              : !inScope
              ? 'This job started before go-live, so it is ignored for commission.'
              : null,
        ),
    ];

    return Column(
      children: [
        SizedBox(
          height: 2,
          child: _loadingDetail
              ? const LinearProgressIndicator(minHeight: 2, color: _ink, backgroundColor: _faint)
              : null,
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) {
              final pad = c.maxWidth < 560 ? 16.0 : 28.0;
              final inner = c.maxWidth - pad * 2;
              return ListView(
                padding: EdgeInsets.fromLTRB(pad, 18, pad, 36),
                children: [
                  _jobHeader(job, lock: lock, closing: closing),
                  const SizedBox(height: 16),
                  _summaryStrip(job, lock: lock, weeks: weeks, inScope: inScope),
                  if (lock != null) ...[
                    const SizedBox(height: 16),
                    _lockBand(job, lock, closing: closing, paid: paid, paidWeeks: paidWeeks),
                  ],
                  if (paid) ...[
                    const SizedBox(height: 12),
                    const AppNotice(
                      "This job is marked commission paid, so its visits can't be changed.",
                      kind: AppNoticeKind.warning,
                    ),
                  ] else if (!inScope) ...[
                    const SizedBox(height: 12),
                    AppNotice(
                      'This job started before go-live (${_day(d['goLiveDate']?.toString())}), so it earns no '
                      "commission and its visits can't be changed.",
                    ),
                  ],
                  const SizedBox(height: 28),
                  _sectionHeading(
                    'Site visits',
                    '${days.length} ${days.length == 1 ? 'visit' : 'visits'}',
                    trailing: visits.any((v) => v.fixedV || v.fixedC || v.fixedW) ? _fixLegend() : null,
                    wide: inner >= 520,
                  ),
                  const SizedBox(height: 10),
                  if (days.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'No site visits recorded for this job.',
                        style: TextStyle(color: _subtle, fontSize: 13),
                      ),
                    )
                  else if (inner >= _tableMin) ...[
                    _dayHeader(),
                    for (final v in visits) _flash(v, _dayRow(v, locked: lock != null, paidWeeks: paidWeeks)),
                  ] else ...[
                    const Divider(height: 1, color: _line),
                    for (final v in visits) _flash(v, _dayStacked(v, locked: lock != null, paidWeeks: paidWeeks)),
                  ],
                  const SizedBox(height: 32),
                  _sectionHeading(
                    'History',
                    corrections.isEmpty
                        ? ''
                        : complete
                        ? '${corrections.length} ${corrections.length == 1 ? 'change' : 'changes'}'
                        : 'Latest $_historyLimit changes',
                    wide: true,
                  ),
                  const SizedBox(height: 12),
                  if (corrections.isEmpty)
                    const Text(
                      'No corrections have been made to this job.',
                      style: TextStyle(color: _subtle, fontSize: 13),
                    )
                  else
                    for (var i = 0; i < corrections.length; i++)
                      _historyEntry(corrections[i], last: i == corrections.length - 1),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _jobHeader(Map<String, dynamic> job, {required Map<String, dynamic>? lock, required bool closing}) {
    final status = job['status']?.toString();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(
                  job['customer_name']?.toString() ?? 'Unknown customer',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _ink, letterSpacing: -0.3),
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 10,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    'Job #${job['job_id']} · Started ${_day(job['start_date']?.toString())}',
                    style: const TextStyle(fontSize: 13.5, color: _slate, fontFeatures: _figures),
                  ),
                  StatusPill(status ?? 'No status'),
                  if (closing && lock == null) _tag('Closing status: locks on the next sync', _green, text: _greenText),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// The job's figures in one strip, the way the payroll history shows its totals: label, number, plain caption.
  Widget _summaryStrip(
    Map<String, dynamic> job, {
    required Map<String, dynamic>? lock,
    required List<_PayWeek> weeks,
    required bool inScope,
  }) {
    final earned = _num(job['commission_earned']) ?? 0;
    final tiles = [
      _stat('Job total', _moneyText(job['total_revenue']), 'From Service Fusion'),
      _stat(
        'Projected commission',
        _moneyText(job['commission_projected']),
        inScope ? 'The pool before the tech split' : 'Started before go-live',
      ),
      _stat(
        'Earned commission',
        _moneyText(job['commission_earned']),
        !inScope
            ? 'Started before go-live'
            : lock != null
            ? 'Frozen when the job closed'
            : 'Nothing until the job closes',
        color: earned > 0 ? _greenText : _ink,
      ),
      _payWeeksStat(weeks, inScope: inScope),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: _line),
          bottom: BorderSide(color: _line),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          Widget row(List<Widget> items) => IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const VerticalDivider(width: 33, thickness: 1, color: _line),
                  Expanded(child: items[i]),
                ],
              ],
            ),
          );
          if (c.maxWidth >= 680) return row(tiles);
          if (c.maxWidth >= 340) {
            return Column(children: [row(tiles.sublist(0, 2)), const SizedBox(height: 14), row(tiles.sublist(2))]);
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < tiles.length; i++) ...[if (i > 0) const SizedBox(height: 12), tiles[i]],
            ],
          );
        },
      ),
    );
  }

  Widget _payWeeksStat(List<_PayWeek> weeks, {required bool inScope}) {
    final paid = weeks.where((w) => w.state == _WeekState.paid).length;
    final unknown = weeks.where((w) => w.state == _WeekState.unknown).length;
    var value = '—';
    var caption = 'No visits to pay yet';
    if (!inScope) {
      caption = 'Started before go-live: nothing is paid';
    } else if (weeks.isEmpty) {
      // the defaults
    } else if (unknown == weeks.length) {
      value = 'Unknown';
      caption = "Couldn't check payroll runs";
    } else {
      value = paid == 0
          ? 'Not run yet'
          : paid == weeks.length
          ? (weeks.length == 1 ? 'Paid' : 'All paid')
          : '$paid of ${weeks.length} paid';
      caption = [
        for (final w in weeks)
          '${_weekRange(w.start, year: false)} ${switch (w.state) {
            _WeekState.paid => 'paid',
            _WeekState.notRun => 'not run',
            _WeekState.unknown => 'not checked',
          }}',
      ].join(' · ');
    }
    return Tooltip(
      message:
          'A fix can change pay in the weeks its visits were worked (daily advances, callback pay) and the week the '
          'job closed (its commission). For a week that was already paid, the difference is settled by an '
          'adjustment run.',
      waitDuration: const Duration(milliseconds: 400),
      child: _stat('Pay weeks', value, caption, color: paid > 0 ? _amberText : _ink),
    );
  }

  /// A figure the way the payroll history shows one: what it is, the number, and a plain line saying what it means.
  Widget _stat(String label, String value, String caption, {Color color = _ink}) => MergeSemantics(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: _slate),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: color,
            height: 1.15,
            fontFeatures: _figures,
          ),
        ),
        const SizedBox(height: 3),
        Text(caption, style: const TextStyle(fontSize: 12.5, color: _subtle, height: 1.3)),
      ],
    ),
  );

  Widget _lockBand(
    Map<String, dynamic> job,
    Map<String, dynamic> lock, {
    required bool closing,
    required bool paid,
    required List<DateTime> paidWeeks,
  }) {
    final canUnlock = !closing && !paid;
    final why = paid
        ? 'Commission is already paid, so this job cannot be unlocked.'
        : 'Change the job to a non-closing status in Service Fusion first.';
    final button = Tooltip(
      message: canUnlock ? 'Remove the lock so commission is recalculated' : why,
      child: OutlinedButton.icon(
        onPressed: canUnlock ? () => _unlock(job, lock, paidWeeks) : null,
        icon: const Icon(Icons.lock_open_rounded, size: 16),
        label: const Text('Unlock'),
        style: OutlinedButton.styleFrom(
          foregroundColor: _ink,
          backgroundColor: Colors.white,
          side: BorderSide(color: canUnlock ? _ink : _line),
          minimumSize: const Size(0, 38),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Closed ${_stamp(lock['locked_at'])} as "${lock['locked_status']}"',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _ink),
        ),
        const SizedBox(height: 3),
        const Text(
          'Its commission was frozen when it closed. Changing the status back in Service Fusion does not unlock it.',
          style: TextStyle(fontSize: 13, color: _slate, height: 1.4),
        ),
        if (closing && !paid)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'To unlock, first change the job to a non-closing status in Service Fusion, '
              'otherwise the next sync locks it again.',
              style: TextStyle(fontSize: 13, color: _amberText, height: 1.4, fontWeight: FontWeight.w600),
            ),
          ),
      ],
    );
    return Container(
      padding: const EdgeInsets.all(14),
      // The same pale yellow as the app's warning notices.
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          const icon = Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.lock_rounded, size: 18, color: _amberText),
          );
          final body = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              icon,
              const SizedBox(width: 10),
              Expanded(child: text),
            ],
          );
          if (c.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                body,
                Padding(padding: const EdgeInsets.only(left: 28, top: 10), child: button),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: body),
              const SizedBox(width: 12),
              button,
            ],
          );
        },
      ),
    );
  }

  Widget _sectionHeading(String title, String meta, {Widget? trailing, required bool wide}) {
    final heading = Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Semantics(
          header: true,
          child: Text(
            title,
            style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, color: _ink),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(meta, style: const TextStyle(fontSize: 12.5, color: _subtle)),
        ),
        if (trailing != null && wide) trailing,
      ],
    );
    if (trailing == null || wide) return heading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [heading, const SizedBox(height: 6), trailing],
    );
  }

  Widget _fixLegend() => const Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.push_pin_rounded, size: 14, color: _amberText),
      SizedBox(width: 5),
      Text('Fixed by the office: the sync keeps it', style: TextStyle(fontSize: 12.5, color: _slate)),
    ],
  );

  // Column widths shared by the header and every row, so they always line up. They grow with the text size, so a
  // pill like "Not verified" is never cut off at 130% text.
  double _k = 1;
  double get _wDate => 100 * _k;
  double get _wWeight => 84 * _k;
  double get _wFlag => 118 * _k;
  double get _wAction => 64 * _k;

  /// Narrower than this, each visit is laid out as a short block instead of a table row, so the technician column
  /// never drops below 140px (a long name still fits on two lines).
  double get _tableMin => _wDate + _wWeight + _wFlag * 2 + _wAction + 24 + 140;

  Widget _dayHeader() {
    const s = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _slate);
    return Container(
      color: _faint,
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
      child: Row(
        children: [
          SizedBox(
            width: _wDate,
            child: const Text('Date', style: s),
          ),
          const Expanded(child: Text('Technician', style: s)),
          SizedBox(
            width: _wWeight,
            child: const Text('Weight', style: s),
          ),
          SizedBox(
            width: _wFlag,
            child: const Text('Verified', style: s),
          ),
          SizedBox(
            width: _wFlag,
            child: const Text('Callback', style: s),
          ),
          SizedBox(width: _wAction),
        ],
      ),
    );
  }

  /// Tints the visit that was just saved and fades it out, so the change is easy to spot. Still with reduced motion.
  Widget _flash(_Visit v, Widget row) {
    if (_flashDay == null || v.id != _flashDay) return row;
    final still = MediaQuery.of(context).disableAnimations;
    return TweenAnimationBuilder<double>(
      key: ValueKey('flash$_flashSeq'),
      tween: Tween(begin: still ? 0 : 1, end: 0),
      duration: still ? Duration.zero : const Duration(milliseconds: 1800),
      curve: Curves.easeOut,
      builder: (context, t, child) => DecoratedBox(
        decoration: BoxDecoration(color: _green.withValues(alpha: 0.10 * t)),
        child: child,
      ),
      child: row,
    );
  }

  /// A status pill. [tone] tints it; [text] is the label colour, which must pass contrast. A fixed value carries a
  /// pin instead of its icon, so "fixed" never relies on colour alone.
  Widget _pill(String label, {required Color tone, required Color text, IconData? icon, bool fixed = false}) {
    final pill = Container(
      padding: const EdgeInsets.fromLTRB(8, 3, 10, 3),
      decoration: BoxDecoration(color: tone.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (fixed)
            const Icon(Icons.push_pin_rounded, size: 13, color: _amberText)
          else if (icon != null)
            Icon(icon, size: 13, color: text),
          if (fixed || icon != null) const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: text),
            ),
          ),
        ],
      ),
    );
    if (!fixed) return pill;
    return Tooltip(
      message: 'Fixed by the office. The sync keeps this value until the fix is removed.',
      child: Semantics(container: true, label: '$label, fixed by the office', excludeSemantics: true, child: pill),
    );
  }

  Widget _verifiedPill(_Visit v) => v.verified
      ? _pill('Verified', tone: _green, text: _greenText, icon: Icons.check_rounded, fixed: v.fixedV)
      : _pill('Not verified', tone: _slate, text: _slate, icon: Icons.remove_rounded, fixed: v.fixedV);

  Widget _callbackPill(_Visit v) => v.callback
      ? _pill('Callback', tone: _red, text: _redText, icon: Icons.replay_rounded, fixed: v.fixedC)
      : _pill('Not callback', tone: _slate, text: _slate, fixed: v.fixedC);

  Widget _was(String text) => Padding(
    padding: const EdgeInsets.only(top: 3, left: 2),
    child: Text(text, style: const TextStyle(fontSize: 12, color: _subtle)),
  );

  Widget _fixButton(_Visit v, {required bool locked, required List<DateTime> paidWeeks}) {
    if (v.blocked != null) {
      return Tooltip(
        message: v.blocked!,
        child: Semantics(
          label: v.blocked,
          child: const Padding(
            padding: EdgeInsets.all(8),
            child: Icon(Icons.lock_outline_rounded, size: 18, color: _subtle),
          ),
        ),
      );
    }
    return OutlinedButton(
      onPressed: () => _fixDay(v.day, jobLocked: locked, paidWeeks: paidWeeks),
      style: OutlinedButton.styleFrom(
        foregroundColor: _ink,
        side: const BorderSide(color: _line),
        minimumSize: const Size(56, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Semantics(
        label: "Fix ${v.tech}'s visit on ${v.date}",
        excludeSemantics: true,
        child: const Text('Fix', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
      ),
    );
  }

  Widget _dayRow(_Visit v, {required bool locked, required List<DateTime> paidWeeks}) {
    Widget weight = Text(
      v.weight,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: v.zeroWeightHint != null ? _amberText : _ink,
        fontFeatures: _figures,
      ),
    );
    if (v.fixedW) {
      weight = Tooltip(
        message: 'Fixed by the office. The sync keeps this value until the fix is removed.',
        child: Semantics(
          container: true,
          label: 'Weight ${v.weight}, fixed by the office',
          excludeSemantics: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.push_pin_rounded, size: 13, color: _amberText),
              const SizedBox(width: 4),
              weight,
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _line)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: _wDate,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  v.date,
                  style: const TextStyle(
                    fontSize: 13.5,
                    color: _ink,
                    fontWeight: FontWeight.w600,
                    fontFeatures: _figures,
                  ),
                ),
                if (v.before) const Text('Before go-live', style: TextStyle(fontSize: 12, color: _subtle)),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    v.tech,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5, color: _ink, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    v.techStatus,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, color: _subtle),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(
            width: _wWeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                weight,
                if (v.was['weight'] != null && v.was['weight'] != v.weight)
                  _was('was ${v.was['weight']}')
                else if (v.zeroWeightHint != null)
                  Tooltip(
                    message: v.zeroWeightHint!,
                    child: const Padding(
                      padding: EdgeInsets.only(top: 3),
                      child: Text(
                        'earns nothing',
                        style: TextStyle(fontSize: 12, color: _amberText, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            width: _wFlag,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _verifiedPill(v),
                if (v.was['verified'] != null && v.was['verified'] != (v.verified ? 'Verified' : 'Not verified'))
                  _was('was ${v.was['verified']}'),
              ],
            ),
          ),
          SizedBox(
            width: _wFlag,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _callbackPill(v),
                if (v.was['callback'] != null && v.was['callback'] != (v.callback ? 'Callback' : 'Not a callback'))
                  _was('was ${v.was['callback']}'),
              ],
            ),
          ),
          SizedBox(
            width: _wAction,
            child: Align(
              alignment: Alignment.centerRight,
              child: _fixButton(v, locked: locked, paidWeeks: paidWeeks),
            ),
          ),
        ],
      ),
    );
  }

  /// One visit as a short block, for narrow windows.
  Widget _dayStacked(_Visit v, {required bool locked, required List<DateTime> paidWeeks}) {
    final was = v.wasLine;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      v.tech,
                      style: const TextStyle(fontSize: 14, color: _ink, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      '${v.date} · ${v.before ? 'Before go-live' : v.techStatus}',
                      style: const TextStyle(fontSize: 12.5, color: _subtle, fontFeatures: _figures),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _fixButton(v, locked: locked, paidWeeks: paidWeeks),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _pill(
                'Weight ${v.weight}',
                tone: v.zeroWeightHint != null ? _amber : _slate,
                text: v.zeroWeightHint != null ? _amberText : _ink,
                fixed: v.fixedW,
              ),
              _verifiedPill(v),
              _callbackPill(v),
            ],
          ),
          if (was.isNotEmpty) _was('Before the office fix: $was'),
          if (v.zeroWeightHint != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Weight 0: this visit earns nothing.',
                style: const TextStyle(fontSize: 12, color: _amberText, fontWeight: FontWeight.w600),
                semanticsLabel: v.zeroWeightHint,
              ),
            ),
        ],
      ),
    );
  }

  Widget _historyEntry(Map<String, dynamic> c, {required bool last}) {
    final action = c['action']?.toString();
    final target = _prettyTarget(c['target']?.toString());
    final isUnlock = action == 'unlock_job';
    final reason = c['reason']?.toString() ?? '';
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The thread down the left joins one change to the next.
          SizedBox(
            width: 18,
            child: Column(
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 5),
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(color: isUnlock ? _amber : _slate, shape: BoxShape.circle),
                ),
                if (!last) Expanded(child: Container(width: 1.5, color: _line)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: _actionLabel(action),
                          style: const TextStyle(fontWeight: FontWeight.w800, color: _ink),
                        ),
                        if (target.isNotEmpty)
                          TextSpan(
                            text: isUnlock ? '  ·  Was $target' : '  ·  $target',
                            style: const TextStyle(color: _slate),
                          ),
                      ],
                    ),
                    style: const TextStyle(fontSize: 13.5, height: 1.3),
                  ),
                  const SizedBox(height: 6),
                  if (isUnlock)
                    Text(
                      '${_prettyValue(action, c['old_value'])} → ${_prettyValue(action, c['new_value'])}',
                      style: const TextStyle(fontSize: 13, color: _slate),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        AppTag(_prettyValue(action, c['old_value'])),
                        const Icon(Icons.arrow_forward_rounded, size: 14, color: _subtle),
                        AppTag(_prettyValue(action, c['new_value']), color: _ink),
                      ],
                    ),
                  const SizedBox(height: 6),
                  Text(
                    '${c['changed_by_name'] ?? ''} · ${_stamp(c['changed_at'])}',
                    style: const TextStyle(fontSize: 12.5, color: _subtle),
                  ),
                  if (reason.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        '"$reason"',
                        style: const TextStyle(fontSize: 13, color: _slate, fontStyle: FontStyle.italic, height: 1.35),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tag(String label, Color tone, {Color? text, IconData? icon}) =>
      _pill(label, tone: tone, text: text ?? tone, icon: icon);

  /// Nothing open yet: what the page is for, and the three rules that matter before changing anything.
  Widget _pickAJob() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(color: _faint, shape: BoxShape.circle),
              child: const Icon(Icons.manage_search_rounded, size: 28, color: _slate),
            ),
            const SizedBox(height: 14),
            const Text(
              'Pick a job to review',
              style: TextStyle(color: _ink, fontSize: 17, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            const Text(
              'Search by job number or customer, then fix a visit that was verified by mistake, '
              'stuck as a callback or given the wrong weight, or unlock a job that was closed by accident.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _slate, fontSize: 13.5, height: 1.45),
            ),
            const SizedBox(height: 22),
            _rule(
              Icons.push_pin_rounded,
              'A fix replaces the value the sync set, and the sync keeps it until the fix is removed.',
            ),
            _rule(Icons.edit_note_rounded, 'Every change needs a reason and is saved with your name.'),
            _rule(
              Icons.event_repeat_rounded,
              'If payroll already ran for a week the fix touches, the difference is settled by an adjustment run.',
            ),
          ],
        ),
      ),
    ),
  );

  Widget _rule(IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 17, color: _slate),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 13, color: _slate, height: 1.4)),
        ),
      ],
    ),
  );

  Widget _detailSkeleton() => Semantics(
    label: 'Loading the job',
    child: Padding(
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 20),
      child: SkeletonPulse(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _skel(280, 24),
            const SizedBox(height: 10),
            _skel(220, 14),
            const SizedBox(height: 22),
            Row(
              children: [
                for (var i = 0; i < 4; i++) ...[
                  if (i > 0) const SizedBox(width: 24),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [_skel(90, 12), const SizedBox(height: 8), _skel(110, 22)],
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 32),
            _skel(double.infinity, 36),
            for (var i = 0; i < 3; i++) ...[const SizedBox(height: 10), _skel(double.infinity, 46)],
          ],
        ),
      ),
    ),
  );

  Widget _skel(double w, double h) => Container(
    width: w,
    height: h,
    decoration: BoxDecoration(color: _faint, borderRadius: BorderRadius.circular(8)),
  );
}

// ----------------------------------------------------------------------------
// Dialogs
// ----------------------------------------------------------------------------

enum _Pick { keep, yes, no, auto }

/// Saves what the dialog collected. Returns an error message, or null when it worked.
typedef _Save<T> = Future<String?> Function(T value);

/// One line of the "When you save" summary: a field, its value now, and its value after the save.
typedef _ChangeRow = ({String field, String now, bool nowFixed, String after, bool afterFixed, String? note});

class _FixDayDialog extends StatefulWidget {
  final Map<String, dynamic> day;
  final bool jobLocked;

  /// Weeks this job can pay into that already have a finalized payroll run.
  final List<DateTime> paidWeeks;
  final _Save<Map<String, dynamic>> onSave;
  const _FixDayDialog({required this.day, required this.jobLocked, required this.paidWeeks, required this.onSave});

  @override
  State<_FixDayDialog> createState() => _FixDayDialogState();
}

class _FixDayDialogState extends State<_FixDayDialog> {
  _Pick _verified = _Pick.keep;
  _Pick _callback = _Pick.keep;
  _Pick _weight = _Pick.keep; // keep | yes (set a value) | auto
  final _weightCtl = TextEditingController();
  final _reason = TextEditingController(); // the note: optional, but required with "Other"
  String? _why; // the reason picked from the list
  String? _error;
  bool _saving = false;

  static const _reasons = ['Tech did not mark complete', 'Tech marked complete by mistake', 'Office error'];
  static const _other = 'Other';

  Map<String, dynamic> get _d => widget.day;
  bool get _isVerified => _d['is_verified'] == true;
  bool get _isCallback => _d['is_callback'] == true;
  bool get _fixedV => _d['override_verified'] != null;
  bool get _fixedC => _d['override_callback'] != null;
  bool get _fixedW => _d['override_weight'] != null;

  @override
  void initState() {
    super.initState();
    final w = _weightText(_d['day_weight']);
    _weightCtl.text = w == '—' ? '' : w;
    _reason.addListener(() => setState(() {}));
    _weightCtl.addListener(() => setState(() => _error = null));
  }

  @override
  void dispose() {
    _weightCtl.dispose();
    _reason.dispose();
    super.dispose();
  }

  /// Un-flagging a callback has to say what the weight becomes: flagging it zeroed the weight and
  /// the old value is gone.
  bool get _needsWeight => _isCallback && _callback == _Pick.no;

  // Choosing what is already set is not a change (it would only add an empty entry to the history).
  bool _noOp(_Pick p, bool? currentOverride) {
    if (p == _Pick.keep) return true;
    if (p == _Pick.auto) return currentOverride == null;
    return currentOverride == (p == _Pick.yes);
  }

  bool get _hasChange =>
      !_noOp(_verified, _d['override_verified'] as bool?) ||
      !_noOp(_callback, _d['override_callback'] as bool?) ||
      (_weight == _Pick.yes) ||
      (_weight == _Pick.auto && _d['override_weight'] != null);

  double? get _weightValue => double.tryParse(_weightCtl.text.trim().replaceAll(',', '.'));
  bool get _weightOk => _weight != _Pick.yes || (_weightValue != null && _weightValue! >= 0 && _weightValue! <= 3);
  bool get _weightMissing => _needsWeight && _weight == _Pick.keep;
  bool get _isOther => _why == _other;
  int get _noteLeft => _minReason - _reason.text.trim().length;
  bool get _removing => _verified == _Pick.auto || _callback == _Pick.auto || _weight == _Pick.auto;

  /// A reason from the list is always needed; "Other" also needs a real note saying what happened.
  bool get _reasonOk => _why != null && (!_isOther || _noteLeft <= 0);

  /// What is sent and kept in the history: the reason, then the note after it when there is one.
  String get _reasonText {
    final note = _reason.text.trim();
    return note.isEmpty ? _why! : '$_why: $note';
  }

  bool get _valid => _hasChange && !_weightMissing && _weightOk && _reasonOk && !_saving;

  /// Each field this save changes, with its value now and after. A replacement, never a difference: the value after
  /// is what the visit will have.
  List<_ChangeRow> get _changes {
    final out = <_ChangeRow>[];
    String v(bool b) => b ? 'Verified' : 'Not verified';
    String c(bool b) => b ? 'Callback' : 'Not a callback';
    if (!_noOp(_verified, _d['override_verified'] as bool?)) {
      final to = _verified == _Pick.auto ? _isVerified : _verified == _Pick.yes;
      out.add((
        field: 'Verified',
        now: v(_isVerified),
        nowFixed: _fixedV,
        after: v(to),
        afterFixed: _verified != _Pick.auto,
        note: _verified == _Pick.auto
            ? 'the sync decides from now on'
            : (to == _isVerified ? 'the sync can no longer change it' : null),
      ));
    }
    if (!_noOp(_callback, _d['override_callback'] as bool?)) {
      final to = _callback == _Pick.auto ? _isCallback : _callback == _Pick.yes;
      out.add((
        field: 'Callback',
        now: c(_isCallback),
        nowFixed: _fixedC,
        after: c(to),
        afterFixed: _callback != _Pick.auto,
        note: _callback == _Pick.auto
            ? 'the sync decides from now on'
            : (to == _isCallback ? 'the sync can no longer change it' : null),
      ));
    }
    final now = _weightText(_d['day_weight']);
    if (_weight == _Pick.yes && _weightValue != null && _weightOk) {
      final after = _weightText(_weightValue);
      out.add((
        field: 'Weight',
        now: now,
        nowFixed: _fixedW,
        after: after,
        afterFixed: true,
        note: after != now ? null : (_fixedW ? 'same as now' : 'the sync can no longer change it'),
      ));
    } else if (_weight == _Pick.auto && _fixedW) {
      out.add((
        field: 'Weight',
        now: now,
        nowFixed: true,
        after: now,
        afterFixed: false,
        note: 'the sync decides from now on',
      ));
    } else if (_callback == _Pick.yes && _weight == _Pick.keep && !_isCallback) {
      out.add((
        field: 'Weight',
        now: now,
        nowFixed: _fixedW,
        after: '0',
        afterFixed: _fixedW,
        note: 'callback days carry no weight',
      ));
    }
    return out;
  }

  Future<void> _submit() async {
    if (!_valid) return;
    final body = <String, dynamic>{};
    if (!_noOp(_verified, _d['override_verified'] as bool?)) {
      body['verified'] = _verified == _Pick.auto ? null : _verified == _Pick.yes;
    }
    if (!_noOp(_callback, _d['override_callback'] as bool?)) {
      body['callback'] = _callback == _Pick.auto ? null : _callback == _Pick.yes;
    }
    if (_weight == _Pick.auto) {
      body['weight'] = null;
    } else if (_weight == _Pick.yes) {
      body['weight'] = _weightValue;
    }
    body['reason'] = _reasonText;

    setState(() {
      _saving = true;
      _error = null;
    });
    final err = await widget.onSave(body);
    if (!mounted) return;
    if (err == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        _saving = false;
        _error = err;
      });
    }
  }

  /// "Now  📌 Not verified" at the right of a field's label.
  Widget _now(String value, {required bool fixed}) => Semantics(
    label: 'Now $value${fixed ? ', fixed by the office' : ''}',
    excludeSemantics: true,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Now ', style: TextStyle(fontSize: 12.5, color: _subtle)),
        if (fixed) ...[const Icon(Icons.push_pin_rounded, size: 13, color: _amberText), const SizedBox(width: 3)],
        Text(
          value,
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _ink),
        ),
      ],
    ),
  );

  Widget _group(String label, String help, Widget now, Widget control) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _ink),
              ),
            ),
            const SizedBox(width: 8),
            now,
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 8),
          child: Text(help, style: const TextStyle(fontSize: 12, color: _slate, height: 1.35)),
        ),
        control,
      ],
    ),
  );

  /// One bulleted reason: a radio-style row, so the choice is one tap and reads as a list, not a typed sentence.
  Widget _reasonRow(String label) {
    final on = _why == label;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: on,
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: _saving ? null : () => setState(() => _why = label),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: _saving ? null : () => setState(() => _why = label),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
          child: Row(
            children: [
              Icon(
                on ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                size: 20,
                color: on ? _ink : _subtle,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label == _other ? 'Other (note required)' : label,
                  style: TextStyle(fontSize: 14, fontWeight: on ? FontWeight.w700 : FontWeight.w600, color: _ink),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A value in the summary, with the pin when the office will have fixed it.
  Widget _value(String text, {required bool fixed, required bool strong}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (fixed) ...[const Icon(Icons.push_pin_rounded, size: 13, color: _amberText), const SizedBox(width: 3)],
      Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: strong ? FontWeight.w800 : FontWeight.w500,
          color: strong ? _ink : _slate,
          fontFeatures: _figures,
        ),
      ),
    ],
  );

  /// Pinned above the buttons: exactly what Save will change, or that nothing is picked yet. Errors land here too, next
  /// to the button that caused them.
  Widget _footer() {
    final rows = _changes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
          decoration: BoxDecoration(
            color: rows.isEmpty ? Colors.white : _faint,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _line),
          ),
          child: rows.isEmpty
              ? const Text(
                  'Nothing will change yet. Pick a new value above.',
                  style: TextStyle(fontSize: 13, color: _subtle),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'When you save',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _slate),
                    ),
                    for (final r in rows)
                      Padding(
                        padding: const EdgeInsets.only(top: 7),
                        child: MergeSemantics(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 72,
                                child: Text(r.field, style: const TextStyle(fontSize: 13, color: _slate)),
                              ),
                              Expanded(
                                child: Wrap(
                                  spacing: 6,
                                  runSpacing: 2,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    _value(r.now, fixed: r.nowFixed, strong: false),
                                    const Icon(Icons.arrow_forward_rounded, size: 14, color: _subtle),
                                    _value(r.after, fixed: r.afterFixed, strong: true),
                                    if (r.note != null)
                                      Text('· ${r.note}', style: const TextStyle(fontSize: 12.5, color: _subtle)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Semantics(liveRegion: true, child: AppNotice(_error!, kind: AppNoticeKind.error)),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    String v(bool b) => b ? 'Verified' : 'Not verified';
    String c(bool b) => b ? 'Callback' : 'Not a callback';
    final reasonHelp = _why == null
        ? 'Pick a reason. It is saved in the history with your name.'
        : (_isOther && _noteLeft > 0
              ? (_reason.text.trim().isEmpty
                    ? 'A note is required for Other.'
                    : '$_noteLeft more character${_noteLeft == 1 ? '' : 's'} needed')
              : 'Saved in the history with your name.');

    // The dialog can't be dismissed mid-save: the result (or the error) would have nowhere to show.
    return PopScope(
      canPop: !_saving,
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.enter, control: true): _submit},
        child: AppDialog(
          title: 'Fix this visit',
          subtitle: '${_d['tech_name']} · ${_day(_d['work_date']?.toString())}',
          icon: Icons.rule_folder_outlined,
          width: 560,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.paidWeeks.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: AppNotice(
                    _paidWeeksNotice(
                      widget.paidWeeks,
                      'If this fix changes what anyone is owed, the difference is paid or taken back by an adjustment '
                      'run the next time payroll is run for ${widget.paidWeeks.length == 1 ? 'that week' : 'those weeks'}.',
                    ),
                    kind: AppNoticeKind.warning,
                  ),
                ),
              _group(
                'Counts as worked',
                "The tech's Completed tap. The sync never un-verifies a day by itself, even if the status is changed back.",
                _now(v(_isVerified), fixed: _fixedV),
                AppSegmented<_Pick>(
                  value: _verified,
                  options: [
                    (_Pick.keep, 'No change'),
                    (_Pick.yes, 'Verified'),
                    (_Pick.no, 'Not verified'),
                    if (_fixedV) (_Pick.auto, 'Remove fix'),
                  ],
                  onChanged: _saving ? (_) {} : (p) => setState(() => _verified = p),
                ),
              ),
              _group(
                'Callback or warranty visit',
                'A callback pays the tech \$50 and charges the original techs. Once flagged, the sync never un-flags it.',
                _now(c(_isCallback), fixed: _fixedC),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppSegmented<_Pick>(
                      value: _callback,
                      options: [
                        (_Pick.keep, 'No change'),
                        (_Pick.yes, 'Callback'),
                        (_Pick.no, 'Not a callback'),
                        if (_fixedC) (_Pick.auto, 'Remove fix'),
                      ],
                      onChanged: _saving
                          ? (_) {}
                          : (p) => setState(() {
                              _callback = p;
                              // Un-flagging needs a weight: suggest a full day.
                              if (_needsWeight && _weight == _Pick.keep) {
                                _weight = _Pick.yes;
                                _weightCtl.text = '1';
                              }
                            }),
                    ),
                    if (_callback == _Pick.yes && !_isCallback)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: AppNotice(
                          "Flagging a callback sets this day's weight to 0 unless you set a weight below.",
                          kind: AppNoticeKind.warning,
                        ),
                      ),
                    if (_needsWeight)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: AppNotice(
                          'Flagging this callback zeroed the weight, and the old value was not kept. '
                          'Set the weight this day should have.',
                          kind: AppNoticeKind.warning,
                        ),
                      ),
                  ],
                ),
              ),
              _group(
                'Day weight',
                "How much of the job's commission this day earns, used exactly as typed: 1 is a full day, 0.5 a half "
                    "day. The tech's own weight is not multiplied in.",
                _now(_weightText(_d['day_weight']), fixed: _fixedW),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppSegmented<_Pick>(
                      value: _weight,
                      options: [
                        (_Pick.keep, 'No change'),
                        (_Pick.yes, 'Set a value'),
                        if (_fixedW) (_Pick.auto, 'Remove fix'),
                      ],
                      onChanged: _saving ? (_) {} : (p) => setState(() => _weight = p),
                    ),
                    if (_weight == _Pick.yes) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          SizedBox(
                            width: 120,
                            child: TextField(
                              controller: _weightCtl,
                              autofocus: true,
                              enabled: !_saving,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                              decoration: appFieldDecoration(
                                label: 'New weight',
                                hint: '0 to 3',
                                error: _weightCtl.text.isNotEmpty && !_weightOk ? 'Use 0 to 3' : null,
                              ),
                            ),
                          ),
                          for (final w in const ['0', '0.5', '1', '1.5'])
                            ActionChip(
                              tooltip: 'Set the weight to $w',
                              label: Text(
                                w,
                                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _ink),
                              ),
                              onPressed: _saving ? null : () => setState(() => _weightCtl.text = w),
                              backgroundColor: _faint,
                              side: BorderSide.none,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                              visualDensity: VisualDensity.compact,
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              _group(
                'Why are you making this change?',
                'Required. Pick the closest reason; choose Other if none fits and say what happened.',
                const SizedBox.shrink(),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final r in [..._reasons, _other]) _reasonRow(r),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _reason,
                      enabled: !_saving,
                      minLines: 2,
                      maxLines: 3,
                      maxLength: 900,
                      buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                      decoration: appFieldDecoration(
                        hint: _isOther ? 'What happened? (required)' : 'Add a note (optional)',
                        helper: reasonHelp,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.jobLocked && _removing)
                const AppNotice(
                  "Removing a fix doesn't recalculate a closed job: the value stays as it is until you set a new one.",
                ),
            ],
          ),
          footer: _footer(),
          actions: [
            AppButton.ghost('Cancel', _saving ? null : () => Navigator.pop(context)),
            AppButton.ink(
              _saving ? 'Saving…' : 'Save correction',
              _valid ? _submit : null,
              icon: _saving ? Icons.hourglass_top_rounded : Icons.check_rounded,
            ),
          ],
        ),
      ),
    );
  }
}

class _UnlockDialog extends StatefulWidget {
  final Map<String, dynamic> job;
  final Map<String, dynamic> lock;

  /// Weeks this job can pay into that already have a finalized payroll run.
  final List<DateTime> paidWeeks;
  final _Save<String> onSave;
  const _UnlockDialog({required this.job, required this.lock, required this.paidWeeks, required this.onSave});

  @override
  State<_UnlockDialog> createState() => _UnlockDialogState();
}

class _UnlockDialogState extends State<_UnlockDialog> {
  final _reason = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _reason.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  int get _left => _minReason - _reason.text.trim().length;
  bool get _valid => _left <= 0 && !_saving;

  Future<void> _submit() async {
    if (!_valid) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final err = await widget.onSave(_reason.text.trim());
    if (!mounted) return;
    if (err == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        _saving = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final lock = widget.lock;
    final week = DateTime.tryParse(lock['pay_week']?.toString() ?? '');
    return PopScope(
      canPop: !_saving,
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.enter, control: true): _submit},
        child: AppDialog(
          title: 'Unlock this job?',
          subtitle: '${job['customer_name'] ?? 'Job'} · #${job['job_id']}',
          icon: Icons.lock_open_rounded,
          iconColor: _red,
          width: 500,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AppNotice(
                "This removes the closing lock and clears the earned amount, so commission is recalculated from the job's "
                'current status. Use it when the job was closed by mistake.',
                kind: AppNoticeKind.warning,
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                decoration: BoxDecoration(color: _faint, borderRadius: BorderRadius.circular(10)),
                child: Column(
                  children: [
                    _fact('Closed', _stamp(lock['locked_at'])),
                    _fact('Status then', lock['locked_status']?.toString() ?? '—'),
                    _fact('Week it closed', week == null ? '—' : _weekRange(week)),
                    _fact('Earned amount cleared', _moneyText(job['commission_earned']), strong: true),
                  ],
                ),
              ),
              if (widget.paidWeeks.isNotEmpty) ...[
                const SizedBox(height: 12),
                AppNotice(
                  _paidWeeksNotice(
                    widget.paidWeeks,
                    'Unlocking changes what is owed, so the difference shows up as an adjustment run the next time '
                    'payroll is run for ${widget.paidWeeks.length == 1 ? 'that week' : 'those weeks'}.',
                  ),
                  kind: AppNoticeKind.error,
                ),
              ],
              const SizedBox(height: 18),
              const AppFieldLabel('Why are you doing this?', help: 'Required.'),
              TextField(
                controller: _reason,
                autofocus: true,
                enabled: !_saving,
                minLines: 2,
                maxLines: 3,
                maxLength: 1000,
                buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                decoration: appFieldDecoration(
                  hint: 'e.g. Job was set to Close Job by mistake',
                  helper: _left > 0 && _reason.text.isNotEmpty
                      ? '$_left more character${_left == 1 ? '' : 's'} needed'
                      : 'Saved in the history with your name.',
                ),
              ),
            ],
          ),
          footer: _error == null
              ? null
              : Semantics(liveRegion: true, child: AppNotice(_error!, kind: AppNoticeKind.error)),
          actions: [
            AppButton.ghost('Cancel', _saving ? null : () => Navigator.pop(context)),
            AppButton.ink(_saving ? 'Unlocking…' : 'Unlock job', _valid ? _submit : null, danger: true),
          ],
        ),
      ),
    );
  }

  Widget _fact(String label, String value, {bool strong = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 172,
            child: Text(label, style: const TextStyle(fontSize: 13, color: _slate)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13.5,
                color: _ink,
                fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
                fontFeatures: _figures,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
