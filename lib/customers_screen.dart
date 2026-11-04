import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'config/access.dart';
import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'widgets/app_ribbon.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';

/// Initials tints, so the list is easier to scan. A name always gets the same one.
const _avatarTones = [DashUi.blue, DashUi.indigo, DashUi.sky, DashUi.amber, DashUi.emeraldDeep, DashUi.red];

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

typedef _Page = ({List<Map<String, dynamic>> rows, int total, int totalPages, DateTime at});

/// Every customer, searchable and sortable, with how many jobs each has had. Read-only: a row opens the customer's page.
class CustomersScreen extends StatefulWidget {
  /// A search to start with (the nav bar search and a job page's customer link open /customers?q=...).
  final String? initialQuery;

  const CustomersScreen({super.key, this.initialQuery});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  @override
  bool get wantKeepAlive => true;

  static const _flex = [6, 6, 6, 2]; // the columns, also what the first-load skeleton is shaped like
  static const _tableWidth = 900.0; // below this the rows stack
  static const _cacheFor = Duration(minutes: 2); // customers sync from Service Fusion, so a page does not stay right for long
  static const _sorts = [('name', 'Name'), ('city', 'City'), ('jobs', 'Number of jobs')];

  final _searchController = TextEditingController();
  final _scroll = ScrollController();
  final _activity = RibbonActivity();
  late final _rowsIn = AnimationController(vsync: this, duration: const Duration(milliseconds: 460), value: 1);
  final _count = NumberFormat.decimalPattern();
  Timer? _debounce;
  Timer? _slowTimer;

  List<Map<String, dynamic>> _customers = const [];
  int _page = 1;
  int _wantedPage = 1; // the page last asked for: Try again and Refresh ask for it again
  int _totalPages = 1;
  int _total = 0;
  int _firstRow = 1;
  int _pageSize = 50;
  String _sortBy = 'name';
  bool _ascending = true;

  bool _loading = true;
  bool _slow = false; // the first load has taken long enough to say the server may be waking up
  String? _error; // nothing to show: takes the place of the table
  String? _stale; // a reload failed: said above the rows it could not replace
  bool _forbidden = false;
  int _requestId = 0; // guards against out-of-order responses

  // What the rows on screen were loaded for. The search box can already say something else while a load is out.
  String? _shownView;
  String _shownQuery = '';

  // Pages already fetched (and the next one, fetched ahead), so Next is instant.
  final Map<String, _Page> _cache = {};

  @override
  void initState() {
    super.initState();
    _searchController.text = (widget.initialQuery ?? '').trim();
    _load(1);
  }

  @override
  void didUpdateWidget(CustomersScreen old) {
    super.didUpdateWidget(old);
    // A new search from the nav bar while this screen is already open (it is kept alive): apply it.
    final q = (widget.initialQuery ?? '').trim();
    if (q.isNotEmpty && q != (old.initialQuery ?? '').trim() && q != _searchController.text.trim()) {
      _debounce?.cancel();
      _searchController.text = q;
      _load(1);
    }
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

  // ---- data ---------------------------------------------------------------

  String _view(String q) => '$q|$_pageSize|$_sortBy|$_ascending';

  Future<_Page> _request(String q, int page) async {
    final uri = Uri.parse('$kApiBaseUrl/api/customers').replace(queryParameters: {
      'q': q,
      'page': '$page',
      'limit': '$_pageSize',
      'sort': _sortBy,
      'dir': _ascending ? 'asc' : 'desc',
    });
    // Generous timeout: Render free instances can take a while to wake up.
    // Customer details need the signed-in user's token, not just the app's shared key.
    final res = await http.get(uri, headers: AuthSession.instance.headers()).timeout(const Duration(seconds: 40));
    if (res.statusCode == 401) {
      AuthSession.instance.logout(); // sends the app back to the sign-in screen
      throw const _SignedOut();
    }
    if (res.statusCode == 403) throw const _LoadError("Your account doesn't have access to customers.", forbidden: true);
    if (res.statusCode != 200) throw _LoadError('Could not load customers (server error ${res.statusCode}).');
    final data = json.decode(res.body) as Map<String, dynamic>;
    return (
      rows: List<Map<String, dynamic>>.from((data['data'] as List? ?? const []).whereType<Map>().map(Map<String, dynamic>.from)),
      total: (data['total'] as num?)?.toInt() ?? 0,
      totalPages: (data['totalPages'] as num?)?.toInt() ?? 1,
      at: DateTime.now(),
    );
  }

  _Page? _cached(String key) {
    final page = _cache[key];
    return page != null && DateTime.now().difference(page.at) < _cacheFor ? page : null;
  }

  void _show(_Page r, int page, String view, String q) {
    // A reload of the same page just updates it; anything else is a new list, read from its top.
    final newList = view != _shownView || page != _page;
    _activity.setRefreshing(false);
    setState(() {
      _customers = r.rows;
      _total = r.total;
      _totalPages = r.totalPages;
      _firstRow = (page - 1) * _pageSize + 1;
      _page = page;
      _shownView = view;
      _shownQuery = q;
      _loading = false;
      _slow = false;
      _error = null;
      _stale = null;
      _forbidden = false;
    });
    _prefetch(q, page + 1, r.totalPages);
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
    final q = _searchController.text.trim();
    final view = _view(q);
    final id = ++_requestId;
    _wantedPage = page;
    _slowTimer?.cancel();

    final cached = _cached('$view|$page');
    if (cached != null) {
      _show(cached, page, view, q);
      return;
    }
    if (_customers.isEmpty) {
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
      final result = await _request(q, page);
      if (!mounted || id != _requestId) return;
      _slowTimer?.cancel();
      // Past the end: the list got shorter since this page was opened. Show the last page rather than "no customers".
      if (result.rows.isEmpty && page > 1) {
        unawaited(_load(result.total > 0 ? result.totalPages : 1));
        return;
      }
      if (_cache.length > 60) _cache.clear();
      _cache['$view|$page'] = result;
      _show(result, page, view, q);
    } on _SignedOut {
      _slowTimer?.cancel();
    } catch (e) {
      if (!mounted || id != _requestId) return;
      _slowTimer?.cancel();
      _activity.setRefreshing(false);
      // Never the raw exception: it can carry the request URL.
      final message = switch (e) {
        _LoadError(:final message) => message,
        TimeoutException() => 'The server is taking too long to respond. It may be waking up. Try again in a moment.',
        http.ClientException() => "Couldn't reach the server. Check your connection and try again.",
        _ => 'Could not load customers. The server sent a reply the app could not read.',
      };
      final forbidden = e is _LoadError && e.forbidden;
      setState(() {
        _loading = false;
        _slow = false;
        _forbidden = forbidden;
        // The rows on screen are still the list that was asked for, so they stay. Rows from another search would pass
        // for the answer to this one.
        if (view == _shownView && _customers.isNotEmpty && !forbidden) {
          _stale = message;
        } else {
          _error = message;
          _stale = null;
        }
      });
    }
  }

  Future<void> _prefetch(String q, int next, int totalPages) async {
    final key = '${_view(q)}|$next';
    if (next > totalPages || _cached(key) != null) return;
    try {
      final result = await _request(q, next);
      if (mounted) _cache[key] = result;
    } catch (_) {
      // Best effort: Next just loads normally if this didn't work.
    }
  }

  // ---- actions ------------------------------------------------------------

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

  void _setSort(String key) {
    // Names and cities read A to Z first; job counts biggest first.
    _ascending = _sortBy == key ? !_ascending : key != 'jobs';
    _sortBy = key;
    _load(1);
  }

  void _setPageSize(int size) {
    if (size == _pageSize) return;
    _pageSize = size;
    _load(1);
  }

  void _refresh() {
    _cache.clear();
    _load(_wantedPage);
  }

  Future<void> _copy(String value, String label) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('$label copied'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        width: 220,
      ));
  }

  /// Opens the customer's own page; the row rides along so the name shows before the full record loads.
  void _open(Map<String, dynamic> c) => context.go('/customers/${c['id']}', extra: c);

  // ---- build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);
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
                title: 'Customers',
                icon: accessIcon('customers'),
                activity: _activity,
                actions: [PageBanner.refresh(onPressed: _loading ? null : _refresh)],
              ),
              Expanded(
                child: CustomScrollView(
                  controller: _scroll,
                  slivers: [
                    SliverToBoxAdapter(child: _toolbar(compact)),
                    if (_stale != null)
                      SliverToBoxAdapter(
                        child: FlatStaleNotice(
                          message: '$_stale Showing the last loaded customers.',
                          busy: _loading,
                          onRetry: _refresh,
                        ),
                      ),
                    ..._content(compact),
                  ],
                ),
              ),
              if (_error == null && _customers.isNotEmpty)
                FlatPager(
                  page: _page,
                  totalPages: _totalPages,
                  total: _total,
                  firstRow: _firstRow,
                  rowsShown: _customers.length,
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

  String get _countLabel {
    if (_shownQuery.isNotEmpty) return '${_count.format(_total)} matching';
    return _total == 1 ? '1 customer' : '${_count.format(_total)} customers';
  }

  Widget _toolbar(bool compact) {
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
                'Search name, phone, email, city...', // contacts and addresses match too; a longer hint cuts off
                onClear: _searchController.text.isEmpty ? null : _clearSearch,
              ),
            ),
          ),
          // The table's headers sort it; stacked rows have none, so the sort is a menu there.
          if (compact) _sortMenu(),
          // No count without rows: a failed load has nothing to count, and an empty list says so itself.
          if (_error == null && _customers.isNotEmpty) Semantics(liveRegion: true, child: Text(_countLabel, style: flatCellMuted)),
        ],
      ),
    );
  }

  Widget _sortMenu() {
    final label = _sorts.firstWhere((s) => s.$1 == _sortBy, orElse: () => _sorts.first).$2;
    return SelectionContainer.disabled(
      child: PopupMenuButton<String>(
        tooltip: 'Sort',
        position: PopupMenuPosition.under,
        onSelected: _setSort,
        itemBuilder: (_) => [
          for (final (key, name) in _sorts)
            PopupMenuItem(
              value: key,
              child: Row(
                children: [
                  Expanded(
                    child: Text(name, style: TextStyle(fontWeight: _sortBy == key ? FontWeight.w700 : FontWeight.w500, color: DashUi.ink)),
                  ),
                  if (_sortBy == key)
                    Icon(_ascending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 16, color: DashUi.ink),
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
              const Icon(Icons.swap_vert_rounded, size: 18, color: DashUi.slate),
              const SizedBox(width: 8),
              Text(label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink)),
              const SizedBox(width: 4),
              Icon(_ascending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 14, color: DashUi.slate),
            ],
          ),
        ),
      ),
    );
  }

  /// What sits under the toolbar, as slivers so the table's header can stay pinned while the rows scroll under it.
  List<Widget> _content(bool compact) {
    if (_error != null) return [SliverToBoxAdapter(child: _errorState())];
    if (_customers.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: _loading ? FlatLoading(label: 'Loading customers', flex: _flex, compact: compact, slow: _slow) : _emptyState(),
        ),
      ];
    }
    final columns = _columns;
    return [
      if (!compact)
        PinnedHeaderSliver(
          child: FlatTableHeader(columns: columns, striped: true, sortKey: _sortBy, ascending: _ascending, onSort: _setSort),
        ),
      // Rows being replaced fade back a little, so a slow search does not look finished.
      SliverAnimatedOpacity(
        opacity: _loading ? 0.55 : 1,
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 160),
        sliver: SliverList.builder(
          itemCount: _customers.length,
          itemBuilder: (_, i) => flatRowEntrance(_rowsIn, i, _row(_customers[i], i, compact, columns)),
        ),
      ),
    ];
  }

  Widget _errorState() {
    return FlatEmpty(
      icon: _forbidden ? Icons.lock_outline_rounded : Icons.cloud_off_rounded,
      title: _forbidden ? 'No access to customers' : "Customers didn't load",
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
    if (_shownQuery.isNotEmpty) {
      return FlatEmpty(
        icon: Icons.person_search_rounded,
        title: 'No matching customers',
        message: 'Nothing matches "$_shownQuery". Try a different name, phone number, email or city.',
        action: OutlinedButton(onPressed: _clearSearch, child: const Text('Clear search')),
      );
    }
    return const FlatEmpty(
      icon: Icons.people_outline_rounded,
      title: 'No customers yet',
      message: 'Customers show here once they sync from Service Fusion.',
    );
  }

  List<FlatCol> get _columns => [
    FlatCol('Customer', flex: _flex[0], sortKey: 'name'),
    FlatCol('Contact info', flex: _flex[1]),
    FlatCol('Service location', flex: _flex[2], sortKey: 'city'),
    FlatCol('Jobs', flex: _flex[3], right: true, sortKey: 'jobs'),
  ];

  Widget _row(Map<String, dynamic> c, int index, bool compact, List<FlatCol> columns) {
    final name = _clean(c['customer_name']) ?? 'Unknown customer';
    return Semantics(
      button: true,
      label: 'Customer $name',
      // Not selectable text: the app-wide selection's I-beam would replace the click cursor. Phone and email copy on click.
      child: SelectionContainer.disabled(
        child: compact
            ? _compactRow(c, index)
            : FlatTableRow(
                columns: columns,
                cells: [_customerCell(c), _contactCell(c), _locationCell(c), _jobsCell(c)],
                index: index,
                striped: true,
                onTap: () => _open(c),
              ),
      ),
    );
  }

  Widget _customerCell(Map<String, dynamic> c) {
    final name = _clean(c['customer_name']) ?? 'Unknown customer';
    final contact = _clean(c['primary_contact']);
    return Row(
      children: [
        DashAvatar(name: name, imageUrl: '', size: 36, accent: _avatarTones[name.hashCode.abs() % _avatarTones.length]),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _tip(name, Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: flatCellBold)),
              if (contact != null && contact.toLowerCase() != name.toLowerCase())
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(contact, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, color: DashUi.slate)),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _contactCell(Map<String, dynamic> c) {
    final phone = _phone(_clean(c['phone']));
    final email = _clean(c['email']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _ContactLine(icon: Icons.phone_outlined, text: phone, label: 'phone', onCopy: phone == null ? null : () => _copy(phone, 'Phone')),
        const SizedBox(height: 4),
        _ContactLine(icon: Icons.mail_outline_rounded, text: email, label: 'email', onCopy: email == null ? null : () => _copy(email, 'Email')),
      ],
    );
  }

  Widget _locationCell(Map<String, dynamic> c) {
    final location = _clean(c['service_location']);
    final cityState = _cityState(c);
    if (location == null && cityState == null) return const Text('No address', style: flatCellMuted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (location != null) _tip(location, Text(location, maxLines: 1, overflow: TextOverflow.ellipsis, style: flatCellStyle)),
        if (cityState != null)
          Padding(
            padding: EdgeInsets.only(top: location == null ? 0 : 2),
            child: Text(cityState, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, color: DashUi.slate)),
          ),
      ],
    );
  }

  Widget _jobsCell(Map<String, dynamic> c) {
    final jobs = _toInt(c['total_jobs']);
    return Text(_count.format(jobs), style: (jobs > 0 ? flatCellBold : flatCellMuted).copyWith(fontFeatures: flatFigures));
  }

  /// A row too narrow for the columns: who and how many jobs first, then how to reach them and where.
  Widget _compactRow(Map<String, dynamic> c, int index) {
    final jobs = _toInt(c['total_jobs']);
    final address = [_clean(c['service_location']), _cityState(c)].whereType<String>().join(' · ');
    return InkWell(
      onTap: () => _open(c),
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
              children: [
                Expanded(child: _customerCell(c)),
                const SizedBox(width: 12),
                Text(
                  '${_count.format(jobs)} ${jobs == 1 ? 'job' : 'jobs'}',
                  style: (jobs > 0 ? flatCellBold : flatCellMuted).copyWith(fontFeatures: flatFigures),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _contactCell(c),
            const SizedBox(height: 4),
            _ContactLine(
              icon: Icons.place_outlined,
              text: address.isEmpty ? null : address,
              label: 'address',
              onCopy: address.isEmpty ? null : () => _copy(address, 'Address'),
            ),
          ],
        ),
      ),
    );
  }

  // ---- helpers --------------------------------------------------------------

  Widget _tip(String message, Widget child) => Tooltip(message: message, waitDuration: const Duration(milliseconds: 400), child: child);

  String? _clean(dynamic v) {
    final s = v?.toString().trim();
    if (s == null || s.isEmpty || s == '--') return null;
    return s;
  }

  /// Service Fusion keeps phones as typed ("4795550199", "479-555-0199"): a 10-digit US number is shown one way,
  /// (479) 555-0199. Anything else (extensions, two numbers) is left as typed rather than guessed at.
  String? _phone(String? raw) {
    if (raw == null) return null;
    var digits = raw.replaceAll(RegExp(r'[\s().\-+]'), '');
    if (digits.length == 11 && digits.startsWith('1')) digits = digits.substring(1);
    if (!RegExp(r'^\d{10}$').hasMatch(digits)) return raw;
    return '(${digits.substring(0, 3)}) ${digits.substring(3, 6)}-${digits.substring(6)}';
  }

  String? _cityState(Map<String, dynamic> c) {
    final city = _clean(c['city']);
    final state = _clean(c['state']);
    if (city == null && state == null) return null;
    return [city, state].whereType<String>().join(', ');
  }
}

int _toInt(dynamic v) => v is num ? v.toInt() : (num.tryParse('${v ?? ''}') ?? 0).toInt();

/// A phone, email or address with its icon. Clicking it copies it (not opening the customer).
class _ContactLine extends StatelessWidget {
  final IconData icon;
  final String? text;
  final String label; // "phone", for "No phone"
  final VoidCallback? onCopy;
  const _ContactLine({required this.icon, required this.text, required this.label, this.onCopy});

  @override
  Widget build(BuildContext context) {
    final empty = text == null;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: empty ? DashUi.muted : DashUi.slate),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            empty ? 'No $label' : text!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, color: empty ? DashUi.slate : DashUi.ink),
          ),
        ),
      ],
    );
    if (onCopy == null) return row;
    return Tooltip(
      message: 'Copy $label: $text',
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(onTap: onCopy, borderRadius: BorderRadius.circular(4), child: row),
    );
  }
}
