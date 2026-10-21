import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'widgets/dashboard_kit.dart';

// ---------------------------------------------------------------------------
// Payroll history: every finalized (and voided) payroll run, newest pay week first. Click a run to see what each
// person was paid in it.
//
// Backend: GET /api/payroll/runs?limit=200 (the list), GET /api/payroll/runs/:id (one run with its lines).
// Read-only: running and voiding payroll stays in the Run payroll dialog.
// ---------------------------------------------------------------------------

/// The most runs the server sends (its maximum). A full page means older runs may exist that aren't listed.
const int _limit = 200;

final NumberFormat _money = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
double _n(dynamic v) => v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);
String _s(dynamic v) => v?.toString() ?? '';

class _HistoryError implements Exception {
  final String message;
  final bool canRetry; // false when asking again can't help (no access)
  const _HistoryError(this.message, {this.canRetry = true});
}

Future<Map<String, dynamic>> _get(String path, {Map<String, String>? query}) async {
  try {
    final res = await http
        .get(Uri.parse('$kApiBaseUrl$path').replace(queryParameters: query), headers: AuthSession.instance.headers())
        .timeout(const Duration(seconds: 60));
    if (res.statusCode == 401) {
      AuthSession.instance.logout(); // sends the app back to the sign-in screen
      throw const _HistoryError('Your session expired. Please sign in again.');
    }
    if (res.statusCode == 403) {
      throw const _HistoryError('Your account does not have access to payroll history.', canRetry: false);
    }
    Map<String, dynamic> data = {};
    try {
      final decoded = json.decode(res.body);
      if (decoded is Map<String, dynamic>) data = decoded;
    } catch (_) {}
    if (res.statusCode >= 400 || data['success'] == false) {
      throw _HistoryError(data['error']?.toString() ?? 'The server returned status ${res.statusCode}.');
    }
    return data;
  } on TimeoutException {
    throw const _HistoryError('The server took too long to respond. Try again in a moment.');
  } on _HistoryError {
    rethrow;
  } catch (_) {
    throw const _HistoryError('Could not reach the server. Check the connection and try again.');
  }
}

class _RunRow {
  final int id;
  final DateTime? weekStart;
  final DateTime? weekEnd;
  final bool adjustment;
  final bool voided;
  final String by;
  final String notes;
  final String voidReason;
  final String voidedBy;
  final double paid;
  final double payable;
  final DateTime? at;

  _RunRow(Map<String, dynamic> j)
    : id = _n(j['id']).round(),
      weekStart = DateTime.tryParse(_s(j['week_start'])),
      weekEnd = DateTime.tryParse(_s(j['week_end'])),
      adjustment = _s(j['run_type']) == 'adjustment',
      voided = _s(j['status']) == 'voided',
      by = _s(j['run_by_name']),
      notes = _s(j['notes']).trim(),
      voidReason = _s(j['void_reason']).trim(),
      voidedBy = _s(j['voided_by_name']),
      paid = _n(j['total_amount_paid']),
      payable = _n(j['total_payable']),
      at = DateTime.tryParse(_s(j['created_at']))?.toLocal();

  String get weekLabel {
    final a = weekStart, b = weekEnd ?? (weekStart == null ? null : DateTime(weekStart!.year, weekStart!.month, weekStart!.day + 6));
    if (a == null || b == null) return 'Unknown week';
    return '${DateFormat('MMM d').format(a)} – ${DateFormat('MMM d, yyyy').format(b)}';
  }
}

/// One job that put money into the company pool in a run's pay week.
class _PoolJob {
  final String jobId;
  final String customer;
  final double amount;

  _PoolJob(Map<String, dynamic> j)
    : jobId = _s(j['job_id']),
      customer = _s(j['customer']),
      amount = _n(j['amount']);
}

class _RunDetail {
  final List<_LineRow> lines;
  final List<_PoolJob> poolJobs;
  final double poolTotal;

  _RunDetail(Map<String, dynamic> data)
    : lines = [for (final l in (data['lines'] as List? ?? const [])) _LineRow(Map<String, dynamic>.from(l as Map))],
      poolJobs = [
        for (final p in ((data['company_pool'] as Map?)?['jobs'] as List? ?? const []))
          _PoolJob(Map<String, dynamic>.from(p as Map)),
      ],
      poolTotal = _n((data['company_pool'] as Map?)?['total']);

  double get retainageTotal => lines.fold(0.0, (s, l) => s + l.retainage);
}

class _LineRow {
  final String name;
  final double gross;
  final double retainage;
  final double payable;
  final double previouslyPaid;
  final double carryRecovered;
  final double paid;

  _LineRow(Map<String, dynamic> j)
    : name = _s(j['tech_name']),
      gross = _n(j['weekly_gross']),
      retainage = _n(j['retainage_held']),
      payable = _n(j['payable']),
      previouslyPaid = _n(j['previously_paid']),
      carryRecovered = _n(j['carry_recovered']),
      paid = _n(j['amount_paid']);
}

/// Opens the payroll history list.
Future<void> showPayrollHistoryDialog(BuildContext context) {
  return showDialog<void>(context: context, builder: (_) => const _PayrollHistoryDialog());
}

class _PayrollHistoryDialog extends StatefulWidget {
  const _PayrollHistoryDialog();

  @override
  State<_PayrollHistoryDialog> createState() => _PayrollHistoryDialogState();
}

class _PayrollHistoryDialogState extends State<_PayrollHistoryDialog> {
  List<_RunRow> _runs = const [];
  bool _loading = true;
  String? _error;
  bool _canRetry = true;
  int _requestId = 0;

  int? _openId;
  final Map<int, _RunDetail> _lines = {};
  final Map<int, String> _lineErrors = {};
  final Set<int> _lineLoading = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await _get('/api/payroll/runs', query: {'limit': '$_limit'});
      if (!mounted || id != _requestId) return;
      setState(() {
        _runs = [for (final r in (data['runs'] as List? ?? const [])) _RunRow(Map<String, dynamic>.from(r as Map))];
        _loading = false;
      });
    } on _HistoryError catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _error = e.message;
        _canRetry = e.canRetry;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _canRetry = true;
        _error = 'The server sent a payroll history this screen could not read. Try again.';
        _loading = false;
      });
    }
  }

  Future<void> _toggle(_RunRow run) async {
    if (_openId == run.id) {
      setState(() => _openId = null);
      return;
    }
    setState(() => _openId = run.id);
    if (_lines.containsKey(run.id) || _lineLoading.contains(run.id)) return;
    setState(() {
      _lineLoading.add(run.id);
      _lineErrors.remove(run.id);
    });
    try {
      final data = await _get('/api/payroll/runs/${run.id}');
      if (!mounted) return;
      setState(() {
        _lines[run.id] = _RunDetail(data);
        _lineLoading.remove(run.id);
      });
    } on _HistoryError catch (e) {
      if (!mounted) return;
      setState(() {
        _lineErrors[run.id] = e.message;
        _lineLoading.remove(run.id);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _lineErrors[run.id] = 'This run could not be read. Try again.';
        _lineLoading.remove(run.id);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 940, maxHeight: 760),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _banner(),
            Flexible(child: _body()),
          ],
        ),
      ),
    );
  }

  /// The payroll screen's dark banner, so the dialog reads as part of that page rather than a stock pop-up.
  Widget _banner() => Container(
    color: DashUi.ink,
    padding: const EdgeInsets.fromLTRB(24, 10, 12, 10),
    child: Row(
      children: [
        const Icon(Icons.history_rounded, size: 20, color: Colors.white70),
        const SizedBox(width: 10),
        Expanded(
          child: Semantics(
            header: true,
            child: const Text(
              'PAYROLL HISTORY',
              style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold, letterSpacing: 1.2),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Close',
          color: Colors.white,
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    ),
  );

  Widget _body() {
    if (_loading) return _skeleton();
    if (_error != null) {
      return _state(
        icon: _canRetry ? Icons.cloud_off_rounded : Icons.lock_outline_rounded,
        title: _canRetry ? 'Could not load payroll history' : 'No access to payroll history',
        message: _error!,
        action: _canRetry
            ? OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42)),
                onPressed: _load,
                child: const Text('Try again'),
              )
            : null,
      );
    }
    if (_runs.isEmpty) {
      return _state(
        icon: Icons.event_available_rounded,
        title: 'No payroll runs yet',
        message: 'Runs show up here once a pay week has been paid with Run payroll.',
      );
    }

    final weeks = _byWeek();
    return Column(
      mainAxisSize: MainAxisSize.min, // size to the runs; a short history doesn't leave a tall empty box
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _summary(),
        LayoutBuilder(builder: (context, c) => c.maxWidth < _narrow ? const SizedBox.shrink() : _columnHeads()),
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 12),
            itemCount: weeks.length,
            itemBuilder: (_, i) => _weekGroup(weeks[i], first: i == 0),
          ),
        ),
        if (_runs.length >= _limit) _cappedNote(),
      ],
    );
  }

  /// Below this width a run is two lines (who and when move under the run number) instead of four columns.
  static const double _narrow = 600;

  static const TextStyle _head = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: DashUi.slate);
  static const List<FontFeature> _figures = [FontFeature.tabularFigures()];

  /// The runs grouped by pay week, newest first (the server's order). Regular, adjustment and voided runs for the
  /// same week sit together, so what a week actually paid can be read in one place.
  List<({String label, List<_RunRow> runs})> _byWeek() {
    final groups = <String, List<_RunRow>>{};
    for (final r in _runs) {
      (groups[r.weekStart?.toIso8601String() ?? 'unknown'] ??= []).add(r);
    }
    return [for (final g in groups.values) (label: g.first.weekLabel, runs: g)];
  }

  // ---- Summary --------------------------------------------------------------

  Widget _summary() {
    final live = _runs.where((r) => !r.voided).toList();
    final total = live.fold<double>(0, (s, r) => s + r.paid);
    final voided = _runs.length - live.length;
    final adjustments = live.where((r) => r.adjustment).length;
    final weeks = {for (final r in live) r.weekStart}.length;
    _RunRow? last;
    for (final r in live) {
      if (last == null || r.id > last.id) last = r;
    }
    final capped = _runs.length >= _limit;

    final tiles = [
      _stat(
        capped ? 'Paid in the latest $_limit runs' : 'Total paid',
        _money.format(total),
        [
          '${live.length} ${live.length == 1 ? 'run' : 'runs'}',
          if (voided > 0) '$voided voided, not counted',
        ].join(' · '),
        color: DashUi.emeraldText,
      ),
      _stat(
        'Pay weeks paid',
        '$weeks',
        adjustments == 0
            ? 'No adjustment runs'
            : '$adjustments ${adjustments == 1 ? 'adjustment run' : 'adjustment runs'} for late corrections',
      ),
      _stat(
        'Last run',
        last?.at == null ? (last == null ? '—' : '#${last.id}') : DateFormat('MMM d, yyyy').format(last!.at!),
        last == null
            ? 'Nothing paid yet'
            : '#${last.id} for ${last.weekLabel}${last.by.isEmpty ? '' : ', by ${last.by}'}',
      ),
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: DashUi.line)),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          if (c.maxWidth < _narrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < tiles.length; i++) ...[if (i > 0) const SizedBox(height: 12), tiles[i]],
              ],
            );
          }
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < tiles.length; i++) ...[
                  if (i > 0) const VerticalDivider(width: 33, thickness: 1, color: DashUi.line),
                  Expanded(child: tiles[i]),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  /// A figure the way the payroll screen shows one: what it is, the number, and a plain line saying what it means.
  Widget _stat(String label, String value, String caption, {Color color = DashUi.ink}) => MergeSemantics(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: DashUi.slate),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: color,
            height: 1.15,
            fontFeatures: _figures,
          ),
        ),
        const SizedBox(height: 2),
        Text(caption, style: const TextStyle(fontSize: 12.5, color: DashUi.subtle, height: 1.3)),
      ],
    ),
  );

  // ---- Run list -------------------------------------------------------------

  /// The run columns, laid out the same way in the headings and in every run row.
  Widget _cols({required Widget run, required Widget by, required Widget on, required Widget paid, Widget? trailing}) =>
      Row(
        children: [
          Expanded(flex: 4, child: run),
          Expanded(flex: 4, child: by),
          Expanded(flex: 3, child: on),
          Expanded(flex: 3, child: paid),
          SizedBox(width: 36, child: trailing),
        ],
      );

  Widget _columnHeads() => Container(
    color: DashUi.faint,
    padding: const EdgeInsets.fromLTRB(40, 9, 12, 9),
    child: _cols(
      run: const Text('Run', style: _head),
      by: const Text('Run by', style: _head),
      on: const Text('Run on', style: _head),
      paid: const Text('Paid', textAlign: TextAlign.right, style: _head),
    ),
  );

  Widget _weekGroup(({String label, List<_RunRow> runs}) g, {required bool first}) {
    final live = g.runs.where((r) => !r.voided).toList();
    final paid = live.fold<double>(0, (s, r) => s + r.paid);
    final voided = g.runs.length - live.length;
    final meta = ['${live.length} ${live.length == 1 ? 'run' : 'runs'}', if (voided > 0) '$voided voided'].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(24, 14, 48, 4),
          decoration: first
              ? null
              : const BoxDecoration(
                  border: Border(top: BorderSide(color: DashUi.line)),
                ),
          child: MergeSemantics(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: g.label,
                          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: DashUi.ink),
                        ),
                        TextSpan(
                          text: '    $meta',
                          style: const TextStyle(fontSize: 12.5, color: DashUi.subtle),
                        ),
                      ],
                    ),
                  ),
                ),
                // Only when several runs paid into the week; with one, it would just repeat that run's amount.
                if (live.length > 1)
                  Text(
                    'Week total ${_money.format(paid)}',
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                      color: DashUi.ink,
                      fontFeatures: _figures,
                    ),
                  ),
              ],
            ),
          ),
        ),
        for (final r in g.runs) _runBlock(r),
      ],
    );
  }

  Widget _runBlock(_RunRow r) {
    final open = _openId == r.id;
    // A voided run is greyed and its amount struck through: it was reversed, so it paid nothing. The rest stays
    // readable so it can still be checked.
    final tone = r.voided ? DashUi.subtle : DashUi.ink;
    final text = TextStyle(fontSize: 13.5, color: tone);
    final amount = Text(
      _money.format(r.paid),
      textAlign: TextAlign.right,
      style: TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w700,
        color: tone,
        fontFeatures: _figures,
        decoration: r.voided ? TextDecoration.lineThrough : null,
      ),
    );
    final runTag = Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '#${r.id}',
          style: text.copyWith(fontWeight: FontWeight.w600, fontFeatures: _figures),
        ),
        if (r.voided)
          _chip('Voided', DashUi.red)
        else if (r.adjustment)
          _chip('Adjustment', DashUi.amber, text: DashUi.amberText)
        else
          _chip('Regular', DashUi.emeraldDeep, text: DashUi.emeraldText),
      ],
    );
    final by = r.by.isEmpty ? '—' : r.by;
    final on = r.at == null ? '—' : DateFormat('MMM d, yyyy').format(r.at!);
    final chevron = AnimatedRotation(
      turns: open ? 0.5 : 0,
      duration: const Duration(milliseconds: 160),
      child: const Icon(Icons.expand_more_rounded, size: 20, color: DashUi.slate),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          expanded: open,
          hint: open ? 'Hides who was paid' : 'Shows who was paid in this run',
          child: InkWell(
            onTap: () => _toggle(r),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(40, 10, 12, 10),
              child: LayoutBuilder(
                builder: (context, c) {
                  if (c.maxWidth + 52 < _narrow) {
                    return Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              runTag,
                              const SizedBox(height: 2),
                              Text('$by · $on', style: text.copyWith(fontSize: 12.5, color: DashUi.subtle)),
                            ],
                          ),
                        ),
                        amount,
                        SizedBox(width: 36, child: chevron),
                      ],
                    );
                  }
                  return _cols(
                    run: runTag,
                    by: Text(by, style: text, overflow: TextOverflow.ellipsis),
                    on: Text(on, style: text),
                    paid: amount,
                    trailing: chevron,
                  );
                },
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: open ? _detail(r) : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  /// A status pill: [color] tints the background, [text] (default [color]) is the label, which must pass contrast.
  Widget _chip(String label, Color color, {Color? text}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
    child: Text(
      label,
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: text ?? color),
    ),
  );

  // ---- One run --------------------------------------------------------------

  Widget _detail(_RunRow r) {
    final Widget content;
    if (_lineLoading.contains(r.id) || (!_lines.containsKey(r.id) && !_lineErrors.containsKey(r.id))) {
      content = const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))),
      );
    } else if (_lineErrors.containsKey(r.id)) {
      content = Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.error_outline_rounded, size: 18, color: DashUi.red),
            const SizedBox(width: 8),
            Expanded(
              child: Text(_lineErrors[r.id]!, style: const TextStyle(color: DashUi.red, fontSize: 13)),
            ),
            TextButton(
              onPressed: () {
                setState(() => _openId = null);
                _toggle(r);
              },
              child: const Text('Try again'),
            ),
          ],
        ),
      );
    } else {
      final detail = _lines[r.id]!;
      final lines = detail.lines;
      const cell = TextStyle(fontSize: 13, color: DashUi.ink, fontFeatures: _figures);
      // A voided run was reversed, so what it "paid" is struck through and greyed like its amount above, not green.
      final paidStyle = r.voided
          ? cell.copyWith(fontWeight: FontWeight.w700, color: DashUi.subtle, decoration: TextDecoration.lineThrough)
          : cell.copyWith(fontWeight: FontWeight.w800, color: DashUi.emeraldText);
      TextStyle figure(double v, {bool paid = false}) => paid
          ? (v > 0 ? paidStyle : cell.copyWith(fontWeight: FontWeight.w800))
          : cell.copyWith(color: v.abs() < 0.005 ? DashUi.subtle : DashUi.ink);
      Widget num(double v, {bool paid = false}) => Expanded(
        flex: 3,
        child: Text(
          _money.format(v),
          textAlign: TextAlign.right,
          style: figure(v, paid: paid),
        ),
      );
      Widget who(_LineRow l) => Row(
        children: [
          DashAvatar(name: l.name, imageUrl: '', size: 26),
          const SizedBox(width: 10),
          Expanded(
            child: Text(l.name, style: cell.copyWith(fontWeight: FontWeight.w600)),
          ),
        ],
      );
      // On a phone-width window the six columns can't fit: each person becomes a name with what this run paid them,
      // and the rest of their line underneath.
      Widget narrowLine(_LineRow l) => Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: DashUi.line)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: who(l)),
                Text(_money.format(l.paid), style: figure(l.paid, paid: true)),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 36, top: 2),
              child: Text(
                'Gross ${_money.format(l.gross)} · Held ${_money.format(l.retainage)} · '
                'Payable ${_money.format(l.payable)} · Paid before ${_money.format(l.previouslyPaid)}',
                style: const TextStyle(fontSize: 12, color: DashUi.subtle, height: 1.35, fontFeatures: _figures),
              ),
            ),
          ],
        ),
      );
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (r.notes.isNotEmpty) _note('Notes', r.notes),
          if (r.voided)
            _note(
              'Voided${r.voidedBy.isEmpty ? '' : ' by ${r.voidedBy}'}',
              r.voidReason.isEmpty ? 'No reason given.' : r.voidReason,
            ),
          if (lines.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Nobody was paid in this run.', style: TextStyle(color: DashUi.slate, fontSize: 13)),
            )
          else
            LayoutBuilder(
              builder: (context, c) {
                if (c.maxWidth < 520) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [for (final l in lines) narrowLine(l)],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      margin: const EdgeInsets.only(top: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(8)),
                      child: const Row(
                        children: [
                          Expanded(flex: 5, child: Text('Person', style: _head)),
                          Expanded(
                            flex: 3,
                            child: Text('Weekly gross', textAlign: TextAlign.right, style: _head),
                          ),
                          Expanded(
                            flex: 3,
                            child: Text('Retainage held', textAlign: TextAlign.right, style: _head),
                          ),
                          Expanded(
                            flex: 3,
                            child: Text('Payable', textAlign: TextAlign.right, style: _head),
                          ),
                          Expanded(
                            flex: 3,
                            child: Text('Paid before', textAlign: TextAlign.right, style: _head),
                          ),
                          Expanded(
                            flex: 3,
                            child: Text('Paid in this run', textAlign: TextAlign.right, style: _head),
                          ),
                        ],
                      ),
                    ),
                    for (final l in lines)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                        decoration: const BoxDecoration(
                          border: Border(bottom: BorderSide(color: DashUi.line)),
                        ),
                        child: Row(
                          children: [
                            Expanded(flex: 5, child: who(l)),
                            num(l.gross),
                            num(l.retainage),
                            num(l.payable),
                            num(l.previouslyPaid),
                            num(l.paid, paid: true),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
          // Adjustment runs re-pay the same week, so the week's pool and retainage are shown once, on the regular run.
          if (!r.adjustment && !r.voided) ...[
            const SizedBox(height: 12),
            _contribution(
              'Retainage held from pay',
              detail.retainageTotal,
              lines.where((l) => l.retainage != 0).length,
            ),
            _contribution(
              'Company pool from jobs closed this week',
              detail.poolTotal,
              detail.poolJobs.length,
              unit: 'job',
            ),
            for (final p in detail.poolJobs)
              Padding(
                padding: const EdgeInsets.only(left: 12, top: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Job ${p.jobId}${p.customer.isEmpty ? '' : '  ${p.customer}'}',
                        style: const TextStyle(fontSize: 12.5, color: DashUi.slate),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(_money.format(p.amount), style: cell.copyWith(fontSize: 12.5, color: DashUi.slate)),
                  ],
                ),
              ),
          ],
        ],
      );
    }
    // Indented under its run with a thread down the left, so it reads as belonging to that run.
    return Container(
      margin: const EdgeInsets.fromLTRB(40, 0, 48, 14),
      padding: const EdgeInsets.fromLTRB(16, 2, 0, 4),
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: DashUi.line, width: 2)),
      ),
      child: content,
    );
  }

  Widget _contribution(String label, double amount, int count, {String unit = 'person'}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(
          child: Text(
            '$label  ·  $count ${count == 1 ? unit : (unit == 'person' ? 'people' : '${unit}s')}',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.ink),
          ),
        ),
        Text(
          _money.format(amount),
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: DashUi.ink, fontFeatures: _figures),
        ),
      ],
    ),
  );

  Widget _note(String label, String text) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 4),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: const TextStyle(fontWeight: FontWeight.w700, color: DashUi.ink),
          ),
          TextSpan(
            text: text,
            style: const TextStyle(color: DashUi.slate),
          ),
        ],
      ),
      style: const TextStyle(fontSize: 13, height: 1.4),
    ),
  );

  Widget _cappedNote() => Container(
    padding: const EdgeInsets.fromLTRB(24, 10, 24, 12),
    decoration: const BoxDecoration(
      color: DashUi.faint,
      border: Border(top: BorderSide(color: DashUi.line)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 1),
          child: Icon(Icons.info_outline_rounded, size: 16, color: DashUi.slate),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Showing the $_limit most recent runs. Older runs exist but are not listed here, so a week before '
            '${_runs.last.weekLabel} that is missing from this list may still have been paid.',
            style: const TextStyle(fontSize: 12.5, color: DashUi.slate, height: 1.35),
          ),
        ),
      ],
    ),
  );

  // ---- States -----------------------------------------------------------------

  /// Loading: the shape of the summary and a few runs, as the payroll screen does, instead of a lone spinner.
  Widget _skeleton() => Semantics(
    label: 'Loading payroll history',
    liveRegion: true,
    child: SkeletonPulse(
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Row(
                children: [
                  Expanded(child: _SkeletonStat()),
                  SizedBox(width: 32),
                  Expanded(child: _SkeletonStat()),
                  SizedBox(width: 32),
                  Expanded(child: _SkeletonStat()),
                ],
              ),
              const SizedBox(height: 20),
              Container(height: 36, color: DashUi.faint),
              for (var i = 0; i < 4; i++)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 14, 16, 0),
                  child: Row(
                    children: [
                      SkeletonBox(h: 12, w: 120),
                      Spacer(),
                      SkeletonBox(h: 12, w: 220),
                      SizedBox(width: 40),
                      SkeletonBox(h: 12, w: 80),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  /// Empty, error and no-access: an icon, a title, what happened and, when it can help, a way forward; the payroll
  /// screen's states look the same.
  Widget _state({required IconData icon, required String title, required String message, Widget? action}) => Padding(
    padding: const EdgeInsets.fromLTRB(32, 44, 32, 44),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: DashUi.line),
          ),
          child: Icon(icon, size: 38, color: DashUi.muted),
        ),
        const SizedBox(height: 18),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: DashUi.ink),
        ),
        const SizedBox(height: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: DashUi.slate, height: 1.4),
          ),
        ),
        if (action != null) ...[const SizedBox(height: 18), action],
      ],
    ),
  );
}

class _SkeletonStat extends StatelessWidget {
  const _SkeletonStat();

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SkeletonBox(h: 10, w: 90),
      SizedBox(height: 10),
      SkeletonBox(h: 20, w: 130),
      SizedBox(height: 8),
      SkeletonBox(h: 10, w: 160),
    ],
  );
}
