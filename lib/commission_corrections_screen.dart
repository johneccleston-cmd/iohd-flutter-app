import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'theme/app_theme.dart';
import 'utils/status_colors.dart';
import 'widgets/app_dialog.dart';
import 'widgets/dashboard_kit.dart';

// Fixes for commission data that Service Fusion statuses cannot undo on their own:
// a day marked Completed by mistake, a visit stuck as a callback, a wrong day weight, or a job that
// was closed by accident. Every change needs a reason and is logged on the server.

const _ink = DashUi.ink;
const _slate = DashUi.slate;
const _muted = DashUi.muted;
const _line = DashUi.line;
const _red = DashUi.red;
const _amber = DashUi.amber;
const _green = DashUi.emeraldDeep;

const _searchLimit = 25; // the server returns at most this many jobs
const _minReason = 5;

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

String _actionLabel(String? a) => switch (a) {
  'set_verified' => 'Verified changed',
  'clear_verified' => 'Verified: stopped fixing',
  'set_callback' => 'Callback changed',
  'clear_callback' => 'Callback: stopped fixing',
  'set_weight' => 'Weight changed',
  'clear_weight' => 'Weight: stopped fixing',
  'unlock_job' => 'Job unlocked',
  _ => a ?? 'Change',
};

/// "Daniel Baty · 2026-10-15" -> "Daniel Baty · Oct 15, 2026".
String _prettyTarget(String? t) {
  if (t == null || t.isEmpty) return '';
  return t.replaceAllMapped(RegExp(r'\d{4}-\d{2}-\d{2}'), (m) => _day(m[0]));
}

/// Old/new values are stored as raw text ("true", "0.00", "back to sync"); show them in words.
String _prettyValue(String? action, dynamic raw) {
  if (raw == null) return '—';
  final s = raw.toString();
  if (s == 'back to sync') return 'Not fixed';
  final isTrue = s == 'true';
  final isFalse = s == 'false';
  if (action != null && action.endsWith('verified') && (isTrue || isFalse)) return isTrue ? 'Verified' : 'Not verified';
  if (action != null && action.endsWith('callback') && (isTrue || isFalse))
    return isTrue ? 'Callback' : 'Not a callback';
  if (action != null && action.endsWith('weight')) return _weightText(s);
  if (isTrue) return 'Yes';
  if (isFalse) return 'No';
  return s;
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

  List<Map<String, dynamic>> _recent = [];
  bool _recentLoading = true;
  String? _recentError;

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
    setState(() {
      _recentLoading = true;
      _recentError = null;
    });
    try {
      final data = await _call('GET', '/corrections?limit=30');
      if (!mounted) return;
      setState(() {
        _recent = List<Map<String, dynamic>>.from(data['corrections'] ?? const []);
        _recentLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _recentLoading = false;
        _recentError = e.toString();
      });
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
      final data = await _call('GET', '/jobs?q=${Uri.encodeQueryComponent(q)}');
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
    setState(() {
      if (!keepContent || _jobId != jobId) _detail = null;
      _jobId = jobId;
      _loadingDetail = true;
      _detailError = null;
    });
    try {
      final data = await _call('GET', '/jobs/${Uri.encodeComponent(jobId)}');
      if (!mounted || _jobId != jobId) return;
      _applyDetail(data);
      setState(() => _loadingDetail = false);
    } catch (e) {
      if (!mounted || _jobId != jobId) return;
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
  /// The dialog stays open (with a spinner) until then, so a failed save never loses what was typed.
  Future<String?> _save(String path, Map<String, dynamic> body, {String done = 'Correction saved.'}) async {
    final jobId = _jobId;
    if (jobId == null) return 'No job is open.';
    try {
      final data = await _call('POST', '/jobs/${Uri.encodeComponent(jobId)}$path', body: body);
      if (mounted) {
        if (_jobId == jobId) setState(() => _applyDetail(data));
        final warnings = List<String>.from(data['warnings'] ?? const []);
        _toast(warnings.isEmpty ? done : '$done ${warnings.first}');
        _loadRecent();
      }
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<void> _fixDay(Map<String, dynamic> day, {required bool jobLocked}) async {
    await showDialog<void>(
      context: context,
      builder: (_) =>
          _FixDayDialog(day: day, jobLocked: jobLocked, onSave: (body) => _save('/day', {'dayId': day['id'], ...body})),
    );
  }

  Future<void> _unlock(Map<String, dynamic> job, Map<String, dynamic> lock) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _UnlockDialog(
        job: job,
        lock: lock,
        onSave: (reason) => _save('/unlock', {'reason': reason}, done: 'Job unlocked.'),
      ),
    );
  }

  // ---- UI -----------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.bgColor,
      child: LayoutBuilder(
        builder: (context, c) {
          final narrow = c.maxWidth < 820;
          final sideWidth = c.maxWidth < 1100 ? 300.0 : 340.0;
          final detailOnly = narrow && _jobId != null;
          return Padding(
            padding: EdgeInsets.all(narrow ? 16 : 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Commission corrections',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: _ink, letterSpacing: -0.3),
                ),
                const SizedBox(height: 4),
                const Text(
                  "Fix things a Service Fusion status can't undo: a day marked Completed by mistake, a visit stuck as a "
                  'callback, a wrong day weight, or a job closed by accident. Every change needs a reason and is logged.',
                  style: TextStyle(fontSize: 13.5, color: _slate, height: 1.4),
                ),
                const SizedBox(height: 18),
                Expanded(
                  child: narrow
                      ? (detailOnly
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  TextButton.icon(
                                    onPressed: () => setState(() => _jobId = null),
                                    icon: const Icon(Icons.arrow_back_rounded, size: 18),
                                    label: const Text('Back to search'),
                                    style: TextButton.styleFrom(foregroundColor: _slate),
                                  ),
                                  Expanded(child: _buildDetailPanel()),
                                ],
                              )
                            : _buildSearchPanel())
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(width: sideWidth, child: _buildSearchPanel()),
                            const SizedBox(width: 20),
                            Expanded(child: _buildDetailPanel()),
                          ],
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  BoxDecoration get _panel => BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(14),
    border: Border.all(color: _line),
  );

  Widget _buildSearchPanel() {
    final q = _search.text.trim();
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
            textInputAction: TextInputAction.search,
            decoration: appFieldDecoration(hint: 'Job number or customer').copyWith(
              prefixIcon: const Icon(Icons.search_rounded, size: 20, color: _slate),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close_rounded, size: 18, color: _muted),
                      onPressed: _clearSearch,
                    ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(child: _buildSearchBody(q)),
        ],
      ),
    );
  }

  Widget _buildSearchBody(String q) {
    if (_searching) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5, color: _ink));
    }
    if (_searchError != null) {
      return _inlineError(_searchError!, _runSearch);
    }
    if (q.isEmpty) return _buildRecent();
    if (q.length < 2) return _hint('Type at least 2 characters.');
    if (_searched && _results.isEmpty) {
      return _hint('No jobs match "$q".\nTry a job number or part of the customer name. Estimates are not listed.');
    }
    if (_results.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView.separated(
            itemCount: _results.length,
            separatorBuilder: (_, _) => const Divider(height: 1, color: _line),
            itemBuilder: (_, i) => _resultTile(_results[i]),
          ),
        ),
        if (_results.length >= _searchLimit)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Showing the first 25 matches. Type more to narrow the list.',
              style: TextStyle(fontSize: 11.5, color: _muted),
            ),
          ),
      ],
    );
  }

  Widget _hint(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: _muted, fontSize: 13, height: 1.4),
      ),
    ),
  );

  Widget _inlineError(String message, VoidCallback retry) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline_rounded, color: _red, size: 22),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: _red, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 10),
        OutlinedButton(onPressed: retry, child: const Text('Try again')),
      ],
    ),
  );

  Widget _resultTile(Map<String, dynamic> j) {
    final selected = j['job_id']?.toString() == _jobId;
    return InkWell(
      onTap: () => _openJob(j['job_id'].toString()),
      child: Container(
        color: selected ? DashUi.faint : null,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              j['customer_name']?.toString() ?? 'Unknown',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: _ink),
            ),
            const SizedBox(height: 2),
            Text(
              '#${j['job_id']} · ${j['status'] ?? 'No status'} · ${_day(j['start_date']?.toString())}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: _slate),
            ),
            if (j['locked'] == true || j['is_commission_paid'] == true)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(
                  spacing: 6,
                  children: [
                    if (j['locked'] == true) const AppTag('Locked', color: _amber),
                    if (j['is_commission_paid'] == true) const AppTag('Paid', color: _red),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecent() {
    if (_recentLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5, color: _ink));
    }
    if (_recentError != null) {
      return _inlineError("Couldn't load recent corrections.\n$_recentError", _loadRecent);
    }
    if (_recent.isEmpty) {
      return _hint('Search for a job to see its visits.\nCorrections you make will be listed here.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('RECENT CORRECTIONS', style: _sectionStyle),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.separated(
            itemCount: _recent.length,
            separatorBuilder: (_, _) => const Divider(height: 1, color: _line),
            itemBuilder: (_, i) {
              final c = _recent[i];
              final selected = c['job_id']?.toString() == _jobId;
              return InkWell(
                onTap: () => _openJob(c['job_id'].toString()),
                child: Container(
                  color: selected ? DashUi.faint : null,
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _actionLabel(c['action']?.toString()),
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: _ink),
                      ),
                      Text(
                        '${c['customer_name'] ?? 'Unknown'} · #${c['job_id']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: _ink),
                      ),
                      Text(
                        '${c['changed_by_name'] ?? ''} · ${_stamp(c['changed_at'])}',
                        style: const TextStyle(fontSize: 11.5, color: _slate),
                      ),
                      if ((c['reason']?.toString() ?? '').isNotEmpty)
                        Text(
                          c['reason'].toString(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11.5, color: _muted),
                        ),
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

  static const _sectionStyle = TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _slate, letterSpacing: 0.8);

  Widget _buildDetailPanel() {
    if (_jobId == null) {
      return Container(
        decoration: _panel,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.manage_search_rounded, size: 40, color: _muted),
            SizedBox(height: 10),
            Text(
              'Pick a job on the left',
              style: TextStyle(color: _ink, fontSize: 15, fontWeight: FontWeight.w800),
            ),
            SizedBox(height: 6),
            SizedBox(
              width: 380,
              child: Text(
                'Search by job number or customer, then fix a visit that was verified by mistake, '
                'stuck as a callback or given the wrong weight, or unlock a job that was closed by accident.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _slate, fontSize: 13, height: 1.45),
              ),
            ),
          ],
        ),
      );
    }
    if (_detailError != null) {
      return Container(
        decoration: _panel,
        child: DashErrorPanel(
          title: "Couldn't load this job",
          message: _detailError!,
          onRetry: () => _openJob(_jobId!),
        ),
      );
    }
    if (_detail == null) {
      return Container(
        decoration: _panel,
        padding: const EdgeInsets.all(20),
        child: SkeletonPulse(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _skel(260, 22),
              const SizedBox(height: 10),
              _skel(180, 14),
              const SizedBox(height: 18),
              _skel(double.infinity, 70),
              const SizedBox(height: 24),
              for (var i = 0; i < 3; i++) ...[_skel(double.infinity, 44), const SizedBox(height: 8)],
            ],
          ),
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
    final inScope = job['inScope'] == true;
    final status = job['status']?.toString();

    return Container(
      decoration: _panel,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          if (_loadingDetail) const LinearProgressIndicator(minHeight: 2, color: _ink, backgroundColor: DashUi.faint),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            job['customer_name']?.toString() ?? 'Unknown customer',
                            style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                              color: _ink,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Job #${job['job_id']} · started ${_day(job['start_date']?.toString())}',
                            style: const TextStyle(fontSize: 13, color: _slate),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Reload this job',
                      onPressed: _loadingDetail ? null : () => _openJob(_jobId!, keepContent: true),
                      icon: const Icon(Icons.refresh_rounded, size: 20, color: _slate),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    AppTag(status ?? 'No status', color: knownStatusColor(status) ?? _slate),
                    if (closing && lock == null) const AppTag('Closing status: locks on the next sync', color: _green),
                    if (!inScope) const AppTag('Started before go-live: ignored for commission', color: _red),
                    if (paid) const AppTag('Commission paid', color: _red),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _stat('Job total', _moneyText(job['total_revenue'])),
                    _stat('Projected commission', _moneyText(job['commission_projected'])),
                    _stat('Earned commission', _moneyText(job['commission_earned'])),
                  ],
                ),
                if (lock != null) ...[const SizedBox(height: 16), _lockCard(job, lock, closing: closing, paid: paid)],
                const SizedBox(height: 22),
                const Text('SITE VISITS', style: _sectionStyle),
                const SizedBox(height: 8),
                if (paid)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: AppNotice(
                      'This job is marked commission paid, so its visits are frozen.',
                      kind: AppNoticeKind.warning,
                    ),
                  ),
                _dayHeader(),
                if (days.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text('No site visits recorded for this job.', style: TextStyle(color: _muted, fontSize: 13)),
                  )
                else
                  for (final day in days) _dayRow(day, paid: paid, inScope: inScope, locked: lock != null),
                const SizedBox(height: 24),
                const Text('HISTORY FOR THIS JOB', style: _sectionStyle),
                const SizedBox(height: 8),
                if (corrections.isEmpty)
                  const Text(
                    'No corrections have been made to this job.',
                    style: TextStyle(color: _muted, fontSize: 13),
                  )
                else
                  for (final c in corrections) _historyEntry(c),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _skel(double w, double h) => Container(
    width: w,
    height: h,
    decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(8)),
  );

  Widget _stat(String label, String value) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(10)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11.5, color: _slate, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(fontSize: 15, color: _ink, fontWeight: FontWeight.w800),
        ),
      ],
    ),
  );

  Widget _historyEntry(Map<String, dynamic> c) {
    final action = c['action']?.toString();
    final target = _prettyTarget(c['target']?.toString());
    final isUnlock = action == 'unlock_job';
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 5, right: 12),
            width: 8,
            height: 8,
            decoration: const BoxDecoration(color: _muted, shape: BoxShape.circle),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _actionLabel(action) + (target.isNotEmpty && !isUnlock ? ' · $target' : ''),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _ink),
                ),
                const SizedBox(height: 4),
                if (isUnlock)
                  Text(target, style: const TextStyle(fontSize: 12.5, color: _slate))
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      AppTag(_prettyValue(action, c['old_value'])),
                      const Icon(Icons.arrow_forward_rounded, size: 14, color: _muted),
                      AppTag(_prettyValue(action, c['new_value']), color: _ink),
                    ],
                  ),
                const SizedBox(height: 4),
                Text(
                  '${c['changed_by_name'] ?? ''} · ${_stamp(c['changed_at'])}',
                  style: const TextStyle(fontSize: 11.5, color: _muted),
                ),
                if ((c['reason']?.toString() ?? '').isNotEmpty)
                  Text(
                    '"${c['reason']}"',
                    style: const TextStyle(fontSize: 12.5, color: _slate, fontStyle: FontStyle.italic, height: 1.35),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _lockCard(Map<String, dynamic> job, Map<String, dynamic> lock, {required bool closing, required bool paid}) {
    final canUnlock = !closing && !paid;
    final why = paid
        ? 'Commission is already paid, so this job cannot be unlocked.'
        : closing
        ? 'Change the job to a non-closing status in Service Fusion first.'
        : '';
    final button = Tooltip(
      message: why,
      child: OutlinedButton.icon(
        onPressed: canUnlock ? () => _unlock(job, lock) : null,
        icon: const Icon(Icons.lock_open_rounded, size: 16),
        label: const Text('Unlock'),
        style: OutlinedButton.styleFrom(
          foregroundColor: _ink,
          side: BorderSide(color: canUnlock ? _ink : _line),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Closed ${_stamp(lock['locked_at'])} as "${lock['locked_status']}"',
          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: _ink),
        ),
        const SizedBox(height: 2),
        Text(
          'Commission is paid in the pay week starting ${_day(lock['pay_week']?.toString())}'
          '${lock['week_paid'] == true ? ', which already has a finalized payroll run' : ''}. '
          'Changing the status back does not unlock it.',
          style: const TextStyle(fontSize: 12.5, color: _slate, height: 1.35),
        ),
        if (closing && !paid)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'To unlock, first change the job to a non-closing status in Service Fusion, '
              'otherwise the next sync locks it again.',
              style: TextStyle(fontSize: 12.5, color: _amber, height: 1.35, fontWeight: FontWeight.w600),
            ),
          ),
      ],
    );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          const icon = Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.lock_rounded, size: 18, color: _amber),
          );
          if (c.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    icon,
                    const SizedBox(width: 10),
                    Expanded(child: text),
                  ],
                ),
                const SizedBox(height: 10),
                button,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              icon,
              const SizedBox(width: 10),
              Expanded(child: text),
              const SizedBox(width: 12),
              button,
            ],
          );
        },
      ),
    );
  }

  // Column widths shared by the header and every row, so they always line up.
  static const _wDate = 104.0;
  static const _wWeight = 76.0;
  static const _wFlag = 112.0;
  static const _wAction = 56.0;

  Widget _dayHeader() {
    const s = TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: _slate, letterSpacing: 0.4);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(8)),
      child: const Row(
        children: [
          SizedBox(
            width: _wDate,
            child: Text('DATE', style: s),
          ),
          Expanded(child: Text('TECH', style: s)),
          SizedBox(
            width: _wWeight,
            child: Text('WEIGHT', style: s),
          ),
          SizedBox(
            width: _wFlag,
            child: Text('VERIFIED', style: s),
          ),
          SizedBox(
            width: _wFlag,
            child: Text('CALLBACK', style: s),
          ),
          SizedBox(width: _wAction),
        ],
      ),
    );
  }

  Widget _flag(String label, Color color, {required bool fixed}) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: fixed ? _amber : Colors.transparent, width: 1.2),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color),
      ),
    );
    return Align(
      alignment: Alignment.centerLeft,
      child: fixed ? Tooltip(message: 'Fixed by the office; the sync keeps this value', child: chip) : chip,
    );
  }

  Widget _dayRow(Map<String, dynamic> day, {required bool paid, required bool inScope, required bool locked}) {
    final before = day['beforeGoLive'] == true;
    final verified = day['is_verified'] == true;
    final callback = day['is_callback'] == true;
    final fixedV = day['override_verified'] != null;
    final fixedC = day['override_callback'] != null;
    final fixedW = day['override_weight'] != null;
    final weight = _num(day['day_weight']) ?? 0;

    final String? blocked = paid
        ? 'This job is marked commission paid, so its visits are frozen.'
        : before
        ? 'This visit is before go-live, so it is ignored for commission.'
        : !inScope
        ? 'This job started before go-live, so it is ignored for commission.'
        : null;

    final zeroWeightHint = (weight == 0 && !callback && !fixedW)
        ? 'Weight 0 means this visit earns nothing. The Service Fusion visit had no "full day", "half day" or '
              '"appointment" wording, or it was a callback, verify delivery or manage project visit. '
              'Use Fix to set a weight if it should pay.'
        : null;

    final techStatus = day['tech_status']?.toString();
    Widget weightCell = Text(
      _weightText(day['day_weight']),
      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: zeroWeightHint != null ? _amber : _ink),
    );
    if (fixedW) {
      weightCell = Tooltip(
        message: 'Fixed by the office; the sync keeps this value',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            border: Border.all(color: _amber, width: 1.2),
            borderRadius: BorderRadius.circular(20),
          ),
          child: weightCell,
        ),
      );
    } else if (zeroWeightHint != null) {
      weightCell = Tooltip(message: zeroWeightHint, child: weightCell);
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
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
                  _day(day['work_date']?.toString()),
                  style: const TextStyle(fontSize: 13, color: _ink, fontWeight: FontWeight.w600),
                ),
                if (before) const Text('Before go-live', style: TextStyle(fontSize: 11, color: _slate)),
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  day['tech_name']?.toString() ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: _ink, fontWeight: FontWeight.w600),
                ),
                Text(
                  techStatus == null || techStatus.isEmpty ? 'No status' : techStatus,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: _slate),
                ),
              ],
            ),
          ),
          SizedBox(
            width: _wWeight,
            child: Align(alignment: Alignment.centerLeft, child: weightCell),
          ),
          SizedBox(
            width: _wFlag,
            child: _flag(verified ? 'Verified' : 'Not verified', verified ? _green : _slate, fixed: fixedV),
          ),
          SizedBox(
            width: _wFlag,
            child: _flag(callback ? 'Callback' : 'Not callback', callback ? _red : _slate, fixed: fixedC),
          ),
          SizedBox(
            width: _wAction,
            child: Tooltip(
              message: blocked ?? '',
              child: TextButton(
                onPressed: blocked != null ? null : () => _fixDay(day, jobLocked: locked),
                style: TextButton.styleFrom(
                  foregroundColor: _ink,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(48, 36),
                ),
                child: const Text('Fix', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------------------
// Dialogs
// ----------------------------------------------------------------------------

enum _Pick { keep, yes, no, auto }

/// Saves what the dialog collected. Returns an error message, or null when it worked.
typedef _Save<T> = Future<String?> Function(T value);

class _FixDayDialog extends StatefulWidget {
  final Map<String, dynamic> day;
  final bool jobLocked;
  final _Save<Map<String, dynamic>> onSave;
  const _FixDayDialog({required this.day, required this.jobLocked, required this.onSave});

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

  /// A reason from the list is always needed; "Other" also needs a real note saying what happened.
  bool get _reasonOk => _why != null && (!_isOther || _noteLeft <= 0);

  /// What is sent and kept in the history: the reason, then the note after it when there is one.
  String get _reasonText {
    final note = _reason.text.trim();
    return note.isEmpty ? _why! : '$_why: $note';
  }

  bool get _valid => _hasChange && !_weightMissing && _weightOk && _reasonOk && !_saving;

  /// "Weight 0 → 1" style lines for the summary box.
  List<String> get _summary {
    final out = <String>[];
    String v(bool b) => b ? 'Verified' : 'Not verified';
    String c(bool b) => b ? 'Callback' : 'Not a callback';
    if (!_noOp(_verified, _d['override_verified'] as bool?)) {
      out.add(
        _verified == _Pick.auto
            ? 'Verified: stop fixing it (it stays ${v(_isVerified).toLowerCase()} for now)'
            : '${v(_isVerified)} → ${v(_verified == _Pick.yes)}',
      );
    }
    if (!_noOp(_callback, _d['override_callback'] as bool?)) {
      out.add(
        _callback == _Pick.auto
            ? 'Callback: stop fixing it (it stays ${c(_isCallback).toLowerCase()} for now)'
            : '${c(_isCallback)} → ${c(_callback == _Pick.yes)}',
      );
    }
    if (_weight == _Pick.yes && _weightValue != null) {
      out.add('Weight ${_weightText(_d['day_weight'])} → ${_weightText(_weightValue)}');
    } else if (_weight == _Pick.auto && _d['override_weight'] != null) {
      out.add('Weight: stop fixing it (stays ${_weightText(_d['day_weight'])} for now)');
    } else if (_callback == _Pick.yes && _weight == _Pick.keep && !_isCallback) {
      out.add('Weight ${_weightText(_d['day_weight'])} → 0 (callback days carry no weight)');
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

  Widget _group(String label, String help, Widget control) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppFieldLabel(label, help: help),
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
                color: on ? _ink : _muted,
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

  // The option that matches today's value is marked "(now)".
  String _opt(String label, bool isNow) => isNow ? '$label (now)' : label;

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    final reasonHelp = _why == null
        ? 'Pick a reason. It is saved in the history with your name.'
        : (_isOther && _noteLeft > 0
              ? (_reason.text.trim().isEmpty
                    ? 'A note is required for Other.'
                    : '$_noteLeft more character${_noteLeft == 1 ? '' : 's'} needed')
              : 'Saved in the history with your name.');

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.enter, control: true): _submit},
      child: AppDialog(
        title: 'Fix this visit',
        subtitle: '${_d['tech_name']} · ${_day(_d['work_date']?.toString())}',
        icon: Icons.rule_folder_outlined,
        width: 520,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  AppTag('Weight ${_weightText(_d['day_weight'])}'),
                  AppTag(_isVerified ? 'Verified' : 'Not verified', color: _isVerified ? _green : _slate),
                  AppTag(_isCallback ? 'Callback' : 'Not a callback', color: _isCallback ? _red : _slate),
                ],
              ),
            ),
            _group(
              'Counts as worked',
              "The tech's Completed tap. The sync never un-verifies a day by itself, even if the status is changed back.",
              AppSegmented<_Pick>(
                value: _verified,
                options: [
                  (_Pick.keep, 'No change'),
                  (_Pick.yes, _opt('Verified', _isVerified)),
                  (_Pick.no, _opt('Not verified', !_isVerified)),
                  (_Pick.auto, 'Stop fixing'),
                ],
                onChanged: _saving ? (_) {} : (v) => setState(() => _verified = v),
              ),
            ),
            _group(
              'Callback or warranty visit',
              'A callback pays the tech \$50 and charges the original techs. Once flagged, the sync never un-flags it.',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppSegmented<_Pick>(
                    value: _callback,
                    options: [
                      (_Pick.keep, 'No change'),
                      (_Pick.yes, _opt('Callback', _isCallback)),
                      (_Pick.no, _opt('Not callback', !_isCallback)),
                      (_Pick.auto, 'Stop fixing'),
                    ],
                    onChanged: _saving
                        ? (_) {}
                        : (v) => setState(() {
                            _callback = v;
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
              "How much of the job's commission this day earns, used exactly as typed: 1 is a full day, 0.5 a half day. "
                  "The tech's own weight is not multiplied in.",
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppSegmented<_Pick>(
                    value: _weight,
                    options: const [(_Pick.keep, 'No change'), (_Pick.yes, 'Set a value'), (_Pick.auto, 'Stop fixing')],
                    onChanged: _saving ? (_) {} : (v) => setState(() => _weight = v),
                  ),
                  if (_weight == _Pick.yes) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        SizedBox(
                          width: 110,
                          child: TextField(
                            controller: _weightCtl,
                            autofocus: true,
                            enabled: !_saving,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                            decoration: appFieldDecoration(
                              hint: '0 to 3',
                              error: _weightCtl.text.isNotEmpty && !_weightOk ? 'Use 0 to 3' : null,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final v in const ['0', '0.5', '1', '1.5'])
                                ActionChip(
                                  label: Text(
                                    v,
                                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _ink),
                                  ),
                                  onPressed: _saving ? null : () => setState(() => _weightCtl.text = v),
                                  backgroundColor: DashUi.faint,
                                  side: BorderSide.none,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                  visualDensity: VisualDensity.compact,
                                ),
                            ],
                          ),
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
            if (widget.jobLocked)
              const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: AppNotice(
                  '"Stop fixing" does not recalculate a closed job: the value saved on the day stays until you set a new one.',
                ),
              ),
            if (summary.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: AppNotice(
                  'This will change:\n${summary.map((s) => '• $s').join('\n')}',
                  kind: AppNoticeKind.success,
                ),
              ),
            if (_error != null) AppNotice(_error!, kind: AppNoticeKind.error),
          ],
        ),
        actions: [
          AppButton.ghost('Cancel', _saving ? null : () => Navigator.pop(context)),
          AppButton.ink(
            _saving ? 'Saving…' : 'Save correction',
            _valid ? _submit : null,
            icon: _saving ? Icons.hourglass_top_rounded : Icons.check_rounded,
          ),
        ],
      ),
    );
  }
}

class _UnlockDialog extends StatefulWidget {
  final Map<String, dynamic> job;
  final Map<String, dynamic> lock;
  final _Save<String> onSave;
  const _UnlockDialog({required this.job, required this.lock, required this.onSave});

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
    final weekPaid = lock['week_paid'] == true;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.enter, control: true): _submit},
      child: AppDialog(
        title: 'Unlock this job?',
        subtitle: '${job['customer_name'] ?? 'Job'} · #${job['job_id']}',
        icon: Icons.lock_open_rounded,
        iconColor: const Color(0xFFB91C1C),
        width: 480,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppNotice(
              "This removes the closing lock and clears the earned amount, so commission is recalculated from the job's "
              'current status. Use it when the job was closed by mistake.',
              kind: AppNoticeKind.warning,
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _fact('Closed', _stamp(lock['locked_at'])),
                _fact('As', lock['locked_status']?.toString() ?? '—'),
                _fact('Earned amount cleared', _moneyText(job['commission_earned'])),
                _fact('Pay week', _day(lock['pay_week']?.toString())),
              ],
            ),
            if (weekPaid) ...[
              const SizedBox(height: 10),
              const AppNotice(
                'That pay week already has a finalized payroll run. The next payroll preview will show an adjustment for it.',
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
            if (_error != null) ...[const SizedBox(height: 10), AppNotice(_error!, kind: AppNoticeKind.error)],
          ],
        ),
        actions: [
          AppButton.ghost('Cancel', _saving ? null : () => Navigator.pop(context)),
          AppButton.ink(_saving ? 'Unlocking…' : 'Unlock job', _valid ? _submit : null, danger: true),
        ],
      ),
    );
  }

  Widget _fact(String label, String value) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(10)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: _slate, fontWeight: FontWeight.w600),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 13, color: _ink, fontWeight: FontWeight.w800),
        ),
      ],
    ),
  );
}
