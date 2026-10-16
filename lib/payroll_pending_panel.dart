import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'widgets/status_pill.dart';

import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'widgets/dashboard_kit.dart';

final NumberFormat _money = NumberFormat.currency(symbol: '\$', decimalDigits: 2);

double _n(dynamic v) => v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);

class _PendingJob {
  final String jobId;
  final String customer;
  final String status;
  final double splitPct;
  final double share;
  final double retainage;
  final double net;
  final int unverifiedDays;

  _PendingJob(Map<String, dynamic> j)
    : jobId = '${j['jobId'] ?? ''}',
      customer = '${j['customer'] ?? ''}',
      status = '${j['status'] ?? ''}',
      splitPct = _n(j['splitPct']),
      share = _n(j['share']),
      retainage = _n(j['retainage']),
      net = _n(j['net']),
      unverifiedDays = _n(j['unverifiedDays']).round();
}

class _PendingTech {
  final String name;
  final String role;
  final String imageUrl;
  final double share;
  final double retainage;
  final double net;
  final List<_PendingJob> jobs;

  _PendingTech(Map<String, dynamic> t)
    : name = '${t['name'] ?? ''}',
      role = '${t['role'] ?? ''}',
      imageUrl = '${t['imageUrl'] ?? ''}',
      share = _n((t['totals'] as Map?)?['share']),
      retainage = _n((t['totals'] as Map?)?['retainage']),
      net = _n((t['totals'] as Map?)?['net']),
      jobs = [for (final j in (t['jobs'] as List? ?? const [])) _PendingJob(Map<String, dynamic>.from(j as Map))];
}

/// Commission projected on jobs that aren't closed yet, per technician. It's the job's net pool split by
/// verified visit weight, exactly how the payroll engine will split it when the job closes. Nothing here
/// is earned until the job closes.
class PayrollPendingPanel extends StatefulWidget {
  /// Changing this reloads the panel (if it has been opened), e.g. after a payroll run is finalized or voided.
  final int refreshToken;

  /// True when shown as the Pending tab's whole page: no collapse bar, loads straight away.
  final bool asPage;

  const PayrollPendingPanel({super.key, this.refreshToken = 0, this.asPage = false});

  @override
  State<PayrollPendingPanel> createState() => _PayrollPendingPanelState();
}

class _PayrollPendingPanelState extends State<PayrollPendingPanel> {
  List<_PendingTech> _techs = const [];
  double _total = 0;
  double _retainage = 0;
  int _jobCount = 0;
  bool _loading = false;
  bool _loaded = false; // the panel starts collapsed, so it only fetches once opened or refreshed
  String? _error;
  bool _open = false;
  final Set<String> _expanded = {};
  int _req = 0;

  @override
  void initState() {
    super.initState();
    if (widget.asPage) {
      _open = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
  }

  @override
  void didUpdateWidget(PayrollPendingPanel old) {
    super.didUpdateWidget(old);
    if (old.refreshToken != widget.refreshToken && _loaded) _load(fresh: true);
  }

  /// [fresh] skips the server's response cache (Refresh, or after a payroll run).
  Future<void> _load({bool fresh = false}) async {
    final id = ++_req;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await http
          .get(
            Uri.parse('$kApiBaseUrl/api/payroll/pending${fresh ? '?fresh=1' : ''}'),
            headers: AuthSession.instance.headers(),
          )
          .timeout(const Duration(seconds: 60));
      if (!mounted || id != _req) return;
      if (res.statusCode == 401) {
        AuthSession.instance.logout();
        return;
      }
      final body = jsonDecode(res.body);
      if (res.statusCode != 200 || body is! Map || body['success'] != true) {
        throw Exception(body is Map && body['error'] != null ? body['error'] : 'Server returned ${res.statusCode}');
      }
      final totals = Map<String, dynamic>.from(body['totals'] as Map);
      setState(() {
        _techs = [
          for (final t in (body['techs'] as List? ?? const [])) _PendingTech(Map<String, dynamic>.from(t as Map)),
        ];
        _total = _n(totals['net']);
        _retainage = _n(totals['retainage']);
        _jobCount = _n((body['counts'] as Map?)?['jobs']).round();
        _loading = false;
        _loaded = true;
      });
    } on TimeoutException {
      if (!mounted || id != _req) return;
      setState(() {
        _error = 'The server took too long to answer.';
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _req) return;
      // Server messages come through as Exception(text); anything else (bad JSON, a cast) is not fit to show.
      final detail = e is Exception && e is! FormatException ? ' ${e.toString().replaceFirst('Exception: ', '')}' : '';
      setState(() {
        _error = 'Couldn\'t load pending commission.$detail';
        _loading = false;
      });
    }
  }

  /// The list of techs (or the loading, error and empty states), without any frame around it.
  Widget _content() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_loading && _techs.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
        )
      else if (_error != null && _techs.isEmpty)
        _message(
          Icons.cloud_off_rounded,
          _error!,
          action: TextButton(onPressed: _load, child: const Text('Try again')),
        )
      else if (_techs.isEmpty)
        _message(
          Icons.hourglass_empty_rounded,
          'Nothing pending right now. Pending commission shows up once a tech marks a visit complete on a job that isn\'t closed yet.',
        )
      else ...[
        if (_error != null)
          Container(
            color: DashUi.red.withValues(alpha: 0.08),
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
            child: Row(
              children: [
                const Icon(Icons.error_outline_rounded, size: 16, color: DashUi.red),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$_error These numbers may be out of date.',
                    style: const TextStyle(fontSize: 12.5, color: DashUi.red, fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton(onPressed: _loading ? null : _load, child: const Text('Try again')),
              ],
            ),
          ),
        for (var i = 0; i < _techs.length; i++) _techRow(_techs[i], i == 0),
        _footnote(),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) {
    if (widget.asPage) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          const Divider(height: 1, color: DashUi.line),
          _content(),
        ],
      );
    }
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: DashUi.line)),
        boxShadow: [BoxShadow(color: Color(0x14000000), blurRadius: 10, offset: Offset(0, -2))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          if (_open) ...[
            const Divider(height: 1, color: DashUi.line),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 340),
              child: SingleChildScrollView(child: _content()),
            ),
          ],
        ],
      ),
    );
  }

  Widget _header() {
    final summary = _techs.isEmpty
        ? 'Projected on jobs that aren\'t closed yet'
        : '${_techs.length} ${_techs.length == 1 ? 'tech' : 'techs'} on $_jobCount ${_jobCount == 1 ? 'job' : 'jobs'}, not earned until each job closes';
    return InkWell(
      onTap: widget.asPage
          ? null
          : () {
              setState(() => _open = !_open);
              if (_open && !_loaded && !_loading) _load();
            },
      child: Padding(
        padding: EdgeInsets.fromLTRB(widget.asPage ? 0 : 24, widget.asPage ? 8 : 4, 14, widget.asPage ? 8 : 4),
        child: Row(
          children: [
            const Icon(Icons.hourglass_top_rounded, size: 15, color: DashUi.amber),
            const SizedBox(width: 8),
            const Text(
              'Pending commission',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.ink),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: DashUi.muted, fontWeight: FontWeight.w500),
              ),
            ),
            if (_loaded && !_loading && _error == null)
              Text(
                _money.format(_total),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: DashUi.ink,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _loading ? null : () => _load(fresh: true),
              visualDensity: VisualDensity.compact,
              iconSize: 17,
              icon: _loading
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh_rounded, color: DashUi.slate),
            ),
            // The docked bar opens upward; as the Pending tab's page there is nothing to open.
            if (!widget.asPage)
              Icon(_open ? Icons.expand_more_rounded : Icons.expand_less_rounded, size: 20, color: DashUi.slate),
          ],
        ),
      ),
    );
  }

  Widget _message(IconData icon, String text, {Widget? action}) {
    return Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        children: [
          Icon(icon, size: 26, color: DashUi.muted),
          const SizedBox(height: 8),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13.5, color: DashUi.slate, height: 1.4),
          ),
          ?action,
        ],
      ),
    );
  }

  Widget _techRow(_PendingTech t, bool first) {
    final open = _expanded.contains(t.name);
    return Container(
      decoration: BoxDecoration(
        border: first ? null : const Border(top: BorderSide(color: DashUi.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => open ? _expanded.remove(t.name) : _expanded.add(t.name)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
              child: Row(
                children: [
                  DashAvatar(name: t.name, imageUrl: t.imageUrl, size: 30),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.name,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: DashUi.ink),
                        ),
                        Text(
                          '${t.jobs.length} ${t.jobs.length == 1 ? 'job' : 'jobs'}${t.role.isEmpty ? '' : ' · ${t.role}'}',
                          style: const TextStyle(fontSize: 12, color: DashUi.muted),
                        ),
                      ],
                    ),
                  ),
                  if (t.retainage > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: Text(
                        '${_money.format(t.retainage)} retainage held',
                        style: const TextStyle(fontSize: 12, color: DashUi.muted, fontWeight: FontWeight.w600),
                      ),
                    ),
                  Text(
                    _money.format(t.net),
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                      color: DashUi.ink,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20, color: DashUi.muted),
                ],
              ),
            ),
          ),
          if (open)
            Container(
              color: DashUi.faint,
              padding: const EdgeInsets.fromLTRB(56, 4, 16, 8),
              child: Column(children: [for (final j in t.jobs) _jobRow(j)]),
            ),
        ],
      ),
    );
  }

  Widget _jobRow(_PendingJob j) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  j.customer.isEmpty ? 'Job ${j.jobId}' : j.customer,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.ink),
                ),
                Text('#${j.jobId}', style: const TextStyle(fontSize: 12, color: DashUi.muted)),
                if (j.status.isNotEmpty) StatusPill(j.status, fontSize: 11.5),
                if (j.unverifiedDays > 0)
                  Text(
                    '${j.unverifiedDays} more ${j.unverifiedDays == 1 ? 'visit' : 'visits'} not verified',
                    style: const TextStyle(fontSize: 12, color: DashUi.amber, fontWeight: FontWeight.w600),
                  ),
              ],
            ),
          ),
          Text(
            '${j.splitPct.toStringAsFixed(j.splitPct == j.splitPct.roundToDouble() ? 0 : 1)}% of job',
            style: const TextStyle(fontSize: 12, color: DashUi.muted),
          ),
          const SizedBox(width: 14),
          SizedBox(
            width: 84,
            child: Text(
              _money.format(j.net),
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: DashUi.ink,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _footnote() {
    return Container(
      color: DashUi.faint,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Text(
        'Each job\'s net pool (1% company pool already out) split by verified visits, the same way payroll splits it when the job closes. '
        'It moves as more visits are verified. The \$200 advances on multi-week jobs are repaid from this share and are not netted here.'
        '${_retainage > 0 ? ' Commercial retainage is already taken out of the amounts above.' : ''}',
        style: const TextStyle(fontSize: 11.5, color: DashUi.muted, height: 1.4),
      ),
    );
  }
}
