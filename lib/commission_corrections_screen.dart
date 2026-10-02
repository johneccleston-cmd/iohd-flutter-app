import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'config/api_config.dart';
import 'config/auth_session.dart';

// Fixes for commission data that Service Fusion statuses cannot undo on their own:
// a day marked Completed by mistake, a visit stuck as a callback, a wrong day weight, or a job that
// was closed by accident. Every change needs a reason and is logged on the server.

const _ink = Color(0xFF181B1F);
const _slate = Color(0xFF5B6572);
const _muted = Color(0xFF9199A6);
const _line = Color(0xFFE4E7EC);
const _brandRed = Color(0xFFCC0007);
const _amber = Color(0xFFB45309);
const _green = Color(0xFF047857);

class _ApiError implements Exception {
  final String message;
  const _ApiError(this.message);
  @override
  String toString() => message;
}

Future<Map<String, dynamic>> _call(String method, String path, {Map<String, dynamic>? body}) async {
  final uri = Uri.parse('$kApiBaseUrl/api/admin/commission$path');
  final headers = AuthSession.instance.headers();
  final http.Response res;
  try {
    res = await (method == 'POST'
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

class CommissionCorrectionsScreen extends StatefulWidget {
  const CommissionCorrectionsScreen({super.key});

  @override
  State<CommissionCorrectionsScreen> createState() => _CommissionCorrectionsScreenState();
}

class _CommissionCorrectionsScreenState extends State<CommissionCorrectionsScreen> {
  final _search = TextEditingController();
  Timer? _debounce;

  List<Map<String, dynamic>> _results = [];
  bool _searching = false;
  String? _searchError;

  String? _jobId;
  Map<String, dynamic>? _detail;
  bool _loadingDetail = false;
  String? _detailError;

  List<Map<String, dynamic>> _recent = [];

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    try {
      final data = await _call('GET', '/corrections?limit=30');
      if (!mounted) return;
      setState(() => _recent = List<Map<String, dynamic>>.from(data['corrections'] ?? const []));
    } catch (_) {
      // The log is a convenience; the page works without it.
    }
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _runSearch);
  }

  Future<void> _runSearch() async {
    final q = _search.text.trim();
    if (q.length < 2) {
      setState(() {
        _results = [];
        _searchError = null;
      });
      return;
    }
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final data = await _call('GET', '/jobs?q=${Uri.encodeQueryComponent(q)}');
      if (!mounted || q != _search.text.trim()) return;
      setState(() {
        _results = List<Map<String, dynamic>>.from(data['jobs'] ?? const []);
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searchError = e.toString();
      });
    }
  }

  Future<void> _openJob(String jobId) async {
    setState(() {
      _jobId = jobId;
      _detail = null;
      _loadingDetail = true;
      _detailError = null;
    });
    try {
      final data = await _call('GET', '/jobs/${Uri.encodeComponent(jobId)}');
      if (!mounted || _jobId != jobId) return;
      setState(() {
        _detail = data;
        _loadingDetail = false;
      });
    } catch (e) {
      if (!mounted || _jobId != jobId) return;
      setState(() {
        _loadingDetail = false;
        _detailError = e.toString();
      });
    }
  }

  void _toast(String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: error ? _brandRed : _ink, behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _fixDay(Map<String, dynamic> day) async {
    final body = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _FixDayDialog(day: day),
    );
    if (body == null || _jobId == null) return;
    try {
      final data = await _call('POST', '/jobs/${Uri.encodeComponent(_jobId!)}/day', body: {'dayId': day['id'], ...body});
      if (!mounted) return;
      setState(() => _detail = data);
      _toast('Correction saved.');
      _loadRecent();
    } catch (e) {
      if (mounted) _toast(e.toString(), error: true);
    }
  }

  Future<void> _unlock() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _ReasonDialog(
        title: 'Unlock this job?',
        message: 'This removes the closing lock and clears the earned amount, so commission is recalculated from '
            "the job's current status. Use it when the job was closed by mistake.",
        confirmLabel: 'Unlock job',
      ),
    );
    if (reason == null || _jobId == null) return;
    try {
      final data = await _call('POST', '/jobs/${Uri.encodeComponent(_jobId!)}/unlock', body: {'reason': reason});
      if (!mounted) return;
      setState(() => _detail = data);
      final warnings = List<String>.from(data['warnings'] ?? const []);
      _toast(warnings.isEmpty ? 'Job unlocked.' : 'Job unlocked. ${warnings.first}');
      _loadRecent();
    } catch (e) {
      if (mounted) _toast(e.toString(), error: true);
    }
  }

  // ---- UI -----------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFF6F7F9),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Commission corrections',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: _ink)),
            const SizedBox(height: 4),
            const Text(
              "Fix things a Service Fusion status can't undo: a day marked Completed by mistake, a visit stuck as a "
              'callback, a wrong day weight, or a job closed by accident. Every change needs a reason and is logged.',
              style: TextStyle(fontSize: 13.5, color: _slate, height: 1.4),
            ),
            const SizedBox(height: 18),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 340, child: _buildSearchPanel()),
                  const SizedBox(width: 20),
                  Expanded(child: _buildDetailPanel()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  BoxDecoration get _panel => BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _line),
      );

  Widget _buildSearchPanel() {
    return Container(
      decoration: _panel,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _search,
            onChanged: _onSearchChanged,
            onSubmitted: (_) => _runSearch(),
            decoration: InputDecoration(
              hintText: 'Job number or customer',
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _searching
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5, color: _brandRed))
                : _searchError != null
                    ? Text(_searchError!, style: const TextStyle(color: _brandRed, fontSize: 13))
                    : _results.isEmpty
                        ? _buildRecent()
                        : ListView.separated(
                            itemCount: _results.length,
                            separatorBuilder: (_, _) => const Divider(height: 1, color: _line),
                            itemBuilder: (_, i) => _resultTile(_results[i]),
                          ),
          ),
        ],
      ),
    );
  }

  Widget _resultTile(Map<String, dynamic> j) {
    final selected = j['job_id'] == _jobId;
    return InkWell(
      onTap: () => _openJob(j['job_id'].toString()),
      child: Container(
        color: selected ? const Color(0xFFFCEEEE) : null,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(j['customer_name']?.toString() ?? 'Unknown',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: _ink)),
            const SizedBox(height: 2),
            Text('#${j['job_id']} · ${j['status'] ?? ''} · ${_day(j['start_date']?.toString())}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: _slate)),
            if (j['locked'] == true || j['is_commission_paid'] == true)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(spacing: 6, children: [
                  if (j['locked'] == true) _chip('Locked', _amber),
                  if (j['is_commission_paid'] == true) _chip('Paid', _brandRed),
                ]),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecent() {
    if (_recent.isEmpty) {
      return const Center(
        child: Text('Search for a job to see its visits.',
            textAlign: TextAlign.center, style: TextStyle(color: _muted, fontSize: 13)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('RECENT CORRECTIONS',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _slate, letterSpacing: 0.8)),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.separated(
            itemCount: _recent.length,
            separatorBuilder: (_, _) => const Divider(height: 1, color: _line),
            itemBuilder: (_, i) {
              final c = _recent[i];
              return InkWell(
                onTap: () => _openJob(c['job_id'].toString()),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${_actionLabel(c['action']?.toString())} · #${c['job_id']}',
                          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _ink)),
                      Text('${c['changed_by_name'] ?? ''} · ${_stamp(c['changed_at'])}',
                          style: const TextStyle(fontSize: 11.5, color: _slate)),
                      Text(c['reason']?.toString() ?? '',
                          maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: _muted)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  static String _actionLabel(String? a) => switch (a) {
        'set_verified' => 'Verified changed',
        'clear_verified' => 'Verified reset',
        'set_callback' => 'Callback changed',
        'clear_callback' => 'Callback reset',
        'set_weight' => 'Weight changed',
        'clear_weight' => 'Weight reset',
        'unlock_job' => 'Job unlocked',
        _ => a ?? 'Change',
      };

  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Text(label, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: color)),
      );

  Widget _buildDetailPanel() {
    if (_jobId == null) {
      return Container(
        decoration: _panel,
        alignment: Alignment.center,
        child: const Text('Pick a job on the left.', style: TextStyle(color: _muted, fontSize: 14)),
      );
    }
    if (_loadingDetail) {
      return Container(
        decoration: _panel,
        alignment: Alignment.center,
        child: const CircularProgressIndicator(strokeWidth: 2.5, color: _brandRed),
      );
    }
    if (_detailError != null) {
      return Container(
        decoration: _panel,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_detailError!, textAlign: TextAlign.center, style: const TextStyle(color: _brandRed)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: () => _openJob(_jobId!), child: const Text('Try again')),
          ],
        ),
      );
    }

    final d = _detail!;
    final job = Map<String, dynamic>.from(d['job'] as Map);
    final lock = d['lock'] == null ? null : Map<String, dynamic>.from(d['lock'] as Map);
    final days = List<Map<String, dynamic>>.from(d['days'] ?? const []);
    final corrections = List<Map<String, dynamic>>.from(d['corrections'] ?? const []);
    final paid = job['is_commission_paid'] == true;
    final closing = job['statusIsClosing'] == true;

    return Container(
      decoration: _panel,
      padding: const EdgeInsets.all(20),
      child: ListView(
        children: [
          Text(job['customer_name']?.toString() ?? 'Unknown customer',
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: _ink)),
          const SizedBox(height: 4),
          Text('Job #${job['job_id']} · started ${_day(job['start_date']?.toString())}',
              style: const TextStyle(fontSize: 13, color: _slate)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 6, children: [
            _chip(job['status']?.toString() ?? 'No status', closing ? _green : _slate),
            if (closing) _chip('Closing status', _green),
            if (job['inScope'] != true) _chip('Started before go-live, ignored for commission', _brandRed),
            if (lock != null) _chip('Locked', _amber),
            if (paid) _chip('Commission paid', _brandRed),
          ]),
          if (lock != null) ...[
            const SizedBox(height: 16),
            _lockCard(lock, closing: closing, paid: paid),
          ],
          const SizedBox(height: 22),
          const Text('SITE VISITS',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _slate, letterSpacing: 0.8)),
          const SizedBox(height: 8),
          if (paid)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('This job is marked commission paid, so its visits are frozen.',
                  style: TextStyle(color: _brandRed, fontSize: 12.5)),
            ),
          _dayHeader(),
          if (days.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('No site visits recorded for this job.', style: TextStyle(color: _muted, fontSize: 13)),
            )
          else
            for (final day in days) _dayRow(day, editable: !paid),
          if (corrections.isNotEmpty) ...[
            const SizedBox(height: 24),
            const Text('HISTORY FOR THIS JOB',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _slate, letterSpacing: 0.8)),
            const SizedBox(height: 8),
            for (final c in corrections)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_actionLabel(c['action']?.toString())}'
                      '${c['target'] != null ? ' · ${c['target']}' : ''}',
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _ink),
                    ),
                    Text('${c['old_value'] ?? '—'}  →  ${c['new_value'] ?? '—'}',
                        style: const TextStyle(fontSize: 12, color: _slate)),
                    Text('${c['changed_by_name'] ?? ''} · ${_stamp(c['changed_at'])} · "${c['reason']}"',
                        style: const TextStyle(fontSize: 11.5, color: _muted)),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _lockCard(Map<String, dynamic> lock, {required bool closing, required bool paid}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lock_rounded, size: 18, color: _amber),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Closed ${_stamp(lock['locked_at'])} as "${lock['locked_status']}"',
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: _ink)),
                const SizedBox(height: 2),
                Text(
                  'Commission is paid in the pay week starting ${_day(lock['pay_week']?.toString())}'
                  '${lock['week_paid'] == true ? ', which already has a finalized payroll run' : ''}. '
                  'Changing the status back does not unlock it.',
                  style: const TextStyle(fontSize: 12.5, color: _slate, height: 1.35),
                ),
                if (closing)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      'To unlock, first change the job to a non-closing status in Service Fusion, '
                      'otherwise the next sync locks it again.',
                      style: TextStyle(fontSize: 12.5, color: _amber, height: 1.35),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: (closing || paid) ? null : _unlock,
            icon: const Icon(Icons.lock_open_rounded, size: 16),
            label: const Text('Unlock'),
          ),
        ],
      ),
    );
  }

  Widget _dayHeader() {
    const s = TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: _muted);
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      child: Row(children: [
        Expanded(flex: 3, child: Text('DATE', style: s)),
        Expanded(flex: 4, child: Text('TECH', style: s)),
        Expanded(flex: 3, child: Text('TECH STATUS', style: s)),
        Expanded(flex: 2, child: Text('WEIGHT', style: s)),
        Expanded(flex: 3, child: Text('VERIFIED', style: s)),
        Expanded(flex: 3, child: Text('CALLBACK', style: s)),
        SizedBox(width: 64),
      ]),
    );
  }

  Widget _dayRow(Map<String, dynamic> day, {required bool editable}) {
    final before = day['beforeGoLive'] == true;
    final verified = day['is_verified'] == true;
    final callback = day['is_callback'] == true;
    final fixedV = day['override_verified'] != null;
    final fixedC = day['override_callback'] != null;
    final fixedW = day['override_weight'] != null;

    Widget flag(bool on, String yes, String no, Color yesColor, bool fixed) => Row(children: [
          Flexible(
            child: Text(on ? yes : no,
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: on ? yesColor : _muted)),
          ),
          if (fixed)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Tooltip(message: 'Fixed by the office; the sync keeps this value', child: Icon(Icons.edit_note_rounded, size: 15, color: _amber)),
            ),
        ]);

    return Opacity(
      opacity: before ? 0.5 : 1,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: _line))),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_day(day['work_date']?.toString()), style: const TextStyle(fontSize: 13, color: _ink, fontWeight: FontWeight.w600)),
                  if (before) const Text('before go-live', style: TextStyle(fontSize: 10.5, color: _muted)),
                  if (day['week_paid'] == true) const Text('week already paid', style: TextStyle(fontSize: 10.5, color: _amber)),
                ],
              ),
            ),
            Expanded(flex: 4, child: Text(day['tech_name']?.toString() ?? '', style: const TextStyle(fontSize: 13, color: _ink))),
            Expanded(flex: 3, child: Text(day['tech_status']?.toString() ?? '—', style: const TextStyle(fontSize: 12.5, color: _slate))),
            Expanded(
              flex: 2,
              child: Row(children: [
                Text(_weightText(day['day_weight']), style: const TextStyle(fontSize: 13, color: _ink)),
                if (fixedW)
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Tooltip(message: 'Fixed by the office; the sync keeps this value', child: Icon(Icons.edit_note_rounded, size: 15, color: _amber)),
                  ),
              ]),
            ),
            Expanded(flex: 3, child: flag(verified, 'Verified', 'Not verified', _green, fixedV)),
            Expanded(flex: 3, child: flag(callback, 'Callback', 'No', _brandRed, fixedC)),
            SizedBox(
              width: 64,
              child: TextButton(onPressed: editable ? () => _fixDay(day) : null, child: const Text('Fix')),
            ),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------------
// Dialogs
// ----------------------------------------------------------------------------

enum _Pick { keep, yes, no, auto }

class _FixDayDialog extends StatefulWidget {
  final Map<String, dynamic> day;
  const _FixDayDialog({required this.day});

  @override
  State<_FixDayDialog> createState() => _FixDayDialogState();
}

class _FixDayDialogState extends State<_FixDayDialog> {
  _Pick _verified = _Pick.keep;
  _Pick _callback = _Pick.keep;
  _Pick _weight = _Pick.keep; // keep | yes (set a value) | auto (back to the sync)
  final _weightCtl = TextEditingController();
  final _reason = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _weightCtl.text = _weightText(widget.day['day_weight']).replaceAll('—', '');
  }

  @override
  void dispose() {
    _weightCtl.dispose();
    _reason.dispose();
    super.dispose();
  }

  Widget _pickRow(String label, _Pick value, ValueChanged<_Pick> onChanged, {required String yes, required String no}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _ink)),
          const SizedBox(height: 6),
          DropdownButtonFormField<_Pick>(
            initialValue: value,
            isDense: true,
            decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
            items: [
              const DropdownMenuItem(value: _Pick.keep, child: Text('Leave as it is')),
              DropdownMenuItem(value: _Pick.yes, child: Text(yes)),
              if (no.isNotEmpty) DropdownMenuItem(value: _Pick.no, child: Text(no)),
              const DropdownMenuItem(value: _Pick.auto, child: Text('Back to automatic (let the sync decide)')),
            ],
            onChanged: (v) => onChanged(v ?? _Pick.keep),
          ),
        ],
      ),
    );
  }

  void _submit() {
    final body = <String, dynamic>{};
    if (_verified != _Pick.keep) body['verified'] = _verified == _Pick.auto ? null : _verified == _Pick.yes;
    if (_callback != _Pick.keep) body['callback'] = _callback == _Pick.auto ? null : _callback == _Pick.yes;
    if (_weight == _Pick.auto) {
      body['weight'] = null;
    } else if (_weight == _Pick.yes) {
      final w = double.tryParse(_weightCtl.text.trim());
      if (w == null || w < 0 || w > 3) {
        setState(() => _error = 'Weight must be a number from 0 to 3.');
        return;
      }
      body['weight'] = w;
    }
    if (body.isEmpty) {
      setState(() => _error = 'Choose at least one change.');
      return;
    }
    final reason = _reason.text.trim();
    if (reason.length < 5) {
      setState(() => _error = 'Please give a reason (at least 5 characters).');
      return;
    }
    body['reason'] = reason;
    Navigator.pop(context, body);
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.day;
    return AlertDialog(
      title: Text('${d['tech_name']} · ${_day(d['work_date']?.toString())}'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _pickRow('Verified (counts as worked)', _verified, (v) => setState(() => _verified = v),
                  yes: 'Mark as verified', no: 'Mark as NOT verified'),
              _pickRow('Callback / warranty visit', _callback, (v) => setState(() => _callback = v),
                  yes: 'Mark as a callback', no: 'Mark as NOT a callback'),
              _pickRow('Day weight', _weight, (v) => setState(() => _weight = v),
                  yes: 'Set to a value…', no: ''),
              if (_weight == _Pick.yes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: TextField(
                    controller: _weightCtl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Weight (0 to 3)',
                      helperText: 'Full day = 1, half day = 0.5, times the tech\'s own weight',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              TextField(
                controller: _reason,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Reason (required)',
                  hintText: 'e.g. Tech tapped Completed by mistake; job is not done',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_error!, style: const TextStyle(color: _brandRed, fontSize: 12.5)),
                ),
              const SizedBox(height: 10),
              const Text(
                'A fixed value stays put through the 3-minute sync until you set it back to automatic.',
                style: TextStyle(fontSize: 12, color: _slate),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(backgroundColor: _brandRed),
          child: const Text('Save correction'),
        ),
      ],
    );
  }
}

class _ReasonDialog extends StatefulWidget {
  final String title;
  final String message;
  final String confirmLabel;
  const _ReasonDialog({required this.title, required this.message, required this.confirmLabel});

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _reason = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.message, style: const TextStyle(fontSize: 13, color: _slate, height: 1.4)),
            const SizedBox(height: 14),
            TextField(
              controller: _reason,
              maxLines: 2,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Reason (required)',
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final r = _reason.text.trim();
            if (r.length < 5) {
              setState(() => _error = 'At least 5 characters.');
              return;
            }
            Navigator.pop(context, r);
          },
          style: FilledButton.styleFrom(backgroundColor: _brandRed),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
