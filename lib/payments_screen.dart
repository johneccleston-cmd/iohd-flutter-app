import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';

/// Every payment on file (the Service Fusion payments in job_payments), newest first. Read-only.
class PaymentsScreen extends StatefulWidget {
  const PaymentsScreen({super.key});

  @override
  State<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends State<PaymentsScreen> {
  static const _pageSize = 50;

  final TextEditingController _searchController = TextEditingController();
  final _date = DateFormat('MMM d, y');
  Timer? _debounce;
  int _requestId = 0; // guards against out-of-order responses

  List<Map<String, dynamic>> _rows = const [];
  Map<String, dynamic> _stats = const {};
  int _page = 1;
  int _totalPages = 1;
  int _total = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(1);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load(int page) async {
    final id = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final uri = Uri.parse('$kApiBaseUrl/api/payments').replace(queryParameters: {
        'q': _searchController.text.trim(),
        'page': '$page',
        'limit': '$_pageSize',
      });
      final res = await http.get(uri, headers: AuthSession.instance.headers(json: false)).timeout(const Duration(seconds: 40));
      if (!mounted || id != _requestId) return;
      if (res.statusCode == 401) {
        AuthSession.instance.logout(); // sends the app back to the sign-in screen
        return;
      }
      if (res.statusCode != 200) throw Exception('Server error (${res.statusCode})');
      final data = json.decode(res.body) as Map<String, dynamic>;
      setState(() {
        _rows = List<Map<String, dynamic>>.from(data['data'] ?? const []);
        _stats = Map<String, dynamic>.from(data['stats'] ?? const {});
        _total = (data['total'] as num?)?.toInt() ?? 0;
        _totalPages = (data['totalPages'] as num?)?.toInt() ?? 1;
        _page = page;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _loading = false;
        _error = e is TimeoutException
            ? 'The server is taking too long to respond. It may be waking up. Try again in a moment.'
            : 'Could not load payments. ${e.toString().replaceFirst('Exception: ', '')}';
      });
    }
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _load(1));
  }

  double _n(Object? v) => double.tryParse('${v ?? ''}') ?? 0;

  String _day(Object? v) {
    final d = DateTime.tryParse('${v ?? ''}');
    return d == null ? '' : _date.format(d.toUtc()); // dates are stored as UTC midnight
  }

  /// Receipt-style label for the type column: a refund or void reads differently from money received.
  (String, Color) _status(String type) {
    switch (type.toLowerCase()) {
      case 'refund':
        return ('Refund', DashUi.amber);
      case 'void':
        return ('Void', DashUi.slate);
      default:
        return ('Paid', DashUi.emeraldDeep);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasStats = _stats.isNotEmpty;
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageBanner(
            title: 'Payments',
            actions: [PageBanner.refresh(onPressed: _loading ? null : () => _load(_page))],
          ),
          SizedBox(height: 3, child: _loading ? const LinearProgressIndicator(minHeight: 3) : null),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FlatStats(
                    stats: [
                      FlatStat('Collected Today', hasStats ? dashMoney(_n(_stats['today'])) : '-'),
                      FlatStat('Collected This Month', hasStats ? dashMoney(_n(_stats['month'])) : '-'),
                      FlatStat('Payments This Month', hasStats ? '${_stats['monthCount'] ?? 0}' : '-'),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 340,
                          child: TextField(
                            controller: _searchController,
                            onChanged: _onSearchChanged,
                            style: const TextStyle(fontSize: 14),
                            decoration: flatSearchDecoration('Search customer, job # or reference...'),
                          ),
                        ),
                        const Spacer(),
                        if (!_loading || _rows.isNotEmpty)
                          Text(
                            '${NumberFormat.decimalPattern().format(_total)} ${_searchController.text.trim().isEmpty ? 'payments' : 'matching'}',
                            style: flatCellMuted,
                          ),
                      ],
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
                      child: Column(
                        children: [
                          Text(_error!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14.5, color: DashUi.slate)),
                          const SizedBox(height: 12),
                          FilledButton(onPressed: () => _load(_page), child: const Text('Try again')),
                        ],
                      ),
                    )
                  else if (!_loading && _rows.isEmpty)
                    FlatEmpty(
                      icon: Icons.payments_outlined,
                      title: _searchController.text.trim().isEmpty ? 'No payments yet' : 'No matching payments',
                      message: _searchController.text.trim().isEmpty
                          ? 'Payments show here once they are received.'
                          : 'Try a different customer name, job number or reference.',
                    )
                  else if (_rows.isNotEmpty) ...[
                    FlatTable(
                      striped: true,
                      columns: const [
                        FlatCol('Date', flex: 3),
                        FlatCol('Job #', flex: 3),
                        FlatCol('Customer', flex: 4),
                        FlatCol('Method', flex: 3),
                        FlatCol('Reference', flex: 3),
                        FlatCol('Amount', flex: 3, right: true),
                        FlatCol('Type', flex: 3),
                      ],
                      rows: [
                        for (final p in _rows)
                          [
                            Text(_day(p['received_on']), style: flatCellBold),
                            _JobLink('${p['job_id'] ?? ''}'),
                            Text(
                              '${p['customer'] ?? ''}'.isEmpty ? 'No job on file' : '${p['customer']}',
                              style: '${p['customer'] ?? ''}'.isEmpty ? flatCellMuted : flatCellBold,
                              overflow: TextOverflow.ellipsis,
                            ),
                            // Stripe payments show just the mark; everything else shows how it was paid.
                            p['via_stripe'] == true
                                ? const Align(alignment: Alignment.centerLeft, child: _StripeMark())
                                : Text('${p['payment_type'] ?? ''}', style: flatCellStyle, overflow: TextOverflow.ellipsis),
                            Text('${p['reference_number'] ?? ''}', style: flatCellMuted, overflow: TextOverflow.ellipsis),
                            Text(
                              dashMoney(_n(p['amount'])),
                              style: flatCellBold.copyWith(
                                fontFeatures: flatFigures,
                                color: _n(p['amount']) < 0 ? DashUi.amber : ('${p['transaction_type']}'.toLowerCase() == 'void' ? DashUi.slate : DashUi.ink),
                              ),
                            ),
                            Builder(builder: (_) {
                              final (label, color) = _status('${p['transaction_type'] ?? ''}');
                              return FlatStatus(label, color);
                            }),
                          ],
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                      child: Row(
                        children: [
                          const Spacer(),
                          IconButton(
                            tooltip: 'Previous page',
                            onPressed: _loading || _page <= 1 ? null : () => _load(_page - 1),
                            icon: const Icon(Icons.chevron_left),
                          ),
                          Text('Page $_page of $_totalPages', style: flatCellMuted),
                          IconButton(
                            tooltip: 'Next page',
                            onPressed: _loading || _page >= _totalPages ? null : () => _load(_page + 1),
                            icon: const Icon(Icons.chevron_right),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Stripe's mark: a purple rounded square with a white "S". Shown on payments that came through Stripe.
class _StripeMark extends StatelessWidget {
  const _StripeMark();

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Paid through Stripe',
      child: Container(
        width: 20,
        height: 20,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: const Color(0xFF635BFF), borderRadius: BorderRadius.circular(5)), // Stripe's brand purple
        child: const Text('S', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800, height: 1)),
      ),
    );
  }
}

/// The job number as a link to that job. A payment with no job on file shows nothing to click.
class _JobLink extends StatelessWidget {
  final String jobId;
  const _JobLink(this.jobId);

  static const _blue = Color(0xFF2563EB); // same link blue as the job page

  @override
  Widget build(BuildContext context) {
    if (jobId.isEmpty) return const Text('', style: flatCellMuted);
    return Tooltip(
      message: 'Open job $jobId',
      child: InkWell(
        onTap: () => context.go('/jobs/${Uri.encodeComponent(jobId)}'),
        child: Text(
          jobId,
          style: flatCellStyle.copyWith(color: _blue, decoration: TextDecoration.underline, decorationColor: const Color(0x662563EB)),
        ),
      ),
    );
  }
}
