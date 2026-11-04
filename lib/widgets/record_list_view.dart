import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../config/access.dart';
import '../config/api_config.dart';
import '../config/auth_session.dart';
import '../utils/status_colors.dart';
import 'app_ribbon.dart';
import 'dashboard_kit.dart';
import 'flat_page.dart';

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
  final String accessKey; // its menu entry (for the ribbon's icon)

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
    required this.accessKey,
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
    accessKey: 'jobs',
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
    accessKey: 'estimates',
  );
}

/// A load failure whose message is already fit to show.
class _LoadError implements Exception {
  final String message;

  /// No access (403): trying again cannot help, so no Try again is offered.
  final bool forbidden;
  const _LoadError(this.message, {this.forbidden = false});
}

/// A 401: the app is already on its way to the sign-in screen, so there is nothing to show here.
class _SignedOut implements Exception {
  const _SignedOut();
}

typedef _Page = ({List<Map<String, dynamic>> rows, int total, int totalPages, bool sortable, DateTime at});

/// One list screen for jobs and estimates: status filter, debounced search (also fed by the nav bar's `?q=`), sortable
/// columns under a pinned header, a pinned pager with a prefetched next page, stacked rows in a narrow window, and proper
/// loading / empty / error states.
class RecordListView extends StatefulWidget {
  final RecordListConfig config;

  /// A search handed in by the route (the nav bar search sends `?q=`).
  final String? initialQuery;

  const RecordListView({super.key, required this.config, this.initialQuery});

  @override
  State<RecordListView> createState() => _RecordListViewState();
}

class _RecordListViewState extends State<RecordListView> with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  @override
  bool get wantKeepAlive => true;

  static const _flex = [3, 3, 7, 4, 4, 5]; // the columns, also what the first-load skeleton is shaped like
  static const _tableWidth = 900.0; // below this the rows stack
  static const _sidebarWidth = 248.0; // only beside a table with room for its columns, otherwise a menu above it
  static const _cacheFor = Duration(minutes: 2); // Service Fusion syncs every minute, so a page does not stay right for long

  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _activity = RibbonActivity();
  late final _rowsIn = AnimationController(vsync: this, duration: const Duration(milliseconds: 460), value: 1);
  final _count = NumberFormat.decimalPattern();
  Timer? _debounce;
  Timer? _slowTimer;

  String _status = 'All';
  String _query = '';
  int _page = 1;
  int _wantedPage = 1; // the page last asked for: Try again and Refresh ask for it again
  int _pageSize = 50;
  int _totalPages = 1;
  int _total = 0;
  int _firstRow = 1; // the number of the first row shown, for "1–50 of 11,763"
  String _sort = 'date';
  bool _ascending = false;
  bool _sortSupported = false; // the server lists its sorts; an older server would ignore them

  List<Map<String, dynamic>> _rows = const [];
  List<Map<String, dynamic>> _counts = const [];
  int? _allCount; // null until the counts arrive: a dash, not a "0" that reads as an empty list

  bool _loading = true;
  bool _slow = false; // the first load has taken long enough to say the server may be waking up
  String? _error; // nothing to show: takes the place of the table
  String? _stale; // a reload failed: said above the rows it could not replace
  bool _forbidden = false;
  int _requestId = 0;

  // What the rows on screen were loaded for. The controls above can already say something else while a load is out.
  String? _shownView;
  String _shownQuery = '';
  String _shownStatus = 'All';

  // Pages already fetched (and the next one, fetched ahead), so Next is instant.
  final Map<String, _Page> _cache = {};

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
      _status = 'All'; // the record asked for may not be in the filter left on
      _applyQuery(q);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _slowTimer?.cancel();
    _search.dispose();
    _scroll.dispose();
    _rowsIn.dispose();
    _activity.dispose();
    super.dispose();
  }

  // ---- data -----------------------------------------------------------------

  Future<http.Response> _get(Uri uri) async {
    final res = await http.get(uri, headers: AuthSession.instance.headers(json: false)).timeout(const Duration(seconds: 40));
    if (res.statusCode == 401) {
      AuthSession.instance.logout(); // sends the app back to the sign-in screen
      throw const _SignedOut();
    }
    return res;
  }

  bool get _defaultSort => _sort == 'date' && !_ascending;

  String get _view => '$_status|$_query|$_pageSize|$_sort|$_ascending';

  Uri _uri(int page) => Uri.parse('$kApiBaseUrl${cfg.listPath}').replace(queryParameters: {
    'status': _status,
    'q': _query,
    if (!_defaultSort) ...{'sort': _sort, 'dir': _ascending ? 'asc' : 'desc'},
    'page': '$page',
    'limit': '$_pageSize',
  });

  Future<_Page> _fetchPage(int page) async {
    final name = cfg.plural.toLowerCase();
    final res = await _get(_uri(page));
    if (res.statusCode == 403) throw _LoadError("Your account doesn't have access to $name.", forbidden: true);
    if (res.statusCode != 200) throw _LoadError('Could not load $name (server error ${res.statusCode}).');
    final data = json.decode(res.body) as Map<String, dynamic>;
    return (
      rows: List<Map<String, dynamic>>.from((data['data'] as List? ?? const []).whereType<Map>().map(Map<String, dynamic>.from)),
      total: (data['total'] as num?)?.toInt() ?? 0,
      totalPages: (data['totalPages'] as num?)?.toInt() ?? 1,
      sortable: (data['sorts'] as List?)?.isNotEmpty ?? false,
      at: DateTime.now(),
    );
  }

  _Page? _cached(String key) {
    final page = _cache[key];
    return page != null && DateTime.now().difference(page.at) < _cacheFor ? page : null;
  }

  void _show(_Page result, int page, String view, String status, String query) {
    // A reload of the same page just updates it; anything else is a new list, read from its top.
    final newList = view != _shownView || page != _page;
    _activity.setRefreshing(false);
    setState(() {
      _rows = result.rows;
      _total = result.total;
      _totalPages = result.totalPages;
      _firstRow = (page - 1) * _pageSize + 1;
      _sortSupported = result.sortable;
      _page = page;
      _shownView = view;
      _shownStatus = status;
      _shownQuery = query;
      _loading = false;
      _slow = false;
      _error = null;
      _stale = null;
      _forbidden = false;
    });
    _prefetch(page + 1, result.totalPages);
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
  }

  Future<void> _load(int page) async {
    final id = ++_requestId;
    final view = _view;
    final status = _status;
    final query = _query;
    _wantedPage = page;
    _slowTimer?.cancel();
    final cached = _cached('$view|$page');
    if (cached != null) {
      _show(cached, page, view, status, query);
      return;
    }
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
      final result = await _fetchPage(page);
      if (!mounted || id != _requestId) return; // a newer request replaced this one
      _slowTimer?.cancel();
      // Past the end: the list got shorter since this page was opened. The server only counts the rows it returns, so
      // it can answer 0 here. Show the last page rather than "no jobs".
      if (result.rows.isEmpty && page > 1) {
        unawaited(_load(result.total > 0 ? result.totalPages : 1));
        return;
      }
      _cache['$view|$page'] = result;
      _show(result, page, view, status, query);
    } on _SignedOut {
      _slowTimer?.cancel();
    } catch (e) {
      if (!mounted || id != _requestId) return;
      _slowTimer?.cancel();
      _activity.setRefreshing(false);
      // Never the raw exception: it can carry the request URL.
      final name = cfg.plural.toLowerCase();
      final message = switch (e) {
        _LoadError(:final message) => message,
        TimeoutException() => 'The server is taking too long to respond. It may be waking up. Try again in a moment.',
        http.ClientException() => "Couldn't reach the server. Check your connection and try again.",
        _ => 'Could not load $name. The server sent a reply the app could not read.',
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

  Future<void> _prefetch(int page, int totalPages) async {
    final key = '$_view|$page';
    if (page > totalPages || _cached(key) != null) return;
    try {
      final result = await _fetchPage(page);
      if (mounted) _cache[key] = result;
    } catch (_) {
      // Best effort: Next just loads normally if this didn't work.
    }
  }

  Future<void> _loadCounts() async {
    try {
      final res = await _get(Uri.parse('$kApiBaseUrl${cfg.countsPath}'));
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
    _load(_wantedPage);
  }

  // ---- actions --------------------------------------------------------------

  void _setStatus(String status) {
    if (status == _status) return;
    _status = status;
    _load(1);
  }

  void _applyQuery(String q) {
    _debounce?.cancel();
    q = q.trim();
    if (q == _query) return;
    _query = q;
    _load(1);
  }

  void _onSearchChanged(String text) {
    setState(() {}); // shows / hides the clear button
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _applyQuery(text));
  }

  void _clearSearch() {
    _search.clear();
    setState(() {});
    _applyQuery('');
  }

  void _clearFilters() {
    _debounce?.cancel();
    _search.clear();
    _status = 'All';
    _query = '';
    _load(1);
  }

  void _setSort(String key) {
    // Names and statuses read A to Z first; dates, numbers and money biggest first.
    _ascending = _sort == key ? !_ascending : key == 'customer' || key == 'status';
    _sort = key;
    _load(1);
  }

  void _setPageSize(int size) {
    if (size == _pageSize) return;
    _pageSize = size;
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
    final scale = MediaQuery.textScalerOf(context);
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageBanner(
            title: cfg.plural,
            icon: accessIcon(cfg.accessKey),
            activity: _activity,
            actions: [PageBanner.refresh(onPressed: _loading ? null : _refresh)],
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                // Larger text needs the room too, so the sidebar and the columns give way sooner.
                final wide = c.maxWidth >= _sidebarWidth + scale.scale(_tableWidth);
                return wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(width: _sidebarWidth, child: _statusSidebar()),
                          Expanded(child: _listPane(showMenuFilter: false)),
                        ],
                      )
                    : _listPane(showMenuFilter: true);
              },
            ),
          ),
        ],
      ),
    );
  }

  // ---- status filter --------------------------------------------------------

  Widget _statusSidebar() {
    return Container(
      decoration: const BoxDecoration(border: Border(right: BorderSide(color: DashUi.line))),
      // Not selectable text: the app-wide selection's I-beam would replace the click cursor.
      child: SelectionContainer.disabled(
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
      ),
    );
  }

  Widget _statusRow(String name, int? count, Color? dot) {
    final selected = _status == name;
    final accent = dot ?? DashUi.blue;
    final shown = count == null ? '—' : _count.format(count);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Semantics(
        button: true,
        selected: selected,
        label: count == null ? name : '$name, $shown',
        child: InkWell(
          onTap: () => _setStatus(name),
          borderRadius: BorderRadius.circular(10),
          hoverColor: DashUi.faint,
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: selected ? accent.withValues(alpha: 0.10) : Colors.transparent,
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
                    style: TextStyle(fontSize: 13.5, fontWeight: selected ? FontWeight.w800 : FontWeight.w600, color: DashUi.ink),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  shown,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: selected ? DashUi.ink : DashUi.slate, fontFeatures: flatFigures),
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
    return SelectionContainer.disabled(
      child: PopupMenuButton<String>(
        tooltip: 'Filter by status',
        position: PopupMenuPosition.under,
        constraints: const BoxConstraints(maxHeight: 420, minWidth: 240),
        onSelected: _setStatus,
        itemBuilder: (_) => [
          PopupMenuItem(value: 'All', child: Text(_allCount == null ? 'All' : 'All  (${_count.format(_allCount)})')),
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
          height: 42,
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
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink),
              ),
              const Icon(Icons.arrow_drop_down_rounded, color: DashUi.slate),
            ],
          ),
        ),
      ),
    );
  }

  // ---- list -----------------------------------------------------------------

  Widget _listPane({required bool showMenuFilter}) {
    return LayoutBuilder(
      builder: (context, c) {
        final compact = c.maxWidth < MediaQuery.textScalerOf(context).scale(_tableWidth);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: CustomScrollView(
                controller: _scroll,
                slivers: [
                  SliverToBoxAdapter(child: _toolbar(showMenuFilter)),
                  if (_stale != null)
                    SliverToBoxAdapter(
                      child: FlatStaleNotice(
                        message: '$_stale Showing the last loaded ${cfg.plural.toLowerCase()}.',
                        busy: _loading,
                        onRetry: _refresh,
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
    );
  }

  String get _countLabel {
    if (_shownQuery.isNotEmpty || _shownStatus != 'All') return '${_count.format(_total)} matching';
    return '${_count.format(_total)} ${_total == 1 ? cfg.singular : cfg.plural.toLowerCase()}';
  }

  Widget _toolbar(bool showMenuFilter) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
      child: Wrap(
        spacing: 16,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (showMenuFilter) _statusMenu(),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: TextField(
              controller: _search,
              onChanged: _onSearchChanged,
              onSubmitted: _applyQuery,
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 14),
              decoration: flatSearchDecoration(
                'Search customer, ${cfg.singular} # or address...',
                onClear: _search.text.isEmpty ? null : _clearSearch,
              ),
            ),
          ),
          // No count without rows: a failed load has nothing to count, and an empty list says so itself.
          if (_error == null && _rows.isNotEmpty) Semantics(liveRegion: true, child: Text(_countLabel, style: flatCellMuted)),
        ],
      ),
    );
  }

  /// What sits under the toolbar, as slivers so the table's header can stay pinned while the rows scroll under it.
  List<Widget> _content(bool compact) {
    if (_error != null) return [SliverToBoxAdapter(child: _errorState())];
    if (_rows.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: _loading ? FlatLoading(label: 'Loading ${cfg.plural.toLowerCase()}', flex: _flex, compact: compact, slow: _slow) : _emptyState(),
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
          itemBuilder: (_, i) => flatRowEntrance(_rowsIn, i, _row(_rows[i], i, compact, columns)),
        ),
      ),
    ];
  }

  Widget _errorState() {
    return FlatEmpty(
      icon: _forbidden ? Icons.lock_outline_rounded : Icons.cloud_off_rounded,
      title: _forbidden ? 'No access to ${cfg.plural.toLowerCase()}' : "${cfg.plural} didn't load",
      message: _error!,
      action: _forbidden
          ? null
          : FilledButton.icon(
              onPressed: _loading ? null : _refresh,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Try again'),
            ),
    );
  }

  Widget _emptyState() {
    final name = cfg.plural.toLowerCase();
    if (_shownStatus == 'All' && _shownQuery.isEmpty) {
      return FlatEmpty(
        icon: Icons.inbox_outlined,
        title: 'No $name yet',
        message: '${cfg.plural} show here once they sync from Service Fusion.',
      );
    }
    return FlatEmpty(
      icon: Icons.search_off_rounded,
      title: 'No $name found',
      message: 'Nothing matches${_shownQuery.isNotEmpty ? ' "$_shownQuery"' : ''}${_shownStatus != 'All' ? ' in $_shownStatus' : ''}.',
      action: OutlinedButton.icon(
        onPressed: _clearFilters,
        icon: const Icon(Icons.filter_alt_off_rounded, size: 18),
        label: const Text('Clear search and filter'),
      ),
    );
  }

  List<FlatCol> get _columns => [
    FlatCol(cfg.idLabel, flex: _flex[0], sortKey: 'id'),
    FlatCol('Date', flex: _flex[1], sortKey: 'date'),
    FlatCol('Customer', flex: _flex[2], sortKey: 'customer'),
    FlatCol(cfg.peopleLabel, flex: _flex[3]),
    FlatCol(cfg.amountLabel, flex: _flex[4], right: true, sortKey: 'amount'),
    FlatCol('Status', flex: _flex[5], sortKey: 'status'),
  ];

  String _idOf(Map<String, dynamic> r) => (r['job_id'] ?? r['id'] ?? '').toString();

  String _customerOf(Map<String, dynamic> r) {
    final name = (r['customer_name'] ?? '').toString().trim();
    return name.isEmpty ? 'Unknown customer' : name;
  }

  String _statusOf(Map<String, dynamic> r) {
    final status = (r['status'] ?? '').toString().trim();
    return status.isEmpty ? 'No status' : status;
  }

  String _peopleOf(Map<String, dynamic> r) {
    final people = (r[cfg.peopleField] ?? '').toString().trim();
    return people.isEmpty ? cfg.peopleEmpty : people;
  }

  Widget _tip(String message, Widget child) => Tooltip(message: message, waitDuration: const Duration(milliseconds: 400), child: child);

  Widget _idCell(Map<String, dynamic> r) => Text(_idOf(r), style: flatCellBold, maxLines: 1, overflow: TextOverflow.ellipsis);

  Widget _dateCell(Map<String, dynamic> r) {
    final date = _date(r['start_date']);
    return date.isEmpty ? const Text('—', style: flatCellMuted) : Text(date, style: flatCellStyle, maxLines: 1, softWrap: false);
  }

  /// The customer, with the address under it (no description).
  Widget _customerCell(Map<String, dynamic> r) {
    final customer = _customerOf(r);
    final address = (r['location'] ?? '').toString().trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _tip(customer, Text(customer, maxLines: 1, overflow: TextOverflow.ellipsis, style: flatCellBold)),
        const SizedBox(height: 2),
        _tip(
          address.isEmpty ? 'No address on file' : address,
          Text(
            address.isEmpty ? 'No address' : address,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13.5, color: DashUi.slate),
          ),
        ),
      ],
    );
  }

  Widget _peopleCell(Map<String, dynamic> r) {
    final people = _peopleOf(r);
    return _tip(people, Text(people, maxLines: 2, overflow: TextOverflow.ellipsis, style: flatCellMuted));
  }

  /// The amount, on one line: a very large one shrinks a little in a narrow window rather than wrap.
  Widget _amountCell(Map<String, dynamic> r) {
    final amount = double.tryParse('${r['total_revenue'] ?? ''}');
    if (amount == null) return const Text('—', style: flatCellMuted);
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerRight,
      child: Text(
        dashMoney(amount),
        maxLines: 1,
        softWrap: false,
        style: flatCellBold.copyWith(fontFeatures: flatFigures, color: amount < 0 ? DashUi.redText : DashUi.ink),
      ),
    );
  }

  /// A row of the table, or below [_tableWidth] the same facts stacked: who and how much first, then the rest under it,
  /// so nothing hides off to the side.
  Widget _row(Map<String, dynamic> r, int index, bool compact, List<FlatCol> columns) {
    return Semantics(
      button: true,
      label: '${cfg.singular} ${_idOf(r)}, ${_customerOf(r)}, ${_statusOf(r)}',
      // Not selectable text: the app-wide selection's I-beam would replace the click cursor.
      child: SelectionContainer.disabled(
        child: compact
            ? _compactRow(r, index)
            : FlatTableRow(
                columns: columns,
                cells: [_idCell(r), _dateCell(r), _customerCell(r), _peopleCell(r), _amountCell(r), _pill(_statusOf(r))],
                index: index,
                striped: true,
                onTap: () => _open(r),
              ),
      ),
    );
  }

  Widget _compactRow(Map<String, dynamic> r, int index) {
    return InkWell(
      onTap: () => _open(r),
      hoverColor: DashUi.line,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: BoxDecoration(
          color: index.isOdd ? DashUi.faint : null,
          border: const Border(top: BorderSide(color: DashUi.line)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: Align(alignment: Alignment.centerLeft, child: _customerCell(r))),
                const SizedBox(width: 12),
                Expanded(flex: 2, child: Align(alignment: Alignment.topRight, child: _amountCell(r))),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(child: Wrap(spacing: 12, children: [_idCell(r), _dateCell(r)])),
                const SizedBox(width: 12),
                Flexible(child: _pill(_statusOf(r))),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${cfg.peopleLabel}: ${_peopleOf(r)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13.5, color: DashUi.slate),
            ),
          ],
        ),
      ),
    );
  }

  String _date(dynamic v) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(v?.toString() ?? '');
    if (m == null) return '';
    return DateFormat('MMM d, y').format(DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!)));
  }

  /// Status as a dot and word. The text always says the status, so colour is never the only signal. The word is darkened
  /// enough for the brightest status colours to read on a striped row.
  Widget _pill(String status) {
    final c = statusColor(status);
    return _tip(
      status,
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color.lerp(c, Colors.black, 0.45)),
            ),
          ),
        ],
      ),
    );
  }
}
