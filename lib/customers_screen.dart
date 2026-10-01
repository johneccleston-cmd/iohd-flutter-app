import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

// ---------------------------------------------------------------------------
// Design tokens
// ---------------------------------------------------------------------------
class _C {
  static const bg = Color(0xFFF4F6F9);
  static const surface = Colors.white;
  static const ink = Color(0xFF111827);
  static const muted = Color(0xFF6B7280);
  static const line = Color(0xFFE5E7EB);
  static const subtle = Color(0xFFF9FAFB);
  static const primary = Color(0xFF2563EB);
  static const primarySoft = Color(0xFFEFF4FF);
  static const money = Color(0xFF047857);
  static const moneySoft = Color(0xFFECFDF5);
}

const _baseUrl = 'https://integrity-backend-cr02.onrender.com';
const _avatarPalette = [
  Color(0xFF2563EB),
  Color(0xFF7C3AED),
  Color(0xFF0891B2),
  Color(0xFFD97706),
  Color(0xFFDB2777),
  Color(0xFF059669),
  Color(0xFF4F46E5),
  Color(0xFFDC2626),
];

class _PageResult {
  final List<Map<String, dynamic>> rows;
  final int total;
  final int totalPages;
  const _PageResult(this.rows, this.total, this.totalPages);
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------
class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final _searchController = TextEditingController();
  Timer? _debounce;

  List<Map<String, dynamic>> _customers = [];
  bool _loading = true;
  String? _error;

  int _page = 1;
  int _totalPages = 1;
  int _total = 0;
  int _pageSize = 50;

  String _sortBy = 'name';
  String _sortDir = 'asc';

  int _requestId = 0; // guards against out-of-order responses
  final Map<String, _PageResult> _cache = {};

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

  // ---- data ---------------------------------------------------------------
  String _key(String q, int page) => '$q|$page|$_pageSize|$_sortBy|$_sortDir';

  Future<_PageResult> _request(String q, int page) async {
    final uri = Uri.parse('$_baseUrl/api/customers').replace(queryParameters: {
      'q': q,
      'page': '$page',
      'limit': '$_pageSize',
      'sort': _sortBy,
      'dir': _sortDir,
    });
    // Generous timeout: Render free instances can take a while to wake up.
    final res = await http.get(uri).timeout(const Duration(seconds: 40));
    if (res.statusCode != 200) {
      throw Exception('Server error (${res.statusCode})');
    }
    final data = json.decode(res.body) as Map<String, dynamic>;
    return _PageResult(
      List<Map<String, dynamic>>.from(data['data'] ?? const []),
      (data['total'] as num?)?.toInt() ?? 0,
      (data['totalPages'] as num?)?.toInt() ?? 1,
    );
  }

  Future<void> _load(int page) async {
    final q = _searchController.text.trim();
    final key = _key(q, page);
    final id = ++_requestId;

    final cached = _cache[key];
    if (cached != null) {
      _apply(cached, page);
      _prefetch(q, page + 1, cached.totalPages);
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = await _request(q, page);
      if (!mounted || id != _requestId) return;
      if (_cache.length > 60) _cache.clear();
      _cache[key] = result;
      _apply(result, page);
      _prefetch(q, page + 1, result.totalPages);
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _loading = false;
        _error = e is TimeoutException
            ? 'The server is taking too long to respond. It may be waking up — try again in a moment.'
            : e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _apply(_PageResult r, int page) {
    setState(() {
      _customers = r.rows;
      _total = r.total;
      _totalPages = r.totalPages;
      _page = page;
      _loading = false;
      _error = null;
    });
  }

  Future<void> _prefetch(String q, int next, int totalPages) async {
    if (next > totalPages) return;
    final key = _key(q, next);
    if (_cache.containsKey(key)) return;
    try {
      _cache[key] = await _request(q, next);
    } catch (_) {}
  }

  // ---- actions ------------------------------------------------------------
  void _onSearchChanged(String _) {
    setState(() {}); // refresh clear button
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
    setState(() {
      if (_sortBy == key) {
        _sortDir = _sortDir == 'asc' ? 'desc' : 'asc';
      } else {
        _sortBy = key;
        _sortDir = (key == 'jobs' || key == 'spent') ? 'desc' : 'asc';
      }
    });
    _load(1);
  }

  void _changePage(int p) {
    if (p < 1 || p > _totalPages || p == _page) return;
    _load(p);
  }

  void _changePageSize(int size) {
    if (size == _pageSize) return;
    setState(() => _pageSize = size);
    _load(1);
  }

  void _refresh() {
    _cache.clear();
    _load(_page);
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

  // ---- build --------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Scaffold(
      backgroundColor: _C.bg,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            const SizedBox(height: 20),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: _C.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _C.line),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x0A000000),
                      blurRadius: 12,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildToolbar(),
                    SizedBox(
                      height: 3,
                      child: _loading
                          ? const LinearProgressIndicator(
                              minHeight: 3,
                              color: _C.primary,
                              backgroundColor: Colors.transparent)
                          : const Divider(height: 1, thickness: 1, color: _C.line),
                    ),
                    Expanded(child: _buildBody()),
                    _buildFooter(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Customers',
                  style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                      color: _C.ink)),
              const SizedBox(height: 2),
              Text(
                _loading && _customers.isEmpty
                    ? 'Loading directory…'
                    : _searchController.text.trim().isEmpty
                        ? '${_fmtInt(_total)} customers in your directory'
                        : '${_fmtInt(_total)} matching "${_searchController.text.trim()}"',
                style: const TextStyle(fontSize: 14, color: _C.muted),
              ),
            ],
          ),
        ),
        IconButton.outlined(
          tooltip: 'Refresh',
          onPressed: _loading ? null : _refresh,
          icon: const Icon(Icons.refresh_rounded, size: 20),
          style: IconButton.styleFrom(
            foregroundColor: _C.muted,
            side: const BorderSide(color: _C.line),
            backgroundColor: _C.surface,
          ),
        ),
      ],
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              onSubmitted: (_) => _searchNow(),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search name, contact, phone, email, or city…',
                hintStyle: const TextStyle(color: _C.muted, fontSize: 14),
                prefixIcon:
                    const Icon(Icons.search_rounded, color: _C.muted, size: 22),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close_rounded,
                            color: _C.muted, size: 20),
                        onPressed: _clearSearch,
                      ),
                filled: true,
                fillColor: _C.subtle,
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: _C.line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: _C.primary, width: 1.6),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          PopupMenuButton<String>(
            tooltip: 'Sort',
            onSelected: _setSort,
            offset: const Offset(0, 48),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            itemBuilder: (_) => [
              _sortItem('name', 'Name'),
              _sortItem('city', 'City'),
              _sortItem('jobs', 'Number of jobs'),
              _sortItem('spent', 'Lifetime revenue'),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: _C.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _C.line),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.swap_vert_rounded, size: 18, color: _C.muted),
                  const SizedBox(width: 6),
                  Text(_sortLabel(),
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _C.ink)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  PopupMenuItem<String> _sortItem(String key, String label) {
    final active = _sortBy == key;
    return PopupMenuItem(
      value: key,
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: active ? _C.primary : _C.ink)),
          ),
          if (active)
            Icon(
                _sortDir == 'asc'
                    ? Icons.arrow_upward_rounded
                    : Icons.arrow_downward_rounded,
                size: 16,
                color: _C.primary),
        ],
      ),
    );
  }

  String _sortLabel() {
    const names = {
      'name': 'Name',
      'city': 'City',
      'jobs': 'Jobs',
      'spent': 'Revenue',
      'contact': 'Contact',
    };
    return '${names[_sortBy] ?? 'Name'} ${_sortDir == 'asc' ? '↑' : '↓'}';
  }

  Widget _buildBody() {
    if (_error != null && _customers.isEmpty) {
      return _StateMessage(
        icon: Icons.cloud_off_rounded,
        iconColor: Colors.redAccent,
        title: "Couldn't load customers",
        message: _error!,
        actionLabel: 'Try again',
        onAction: () => _load(_page),
      );
    }
    if (_loading && _customers.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: _C.primary));
    }
    if (_customers.isEmpty) {
      final searching = _searchController.text.trim().isNotEmpty;
      return _StateMessage(
        icon: Icons.person_search_rounded,
        iconColor: _C.muted,
        title: searching ? 'No matches found' : 'No customers yet',
        message: searching
            ? 'Try a different name, phone number, email, or city.'
            : 'Customers will show up here once they are added.',
        actionLabel: searching ? 'Clear search' : null,
        onAction: searching ? _clearSearch : null,
      );
    }

    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 900;
      return AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: _loading ? 0.5 : 1,
        child: wide ? _buildTable() : _buildCardList(),
      );
    });
  }

  // ---- wide layout: table ---------------------------------------------------
  Widget _buildTable() {
    return Column(
      children: [
        Container(
          color: _C.subtle,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(
            children: [
              _headerCell('CUSTOMER', 'name', flex: 30),
              _headerCell('CONTACT INFO', null, flex: 28),
              _headerCell('SERVICE LOCATION', 'city', flex: 26),
              _headerCell('JOBS', 'jobs', flex: 8, align: MainAxisAlignment.center),
              _headerCell('LIFETIME REVENUE', 'spent',
                  flex: 14, align: MainAxisAlignment.end),
            ],
          ),
        ),
        const Divider(height: 1, thickness: 1, color: _C.line),
        Expanded(
          child: ListView.separated(
            itemCount: _customers.length,
            separatorBuilder: (_, __) =>
                const Divider(height: 1, thickness: 1, color: _C.line),
            itemBuilder: (_, i) => _tableRow(_customers[i]),
          ),
        ),
      ],
    );
  }

  Widget _headerCell(String label, String? sortKey,
      {required int flex, MainAxisAlignment align = MainAxisAlignment.start}) {
    final active = sortKey != null && _sortBy == sortKey;
    final text = Text(
      label,
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: active ? _C.primary : _C.muted,
      ),
    );
    return Expanded(
      flex: flex,
      child: sortKey == null
          ? Align(alignment: Alignment.centerLeft, child: text)
          : InkWell(
              onTap: () => _setSort(sortKey),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisAlignment: align,
                  children: [
                    Flexible(child: text),
                    if (active) ...[
                      const SizedBox(width: 4),
                      Icon(
                        _sortDir == 'asc'
                            ? Icons.arrow_upward_rounded
                            : Icons.arrow_downward_rounded,
                        size: 14,
                        color: _C.primary,
                      ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }

  Widget _tableRow(Map<String, dynamic> c) {
    final name = _clean(c['customer_name']) ?? 'Unknown';
    final contact = _clean(c['primary_contact']);
    final phone = _clean(c['phone']);
    final email = _clean(c['email']);
    final location = _clean(c['service_location']);
    final cityState = _cityState(c);

    return InkWell(
      hoverColor: _C.primarySoft.withOpacity(0.5),
      onTap: () {},
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              flex: 30,
              child: Row(
                children: [
                  _Avatar(name: name),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w700,
                                color: _C.ink)),
                        if (contact != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(contact,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 13, color: _C.muted)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 28,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ContactLine(
                    icon: Icons.phone_outlined,
                    text: phone,
                    onCopy: phone == null ? null : () => _copy(phone, 'Phone'),
                  ),
                  const SizedBox(height: 4),
                  _ContactLine(
                    icon: Icons.mail_outline_rounded,
                    text: email,
                    onCopy: email == null ? null : () => _copy(email, 'Email'),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 26,
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(location ?? '—',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13.5, color: _C.ink)),
                    if (cityState != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(cityState,
                            style: const TextStyle(
                                fontSize: 12.5, color: _C.muted)),
                      ),
                  ],
                ),
              ),
            ),
            Expanded(
              flex: 8,
              child: Center(child: _JobsChip(count: _toInt(c['total_jobs']))),
            ),
            Expanded(
              flex: 14,
              child: Align(
                alignment: Alignment.centerRight,
                child: _Money(amount: _toNum(c['total_spent'])),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- narrow layout: cards -------------------------------------------------
  Widget _buildCardList() {
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _customers.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) => _card(_customers[i]),
    );
  }

  Widget _card(Map<String, dynamic> c) {
    final name = _clean(c['customer_name']) ?? 'Unknown';
    final contact = _clean(c['primary_contact']);
    final phone = _clean(c['phone']);
    final email = _clean(c['email']);
    final location = _clean(c['service_location']);
    final cityState = _cityState(c);
    final address = [location, cityState].whereType<String>().join(' · ');

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _C.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Avatar(name: name),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: _C.ink)),
                    if (contact != null)
                      Text(contact,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, color: _C.muted)),
                  ],
                ),
              ),
              _Money(amount: _toNum(c['total_spent'])),
            ],
          ),
          const SizedBox(height: 12),
          _ContactLine(
            icon: Icons.phone_outlined,
            text: phone,
            onCopy: phone == null ? null : () => _copy(phone, 'Phone'),
          ),
          const SizedBox(height: 4),
          _ContactLine(
            icon: Icons.mail_outline_rounded,
            text: email,
            onCopy: email == null ? null : () => _copy(email, 'Email'),
          ),
          const SizedBox(height: 4),
          _ContactLine(icon: Icons.place_outlined, text: address.isEmpty ? null : address),
          const SizedBox(height: 10),
          _JobsChip(count: _toInt(c['total_jobs']), expanded: true),
        ],
      ),
    );
  }

  // ---- footer ---------------------------------------------------------------
  Widget _buildFooter() {
    final start = _total == 0 ? 0 : (_page - 1) * _pageSize + 1;
    final end = (_page * _pageSize) > _total ? _total : _page * _pageSize;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: _C.subtle,
        border: Border(top: BorderSide(color: _C.line)),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 8,
        spacing: 24,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            children: [
              const Text('Rows',
                  style: TextStyle(
                      color: _C.muted,
                      fontSize: 13,
                      fontWeight: FontWeight.w500)),
              SegmentedButton<int>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 50, label: Text('50')),
                  ButtonSegment(value: 100, label: Text('100')),
                ],
                selected: {_pageSize},
                onSelectionChanged: (s) => _changePageSize(s.first),
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: const WidgetStatePropertyAll(
                      TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
              Text('${_fmtInt(start)}–${_fmtInt(end)} of ${_fmtInt(_total)}',
                  style: const TextStyle(
                      color: _C.muted,
                      fontSize: 13,
                      fontWeight: FontWeight.w500)),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton.outlined(
                tooltip: 'Previous page',
                onPressed: _page > 1 && !_loading ? () => _changePage(_page - 1) : null,
                icon: const Icon(Icons.chevron_left_rounded),
                visualDensity: VisualDensity.compact,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Text('Page $_page of $_totalPages',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: _C.ink)),
              ),
              IconButton.outlined(
                tooltip: 'Next page',
                onPressed: _page < _totalPages && !_loading
                    ? () => _changePage(_page + 1)
                    : null,
                icon: const Icon(Icons.chevron_right_rounded),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---- helpers --------------------------------------------------------------
  String? _clean(dynamic v) {
    final s = v?.toString().trim();
    if (s == null || s.isEmpty || s == '--') return null;
    return s;
  }

  String? _cityState(Map<String, dynamic> c) {
    final city = _clean(c['city']);
    final state = _clean(c['state']);
    if (city == null && state == null) return null;
    return [city, state].whereType<String>().join(', ');
  }
}

num _toNum(dynamic v) => v is num ? v : (num.tryParse('${v ?? ''}') ?? 0);
int _toInt(dynamic v) => _toNum(v).toInt();

String _fmtInt(int n) => n.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');

String _fmtMoney(num n) {
  if (n <= 0) return '\$0';
  return '\$${_fmtInt(n.round())}';
}

// ---------------------------------------------------------------------------
// Small widgets
// ---------------------------------------------------------------------------
class _Avatar extends StatelessWidget {
  final String name;
  const _Avatar({required this.name});

  @override
  Widget build(BuildContext context) {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    final initials = parts.isEmpty
        ? '?'
        : parts.length == 1
            ? parts.first.characters.first.toUpperCase()
            : (parts.first.characters.first + parts.last.characters.first)
                .toUpperCase();
    final color = _avatarPalette[name.hashCode.abs() % _avatarPalette.length];

    return CircleAvatar(
      radius: 20,
      backgroundColor: color.withOpacity(0.12),
      child: Text(initials,
          style: TextStyle(
              color: color, fontWeight: FontWeight.w800, fontSize: 13.5)),
    );
  }
}

class _ContactLine extends StatelessWidget {
  final IconData icon;
  final String? text;
  final VoidCallback? onCopy;
  const _ContactLine({required this.icon, required this.text, this.onCopy});

  @override
  Widget build(BuildContext context) {
    final empty = text == null;
    final row = Row(
      children: [
        Icon(icon, size: 15, color: empty ? _C.line : _C.muted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            empty ? '—' : text!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 13, color: empty ? _C.muted : _C.ink),
          ),
        ),
      ],
    );
    if (onCopy == null) return row;
    return Tooltip(
      message: 'Click to copy',
      child: InkWell(
        onTap: onCopy,
        borderRadius: BorderRadius.circular(4),
        child: row,
      ),
    );
  }
}

class _JobsChip extends StatelessWidget {
  final int count;
  final bool expanded;
  const _JobsChip({required this.count, this.expanded = false});

  @override
  Widget build(BuildContext context) {
    final has = count > 0;
    final label = expanded ? '$count ${count == 1 ? 'job' : 'jobs'}' : '$count';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: has ? _C.primarySoft : _C.subtle,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.work_outline_rounded,
              size: 13, color: has ? _C.primary : _C.muted),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: has ? _C.primary : _C.muted)),
        ],
      ),
    );
  }
}

class _Money extends StatelessWidget {
  final num amount;
  const _Money({required this.amount});

  @override
  Widget build(BuildContext context) {
    final has = amount > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: has ? _C.moneySoft : _C.subtle,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        _fmtMoney(amount),
        style: TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w700,
          color: has ? _C.money : _C.muted,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _StateMessage extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _StateMessage({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.08),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 32, color: iconColor),
              ),
              const SizedBox(height: 16),
              Text(title,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700, color: _C.ink)),
              const SizedBox(height: 6),
              Text(message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 13.5, color: _C.muted, height: 1.4)),
              if (actionLabel != null) ...[
                const SizedBox(height: 16),
                FilledButton.tonal(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}