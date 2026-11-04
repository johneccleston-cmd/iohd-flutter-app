import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'config/access.dart';
import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'widgets/app_ribbon.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';

/// Every invoice on file, newest first. Read-only: today they are a copy of Service Fusion's invoices (synced by the
/// backend), later the app's own or QuickBooks Online's. The screen only reads /api/invoices, so that switch needs no change here.
/// Service Fusion's invoices have no job number, so the server works out each one's job from its payments, or failing
/// that an exact total or PO match (invoices.js). An invoice with no sure match shows a dash, never a guess.
class InvoicesScreen extends StatefulWidget {
  /// A search to start with (the nav bar search opens /invoices?q= with the invoice's number).
  final String? initialQuery;

  const InvoicesScreen({super.key, this.initialQuery});

  @override
  State<InvoicesScreen> createState() => _InvoicesScreenState();
}

/// A load failure whose message is already fit to show.
class _LoadError implements Exception {
  final String message;

  /// No access (403): trying again cannot help, so no Try again is offered.
  final bool forbidden;
  const _LoadError(this.message, {this.forbidden = false});
}

class _InvoicesScreenState extends State<InvoicesScreen> with SingleTickerProviderStateMixin {
  static const _filters = [('all', 'All'), ('unpaid', 'Unpaid'), ('overdue', 'Overdue'), ('paid', 'Paid')];
  static const _flex = [3, 2, 3, 4, 3, 3, 3, 3, 3]; // the columns, also what the first-load skeleton is shaped like
  static const _tableWidth = 1000.0; // two columns more than Payments: below this the rows stack

  final TextEditingController _searchController = TextEditingController();
  final _scroll = ScrollController();
  final _activity = RibbonActivity();
  late final _rowsIn = AnimationController(vsync: this, duration: const Duration(milliseconds: 460), value: 1);
  final _date = DateFormat('MMM d, y');
  final _count = NumberFormat.decimalPattern();
  Timer? _debounce;
  Timer? _slowTimer;
  int _requestId = 0; // guards against out-of-order responses

  List<Map<String, dynamic>> _rows = const [];
  Map<String, dynamic> _stats = const {};
  String _status = 'all';
  int _page = 1;
  int _wantedPage = 1; // the page last asked for: Try again and Refresh ask for it again
  int _totalPages = 1;
  int _total = 0;
  int _firstRow = 1; // the number of the first row shown, for "1–50 of 10,669"
  int _pageSize = 50;
  String _sort = 'issued';
  bool _ascending = false;
  bool _sortSupported = false; // the server lists its sorts; an older server would ignore them
  bool _jobsSupported = false; // same: an older server sends no job numbers, so there is no column to show
  bool _balanceSupported = false; // same for what is left to pay
  bool _loading = true;
  bool _slow = false; // the first load has taken long enough to say the server may be waking up
  String? _error; // nothing to show: takes the place of the table
  String? _stale; // a reload failed: said above the rows it could not replace
  bool _forbidden = false;

  // What the rows on screen were loaded for. The controls above can already say something else while a load is out.
  String? _shownView;
  String _shownQuery = '';
  String _shownStatus = 'all';

  @override
  void initState() {
    super.initState();
    _searchController.text = (widget.initialQuery ?? '').trim();
    _load(1);
  }

  @override
  void didUpdateWidget(InvoicesScreen old) {
    super.didUpdateWidget(old);
    final q = (widget.initialQuery ?? '').trim();
    if (q.isEmpty || q == (old.initialQuery ?? '').trim()) return;
    _debounce?.cancel();
    _searchController.text = q;
    _status = 'all'; // the invoice asked for may not be in the filter left on
    _load(1);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _slowTimer?.cancel();
    _searchController.dispose();
    _scroll.dispose();
    _rowsIn.dispose();
    _activity.dispose();
    super.dispose();
  }

  bool get _defaultSort => _sort == 'issued' && !_ascending;

  Future<void> _load(int page) async {
    final id = ++_requestId;
    final q = _searchController.text.trim();
    final status = _status;
    final view = '$q|$status|$_pageSize|$_sort|$_ascending';
    _wantedPage = page;
    _slowTimer?.cancel();
    if (_rows.isEmpty) {
      _slowTimer = Timer(const Duration(seconds: 8), () {
        if (mounted && _loading) setState(() => _slow = true);
      });
    } else {
      _activity.setRefreshing(true);
    }
    setState(() {
      _loading = true;
      _slow = false;
      _error = null;
      _forbidden = false;
    });
    try {
      final uri = Uri.parse('$kApiBaseUrl/api/invoices').replace(queryParameters: {
        'q': q,
        'status': status,
        if (!_defaultSort) ...{'sort': _sort, 'dir': _ascending ? 'asc' : 'desc'},
        'page': '$page',
        'limit': '$_pageSize',
      });
      final res = await http.get(uri, headers: AuthSession.instance.headers(json: false)).timeout(const Duration(seconds: 40));
      if (!mounted || id != _requestId) return;
      _slowTimer?.cancel();
      _activity.setRefreshing(false);
      if (res.statusCode == 401) {
        AuthSession.instance.logout(); // sends the app back to the sign-in screen
        return;
      }
      if (res.statusCode == 403) throw const _LoadError("Your account doesn't have access to invoices.", forbidden: true);
      if (res.statusCode != 200) throw _LoadError('Could not load invoices (server error ${res.statusCode}).');
      final data = json.decode(res.body) as Map<String, dynamic>;
      final rows = List<Map<String, dynamic>>.from(data['data'] ?? const []);
      final total = (data['total'] as num?)?.toInt() ?? 0;
      final totalPages = (data['totalPages'] as num?)?.toInt() ?? 1;
      // Past the end: the list got shorter since this page was opened. Show the last page rather than "no invoices".
      if (rows.isEmpty && total > 0 && page > totalPages) {
        unawaited(_load(totalPages));
        return;
      }
      // A reload of the same page just updates it; anything else is a new list, read from its top.
      final newList = view != _shownView || page != _page;
      setState(() {
        _rows = rows;
        _stats = Map<String, dynamic>.from(data['stats'] ?? const {});
        _total = total;
        _totalPages = totalPages;
        _firstRow = (page - 1) * _pageSize + 1;
        _sortSupported = (data['sorts'] as List?)?.isNotEmpty ?? false;
        _jobsSupported = data['jobLinks'] == true;
        _balanceSupported = (data['sorts'] as List?)?.contains('balance') ?? false;
        _page = page;
        _shownView = view;
        _shownQuery = q;
        _shownStatus = status;
        _stale = null;
        _loading = false;
      });
      if (!newList) {
        _activity.landed();
        return;
      }
      if (_scroll.hasClients) _scroll.jumpTo(0);
      if (MediaQuery.disableAnimationsOf(context)) {
        _rowsIn.value = 1;
      } else {
        _rowsIn.forward(from: 0);
      }
    } catch (e) {
      if (!mounted || id != _requestId) return;
      _slowTimer?.cancel();
      _activity.setRefreshing(false);
      // Never the raw exception: it can carry the request URL.
      final message = switch (e) {
        _LoadError(:final message) => message,
        TimeoutException() => 'The server is taking too long to respond. It may be waking up. Try again in a moment.',
        http.ClientException() => "Couldn't reach the server. Check your connection and try again.",
        _ => 'Could not load invoices. The server sent a reply the app could not read.',
      };
      final forbidden = e is _LoadError && e.forbidden;
      setState(() {
        _loading = false;
        _slow = false;
        _forbidden = forbidden;
        // The rows on screen are still the list that was asked for, so they stay. Rows from another search or filter
        // would pass for the answer to this one.
        if (view == _shownView && _rows.isNotEmpty && !forbidden) {
          _stale = message;
        } else {
          _error = message;
          _stale = null;
        }
      });
    }
  }

  void _onSearchChanged(String _) {
    setState(() {}); // the clear button comes and goes with the text
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _load(1));
  }

  void _searchNow() {
    _debounce?.cancel();
    _load(1);
  }

  void _clearSearch() {
    _searchController.clear();
    _searchNow();
  }

  void _setStatus(String status) {
    if (_status == status) return;
    setState(() => _status = status);
    _load(1);
  }

  void _setSort(String key) {
    setState(() {
      // Names read A to Z first and due dates oldest first; issue dates and money biggest first.
      _ascending = _sort == key ? !_ascending : key == 'customer' || key == 'due';
      _sort = key;
    });
    _load(1);
  }

  void _setPageSize(int size) {
    if (size == _pageSize) return;
    setState(() => _pageSize = size);
    _load(1);
  }

  bool get _narrowed => _searchController.text.trim().isNotEmpty || _status != 'all';

  double _n(Object? v) => double.tryParse('${v ?? ''}') ?? 0;

  /// Service Fusion's invoice times are Chicago days labelled UTC, so the day is the one on the label.
  String _day(Object? v) {
    final d = DateTime.tryParse('${v ?? ''}');
    return d == null ? '' : _date.format(d.toUtc());
  }

  Widget _dayCell(Object? v, TextStyle style) {
    final day = _day(v);
    return day.isEmpty ? const Text('—', style: flatCellMuted) : Text(day, style: style, maxLines: 1, softWrap: false);
  }

  /// Text tones, so they stay readable on the striped rows.
  (String, Color) _statusOf(Map<String, dynamic> i) {
    if (i['is_paid'] == true) return ('Paid', DashUi.emeraldText);
    if (i['written_off'] == true) return ('Written off', DashUi.slate);
    if (i['overdue'] == true) return ('Overdue', DashUi.redText);
    return ('Unpaid', DashUi.amberText);
  }

  Widget _statusCell(Map<String, dynamic> i) {
    final (label, color) = _statusOf(i);
    if (i['is_paid'] != true && i['written_off'] == true) {
      return Tooltip(
        message: 'This job is written off, so its invoice is not counted as awaiting payment or overdue.',
        child: FlatStatus(label, color),
      );
    }
    return FlatStatus(label, color);
  }

  Widget _numberCell(Map<String, dynamic> i) {
    final number = '${i['number'] ?? ''}';
    return number.isEmpty ? const Text('—', style: flatCellMuted) : Text(number, style: flatCellBold, maxLines: 1, overflow: TextOverflow.ellipsis);
  }

  /// The invoice's job. The tooltip says when it was matched rather than recorded, so a wrong one can be spotted. A job
  /// not in the app shows the number as plain text (there is no job page to open).
  Widget _jobCell(Map<String, dynamic> i) {
    final job = '${i['job_id'] ?? ''}';
    if (job.isEmpty) {
      return const Tooltip(
        message: 'No payment, total or PO number ties this invoice to one job.',
        child: Text('—', style: flatCellMuted),
      );
    }
    if (i['job_on_file'] == false) {
      return Tooltip(message: 'Job $job is not in the app, so there is no job page to open.', child: Text(job, style: flatCellMuted));
    }
    final how = switch (i['job_link']) {
      'amount' => " Matched on the customer and the invoice's total, not recorded in Service Fusion.",
      'po' => ' Matched on the customer and PO number, not recorded in Service Fusion.',
      _ => '',
    };
    return FlatLink(job, tip: 'Open job $job.$how', onTap: () => context.go('/jobs/${Uri.encodeComponent(job)}'));
  }

  Widget _customerCell(Map<String, dynamic> i) {
    final name = '${i['customer'] ?? ''}';
    if (name.isEmpty) return const Text('No customer on file', style: flatCellMuted, maxLines: 1, overflow: TextOverflow.ellipsis);
    return FlatLink(name, tip: 'Open $name', onTap: () => context.go('/customers?q=${Uri.encodeQueryComponent(name)}'));
  }

  Widget _poCell(Map<String, dynamic> i) {
    final po = '${i['po_number'] ?? ''}'.trim();
    if (po.isEmpty || po == 'null') return const Text('—', style: flatCellMuted);
    return Tooltip(
      message: po,
      waitDuration: const Duration(milliseconds: 400),
      child: Text(po, style: flatCellMuted, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }

  /// The amount, on one line: a very large one shrinks a little in a narrow window rather than wrap.
  Widget _amountCell(Map<String, dynamic> i) {
    final total = _n(i['total']);
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerRight,
      child: Text(
        dashMoney(total),
        maxLines: 1,
        softWrap: false,
        style: flatCellBold.copyWith(fontFeatures: flatFigures, color: total < 0 ? DashUi.redText : DashUi.ink),
      ),
    );
  }

  /// What is still owed: the invoice's total less what has been paid. These add up to the figures above, apart from a
  /// written-off job's, which is shown quietly because nobody is collecting it.
  Widget _balanceCell(Map<String, dynamic> i) {
    final balance = _n(i['balance']);
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerRight,
      child: Text(
        dashMoney(balance),
        maxLines: 1,
        softWrap: false,
        style: (balance > 0 && i['written_off'] != true ? flatCellBold : flatCellMuted).copyWith(fontFeatures: flatFigures),
      ),
    );
  }

  List<FlatCol> get _columns => [
    FlatCol('Issued', flex: _flex[0], sortKey: 'issued'),
    FlatCol('Invoice', flex: _flex[1]),
    if (_jobsSupported) FlatCol('Job #', flex: _flex[2]),
    FlatCol('Customer', flex: _flex[3], sortKey: 'customer'),
    FlatCol('PO #', flex: _flex[4]),
    FlatCol('Due', flex: _flex[5], sortKey: 'due'),
    FlatCol('Amount', flex: _flex[6], right: true, sortKey: 'amount'),
    if (_balanceSupported) FlatCol('Balance', flex: _flex[7], right: true, sortKey: 'balance'),
    FlatCol('Status', flex: _flex[8]),
  ];

  List<Widget> _cells(Map<String, dynamic> i) => [
    _dayCell(i['invoice_date'], flatCellStyle),
    _numberCell(i),
    if (_jobsSupported) _jobCell(i),
    _customerCell(i),
    _poCell(i),
    _dayCell(i['due_date'], flatCellMuted),
    _amountCell(i),
    if (_balanceSupported) _balanceCell(i),
    // Shrinks a little in a narrow window rather than overflow the column.
    FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: _statusCell(i)),
  ];

  /// A row too narrow for the columns: who and how much first, then the rest under it, so nothing hides off to the side.
  Widget _compactRow(Map<String, dynamic> i, int index) {
    final due = _day(i['due_date']);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: BoxDecoration(
        color: index.isOdd ? DashUi.faint : null,
        border: const Border(top: BorderSide(color: DashUi.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(flex: 3, child: Align(alignment: Alignment.centerLeft, child: _customerCell(i))),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: _amountCell(i))),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(child: Wrap(spacing: 12, children: [_numberCell(i), _dayCell(i['invoice_date'], flatCellStyle)])),
              const SizedBox(width: 12),
              _statusCell(i),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 16,
            children: [
              if (_jobsSupported && '${i['job_id'] ?? ''}'.isNotEmpty) _jobCell(i),
              if ('${i['po_number'] ?? ''}'.trim().isNotEmpty) ConstrainedBox(constraints: const BoxConstraints(maxWidth: 140), child: _poCell(i)),
              if (due.isNotEmpty) Text('Due $due', style: flatCellMuted),
              if (_balanceSupported && _n(i['balance']) != _n(i['total'])) Text('Balance ${dashMoney(_n(i['balance']))}', style: flatCellBold),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statStrip(bool compact) {
    if (_stats.isEmpty) {
      return const FlatStats(
        stats: [FlatStat('Awaiting payment', '—'), FlatStat('Overdue', '—'), FlatStat('Invoiced (30 days)', '—')],
      );
    }
    final awaitingCount = (_stats['awaitingCount'] as num?)?.toInt() ?? 0;
    final overdueCount = (_stats['overdueCount'] as num?)?.toInt() ?? 0;
    return FlatStats(
      stats: [
        // Shorter on a phone, where the longer label would cut off its count.
        FlatStat.counted('${compact ? 'Awaiting' : 'Awaiting payment'} (${_count.format(awaitingCount)})', _n(_stats['awaiting']), dashMoney),
        FlatStat.counted('Overdue (${_count.format(overdueCount)})', _n(_stats['overdue']), dashMoney, tone: overdueCount > 0 ? DashUi.red : null),
        FlatStat.counted('Invoiced (30 days)', _n(_stats['invoiced30d']), dashMoney),
      ],
    );
  }

  String get _countLabel {
    if (_narrowed) return '${_count.format(_total)} matching';
    return _total == 1 ? '1 invoice' : '${_count.format(_total)} invoices';
  }

  Widget _toolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
      child: Wrap(
        spacing: 16,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              onSubmitted: (_) => _searchNow(),
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 14),
              decoration: flatSearchDecoration(
                _jobsSupported ? 'Search customer, invoice #, job # or PO...' : 'Search customer, invoice # or PO...',
                onClear: _searchController.text.isEmpty ? null : _clearSearch,
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (value, label) in _filters) FlatFilterChip(label: label, selected: _status == value, onSelected: () => _setStatus(value)),
            ],
          ),
          // No count without rows: a failed load has nothing to count, and an empty list says so itself.
          if (_error == null && _rows.isNotEmpty) Semantics(liveRegion: true, child: Text(_countLabel, style: flatCellMuted)),
        ],
      ),
    );
  }

  Widget _errorState() {
    return FlatEmpty(
      icon: _forbidden ? Icons.lock_outline_rounded : Icons.cloud_off_rounded,
      title: _forbidden ? 'No access to invoices' : "Invoices didn't load",
      message: _error!,
      action: _forbidden
          ? null
          : FilledButton.icon(
              onPressed: _loading ? null : () => _load(_wantedPage),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Try again'),
            ),
    );
  }

  Widget _emptyState() {
    if (_shownQuery.isNotEmpty) {
      return FlatEmpty(
        icon: Icons.search_off_rounded,
        title: 'No matching invoices',
        message: 'Nothing matches "$_shownQuery". Try a different customer name, invoice number, job number or PO.',
        action: OutlinedButton(onPressed: _clearSearch, child: const Text('Clear search')),
      );
    }
    if (_shownStatus != 'all') {
      return FlatEmpty(
        icon: Icons.receipt_long_outlined,
        title: 'No $_shownStatus invoices',
        message: 'There are no invoices with this status right now.',
        action: OutlinedButton(onPressed: () => _setStatus('all'), child: const Text('Show all invoices')),
      );
    }
    return const FlatEmpty(
      icon: Icons.receipt_long_outlined,
      title: 'No invoices yet',
      message: 'Invoices show here once they sync. The first sync can take a few minutes.',
    );
  }

  /// What sits under the toolbar, as slivers so the table's header can stay pinned while the rows scroll under it.
  List<Widget> _content(bool compact) {
    if (_error != null) return [SliverToBoxAdapter(child: _errorState())];
    if (_rows.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: _loading ? FlatLoading(label: 'Loading invoices', flex: _flex, compact: compact, slow: _slow) : _emptyState(),
        ),
      ];
    }
    final columns = _columns;
    return [
      if (!compact)
        PinnedHeaderSliver(
          child: FlatTableHeader(
            columns: columns,
            striped: true,
            sortKey: _sort,
            ascending: _ascending,
            onSort: _sortSupported ? _setSort : null,
          ),
        ),
      // Rows being replaced fade back a little, so a slow search does not look finished.
      SliverAnimatedOpacity(
        opacity: _loading ? 0.55 : 1,
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 160),
        sliver: SliverList.builder(
          itemCount: _rows.length,
          itemBuilder: (_, i) => flatRowEntrance(
            _rowsIn,
            i,
            compact ? _compactRow(_rows[i], i) : FlatTableRow(columns: columns, cells: _cells(_rows[i]), index: i, striped: true),
          ),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: LayoutBuilder(
        builder: (context, c) {
          // Larger text needs the room too, so the columns give way sooner.
          final compact = c.maxWidth < MediaQuery.textScalerOf(context).scale(_tableWidth);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PageBanner(
                title: 'Invoices',
                icon: accessIcon('invoices'),
                activity: _activity,
                actions: [PageBanner.refresh(onPressed: _loading ? null : () => _load(_wantedPage))],
              ),
              Expanded(
                child: CustomScrollView(
                  controller: _scroll,
                  slivers: [
                    SliverToBoxAdapter(child: _statStrip(compact)),
                    SliverToBoxAdapter(child: _toolbar()),
                    if (_stale != null)
                      SliverToBoxAdapter(
                        child: FlatStaleNotice(
                          message: '$_stale Showing the last loaded invoices.',
                          busy: _loading,
                          onRetry: () => _load(_wantedPage),
                        ),
                      ),
                    ..._content(compact),
                  ],
                ),
              ),
              if (_error == null && _rows.isNotEmpty)
                FlatPager(
                  page: _page,
                  totalPages: _totalPages,
                  total: _total,
                  firstRow: _firstRow,
                  rowsShown: _rows.length,
                  pageSize: _pageSize,
                  busy: _loading,
                  compact: compact,
                  onPage: _load,
                  onPageSize: _setPageSize,
                ),
            ],
          );
        },
      ),
    );
  }
}
