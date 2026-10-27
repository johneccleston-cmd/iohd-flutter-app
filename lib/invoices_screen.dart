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

/// Every invoice on file, newest first. Read-only: today they are a copy of Service Fusion's invoices (synced by the
/// backend), later the app's own or QuickBooks Online's. The screen only reads /api/invoices, so that switch needs no change here.
class InvoicesScreen extends StatefulWidget {
  const InvoicesScreen({super.key});

  @override
  State<InvoicesScreen> createState() => _InvoicesScreenState();
}

class _InvoicesScreenState extends State<InvoicesScreen> {
  static const _pageSize = 50;
  static const _filters = [('all', 'All'), ('unpaid', 'Unpaid'), ('overdue', 'Overdue'), ('paid', 'Paid')];

  final TextEditingController _searchController = TextEditingController();
  final _date = DateFormat('MMM d, y');
  Timer? _debounce;
  int _requestId = 0; // guards against out-of-order responses

  List<Map<String, dynamic>> _rows = const [];
  Map<String, dynamic> _stats = const {};
  String _status = 'all';
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
      final uri = Uri.parse('$kApiBaseUrl/api/invoices').replace(queryParameters: {
        'q': _searchController.text.trim(),
        'status': _status,
        'page': '$page',
        'limit': '$_pageSize',
      });
      final res = await http.get(uri, headers: AuthSession.instance.headers(json: false)).timeout(const Duration(seconds: 40));
      if (!mounted || id != _requestId) return;
      if (res.statusCode == 401) {
        AuthSession.instance.logout(); // sends the app back to the sign-in screen
        return;
      }
      if (res.statusCode == 403) throw Exception('You do not have access to invoices.');
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
            : 'Could not load invoices. ${e.toString().replaceFirst('Exception: ', '')}';
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
    return d == null ? '' : _date.format(d.toLocal());
  }

  (String, Color) _statusOf(Map<String, dynamic> i) {
    if (i['is_paid'] == true) return ('Paid', DashUi.emeraldDeep);
    if (i['overdue'] == true) return ('Overdue', DashUi.red);
    return ('Unpaid', DashUi.amber);
  }

  static const _linkBlue = Color(0xFF2563EB); // same link blue as the Payments screen and job page

  Widget _customerCell(String name) {
    if (name.isEmpty) return Text('No customer on file', style: flatCellMuted, overflow: TextOverflow.ellipsis);
    return Align(
      alignment: Alignment.centerLeft,
      child: Tooltip(
        message: 'Open $name',
        child: InkWell(
          onTap: () => context.go('/customers?q=${Uri.encodeQueryComponent(name)}'),
          child: Text(
            name,
            style: flatCellStyle.copyWith(color: _linkBlue, decoration: TextDecoration.underline, decorationColor: const Color(0x662563EB)),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  bool get _searching => _searchController.text.trim().isNotEmpty || _status != 'all';

  @override
  Widget build(BuildContext context) {
    final hasStats = _stats.isNotEmpty;
    final awaitingCount = (_stats['awaitingCount'] as num?)?.toInt() ?? 0;
    final overdueCount = (_stats['overdueCount'] as num?)?.toInt() ?? 0;
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageBanner(
            title: 'Invoices',
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
                      FlatStat('Awaiting Payment${hasStats ? ' ($awaitingCount)' : ''}', hasStats ? dashMoney(_n(_stats['awaiting'])) : '-'),
                      FlatStat('Overdue${hasStats ? ' ($overdueCount)' : ''}', hasStats ? dashMoney(_n(_stats['overdue'])) : '-',
                          tone: hasStats && overdueCount > 0 ? DashUi.red : null),
                      FlatStat('Invoiced (30 days)', hasStats ? dashMoney(_n(_stats['invoiced30d'])) : '-'),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                    child: Wrap(
                      spacing: 16,
                      runSpacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: 340,
                          child: TextField(
                            controller: _searchController,
                            onChanged: _onSearchChanged,
                            style: const TextStyle(fontSize: 14),
                            decoration: flatSearchDecoration('Search customer, invoice # or PO...'),
                          ),
                        ),
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final (value, label) in _filters)
                              ChoiceChip(
                                label: Text(label),
                                selected: _status == value,
                                onSelected: (_) {
                                  if (_status == value) return;
                                  setState(() => _status = value);
                                  _load(1);
                                },
                              ),
                          ],
                        ),
                        if (!_loading || _rows.isNotEmpty)
                          Text('${NumberFormat.decimalPattern().format(_total)} ${_searching ? 'matching' : 'invoices'}', style: flatCellMuted),
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
                      icon: Icons.receipt_long_outlined,
                      title: _searching ? 'No matching invoices' : 'No invoices yet',
                      message: _searching
                          ? 'Try a different customer name, invoice number or filter.'
                          : 'Invoices show here once they sync. The first sync can take a few minutes.',
                    )
                  else if (_rows.isNotEmpty) ...[
                    FlatTable(
                      striped: true,
                      columns: const [
                        FlatCol('Issued', flex: 3),
                        FlatCol('Invoice', flex: 2),
                        FlatCol('Customer', flex: 5),
                        FlatCol('PO #', flex: 2),
                        FlatCol('Due', flex: 3),
                        FlatCol('Amount', flex: 3, right: true),
                        FlatCol('Status', flex: 3),
                      ],
                      rows: [
                        for (final i in _rows)
                          [
                            Text(_day(i['invoice_date']), style: flatCellStyle),
                            Text('${i['number'] ?? ''}', style: flatCellBold),
                            _customerCell('${i['customer'] ?? ''}'),
                            Text('${i['po_number'] ?? ''}', style: flatCellMuted, overflow: TextOverflow.ellipsis),
                            Text(_day(i['due_date']), style: flatCellMuted),
                            Text(dashMoney(_n(i['total'])), style: flatCellStyle.copyWith(fontFeatures: flatFigures)),
                            Builder(builder: (_) {
                              final (label, color) = _statusOf(i);
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
