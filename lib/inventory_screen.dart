import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'config/access.dart';
import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'widgets/app_dialog.dart';
import 'widgets/app_ribbon.dart';
import 'widgets/catalog_kit.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';
import 'widgets/page_selection.dart';
import 'theme/app_theme.dart';

/// Stock Levels: what is on the warehouse shelves right now, read live from the Inventory Google Sheet (backend
/// GET /get_full_inventory), which phone checkouts, scan checkouts and cycle counts update. Read-only.
///
/// A part's status follows the same rule as the Inventory dashboard and the Warehouse KPI page: low is at or below a
/// reorder point that has actually been set; out is a part with a reorder point and none on hand. A part with no reorder
/// point is one the warehouse doesn't keep a minimum of, so having none of it is not a warning ("Not kept in stock").
///
/// The page is laid out like the Product Catalog (widgets/catalog_kit.dart): a command row with search, filter chips and the
/// count over a header-and-stripes table; collapsed filter groups in a sidebar (a Filters button and dialog when the window
/// is too narrow); a footer pager.
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
  bool _sidebarHidden = false;
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

  /// The columns for a table [width] wide: the part takes what the fixed columns leave.
  List<CatalogCol> _cols(double width) {
    final roomy = width >= 1150; // under it the fixed columns tighten so part names keep to fewer lines
    return [
      const CatalogCol('PART', sortKey: 'name'),
      CatalogCol('PART #', width: roomy ? 112 : 92, sortKey: 'part'),
      CatalogCol('LOCATION', width: roomy ? 96 : 84, sortKey: 'location'),
      CatalogCol('CATEGORY', width: roomy ? 196 : 150, sortKey: 'category'),
      CatalogCol('ON HAND', width: roomy ? 84 : 78, right: true, sortKey: 'qty'),
      if (_hasReorder) CatalogCol('REORDER AT', width: roomy ? 104 : 96, right: true, sortKey: 'reorder'),
      CatalogCol('STATUS', width: roomy ? 150 : 136, sortKey: 'status'),
    ];
  }

  Widget _qtyText(StockItem i) {
    final attention = i.status == StockStatus.out || i.status == StockStatus.low;
    return Text(
      _count.format(i.qty),
      maxLines: 1,
      style: attention ? CatalogUi.cellStrong.copyWith(color: i.status.color) : (i.qty > 0 ? CatalogUi.cell : CatalogUi.cellQuiet),
    );
  }

  Widget _reorderText(StockItem i) {
    final rp = i.reorderPoint ?? 0;
    return Text(rp > 0 ? _count.format(rp) : '—', maxLines: 1, style: rp > 0 ? CatalogUi.cell : CatalogUi.cellQuiet);
  }

  /// A status dot and label; the label wraps rather than overflowing a narrow column.
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
          child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: color)),
        ),
      ],
    );
  }

  Widget _quiet(String s) => Text(s.isEmpty ? '—' : s, maxLines: 1, overflow: TextOverflow.ellipsis, style: CatalogUi.cellQuiet);

  List<Widget> _cells(StockItem i) => [
    Text(i.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: CatalogUi.name),
    _quiet(i.partNumber),
    _quiet(i.location),
    Text(i.category, maxLines: 1, overflow: TextOverflow.ellipsis, style: CatalogUi.cell),
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
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      color: index.isOdd ? CatalogUi.stripe : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(i.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: CatalogUi.name)),
              const SizedBox(width: 12),
              _statusText(i),
            ],
          ),
          const SizedBox(height: 4),
          Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: CatalogUi.meta),
          const SizedBox(height: 4),
          Wrap(
            spacing: 16,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [const Text('On hand ', style: CatalogUi.meta), _qtyText(i)]),
              if (_hasReorder) Row(mainAxisSize: MainAxisSize.min, children: [const Text('Reorder at ', style: CatalogUi.meta), _reorderText(i)]),
            ],
          ),
        ],
      ),
    );
  }

  /// One part's row: the catalog's stripes and rhythm, but nothing to open (so no hover arrow).
  Widget _row(StockItem i, int index, bool compact, List<CatalogCol> cols) {
    final rp = i.reorderPoint ?? 0;
    return Semantics(
      label: '${i.name}, ${_count.format(i.qty)} on hand${rp > 0 ? ', reorder at ${_count.format(rp)}' : ''}, ${i.status.label}',
      excludeSemantics: true,
      child: SelectionContainer.disabled(
        child: compact
            ? _compactRow(i, index)
            : Container(
                constraints: const BoxConstraints(minHeight: CatalogUi.rowHeight),
                padding: const EdgeInsets.symmetric(horizontal: CatalogUi.side, vertical: 8),
                color: index.isOdd ? CatalogUi.stripe : Colors.white,
                child: CatalogCells(cols: cols, cells: _cells(i)),
              ),
      ),
    );
  }

  // ---- filters --------------------------------------------------------------

  /// All the filters, collapsed until opened. The sidebar scrolls them as one; the narrow window's dialog shows the same.
  Widget _filterGroups() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_hasReorder)
          CatalogFilterGroup(
            title: 'Stock status',
            initiallyOpen: false,
            picked: _statuses.length,
            child: Column(
              children: [
                for (final s in StockStatus.values)
                  CatalogCheckRow(label: s.label, count: _statusCount(s), selected: _statuses.contains(s), onTap: () => _toggle(_statuses, s), dot: s.color),
              ],
            ),
          ),
        CatalogFilterGroup(
          title: 'Category',
          initiallyOpen: false,
          picked: _cats.length,
          child: Column(
            children: [for (final (name, n) in _categoryCounts) CatalogCheckRow(label: name, count: n, selected: _cats.contains(name), onTap: () => _toggle(_cats, name))],
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _filterSidebar() {
    return Container(
      decoration: const BoxDecoration(border: Border(right: BorderSide(color: DashUi.line))),
      // Not selectable text: the app-wide selection's I-beam would replace the click cursor.
      child: SelectionContainer.disabled(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // As tall as the command row beside it, so the two hairlines run as one.
            Container(
              height: CatalogUi.commandHeight,
              padding: const EdgeInsets.fromLTRB(20, 0, 10, 0),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: DashUi.line))),
              child: Row(
                children: [
                  const Icon(Icons.tune_rounded, size: 18, color: DashUi.slate),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Filters', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: DashUi.ink)),
                  ),
                  AnimatedOpacity(
                    opacity: _filterCount == 0 ? 0 : 1,
                    duration: CatalogUi.motion(context),
                    child: TextButton(
                      onPressed: _filterCount == 0 ? null : _resetFilters,
                      style: TextButton.styleFrom(foregroundColor: DashUi.ink, padding: const EdgeInsets.symmetric(horizontal: 10), minimumSize: const Size(0, 32)),
                      child: const Text('Clear all', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Hide filters',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() => _sidebarHidden = true),
                    icon: const Icon(Icons.keyboard_double_arrow_left_rounded, size: 18, color: DashUi.slate),
                  ),
                ],
              ),
            ),
            Expanded(child: SingleChildScrollView(padding: const EdgeInsets.only(top: 6), child: _filterGroups())),
          ],
        ),
      ),
    );
  }

  static final ButtonStyle _outlined = OutlinedButton.styleFrom(
    minimumSize: const Size(0, 38),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    foregroundColor: DashUi.ink,
    backgroundColor: Colors.white,
    side: const BorderSide(color: DashUi.line),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    textStyle: const TextStyle(fontFamily: AppTheme.fontFamily, fontFamilyFallback: AppTheme.fontFamilyFallback, fontSize: 13.5, fontWeight: FontWeight.w700),
  );

  /// The Filters button: on a window too narrow for the sidebar it opens the filters in a dialog; where the sidebar
  /// fits but was hidden, it brings the sidebar back.
  Widget _filterButton({bool reopensSidebar = false}) {
    final n = _filterCount;
    return SelectionContainer.disabled(
      child: Semantics(
        button: true,
        label: n == 0 ? 'Filters' : 'Filters, $n set',
        excludeSemantics: true,
        child: OutlinedButton(
          onPressed: reopensSidebar
              ? () => setState(() => _sidebarHidden = false)
              : () => showDialog<void>(
                  context: context,
                  builder: (ctx) => AppDialog(
                    title: 'Filters',
                    icon: accessIcon('stock'),
                    width: 420,
                    body: ValueListenableBuilder<int>(
                      valueListenable: _filterTick,
                      builder: (_, _, _) => SingleChildScrollView(child: _filterGroups()),
                    ),
                    actions: [AppButton.ghost('Clear all', _resetFilters), AppButton.ink('Done', () => Navigator.pop(ctx))],
                  ),
                ),
          style: _outlined,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.tune_rounded, size: 18, color: DashUi.slate),
              const SizedBox(width: 8),
              const Text('Filters'),
              if (n > 0) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(color: DashUi.ink, borderRadius: BorderRadius.circular(999)),
                  child: Text('$n', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The filters that are on, each one a chip that takes it off.
  List<({String group, String value, VoidCallback remove})> get _chips => [
    for (final s in StockStatus.values)
      if (_statuses.contains(s)) (group: 'Status', value: s.label, remove: () => _toggle(_statuses, s)),
    for (final c in _cats.toList()..sort()) (group: 'Category', value: c, remove: () => _toggle(_cats, c)),
  ];

  // ---- list -----------------------------------------------------------------

  Widget _countLabel(int shown) {
    final filtered = _query.isNotEmpty || _filterCount > 0;
    const strong = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink, fontFeatures: CatalogUi.figures);
    return Semantics(
      liveRegion: true,
      child: filtered
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${_count.format(shown)} matching', style: strong),
                Text(' of ${_count.format(_all.length)}', style: const TextStyle(fontSize: 13.5, color: DashUi.slate, fontFeatures: CatalogUi.figures)),
              ],
            )
          : Text(shown == 1 ? '1 part' : '${_count.format(shown)} parts', style: strong.copyWith(color: DashUi.slate, fontWeight: FontWeight.w600)),
    );
  }

  Widget _searchBox() {
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _clearSearch},
      child: CatalogSearchField(
        controller: _search,
        hint: 'Search part, part #, shelf or category',
        onClear: _search.text.isEmpty ? null : _clearSearch,
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
    );
  }

  /// The command row: search, the filters that are on, the count. One 52 px line; on a phone-narrow pane the chips go under it.
  Widget _commandRow({required bool filterButton, required bool compact, required int shown, required double width, bool reopensSidebar = false}) {
    final chips = _chips;
    final small = width < 640;
    final searchWidth = (width * 0.34).clamp(260.0, 440.0);
    final line = Row(
      children: [
        if (small) Expanded(child: _searchBox()) else SizedBox(width: searchWidth, child: _searchBox()),
        if (filterButton) ...[const SizedBox(width: 10), _filterButton(reopensSidebar: reopensSidebar)],
        if (compact) ...[const SizedBox(width: 8), _sortMenu()],
        if (!small) ...[const SizedBox(width: 14), Expanded(child: CatalogChipStrip(chips: chips)), const SizedBox(width: 14), _countLabel(shown)],
      ],
    );
    return Container(
      decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: DashUi.line))),
      padding: EdgeInsets.symmetric(horizontal: compact ? 12 : CatalogUi.side),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: CatalogUi.commandHeight, child: line),
          if (small)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _countLabel(shown),
                  for (final c in chips) CatalogFilterChip(key: ValueKey('${c.group}:${c.value}'), group: c.group, value: c.value, onRemove: c.remove),
                ],
              ),
            ),
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
              height: 40,
              child: Row(
                children: [
                  Expanded(
                    child: Text(name, style: TextStyle(fontWeight: _sortKey == key ? FontWeight.w700 : FontWeight.w500, color: DashUi.ink)),
                  ),
                  if (_sortKey == key) Icon(_ascending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 16, color: DashUi.ink),
                ],
              ),
            ),
        ],
        child: ClickCursor(child: Container(
          height: 38,
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
        )),
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
    // Larger text needs the room too, so the sidebar and the columns give way sooner.
    final wide = width >= CatalogUi.sidebarWidth + scale.scale(_tableWidth);
    if (_loading) return _loadingView(width, wide);
    if (_error != null && _all.isEmpty) {
      return Center(
        child: FlatEmpty(icon: Icons.cloud_off_rounded, title: 'Could not load stock levels', message: _error!, action: AppButton.ink('Try again', _load)),
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
    if (_sidebarHidden) return _listPane(filterButton: true, reopensSidebar: true);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // One traversal group each, so Tab finishes the filters before the table (it zig-zagged by height between them).
        SizedBox(width: CatalogUi.sidebarWidth, child: FocusTraversalGroup(child: _filterSidebar())),
        Expanded(child: FocusTraversalGroup(child: _listPane(filterButton: false))),
      ],
    );
  }

  /// Loading: the page's own frame with pulsing rows, so nothing jumps when the list lands.
  Widget _loadingView(double width, bool wide) {
    final listWidth = wide ? width - CatalogUi.sidebarWidth : width;
    final table = listWidth >= _tableWidth;
    // Stacked rows on a narrow window: one placeholder column, not the table's fixed ones.
    final cols = table ? _cols(listWidth) : const [CatalogCol('PART')];
    final pane = Semantics(
      label: 'Loading stock levels',
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: CatalogUi.commandHeight,
            padding: const EdgeInsets.symmetric(horizontal: CatalogUi.side),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: DashUi.line))),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: DashUi.slate)),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    _slow ? 'Still loading. The server can take a moment when it has just started.' : 'Loading stock levels',
                    style: CatalogUi.meta.copyWith(fontSize: 13.5),
                  ),
                ),
              ],
            ),
          ),
          if (table) CatalogTableHeader(cols: cols, sortKey: _sortKey, ascending: _ascending, onSort: (_) {}),
          Expanded(
            child: ClipRect(
              child: OverflowBox(alignment: Alignment.topCenter, maxHeight: double.infinity, child: CatalogSkeleton(cols: cols, rows: 24)),
            ),
          ),
        ],
      ),
    );
    if (!wide) return pane;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: CatalogUi.sidebarWidth,
          decoration: const BoxDecoration(border: Border(right: BorderSide(color: DashUi.line))),
          alignment: Alignment.topLeft,
          child: Container(
            height: CatalogUi.commandHeight,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: DashUi.line))),
            child: const Row(
              children: [
                Icon(Icons.tune_rounded, size: 18, color: DashUi.slate),
                SizedBox(width: 8),
                Text('Filters', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: DashUi.ink)),
              ],
            ),
          ),
        ),
        Expanded(child: pane),
      ],
    );
  }

  Widget _listPane({required bool filterButton, bool reopensSidebar = false}) {
    return LayoutBuilder(
      builder: (context, c) {
        final compact = c.maxWidth < MediaQuery.textScalerOf(context).scale(_tableWidth);
        final shown = _shown;
        final pages = shown.isEmpty ? 1 : (shown.length / _pageSize).ceil();
        final page = _page.clamp(1, pages);
        final start = (page - 1) * _pageSize;
        final rows = shown.skip(start).take(_pageSize).toList();
        final cols = _cols(c.maxWidth);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _commandRow(filterButton: filterButton, compact: compact, shown: shown.length, width: c.maxWidth, reopensSidebar: reopensSidebar),
            if (_error != null) FlatStaleNotice(message: '$_error The list below may be out of date.', busy: false, onRetry: _load),
            if (!_hasReorder)
              const Padding(
                padding: EdgeInsets.fromLTRB(CatalogUi.side, 10, CatalogUi.side, 4),
                child: Text('Low and out of stock appear once the server sends each part\'s reorder point.', style: CatalogUi.meta),
              ),
            if (shown.isEmpty)
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    child: FlatEmpty(
                      icon: Icons.search_off_rounded,
                      title: _query.isEmpty ? 'No parts match' : 'No parts match "$_query"',
                      message: 'Try other words, or take off some filters.',
                      action: AppButton.ghost('Clear search and filters', _clearAll),
                    ),
                  ),
                ),
              )
            else ...[
              if (!compact) CatalogTableHeader(key: const ValueKey('stock-header'), cols: cols, sortKey: _sortKey, ascending: _ascending, onSort: _sort),
              Expanded(
                child: ListView.builder(
                  controller: _scroll,
                  itemCount: rows.length,
                  itemBuilder: (_, i) => flatRowEntrance(_rowsIn, i, _row(rows[i], i, compact, cols)),
                ),
              ),
              CatalogPager(
                key: const ValueKey('stock-footer'),
                page: page,
                totalPages: pages,
                firstRow: start + 1,
                rowsShown: rows.length,
                pageSize: _pageSize,
                compact: compact,
                onPage: (p) => _newView(() => _page = p),
                onPageSize: (s) => _newView(() {
                  _pageSize = s;
                  _page = 1;
                }),
              ),
            ],
          ],
        );
      },
    );
  }
}
