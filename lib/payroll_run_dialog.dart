import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'widgets/dashboard_kit.dart';

// ---------------------------------------------------------------------------
// Run and finalize payroll for one pay week (Monday to Sunday).
//
// Backend: GET /api/payroll/runs/preview?week=  (no writes), POST /api/payroll/runs {week, notes} (finalize),
// GET /api/payroll/runs (history), POST /api/payroll/runs/:id/void {reason}.
//
// A week can be run more than once: every run only pays the difference from what earlier finalized runs already
// paid, so a late correction becomes a small adjustment run and nothing is paid twice. A week can only be run
// once it is over.
// ---------------------------------------------------------------------------

final NumberFormat _money = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
double _n(dynamic v) => v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);
String _ymdOf(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
DateTime _mondayOf(DateTime d) {
  final day = DateTime(d.year, d.month, d.day);
  return day.subtract(Duration(days: day.weekday - DateTime.monday));
}

class _ApiError implements Exception {
  final String message;
  const _ApiError(this.message);
  @override
  String toString() => message;
}

Future<Map<String, dynamic>> _call(String method, String path, {Map<String, String>? query, Object? body}) async {
  final uri = Uri.parse('$kApiBaseUrl$path').replace(queryParameters: query);
  final headers = {...AuthSession.instance.headers(), 'Content-Type': 'application/json'};
  try {
    final http.Response res;
    if (method == 'POST') {
      res = await http.post(uri, headers: headers, body: json.encode(body ?? {})).timeout(const Duration(seconds: 90));
    } else {
      res = await http.get(uri, headers: headers).timeout(const Duration(seconds: 90));
    }
    Map<String, dynamic> data = {};
    try {
      final decoded = json.decode(res.body);
      if (decoded is Map<String, dynamic>) data = decoded;
    } catch (_) {}
    if (res.statusCode == 401) {
      AuthSession.instance.logout(); // sends the app back to the sign-in screen
      throw const _ApiError('Your session expired. Please sign in again.');
    }
    if (res.statusCode == 403) throw const _ApiError('Your account does not have access to run payroll.');
    if (res.statusCode >= 400 || data['success'] == false) {
      throw _ApiError(data['error']?.toString() ?? 'The server returned status ${res.statusCode}.');
    }
    return data;
  } on TimeoutException {
    throw const _ApiError('The server took too long to respond. Try again in a moment.');
  } on _ApiError {
    rethrow;
  } catch (_) {
    throw const _ApiError('Could not reach the server. Check the connection and try again.');
  }
}

class _RunLine {
  final String name;
  final bool isSales;
  final double gross;
  final double hurdle;
  final double payable;
  final double previouslyPaid;
  final double carryRecovered;
  final double amountPaid;

  _RunLine(Map<String, dynamic> j)
      : name = '${j['tech_name'] ?? ''}',
        isSales = j['is_sales'] == true,
        gross = _n(j['weekly_gross']),
        hurdle = _n(j['hurdle']),
        payable = _n(j['payable']),
        previouslyPaid = _n(j['previously_paid']),
        carryRecovered = _n(j['carry_recovered']),
        amountPaid = _n(j['amount_paid']);
}

class _Preview {
  final List<_RunLine> lines;
  final double payable;
  final double previouslyPaid;
  final double toPay;
  final bool hasPriorRuns;
  final bool weekIsOver;

  _Preview(Map<String, dynamic> j)
      : lines = [for (final l in (j['lines'] as List? ?? const [])) _RunLine(Map<String, dynamic>.from(l as Map))],
        payable = _n((j['totals'] as Map?)?['payable']),
        previouslyPaid = _n((j['totals'] as Map?)?['previously_paid']),
        toPay = _n((j['totals'] as Map?)?['amount_paid']),
        hasPriorRuns = j['has_prior_runs'] == true,
        weekIsOver = j['week_is_over'] == true;
}

class _Run {
  final int id;
  final String type;
  final String status;
  final String by;
  final String? notes;
  final double paid;
  final DateTime? at;
  final String? voidReason;

  _Run(Map<String, dynamic> j)
      : id = _n(j['id']).round(),
        type = '${j['run_type'] ?? ''}',
        status = '${j['status'] ?? ''}',
        by = '${j['run_by_name'] ?? ''}',
        notes = (j['notes'] as String?)?.trim().isEmpty ?? true ? null : j['notes'] as String,
        paid = _n(j['total_amount_paid']),
        at = DateTime.tryParse('${j['created_at'] ?? ''}')?.toLocal(),
        voidReason = j['void_reason'] as String?;
}

/// Opens the run payroll dialog on the pay week containing [initialDate]. [onChanged] fires after a run is
/// finalized or voided so the caller can refresh its numbers.
Future<void> showPayrollRunDialog(BuildContext context, {required DateTime initialDate, VoidCallback? onChanged}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _PayrollRunDialog(initialDate: initialDate, onChanged: onChanged),
  );
}

class _PayrollRunDialog extends StatefulWidget {
  final DateTime initialDate;
  final VoidCallback? onChanged;
  const _PayrollRunDialog({required this.initialDate, this.onChanged});

  @override
  State<_PayrollRunDialog> createState() => _PayrollRunDialogState();
}

class _PayrollRunDialogState extends State<_PayrollRunDialog> {
  late DateTime _week = _mondayOf(widget.initialDate);
  _Preview? _preview;
  List<_Run> _runs = const [];
  bool _loading = true;
  bool _busy = false; // finalizing or voiding
  String? _error;
  String? _message;
  int _requestId = 0;
  final _notes = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final id = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final week = _ymdOf(_week);
      final results = await Future.wait([
        _call('GET', '/api/payroll/runs/preview', query: {'week': week}),
        _call('GET', '/api/payroll/runs', query: {'limit': '100'}),
      ]);
      if (!mounted || id != _requestId) return;
      final runs = [
        for (final r in (results[1]['runs'] as List? ?? const []))
          if ('${(r as Map)['week_start']}' == week) _Run(Map<String, dynamic>.from(r)),
      ];
      setState(() {
        _preview = _Preview(results[0]);
        _runs = runs;
        _loading = false;
      });
    } on _ApiError catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  void _stepWeek(int dir) {
    if (_busy) return;
    setState(() {
      _week = _week.add(Duration(days: 7 * dir));
      _message = null;
      _preview = null;
      _runs = const [];
    });
    _load();
  }

  bool get _canFinalize {
    final p = _preview;
    if (p == null || _busy || _loading) return false;
    if (!p.weekIsOver || p.lines.isEmpty) return false;
    if (p.hasPriorRuns && p.lines.every((l) => l.amountPaid == 0 && l.carryRecovered == 0)) return false;
    return true;
  }

  Future<void> _finalize() async {
    final p = _preview!;
    final end = _week.add(const Duration(days: 6));
    final label = '${DateFormat('MMM d').format(_week)} – ${DateFormat('MMM d, yyyy').format(end)}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(p.hasPriorRuns ? 'Finalize adjustment run?' : 'Finalize payroll?'),
        content: Text(
          'Pay week $label.\n\n'
          'This records ${_money.format(p.toPay)} to pay now across ${p.lines.length} '
          '${p.lines.length == 1 ? 'person' : 'people'}. Anything paid in this run will not be paid again in a later run. '
          'You can void the latest run for a week if it was a mistake.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Finalize')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final res = await _call('POST', '/api/payroll/runs', body: {'week': _ymdOf(_week), 'notes': _notes.text.trim()});
      if (!mounted) return;
      final warnings = [for (final w in (res['warnings'] as List? ?? const [])) '$w'];
      _notes.clear();
      setState(() {
        _busy = false;
        _message = 'Payroll finalized (run #${res['run_id']}).${warnings.isEmpty ? '' : ' ${warnings.join(' ')}'}';
      });
      widget.onChanged?.call();
      _load();
    } on _ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  Future<void> _void(_Run run) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Void run #${run.id}?'),
        content: SizedBox(
          width: 380,
          child: TextField(
            controller: reason,
            autofocus: true,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Reason (required)', border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: DashUi.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Void run'),
          ),
        ],
      ),
    );
    final text = reason.text.trim();
    reason.dispose();
    if (ok != true || text.isEmpty || !mounted) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await _call('POST', '/api/payroll/runs/${run.id}/void', body: {'reason': text});
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = 'Run #${run.id} voided.';
      });
      widget.onChanged?.call();
      _load();
    } on _ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final end = _week.add(const Duration(days: 6));
    final label = '${DateFormat('MMM d').format(_week)} – ${DateFormat('MMM d, yyyy').format(end)}';
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Run payroll', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: DashUi.ink)),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Previous week',
                    onPressed: _busy ? null : () => _stepWeek(-1),
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  Text(label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink)),
                  IconButton(
                    tooltip: 'Next week',
                    onPressed: _busy ? null : () => _stepWeek(1),
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              if (_message != null) _banner(_message!, DashUi.emeraldDeep),
              if (_error != null && _preview != null) _banner(_error!, DashUi.red),
              Flexible(child: _body()),
              const SizedBox(height: 12),
              _footer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _banner(String text, Color color) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Text(text, style: TextStyle(fontSize: 12.5, color: color, fontWeight: FontWeight.w600)),
      );

  Widget _body() {
    if (_loading && _preview == null) {
      return const SizedBox(height: 220, child: Center(child: CircularProgressIndicator()));
    }
    if (_error != null && _preview == null) {
      return SizedBox(
        height: 220,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: DashUi.red, fontSize: 13)),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }
    final p = _preview!;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!p.weekIsOver)
            _banner('This pay week is not over yet. You can preview it, but it can only be finalized after Sunday.', DashUi.amber),
          Row(
            children: [
              _stat('To pay now', _money.format(p.toPay), DashUi.ink),
              _stat('Already paid this week', _money.format(p.previouslyPaid), DashUi.slate),
              _stat('Week payable in total', _money.format(p.payable), DashUi.slate),
            ],
          ),
          const SizedBox(height: 12),
          if (p.lines.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(child: Text('Nothing to pay for this week.', style: TextStyle(color: DashUi.muted))),
            )
          else
            _table(p),
          if (_runs.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('Runs for this week', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: DashUi.ink)),
            const SizedBox(height: 6),
            for (final r in _runs) _runRow(r),
          ],
        ],
      ),
    );
  }

  Widget _stat(String label, String value, Color color) => Expanded(
        child: Container(
          margin: const EdgeInsets.only(right: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: DashUi.panel(radius: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 11.5, color: DashUi.muted, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color)),
            ],
          ),
        ),
      );

  Widget _table(_Preview p) {
    const head = TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: DashUi.muted);
    const cell = TextStyle(fontSize: 12.5, color: DashUi.ink);
    Widget c(String t, {int flex = 2, TextStyle style = cell, TextAlign align = TextAlign.right}) =>
        Expanded(flex: flex, child: Text(t, style: style, textAlign: align));
    return Container(
      decoration: DashUi.panel(radius: 12),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Row(
              children: [
                c('Name', flex: 3, style: head, align: TextAlign.left),
                c('Weekly gross', style: head),
                c('Hurdle', style: head),
                c('Payable', style: head),
                c('Paid before', style: head),
                c('Recovered', style: head),
                c('Pay now', style: head),
              ],
            ),
          ),
          const Divider(height: 1, color: DashUi.line),
          for (final l in p.lines)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  c(l.name, flex: 3, align: TextAlign.left, style: cell.copyWith(fontWeight: FontWeight.w600)),
                  c(_money.format(l.gross)),
                  c(l.hurdle == 0 ? '—' : _money.format(l.hurdle)),
                  c(_money.format(l.payable)),
                  c(l.previouslyPaid == 0 ? '—' : _money.format(l.previouslyPaid)),
                  c(l.carryRecovered == 0 ? '—' : _money.format(l.carryRecovered)),
                  c(
                    _money.format(l.amountPaid),
                    style: cell.copyWith(fontWeight: FontWeight.w800, color: l.amountPaid < 0 ? DashUi.red : DashUi.ink),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _runRow(_Run r) {
    final voided = r.status == 'voided';
    // Only the most recent finalized run of a week can be voided (the server enforces it too).
    final latestFinal = _runs.firstWhere((x) => x.status == 'finalized', orElse: () => r).id == r.id;
    final when = r.at == null ? '' : DateFormat('MMM d, h:mm a').format(r.at!);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '#${r.id}  ${r.type == 'adjustment' ? 'Adjustment' : 'Regular'}  ·  ${_money.format(r.paid)}  ·  ${r.by}  ·  $when'
              '${r.notes != null ? '  ·  ${r.notes}' : ''}'
              '${voided ? '  ·  VOIDED${r.voidReason != null ? ': ${r.voidReason}' : ''}' : ''}',
              style: TextStyle(
                fontSize: 12.5,
                color: voided ? DashUi.muted : DashUi.slate,
                decoration: voided ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
          if (!voided && latestFinal)
            TextButton(onPressed: _busy ? null : () => _void(r), child: const Text('Void')),
        ],
      ),
    );
  }

  Widget _footer() {
    final p = _preview;
    final needsNothing = p != null &&
        p.weekIsOver &&
        p.hasPriorRuns &&
        p.lines.every((l) => l.amountPaid == 0 && l.carryRecovered == 0);
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _notes,
            enabled: !_busy,
            maxLength: 500,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Notes (optional)',
              counterText: '',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 12),
        if (needsNothing)
          const Text('Already fully paid', style: TextStyle(fontSize: 12.5, color: DashUi.muted, fontWeight: FontWeight.w600)),
        const SizedBox(width: 12),
        FilledButton.icon(
          onPressed: _canFinalize ? _finalize : null,
          icon: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.lock_outline_rounded, size: 18),
          label: Text(p?.hasPriorRuns == true ? 'Finalize adjustment' : 'Finalize payroll'),
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 44),
            backgroundColor: DashUi.ink,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ],
    );
  }
}
