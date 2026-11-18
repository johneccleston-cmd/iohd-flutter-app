import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'config/access.dart';
import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'widgets/app_dialog.dart';
import 'widgets/app_ribbon.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';

/// Stock Levels: what is on the warehouse shelves right now, read live from the Inventory Google Sheet (backend
/// GET /get_full_inventory), which phone checkouts, scan checkouts and cycle counts update. Read-only.
///
/// A part's status follows the same rule as the Inventory dashboard and the Warehouse KPI page: low is at or below a
/// reorder point that has actually been set; out is a part with a reorder point and none on hand. A part with no reorder
/// point is one the warehouse doesn't keep a minimum of, so having none of it is not a warning ("Not kept in stock").
///
/// Filters sit in a sidebar like the Product Catalog (a Filters button and dialog when the window is too narrow).
class InventoryScreen extends StatefulWidget {
  /// Tests pass a fake list; the app loads the real one.
  final Future<List<StockItem>> Function()? loader;
  const InventoryScreen({super.key, this.loader});

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

/// Ordered by how much it needs attention: the default sort puts out of stock first.
enum StockStatus { out, low, ok, notStocked }

extension on StockStatus {
  String get label => switch (this) {
    StockStatus.out => 'Out of stock',
    StockStatus.low => 'Low stock',
    StockStatus.ok => 'In stock',
    StockStatus.notStocked => 'Not kept in stock',
  };

  Color get color => switch (this) {
    StockStatus.out => DashUi.redText,
    StockStatus.low => DashUi.amberText,
    StockStatus.ok => DashUi.emeraldText,
    StockStatus.notStocked => DashUi.slate,
  };
}

class StockItem {
  final String name;
  final String category;
  final String partNumber; // '' when the sheet has none
  final String location; // '' when the sheet has none
  final int qty;

  /// 0 = no reorder point set. Null = the server is older than the field (no reorder points to go by).
  final int? reorderPoint;

  const StockItem({
    required this.name,
    required this.category,
    this.partNumber = '',
    this.location = '',
    required this.qty,
    this.reorderPoint = 0,
  });

  static int? _int(Object? v) {
    if (v is num) return v.toInt();
    final s = '${v ?? ''}'.replaceAll(RegExp(r'[,\s]'), '');
    if (s.isEmpty) return null;
    return int.tryParse(s) ?? double.tryParse(s)?.toInt();
  }

  factory StockItem.fromJson(Map<String, dynamic> j) {
    final part = '${j['partNumber'] ?? ''}'.trim();
    final cat = '${j['category'] ?? ''}'.trim();
    return StockItem(
      name: '${j['name'] ?? ''}'.trim(),
      category: cat.isEmpty ? 'Uncategorized' : cat,
      partNumber: part.toUpperCase() == 'N/A' ? '' : part,
      location: '${j['location'] ?? ''}'.trim(),
      qty: _int(j['qty']) ?? 0,
      reorderPoint: j.containsKey('reorderPoint') ? math.max(0, _int(j['reorderPoint']) ?? 0) : null,
    );
  }

  StockStatus get status {
    final rp = reorderPoint ?? 0;
    if (rp > 0) {
      if (qty <= 0) return StockStatus.out;
      if (qty <= rp) return StockStatus.low;
      return StockStatus.ok;
    }
    return qty > 0 ? StockStatus.ok : StockStatus.notStocked;
  }
}

/// GET /get_full_inventory. Throws an Exception whose message is fit to show.
Future<List<StockItem>> fetchStockLevels() async {
  final http.Response res;
  try {
    res = await http
        .get(Uri.parse('$kApiBaseUrl/get_full_inventory'), headers: AuthSession.instance.headers())
        .timeout(const Duration(seconds: 20));
  } on TimeoutException {
    throw Exception('The server took too long to answer. Try again.');
  } catch (_) {
    throw Exception('Could not reach the server. Check your connection and try again.');
  }
  if (res.statusCode == 401) {
    AuthSession.instance.logout(); // sends the app back to the sign-in screen
    throw Exception('Your session expired. Please sign in again.');
  }
  if (res.statusCode != 200) throw Exception('Could not load stock levels (server error ${res.statusCode}).');
  final Object? data;
  try {
    data = jsonDecode(utf8.decode(res.bodyBytes));
  } catch (_) {
    throw Exception('The server sent stock levels the app could not read.');
  }
  if (data is! List) throw Exception('The server sent stock levels the app could not read.');
  return [
    for (final e in data)
      if (e is Map) StockItem.fromJson(Map<String, dynamic>.from(e)),
  ]
      // The sheet's header row ("Part Name") came through as an item before the server skipped it.
      .where((i) => i.name.isNotEmpty && i.name.toLowerCase() != 'part name')
      .toList();
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------
class _InventoryScreenState extends State<InventoryScreen> with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  @override
  bool get wantKeepAlive => true;

  static const _sidebarWidth = 264.0;
  static const _tableWidth = 900.0; // below this the rows stack
  static const _sorts = [
    ('status', 'Status'),
    ('name', 'Part'),
    ('part', 'Part #'),
    ('location', 'Location'),
    ('category', 'Category'),
    ('qty', 'On hand'),
    ('reorder', 'Reorder at'),
  ];

  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _activity = RibbonActivity();
  final _filterTick = ValueNotifier<int>(0); // tells the Filters dialog (narrow windows) to redraw
  late final _rowsIn = AnimationController(vsync: this, duration: const Duration(milliseconds: 460), value: 1);
  Timer? _slowTimer;
  Timer? _debounce;

  List<StockItem> _all = const [];
  bool _loading = true;
  bool _slow = false;
  String? _error;

  String _query = '';
  String _sortKey = 'status';
  bool _ascending = true;
  int _page = 1;
  int _pageSize = 50;

  final Set<StockStatus> _statuses = {};
  final Set<String> _cats = {};

  static final _count = NumberFormat.decimalPattern();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    _filterTick.dispose();
    _rowsIn.dispose();
    _activity.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final first = _all.isEmpty;
    setState(() {
      _loading = first;
      _error = null;
      _slow = false;
    });
    _slowTimer?.cancel();
    if (first) {
      _slowTimer = Timer(const Duration(seconds: 8), () {
        if (mounted && _loading) setState(() => _slow = true);
      });
    } else {
      _activity.setRefreshing(true);
    }
    try {
      final items = await (widget.loader ?? fetchStockLevels)();
      if (!mounted) return;
      setState(() {
        _all = items;
        _loading = false;
        _cats.removeWhere((c) => !_all.any((i) => i.category == c)); // a category that is gone cannot stay picked
      });
      _filterTick.value++;
      _activity.landed();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e'.replaceFirst('Exception: ', '');
      });
    } finally {
      _slowTimer?.cancel();
      _activity.setRefreshing(false);
    }
  }

  // ---- derived data ---------------------------------------------------------

  /// False until the server sends reorder points (an older backend): statuses can't say low or out then.
  bool get _hasReorder => _all.any((i) => i.reorderPoint != null);

  int _statusCount(StockStatus s) => _all.where((i) => i.status == s).length;

  List<(String, int)> get _categoryCounts {
    final counts = <String, int>{};
    for (final i in _all) {
      counts[i.category] = (counts[i.category] ?? 0) + 1;
    }
    final names = counts.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return [for (final n in names) (n, counts[n]!)];
  }

  List<StockItem> get _shown {
    final words = _query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final list = _all.where((i) {
      if (_statuses.isNotEmpty && !_statuses.contains(i.status)) return false;
      if (_cats.isNotEmpty && !_cats.contains(i.category)) return false;
      if (words.isEmpty) return true;
      final hay = '${i.name} ${i.partNumber} ${i.location} ${i.category}'.toLowerCase();
      return words.every(hay.contains);
    }).toList();
    int text(String a, String b) {
      // Blanks last whichever way the column is read.
      if (a.isEmpty != b.isEmpty) return a.isEmpty ? (_ascending ? 1 : -1) : (_ascending ? -1 : 1);
      return a.toLowerCase().compareTo(b.toLowerCase());
    }

    int cmp(StockItem a, StockItem b) => switch (_sortKey) {
      'name' => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      'part' => text(a.partNumber, b.partNumber),
      'location' => text(a.location, b.location),
      'category' => a.category.toLowerCase().compareTo(b.category.toLowerCase()),
      'qty' => a.qty.compareTo(b.qty),
      'reorder' => (a.reorderPoint ?? 0).compareTo(b.reorderPoint ?? 0),
      // Needs attention first; within a status, the fewest on hand first.
      _ => a.status.index != b.status.index ? a.status.index.compareTo(b.status.index) : a.qty.compareTo(b.qty),
    };
    list.sort((a, b) {
      final c = _ascending ? cmp(a, b) : cmp(b, a);
      return c != 0 ? c : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  int get _filterCount => (_statuses.isEmpty ? 0 : 1) + (_cats.isEmpty ? 0 : 1);

  /// A new list (another sort, search, filter or page): read from its top, rows settling in.
  void _newView(VoidCallback change) {
    setState(change);
    _filterTick.value++;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (MediaQuery.disableAnimationsOf(context)) {
      _rowsIn.value = 1;
    } else {
      _rowsIn.forward(from: 0);
    }
  }

  void _sort(String key) => _newView(() {
    if (_sortKey == key) {
      _ascending = !_ascending;
    } else {
      _sortKey = key;
      // Text and status read top-down first; quantities biggest first.
      _ascending = !(key == 'qty' || key == 'reorder');
    }
    _page = 1;
  });

  void _toggle<T>(Set<T> group, T value) => _newView(() {
    if (!group.remove(value)) group.add(value);
    _page = 1;
  });

  void _resetFilters() => _newView(() {
    _statuses.clear();
    _cats.clear();
    _page = 1;
  });

  void _clearAll() {
    _debounce?.cancel();
    _search.clear();
    _query = '';
    _resetFilters();
  }

  void _applyQuery(String v) {
    final q = v.trim();
    if (q == _query) return;
    _newView(() {
      _query = q;
      _page = 1;
    });
  }

  void _clearSearch() {
    _debounce?.cancel();
    _search.clear();
    _applyQuery('');
    setState(() {});
  }

  // ---- table ----------------------------------------------------------------

  List<FlatCol> get _cols => [
    const FlatCol('Part', flex: 7, sortKey: 'name'),
    const FlatCol('Part #', flex: 3, sortKey: 'part'),
    const FlatCol('Location', flex: 2, sortKey: 'location'),
    const FlatCol('Category', flex: 4, sortKey: 'category'),
    const FlatCol('On hand', flex: 3, right: true, sortKey: 'qty'),
    if (_hasReorder) const FlatCol('Reorder at', flex: 3, right: true, sortKey: 'reorder'),
    const FlatCol('Status', flex: 4, sortKey: 'status'),
  ];

  Widget _qtyText(StockItem i) {
    final attention = i.status == StockStatus.out || i.status == StockStatus.low;
    return Text(
      _count.format(i.qty),
      style: (attention ? flatCellBold.copyWith(color: i.status.color) : (i.qty > 0 ? flatCellStyle : flatCellMuted))
          .copyWith(fontFeatures: flatFigures),
    );
  }

  Widget _reorderText(StockItem i) {
    final rp = i.reorderPoint ?? 0;
    return Text(rp > 0 ? _count.format(rp) : '—', style: (rp > 0 ? flatCellStyle : flatCellMuted).copyWith(fontFeatures: flatFigures));
  }

  /// FlatStatus's dot and label, but the label wraps rather than overflowing a narrow column.
  Widget _statusText(StockItem i) {
    final (label, color) = _hasReorder
        ? (i.status.label, i.status.color)
        : (i.qty > 0 ? 'In stock' : 'None on hand', i.qty > 0 ? DashUi.emeraldText : DashUi.slate);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Flexible(
          child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color)),
        ),
      ],
    );
  }

  Widget _muted(String s) => Text(s.isEmpty ? '—' : s, maxLines: 1, overflow: TextOverflow.ellipsis, style: flatCellMuted);

  List<Widget> _cells(StockItem i) => [
    Text(i.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: flatCellBold),
    _muted(i.partNumber),
    _muted(i.location),
    Text(i.category, maxLines: 2, overflow: TextOverflow.ellipsis, style: flatCellStyle),
    _qtyText(i),
    if (_hasReorder) _reorderText(i),
    _statusText(i),
  ];

  /// A row too narrow for the columns: the part and its status first, then part #, location and category, then counts.
  Widget _compactRow(StockItem i, int index) {
    final meta = [
      if (i.partNumber.isNotEmpty) 'Part # ${i.partNumber}',
      if (i.location.isNotEmpty) 'Shelf ${i.location}',
      i.category,
    ].join('  ·  ');
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(i.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: flatCellBold)),
              const SizedBox(width: 12),
              _statusText(i),
            ],
          ),
          const SizedBox(height: 4),
          Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: flatCellMuted),
          const SizedBox(height: 4),
          Wrap(
            spacing: 16,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [const Text('On hand ', style: flatCellMuted), _qtyText(i)]),
              if (_hasReorder)
                Row(mainAxisSize: MainAxisSize.min, children: [const Text('Reorder at ', style: flatCellMuted), _reorderText(i)]),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(StockItem i, int index, bool compact, List<FlatCol> cols) {
    final rp = i.reorderPoint ?? 0;
    return Semantics(
      label: '${i.name}, ${_count.format(i.qty)} on hand${rp > 0 ? ', reorder at ${_count.format(rp)}' : ''}, ${i.status.label}',
      excludeSemantics: true,
      child: compact ? _compactRow(i, index) : FlatTableRow(columns: cols, cells: _cells(i), index: index, striped: true),
    );
  }

  // ---- filters --------------------------------------------------------------

  /// A pick-any-number row: a check box, an optional status dot, the name and how many parts it holds.
  Widget _checkRow(String label, int count, bool selected, VoidCallback onTap, {Color? dot}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Semantics(
        button: true,
        checked: selected,
        label: '$label, ${_count.format(count)}',
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          hoverColor: DashUi.faint,
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: selected ? DashUi.ink.withValues(alpha: 0.06) : Colors.transparent, borderRadius: BorderRadius.circular(10)),
            child: Row(
              children: [
                Icon(
                  selected ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                  size: 20,
                  color: selected ? DashUi.ink : DashUi.slate,
                ),
                const SizedBox(width: 10),
                if (dot != null) ...[
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, fontWeight: selected ? FontWeight.w800 : FontWeight.w600, color: DashUi.ink),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _count.format(count),
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: selected ? DashUi.ink : DashUi.slate, fontFeatures: flatFigures),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _filterGroup(String title, Widget child, {String? caption}) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 10, 8, 2),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
          child: Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: DashUi.ink)),
        ),
        child,
        if (caption != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 4, 4),
            child: Text(caption, style: const TextStyle(fontSize: 12.5, height: 1.35, color: DashUi.slate)),
          ),
      ],
    ),
  );

  Widget _filterGroups() {
    final cats = _categoryCounts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_hasReorder)
          _filterGroup(
            'Stock status',
            Column(
              children: [
                for (final s in StockStatus.values)
                  _checkRow(s.label, _statusCount(s), _statuses.contains(s), () => _toggle(_statuses, s), dot: s.color),
              ],
            ),
            caption: 'Low is at or below the part\'s reorder point. A part with no reorder point isn\'t kept in stock, '
                'so having none of it isn\'t counted as out.',
          ),
        _filterGroup(
          'Category',
          // Every category in the sidebar's own scroll (no box scrolling inside it).
          Column(children: [for (final (name, n) in cats) _checkRow(name, n, _cats.contains(name), () => _toggle(_cats, name))]),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _clearFiltersButton() => TextButton(
    onPressed: _filterCount == 0 ? null : _resetFilters,
    style: TextButton.styleFrom(foregroundColor: DashUi.ink, padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(0, 32)),
    child: const Text('Clear all', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
  );

  Widget _filterSidebar() {
    return Container(
      decoration: const BoxDecoration(border: Border(right: BorderSide(color: DashUi.line))),
      child: SelectionContainer.disabled(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Filters', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: DashUi.ink)),
                  ),
                  _clearFiltersButton(),
                ],
              ),
            ),
            const Divider(height: 1, color: DashUi.line),
            Expanded(child: SingleChildScrollView(child: _filterGroups())),
          ],
        ),
      ),
    );
  }

  /// The Filters button and its dialog, for windows too narrow for the sidebar.
  Widget _filterButton() {
    final n = _filterCount;
    return SelectionContainer.disabled(
      child: Semantics(
        button: true,
        label: n == 0 ? 'Filters' : 'Filters, $n set',
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => showDialog<void>(
            context: context,
            builder: (ctx) => AppDialog(
              title: 'Filters',
              icon: accessIcon('stock'),
              width: 420,
              body: ValueListenableBuilder<int>(
                valueListenable: _filterTick,
                builder: (_, _, _) => SingleChildScrollView(child: _filterGroups()),
              ),
              actions: [
                AppButton.ghost('Clear all', _resetFilters),
                AppButton.ink('Done', () => Navigator.pop(ctx)),
              ],
            ),
          ),
          child: Container(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: DashUi.line)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.filter_list_rounded, size: 18, color: DashUi.slate),
                const SizedBox(width: 8),
                const Text('Filters', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink)),
                if (n > 0) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                    decoration: BoxDecoration(color: DashUi.ink, borderRadius: BorderRadius.circular(10)),
                    child: Text('$n', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- list -----------------------------------------------------------------

  /// "445 parts · 4,411 units on hand", or what the search and filters left.
  String _countLabel(List<StockItem> shown) {
    final units = shown.fold<int>(0, (s, i) => s + (i.qty > 0 ? i.qty : 0));
    final filtered = _query.isNotEmpty || _filterCount > 0;
    final parts = filtered ? '${_count.format(shown.length)} matching' : (shown.length == 1 ? '1 part' : '${_count.format(shown.length)} parts');
    return '$parts  ·  ${_count.format(units)} ${units == 1 ? 'unit' : 'units'} on hand';
  }

  Widget _toolbar(bool compact, bool filterButton, List<StockItem> shown) {
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
              controller: _search,
              style: const TextStyle(fontSize: 14),
              textInputAction: TextInputAction.search,
              decoration: flatSearchDecoration(
                'Search part, part #, shelf or category',
                onClear: _search.text.isEmpty ? null : _clearSearch,
              ),
              onSubmitted: (v) {
                _debounce?.cancel();
                _applyQuery(v);
              },
              onChanged: (v) {
                setState(() {}); // the clear button comes and goes with the text
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 250), () {
                  if (mounted) _applyQuery(v);
                });
              },
            ),
          ),
          if (filterButton) _filterButton(),
          if (compact) _sortMenu(),
          Semantics(liveRegion: true, child: Text(_countLabel(shown), style: flatCellMuted)),
        ],
      ),
    );
  }

  Widget _sortMenu() {
    final cols = _sorts.where((s) => _hasReorder || s.$1 != 'reorder').toList();
    final label = cols.firstWhere((s) => s.$1 == _sortKey, orElse: () => cols.first).$2;
    return SelectionContainer.disabled(
      child: PopupMenuButton<String>(
        tooltip: 'Sort',
        position: PopupMenuPosition.under,
        onSelected: _sort,
        itemBuilder: (_) => [
          for (final (key, name) in cols)
            PopupMenuItem(
              value: key,
              child: Row(
                children: [
                  Expanded(
                    child: Text(name, style: TextStyle(fontWeight: _sortKey == key ? FontWeight.w700 : FontWeight.w500, color: DashUi.ink)),
                  ),
                  if (_sortKey == key)
                    Icon(_ascending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 16, color: DashUi.ink),
                ],
              ),
            ),
        ],
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: DashUi.line)),
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

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageBanner(
            title: 'Stock Levels',
            icon: accessIcon('stock'),
            activity: _activity,
            actions: [RibbonRefreshButton(onPressed: _loading ? null : _load)],
          ),
          Expanded(
            child: PageSheet(child: LayoutBuilder(builder: (context, c) => _body(c.maxWidth))),
          ),
        ],
      ),
    );
  }

  Widget _body(double width) {
    final scale = MediaQuery.textScalerOf(context);
    final wide = width >= _sidebarWidth + scale.scale(_tableWidth);
    final cols = _cols;
    if (_loading) {
      return FlatLoading(label: 'Loading stock levels', flex: [for (final c in cols) c.flex], compact: width < scale.scale(_tableWidth), slow: _slow);
    }
    if (_error != null && _all.isEmpty) {
      return Center(
        child: FlatEmpty(
          icon: Icons.cloud_off_rounded,
          title: 'Could not load stock levels',
          message: _error!,
          action: AppButton.ink('Try again', _load),
        ),
      );
    }
    if (_all.isEmpty) {
      return Center(
        child: FlatEmpty(
          icon: Icons.inventory_2_outlined,
          title: 'No parts on the inventory sheet',
          message: 'Parts appear here once they are added to the warehouse inventory sheet.',
          action: AppButton.ghost('Refresh', _load),
        ),
      );
    }
    if (!wide) return _listPane(filterButton: true);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: _sidebarWidth, child: _filterSidebar()),
        Expanded(child: _listPane(filterButton: false)),
      ],
    );
  }

  Widget _listPane({required bool filterButton}) {
    return LayoutBuilder(
      builder: (context, c) {
        final compact = c.maxWidth < MediaQuery.textScalerOf(context).scale(_tableWidth);
        final cols = _cols;
        final shown = _shown;
        final pages = shown.isEmpty ? 1 : (shown.length / _pageSize).ceil();
        final page = _page.clamp(1, pages);
        final start = (page - 1) * _pageSize;
        final rows = shown.skip(start).take(_pageSize).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: CustomScrollView(
                controller: _scroll,
                slivers: [
                  SliverToBoxAdapter(child: _toolbar(compact, filterButton, shown)),
                  if (_error != null)
                    SliverToBoxAdapter(child: FlatStaleNotice(message: '$_error The list below may be out of date.', busy: false, onRetry: _load)),
                  if (!_hasReorder)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(24, 0, 24, 12),
                        child: Text('Low and out of stock appear once the server sends each part\'s reorder point.', style: flatCellMuted),
                      ),
                    ),
                  if (shown.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: FlatEmpty(
                          icon: Icons.search_off_rounded,
                          title: _query.isEmpty ? 'No parts match' : 'No parts match "$_query"',
                          message: 'Try other words, or take off some filters.',
                          action: AppButton.ghost('Clear search and filters', _clearAll),
                        ),
                      ),
                    )
                  else ...[
                    if (!compact)
                      PinnedHeaderSliver(
                        child: FlatTableHeader(
                          columns: cols,
                          striped: true,
                          sortKey: _sortKey,
                          ascending: _ascending,
                          onSort: _sort,
                        ),
                      ),
                    SliverList.builder(
                      itemCount: rows.length,
                      itemBuilder: (_, i) => flatRowEntrance(_rowsIn, i, _row(rows[i], i, compact, cols)),
                    ),
                  ],
                ],
              ),
            ),
            if (shown.isNotEmpty)
              FlatPager(
                page: page,
                totalPages: pages,
                total: shown.length,
                firstRow: start + 1,
                rowsShown: rows.length,
                pageSize: _pageSize,
                busy: false,
                compact: compact,
                onPage: (p) => _newView(() => _page = p),
                onPageSize: (s) => _newView(() {
                  _pageSize = s;
                  _page = 1;
                }),
              ),
          ],
        );
      },
    );
  }
}
