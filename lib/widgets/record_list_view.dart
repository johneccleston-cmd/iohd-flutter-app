import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../config/api_config.dart';
import '../config/auth_session.dart';
import '../theme/app_theme.dart';
import '../utils/status_colors.dart';
import 'dashboard_kit.dart';

/// What differs between the Jobs list and the Estimates list. Everything else is shared.
class RecordListConfig {
  final String singular; // "job"
  final String plural; // "Jobs"
  final String idLabel; // "Job #"
  final String amountLabel; // "Revenue"
  final String peopleLabel; // "Techs" / "Sales owner"
  final String peopleEmpty; // shown when nobody is on the record
  final String listPath;
  final String countsPath;
  final String detailBase; // "/jobs"
  final String peopleField; // the list row's field holding the names

  const RecordListConfig({
    required this.singular,
    required this.plural,
    required this.idLabel,
    required this.amountLabel,
    required this.peopleLabel,
    required this.peopleEmpty,
    required this.listPath,
    required this.countsPath,
    required this.detailBase,
    required this.peopleField,
  });

  static const jobs = RecordListConfig(
    singular: 'job',
    plural: 'Jobs',
    idLabel: 'Job #',
    amountLabel: 'Revenue',
    peopleLabel: 'Techs',
    peopleEmpty: 'Unassigned',
    listPath: '/api/jobs',
    countsPath: '/api/jobs/status-counts',
    detailBase: '/jobs',
    peopleField: 'techs_assigned',
  );

  static const estimates = RecordListConfig(
    singular: 'estimate',
    plural: 'Estimates',
    idLabel: 'Estimate #',
    amountLabel: 'Value',
    peopleLabel: 'Sales owner',
    peopleEmpty: '—',
    listPath: '/api/estimates',
    countsPath: '/api/estimates/status-counts',
    detailBase: '/estimates',
    peopleField: 'opportunity_owner',
  );
}

/// One list screen for jobs and estimates: status filter, debounced search (also fed by the nav bar's `?q=`),
/// compact clickable rows, paging with a prefetched next page, and proper loading / empty / error states.
class RecordListView extends StatefulWidget {
  final RecordListConfig config;

  /// A search handed in by the route (the nav bar search sends `?q=`).
  final String? initialQuery;

  const RecordListView({super.key, required this.config, this.initialQuery});

  @override
  State<RecordListView> createState() => _RecordListViewState();
}

class _RecordListViewState extends State<RecordListView> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  static const _pageSizes = [25, 50, 100];
  static const _sidebarBreakpoint = 1000.0; // below this the status filter becomes a menu above the table
  static const _compactBreakpoint = 720.0; // below this each row is two lines

  final _search = TextEditingController();
  final _money = NumberFormat.currency(symbol: r'$');
  final _count = NumberFormat.decimalPattern();
  Timer? _debounce;

  String _status = 'All';
  String _query = '';
  int _page = 1;
  int _pageSize = 50;
  int _totalPages = 1;
  int _total = 0;

  List<Map<String, dynamic>> _rows = const [];
  List<Map<String, dynamic>> _counts = const [];
  int _allCount = 0;

  bool _loading = true;
  String? _error;
  int _requestId = 0;

  // Pages already fetched (and the next one, fetched ahead), so Next is instant.
  final Map<String, ({List<Map<String, dynamic>> rows, int total, int totalPages})> _cache = {};

  RecordListConfig get cfg => widget.config;

  @override
  void initState() {
    super.initState();
    final q = (widget.initialQuery ?? '').trim();
    _query = q;
    _search.text = q;
    _loadCounts();
    _load(1);
  }

  @override
  void didUpdateWidget(RecordListView old) {
    super.didUpdateWidget(old);
    // The nav bar search can be used while this screen is already open (it is kept alive): apply the new search.
    final q = (widget.initialQuery ?? '').trim();
    if (q.isNotEmpty && q != (old.initialQuery ?? '').trim() && q != _query) {
      _search.text = q;
      _applyQuery(q);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  // ---- data -----------------------------------------------------------------

  Future<http.Response> _get(String pathAndQuery) async {
    final res = await http
        .get(Uri.parse('$kApiBaseUrl$pathAndQuery'), headers: AuthSession.instance.headers(json: false))
        .timeout(const Duration(seconds: 40));
    if (res.statusCode == 401) {
      AuthSession.instance.logout(); // sends the app back to the sign-in screen
      throw Exception('Your session expired. Please sign in again.');
    }
    return res;
  }

  String _key(int page, {int? size, String? status, String? query}) => '${status ?? _status}|${query ?? _query}|${size ?? _pageSize}|$page';

  String _url(int page) => '${cfg.listPath}?status=${Uri.encodeComponent(_status)}&q=${Uri.encodeComponent(_query)}&page=$page&limit=$_pageSize';

  Future<({List<Map<String, dynamic>> rows, int total, int totalPages})> _fetchPage(int page) async {
    final res = await _get(_url(page));
    if (res.statusCode != 200) throw Exception('The server returned status ${res.statusCode}.');
    final data = json.decode(res.body) as Map<String, dynamic>;
    return (
      rows: List<Map<String, dynamic>>.from((data['data'] as List? ?? const []).whereType<Map>().map(Map<String, dynamic>.from)),
      total: (data['total'] as num?)?.toInt() ?? 0,
      totalPages: (data['totalPages'] as num?)?.toInt() ?? 1,
    );
  }

  Future<void> _load(int page) async {
    final id = ++_requestId;
    final cached = _cache[_key(page)];
    if (cached != null) {
      setState(() {
        _rows = cached.rows;
        _total = cached.total;
        _totalPages = cached.totalPages;
        _page = page;
        _loading = false;
        _error = null;
      });
      _prefetch(page + 1, cached.totalPages);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _fetchPage(page);
      if (!mounted || id != _requestId) return; // a newer request replaced this one
      _cache[_key(page)] = result;
      setState(() {
        _rows = result.rows;
        _total = result.total;
        _totalPages = result.totalPages;
        _page = page;
        _loading = false;
      });
      _prefetch(page + 1, result.totalPages);
    } on TimeoutException {
      if (!mounted || id != _requestId) return;
      setState(() {
        _loading = false;
        _error = 'The ${cfg.plural.toLowerCase()} took too long to load.';
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _prefetch(int page, int totalPages) async {
    if (page > totalPages || _cache.containsKey(_key(page))) return;
    final key = _key(page);
    try {
      final result = await _fetchPage(page);
      if (mounted) _cache[key] = result;
    } catch (_) {
      // Best effort: Next just loads normally if this didn't work.
    }
  }

  Future<void> _loadCounts() async {
    try {
      final res = await _get(cfg.countsPath);
      if (!mounted || res.statusCode != 200) return;
      final data = json.decode(res.body) as Map<String, dynamic>;
      setState(() {
        _allCount = (data['total'] as num?)?.toInt() ?? 0;
        _counts = List<Map<String, dynamic>>.from((data['counts'] as List? ?? const []).whereType<Map>().map(Map<String, dynamic>.from))
          ..sort((a, b) => ((int.tryParse('${b['count']}') ?? 0)).compareTo(int.tryParse('${a['count']}') ?? 0)); // biggest first
      });
    } catch (_) {
      // The filter just shows "All" until the counts arrive; the list itself is unaffected.
    }
  }

  void _refresh() {
    _cache.clear();
    _loadCounts();
    _load(_page);
  }

  // ---- actions --------------------------------------------------------------

  void _setStatus(String status) {
    if (status == _status) return;
    _status = status;
    _page = 1;
    _load(1);
  }

  void _applyQuery(String q) {
    _debounce?.cancel();
    q = q.trim();
    if (q == _query) return;
    _query = q;
    _page = 1;
    _load(1);
  }

  void _onSearchChanged(String text) {
    setState(() {}); // shows / hides the clear button
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _applyQuery(text));
  }

  void _clearFilters() {
    _debounce?.cancel();
    _search.clear();
    _status = 'All';
    _query = '';
    _page = 1;
    _load(1);
  }

  void _setPageSize(int size) {
    if (size == _pageSize) return;
    _pageSize = size;
    _page = 1;
    _load(1);
  }

  void _open(Map<String, dynamic> row) {
    final id = (row['job_id'] ?? row['id'] ?? '').toString();
    if (id.isEmpty) return;
    context.go('${cfg.detailBase}/${Uri.encodeComponent(id)}', extra: row);
  }

  // ---- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: AppTheme.bgColor,
      body: LayoutBuilder(
        builder: (context, c) {
          final wide = c.maxWidth >= _sidebarBreakpoint;
          final pad = c.maxWidth < 600 ? 12.0 : (c.maxWidth < 1000 ? 16.0 : 24.0);
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1600),
              child: Padding(
                padding: EdgeInsets.fromLTRB(pad, (pad * 0.8).roundToDouble(), pad, pad),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(),
                    SizedBox(height: pad * 0.7),
                    Expanded(
                      child: wide
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SizedBox(width: 248, child: _statusSidebar()),
                                SizedBox(width: pad),
                                Expanded(child: _tableCard(showMenuFilter: false)),
                              ],
                            )
                          : _tableCard(showMenuFilter: true),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _header() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                cfg.plural,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: DashUi.ink, letterSpacing: -0.4),
              ),
            ],
          ),
        ),
        IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh_rounded), onPressed: _loading ? null : _refresh),
      ],
    );
  }

  // ---- status filter --------------------------------------------------------

  Widget _statusSidebar() {
    return Container(
      decoration: DashUi.panel(),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Text(
              'Status',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: DashUi.ink),
            ),
          ),
          const Divider(height: 1, color: DashUi.line),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(8),
              children: [
                _statusRow('All', _allCount, null),
                for (final c in _counts)
                  _statusRow((c['status'] ?? 'Unknown').toString(), int.tryParse('${c['count']}') ?? 0, statusColor((c['status'] ?? '').toString())),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusRow(String name, int count, Color? dot) {
    final selected = _status == name;
    final accent = dot ?? DashUi.blue;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Semantics(
        button: true,
        selected: selected,
        label: '$name, $count',
        child: InkWell(
          onTap: () => _setStatus(name),
          borderRadius: BorderRadius.circular(10),
          hoverColor: DashUi.faint,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: selected ? accent.withValues(alpha: 0.10) : null,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: selected ? accent.withValues(alpha: 0.35) : Colors.transparent),
            ),
            child: Row(
              children: [
                if (dot != null) ...[
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 9),
                ],
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: selected ? FontWeight.w800 : FontWeight.w600, color: selected ? accent : DashUi.ink),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _count.format(count),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: selected ? accent : DashUi.slate),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The status filter as a menu, for windows too narrow for the sidebar.
  Widget _statusMenu() {
    return PopupMenuButton<String>(
      tooltip: 'Filter by status',
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(maxHeight: 420, minWidth: 240),
      onSelected: _setStatus,
      itemBuilder: (_) => [
        PopupMenuItem(value: 'All', child: Text('All  (${_count.format(_allCount)})')),
        for (final c in _counts)
          PopupMenuItem(
            value: (c['status'] ?? 'Unknown').toString(),
            child: Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(color: statusColor((c['status'] ?? '').toString()), shape: BoxShape.circle),
                ),
                const SizedBox(width: 9),
                Expanded(child: Text((c['status'] ?? 'Unknown').toString())),
                Text(_count.format(int.tryParse('${c['count']}') ?? 0), style: const TextStyle(color: DashUi.slate)),
              ],
            ),
          ),
      ],
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: DashUi.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.filter_list_rounded, size: 18, color: DashUi.slate),
            const SizedBox(width: 8),
            Text(
              _status == 'All' ? 'All statuses' : _status,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.ink),
            ),
            const Icon(Icons.arrow_drop_down_rounded, color: DashUi.slate),
          ],
        ),
      ),
    );
  }

  // ---- table ----------------------------------------------------------------

  Widget _tableCard({required bool showMenuFilter}) {
    return Container(
      decoration: DashUi.panel(),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, c) {
          final compact = c.maxWidth < _compactBreakpoint;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _toolbar(showMenuFilter),
              const Divider(height: 1, color: DashUi.line),
              if (!compact && _error == null && !(_rows.isEmpty && !_loading)) _headerRow(c.maxWidth),
              Expanded(child: _body(compact, c.maxWidth)),
              if (_error == null) _footer(compact),
            ],
          );
        },
      ),
    );
  }

  Widget _toolbar(bool showMenuFilter) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          if (showMenuFilter) ...[_statusMenu(), const SizedBox(width: 10)],
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: TextField(
                controller: _search,
                onChanged: _onSearchChanged,
                onSubmitted: (q) => _applyQuery(q),
                textInputAction: TextInputAction.search,
                style: const TextStyle(fontSize: 14, color: DashUi.ink),
                decoration: InputDecoration(
                  hintText: 'Search by customer, ${cfg.singular} number or address',
                  hintStyle: const TextStyle(color: DashUi.muted, fontSize: 13.5),
                  prefixIcon: const Icon(Icons.search_rounded, color: DashUi.slate, size: 20),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () {
                            _search.clear();
                            _applyQuery('');
                            setState(() {});
                          },
                        ),
                  filled: true,
                  fillColor: DashUi.faint,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: DashUi.line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: DashUi.line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: DashUi.blue, width: 1.5),
                  ),
                ),
              ),
            ),
          ),
          const Spacer(),
          const SizedBox(width: 10),
          const Text(
            'Rows',
            style: TextStyle(fontSize: 13, color: DashUi.slate, fontWeight: FontWeight.w500),
          ),
          const SizedBox(width: 8),
          DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: _pageSize,
              isDense: true,
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink),
              items: [for (final n in _pageSizes) DropdownMenuItem(value: n, child: Text('$n'))],
              onChanged: (v) {
                if (v != null) _setPageSize(v);
              },
            ),
          ),
        ],
      ),
    );
  }

  // Column widths shared by the header and the rows so they line up.
  static const double _gap = 16;
  static const double _idW = 96;
  static const double _dateW = 92;
  static const double _peopleW = 140;
  static const double _statusW = 156;

  bool _showPeople(double width) => width >= 880;

  Widget _headerRow(double width) {
    TextStyle s = const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: DashUi.slate, letterSpacing: 0.6);
    Widget cell(String t, {double? w, TextAlign align = TextAlign.left, int flex = 0}) {
      final text = Text(t.toUpperCase(), style: s, textAlign: align, maxLines: 1);
      return flex > 0 ? Expanded(flex: flex, child: text) : SizedBox(width: w, child: text);
    }

    return Container(
      color: DashUi.faint,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          cell(cfg.idLabel, w: _idW),
          const SizedBox(width: _gap),
          cell('Date', w: _dateW),
          const SizedBox(width: _gap),
          cell('Customer', flex: 1),
          const SizedBox(width: _gap),
          if (_showPeople(width)) ...[cell(cfg.peopleLabel, w: _peopleW), const SizedBox(width: _gap)],
          cell('Status', w: _statusW),
        ],
      ),
    );
  }

  Widget _body(bool compact, double width) {
    if (_error != null) {
      return DashErrorPanel(title: 'Could not load ${cfg.plural.toLowerCase()}', message: _error!, onRetry: () => _load(_page));
    }
    if (_loading) return _skeleton(compact);
    if (_rows.isEmpty) return _empty();
    return ListView.separated(
      itemCount: _rows.length,
      separatorBuilder: (_, _) => const Divider(height: 1, color: DashUi.line),
      itemBuilder: (_, i) => _row(_rows[i], compact, width),
    );
  }

  Widget _skeleton(bool compact) {
    Widget bar(double w, double h) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(6)),
    );
    return SkeletonPulse(
      child: ListView.separated(
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 9,
        separatorBuilder: (_, _) => const Divider(height: 1, color: DashUi.line),
        itemBuilder: (_, _) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(
            children: [
              bar(compact ? 150 : 90, 14),
              const SizedBox(width: 24),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [bar(220, 14), const SizedBox(height: 8), bar(300, 11)]),
              ),
              const SizedBox(width: 24),
              bar(110, 22),
            ],
          ),
        ),
      ),
    );
  }

  Widget _empty() {
    final filtered = _status != 'All' || _query.isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off_rounded, size: 44, color: DashUi.muted),
            const SizedBox(height: 10),
            Text(
              'No ${cfg.plural.toLowerCase()} found',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: DashUi.ink),
            ),
            const SizedBox(height: 4),
            Text(
              filtered
                  ? 'Nothing matches${_query.isNotEmpty ? ' "$_query"' : ''}${_status != 'All' ? ' in $_status' : ''}.'
                  : 'There are no ${cfg.plural.toLowerCase()} yet.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13.5, color: DashUi.slate),
            ),
            if (filtered) ...[
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: _clearFilters,
                icon: const Icon(Icons.filter_alt_off_rounded, size: 18),
                label: const Text('Clear search and filter'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(Map<String, dynamic> r, bool compact, double width) {
    final id = (r['job_id'] ?? r['id'] ?? '').toString();
    final customer = (r['customer_name'] ?? 'Unknown customer').toString();
    final address = (r['location'] ?? '').toString().trim();
    final status = (r['status'] ?? 'No status').toString();
    final people = (r[cfg.peopleField] ?? '').toString().trim();
    final amount = double.tryParse('${r['total_revenue'] ?? ''}');
    final date = _date(r['start_date']);
    final detail = address.isNotEmpty ? address : 'No address'; // just the address (no description) under the customer

    final nameAndDetail = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          customer,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: DashUi.ink),
        ),
        const SizedBox(height: 2),
        Tooltip(
          message: detail,
          waitDuration: const Duration(milliseconds: 500),
          child: Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, color: address.isEmpty ? DashUi.muted : DashUi.slate),
          ),
        ),
      ],
    );

    final amountText = Text(
      amount == null ? '—' : _money.format(amount),
      textAlign: TextAlign.right,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.successGreen, fontFeatures: [FontFeature.tabularFigures()]),
    );

    return Semantics(
      button: true,
      label: '${cfg.singular} $id, $customer, $status',
      child: InkWell(
        onTap: () => _open(r),
        hoverColor: DashUi.faint,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: compact ? 12 : 11),
          child: compact
              ? Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          nameAndDetail,
                          const SizedBox(height: 4),
                          Text(
                            '#$id${date.isEmpty ? '' : '  ·  $date'}',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: DashUi.muted),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [_pill(status), const SizedBox(height: 6), amountText],
                    ),
                  ],
                )
              : Row(
                  children: [
                    SizedBox(
                      width: _idW,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '#$id',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink),
                          ),
                          const SizedBox(height: 2),
                          amountText,
                        ],
                      ),
                    ),
                    const SizedBox(width: _gap),
                    SizedBox(
                      width: _dateW,
                      child: Text(date.isEmpty ? '—' : date, style: const TextStyle(fontSize: 13, color: DashUi.slate)),
                    ),
                    const SizedBox(width: _gap),
                    Expanded(child: nameAndDetail),
                    const SizedBox(width: _gap),
                    if (_showPeople(width)) ...[
                      SizedBox(
                        width: _peopleW,
                        child: Text(
                          people.isEmpty ? cfg.peopleEmpty : people,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: people.isEmpty ? DashUi.muted : DashUi.slate),
                        ),
                      ),
                      const SizedBox(width: _gap),
                    ],
                    SizedBox(
                      width: _statusW,
                      child: Align(alignment: Alignment.centerLeft, child: _pill(status)),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  String _date(dynamic v) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(v?.toString() ?? '');
    if (m == null) return '';
    return DateFormat('MMM d, y').format(DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!)));
  }

  /// Status as a tinted pill. The text always says the status, so colour is never the only signal.
  Widget _pill(String status) {
    final c = statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: Color.lerp(c, Colors.black, 0.4)),
            ),
          ),
        ],
      ),
    );
  }

  // ---- footer ---------------------------------------------------------------

  Widget _footer(bool compact) {
    final start = _total == 0 ? 0 : (_page - 1) * _pageSize + 1;
    final end = (_page * _pageSize) > _total ? _total : _page * _pageSize;
    final pager = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 20,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 32, height: 28),
          tooltip: 'Previous page',
          icon: const Icon(Icons.chevron_left_rounded),
          onPressed: (_page > 1 && !_loading) ? () => _load(_page - 1) : null,
        ),
        Text(
          'Page ${_count.format(_page)} of ${_count.format(_totalPages)}',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.ink),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 20,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 32, height: 28),
          tooltip: 'Next page',
          icon: const Icon(Icons.chevron_right_rounded),
          onPressed: (_page < _totalPages && !_loading) ? () => _load(_page + 1) : null,
        ),
      ],
    );
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: compact ? 4 : 2),
      decoration: const BoxDecoration(
        color: DashUi.faint,
        border: Border(top: BorderSide(color: DashUi.line)),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 4,
        spacing: 16,
        children: [
          // A Wrap, not a Row, so on a phone-width window the count drops to its own line instead of overflowing.
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 2,
            children: [
              Text(
                '${_count.format(start)}–${_count.format(end)} of ${_count.format(_total)}',
                style: const TextStyle(fontSize: 13, color: DashUi.slate, fontWeight: FontWeight.w500),
              ),
            ],
          ),
          pager,
        ],
      ),
    );
  }
}
