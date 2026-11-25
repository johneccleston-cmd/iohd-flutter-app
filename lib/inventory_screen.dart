import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config/access.dart';
import 'config/auth_session.dart';
import 'purchase_orders_api.dart' show PurchaseOrder, PoLine;
import 'stock_levels_api.dart';
import 'stock_part_panel.dart';
import 'widgets/app_dialog.dart';
import 'widgets/app_ribbon.dart';
import 'widgets/catalog_kit.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';
import 'widgets/page_selection.dart';
import 'theme/app_theme.dart';

export 'stock_levels_api.dart';

/// Stock Levels: what is on the warehouse shelves right now, read live from the Inventory Google Sheet (backend
/// GET /get_full_inventory), which phone checkouts, scan checkouts, cycle counts and office corrections update.
///
/// A part's status follows the same rule as the Inventory dashboard and the Warehouse KPI page: low is at or below a
/// reorder point that has actually been set; out is a part with a reorder point and none on hand. A part with no reorder
/// point is one the warehouse doesn't keep a minimum of, so having none of it is "None on hand", not a warning. A count
/// below zero is always a warning ("Below zero").
///
/// Laid out like the Product Catalog (widgets/catalog_kit.dart): a command row (search, Needs attention, filter chips,
/// the count and when the Sheet was read) over a header-and-stripes table whose columns fit the window; filter groups in
/// a sidebar (a Filters button and dialog when the window is too narrow); a footer pager. A row opens the part's page
/// (stock_part_panel.dart): its history, copy buttons, the catalog link and, for admins, Change stock.
///
/// UI audit 2026-11-25 (docs/stock-levels-ui-audit-2026-11-25.md): the item numbers in the comments refer to it.
class InventoryScreen extends StatefulWidget {
  /// Tests pass a fake list; the app loads the real one.
  final Future<List<StockItem>> Function()? loader;

  /// Tests that need the Sheet's read time pass this instead.
  final Future<StockLoad> Function()? fullLoader;

  /// The address's query (F11): `view=attention`, `status=out|low`, `cat=Remote|Hardware`, `q=…`. The Inventory
  /// dashboard's "At or below reorder point" card opens `/inventory?view=attention`.
  final Map<String, String> link;

  /// Tests: saves an export instead of the file dialog; answers whether it was saved.
  final Future<bool> Function(String fileName, Uint8List bytes)? exporter;

  /// Tests: a part's history.
  final Future<StockHistory> Function(String name)? history;

  /// Tests: who may correct stock and start a purchase order (default: the signed-in person's rights).
  final bool? canAdjust;
  final bool? canOrder;

  const InventoryScreen({
    super.key,
    this.loader,
    this.fullLoader,
    this.link = const {},
    this.exporter,
    this.history,
    this.canAdjust,
    this.canOrder,
  });

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

// ---------------------------------------------------------------------------------------------------------------------
// Columns (L1, L5, A2): widths in pixels at 100% text that grow with the text size; the part name gets what is left, at
// least [_partMin] and at most [_partMax]. When the part would get less than its minimum, the least needed columns go
// first (To order, then Category, then Shelf; they stay in the part's page, the sort menu and the export); below that
// the rows stack. Past [_partMax] the spare room goes to Category and then to the end of the row.
// ---------------------------------------------------------------------------------------------------------------------

class _Col {
  final String key;
  final String label;
  final double width;
  final bool right;
  const _Col(this.key, this.label, this.width, {this.right = false});
}

const double _partMin = 280;
const double _partMax = 560;
const List<_Col> _allCols = [
  _Col('part', 'PART #', 100),
  _Col('location', 'SHELF', 72),
  _Col('category', 'CATEGORY', 170),
  _Col('qty', 'ON HAND', 84, right: true),
  _Col('reorder', 'REORDER POINT', 126, right: true),
  _Col('order', 'TO ORDER', 88, right: true),
  _Col('status', 'STATUS', 144),
];
const List<String> _dropOrder = ['order', 'category', 'location'];

class _Layout {
  final List<CatalogCol> cols;
  final List<String> keys; // column keys in order, 'name' first
  final Set<String> dropped;
  const _Layout(this.cols, this.keys, this.dropped);
}

class _InventoryScreenState extends State<InventoryScreen> with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  @override
  bool get wantKeepAlive => true;

  static const _sorts = [
    ('status', 'Status'),
    ('name', 'Part'),
    ('part', 'Part #'),
    ('location', 'Shelf'),
    ('category', 'Category'),
    ('qty', 'On hand'),
    ('reorder', 'Reorder point'),
    ('order', 'To order'),
  ];

  /// Reloads by itself when the list is older than this while the page is on screen (F2).
  static const _autoRefresh = Duration(minutes: 5);

  /// Past this, the count line turns amber and says how old the list is.
  static const _staleAfter = Duration(minutes: 15);

  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'stock search');
  final _catSearch = TextEditingController();
  final _scroll = ScrollController();
  final _activity = RibbonActivity();
  final _filterTick = ValueNotifier<int>(0); // tells the Filters dialog (narrow windows) to redraw
  bool _sidebarHidden = false;
  late final _rowsIn = AnimationController(vsync: this, duration: const Duration(milliseconds: 460), value: 1);
  Timer? _slowTimer;
  Timer? _debounce;
  Timer? _clock;

  List<StockItem> _all = const [];
  int _version = 0; // bumped on every new list, for the memo below
  bool _loading = true;
  bool _slow = false;
  String? _error;
  int _loads = 0; // F1: which load is the newest; an older answer that lands later is dropped
  int _inFlight = 0;
  DateTime? _loadedAt;
  DateTime? _sheetReadAt;
  bool _visible = true;

  String _query = '';
  String _sortKey = 'status';
  bool _ascending = true;
  int _page = 1;
  int _pageSize = 50;

  final Set<StockStatus> _statuses = {};
  final Set<String> _cats = {};

  static final _count = NumberFormat.decimalPattern();
  static final _money = NumberFormat.simpleCurrency(decimalDigits: 0);
  static final _time = DateFormat('h:mm a');

  bool get _busy => _inFlight > 0;
  bool get _canAdjust => widget.canAdjust ?? canAdjustStock;
  bool get _canOrder => widget.canOrder ?? AuthSession.instance.can('purchase_orders', AccessAction.create);

  @override
  void initState() {
    super.initState();
    _applyLink(widget.link);
    _restorePrefs();
    _load();
    HardwareKeyboard.instance.addHandler(_onKey);
    _clock = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
  }

  @override
  void didUpdateWidget(covariant InventoryScreen old) {
    super.didUpdateWidget(old);
    if (!mapEquals(old.link, widget.link)) _newView(() => _applyLink(widget.link));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // F2: back on this tab after another one: reload when the list is more than a minute old.
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible && !_visible && _age > const Duration(minutes: 1) && !_busy && _all.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
    _visible = visible;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _slowTimer?.cancel();
    _debounce?.cancel();
    _clock?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _catSearch.dispose();
    _scroll.dispose();
    _filterTick.dispose();
    _rowsIn.dispose();
    _activity.dispose();
    super.dispose();
  }

  // ---- links and remembered choices (F11, U12) ------------------------------------------------------------------------

  void _applyLink(Map<String, String> link) {
    if (link.isEmpty) return;
    _statuses.clear();
    _cats.clear();
    if (link['view'] == 'attention') _statuses.addAll(kAttention);
    for (final s in (link['status'] ?? '').split('|')) {
      final hit = StockStatus.values.where((v) => v.name == s.trim());
      if (hit.isNotEmpty) _statuses.add(hit.first);
    }
    for (final c in (link['cat'] ?? '').split('|')) {
      if (c.trim().isNotEmpty) _cats.add(c.trim());
    }
    final q = (link['q'] ?? '').trim();
    _search.text = q;
    _query = q;
    _page = 1;
  }

  Future<void> _restorePrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (!mounted) return;
      final sort = p.getString('stock.sort');
      setState(() {
        if (sort != null && _sorts.any((s) => s.$1 == sort)) _sortKey = sort;
        _ascending = p.getBool('stock.asc') ?? _ascending;
        final size = p.getInt('stock.pageSize');
        if (size == 50 || size == 100) _pageSize = size!;
        _sidebarHidden = p.getBool('stock.sidebarHidden') ?? false;
      });
    } catch (_) {
      // No saved choices (tests, or storage unavailable): the defaults stand.
    }
  }

  Future<void> _savePrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('stock.sort', _sortKey);
      await p.setBool('stock.asc', _ascending);
      await p.setInt('stock.pageSize', _pageSize);
      await p.setBool('stock.sidebarHidden', _sidebarHidden);
    } catch (_) {}
  }

  // ---- loading (F1, F2, F13) -----------------------------------------------------------------------------------------

  Duration get _age => _loadedAt == null ? Duration.zero : DateTime.now().difference(_sheetReadAt ?? _loadedAt!);

  /// Every 30 s: redraw the "read … ago" line when its minute changed, and reload when the list is old and on screen.
  void _tick() {
    if (!mounted || _all.isEmpty) return;
    final onScreen = TickerMode.valuesOf(context).enabled && (ModalRoute.of(context)?.isCurrent ?? true);
    if (onScreen && !_busy && _age >= _autoRefresh) {
      _load();
    } else {
      setState(() {});
    }
  }

  Future<StockLoad> _fetch() async {
    if (widget.fullLoader != null) return widget.fullLoader!();
    if (widget.loader != null) return StockLoad(await widget.loader!());
    return fetchStockLoad();
  }

  Future<void> _load() async {
    final ticket = ++_loads;
    final first = _all.isEmpty;
    _inFlight++;
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
      final got = await _fetch();
      if (!mounted || ticket != _loads) return; // a newer load was sent meanwhile: its answer wins
      final gone = _cats.where((c) => !got.items.any((i) => i.category == c)).toList();
      setState(() {
        _all = got.items;
        _version++;
        _loading = false;
        _loadedAt = DateTime.now();
        _sheetReadAt = got.sheetReadAt;
        _cats.removeAll(gone); // a category that is gone cannot stay picked
      });
      _filterTick.value++;
      _activity.landed();
      if (gone.isNotEmpty) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(gone.length == 1
              ? 'The category filter "${gone.first}" was taken off: no part is in it any more.'
              : '${gone.length} category filters were taken off: no part is in them any more.'),
        ));
      }
    } catch (e) {
      if (!mounted || ticket != _loads) return;
      setState(() {
        _loading = false;
        _error = e is StockApiError ? e.message : '$e'.replaceFirst('Exception: ', '');
      });
    } finally {
      _inFlight--;
      if (mounted && _inFlight == 0) {
        _slowTimer?.cancel();
        _activity.setRefreshing(false);
        setState(() {});
      }
    }
  }

  // ---- derived data (F3, F7, F8, F9, F12) ------------------------------------------------------------------------------

  /// False until the server sends reorder points (an older backend): statuses can't say low or out then.
  bool get _hasReorder => _all.isEmpty || _all.any((i) => i.reorderPoint != null);

  /// Whether this person gets costs from the server (Line Items & Costs > View).
  bool get _hasCost => _all.any((i) => i.cost != null);

  List<String> get _words => _query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

  bool _passes(StockItem i, {bool status = true, bool cats = true}) {
    if (status && _statuses.isNotEmpty && !_statuses.contains(i.status)) return false;
    if (cats && _cats.isNotEmpty && !_cats.contains(i.category)) return false;
    final words = _words;
    if (words.isEmpty) return true;
    final hay = i.searchText;
    return words.every(hay.contains);
  }

  String _memoKey = '';
  List<StockItem> _memoShown = const [];
  Map<StockStatus, int> _memoStatus = const {};
  List<(String, int)> _memoCats = const [];

  void _derive() {
    final key = '$_version|$_query|${_statuses.map((s) => s.index).toList()..sort()}|${_cats.toList()..sort()}|$_sortKey|$_ascending';
    if (key == _memoKey) return;
    _memoKey = key;
    // Each group's counts follow the search and the OTHER group's picks, so a count says what picking it would show (F3).
    final status = {for (final s in StockStatus.values) s: 0};
    final cats = <String, int>{};
    for (final c in _all.map((i) => i.category)) {
      cats[c] = 0;
    }
    final shown = <StockItem>[];
    for (final i in _all) {
      final inStatus = _passes(i, status: false);
      final inCats = _passes(i, cats: false);
      if (inStatus) status[i.status] = status[i.status]! + 1;
      if (inCats) cats[i.category] = cats[i.category]! + 1;
      if (inStatus && inCats && (_statuses.isEmpty || _statuses.contains(i.status))) shown.add(i);
    }
    final names = cats.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    _memoStatus = status;
    _memoCats = [for (final n in names) (n, cats[n]!)];

    int text(String a, String b) {
      // Blanks last whichever way the column is read.
      if (a.isEmpty != b.isEmpty) return a.isEmpty ? (_ascending ? 1 : -1) : (_ascending ? -1 : 1);
      return a.toLowerCase().compareTo(b.toLowerCase());
    }

    int byStatus(StockItem a, StockItem b) => a.status.index.compareTo(b.status.index);
    int cmp(StockItem a, StockItem b) => switch (_sortKey) {
      'name' => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      'part' => text(a.partNumber, b.partNumber),
      'location' => text(a.location, b.location),
      'category' => a.category.toLowerCase().compareTo(b.category.toLowerCase()),
      // Ties: the part that needs attention first (F7), so the out-of-stock parts don't hide among the 0s.
      'qty' => a.qty != b.qty ? a.qty.compareTo(b.qty) : (_ascending ? byStatus(a, b) : byStatus(b, a)),
      'reorder' => text((a.reorderPoint ?? 0) > 0 ? '${a.reorderPoint}'.padLeft(9, '0') : '', (b.reorderPoint ?? 0) > 0 ? '${b.reorderPoint}'.padLeft(9, '0') : ''),
      'order' => text(a.toOrder > 0 ? '${a.toOrder}'.padLeft(9, '0') : '', b.toOrder > 0 ? '${b.toOrder}'.padLeft(9, '0') : ''),
      // Needs attention first; within a status, the fewest on hand first.
      _ => a.status.index != b.status.index ? byStatus(a, b) : a.qty.compareTo(b.qty),
    };
    // The blank-last columns (F8) compare blanks the same way both directions, so they are not simply reversed.
    final blankAware = _sortKey == 'part' || _sortKey == 'location' || _sortKey == 'reorder' || _sortKey == 'order';
    shown.sort((a, b) {
      var c = blankAware ? _blankSafe(cmp, a, b) : (_ascending ? cmp(a, b) : cmp(b, a));
      if (c == 0 && _sortKey != 'status' && _sortKey != 'qty') c = byStatus(a, b);
      return c != 0 ? c : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    _memoShown = shown;
  }

  int _blankSafe(int Function(StockItem, StockItem) cmp, StockItem a, StockItem b) {
    String v(StockItem i) => switch (_sortKey) {
      'part' => i.partNumber,
      'location' => i.location,
      'reorder' => (i.reorderPoint ?? 0) > 0 ? 'x' : '',
      _ => i.toOrder > 0 ? 'x' : '',
    };
    final ea = v(a).isEmpty, eb = v(b).isEmpty;
    if (ea != eb) return ea ? 1 : -1;
    return _ascending ? cmp(a, b) : cmp(b, a);
  }

  List<StockItem> get _shown {
    _derive();
    return _memoShown;
  }

  int _statusCount(StockStatus s) {
    _derive();
    return _memoStatus[s] ?? 0;
  }

  List<(String, int)> get _categoryCounts {
    _derive();
    return _memoCats;
  }

  int get _attentionCount => kAttention.fold(0, (n, s) => n + _statusCount(s));
  /// On when the status filter is exactly the parts that need attention (Out and Low, Below zero or not).
  bool get _attentionOn => _statuses.containsAll(const {StockStatus.out, StockStatus.low}) && _statuses.every(kAttention.contains);
  bool get _anythingSet => _query.isNotEmpty || _statuses.isNotEmpty || _cats.isNotEmpty;
  int get _filterCount => (_statuses.isEmpty ? 0 : 1) + (_cats.isEmpty ? 0 : 1);

  // ---- changes ---------------------------------------------------------------------------------------------------------

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

  void _sort(String key) {
    _newView(() {
      if (_sortKey == key) {
        _ascending = !_ascending;
      } else {
        _sortKey = key;
        // Text and status read top-down first; quantities biggest first.
        _ascending = !(key == 'qty' || key == 'reorder' || key == 'order');
      }
      _page = 1;
    });
    _savePrefs();
  }

  void _toggle<T>(Set<T> group, T value) => _newView(() {
    if (!group.remove(value)) group.add(value);
    _page = 1;
  });

  void _toggleAttention() => _newView(() {
    final on = _attentionOn;
    _statuses.clear();
    if (!on) _statuses.addAll(kAttention);
    _page = 1;
  });

  /// Clear all (U6): the search and every filter, the same everywhere on the page.
  void _clearAll() {
    _debounce?.cancel();
    _search.clear();
    _newView(() {
      _query = '';
      _statuses.clear();
      _cats.clear();
      _page = 1;
    });
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
  }

  void _setSidebarHidden(bool v) {
    setState(() => _sidebarHidden = v);
    _savePrefs();
  }

  /// "/" jumps to the search box (F10), while this page is the one on screen and no text box has the keyboard.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.character != '/' || !mounted || _all.isEmpty) return false;
    if (!TickerMode.valuesOf(context).enabled) return false; // another tab of the app is showing
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false; // a dialog is on top
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null && (focused.widget is EditableText || focused.findAncestorWidgetOfExactType<EditableText>() != null)) return false;
    _searchFocus.requestFocus();
    return true;
  }

  Future<void> _openPart(StockItem i) async {
    final changed = await showStockPart(context, i, canAdjust: _canAdjust, history: widget.history);
    if (changed && mounted) _load();
  }

  void _showPart(String name) {
    _search.text = name;
    _newView(() {
      _query = name;
      _statuses.clear();
      _cats.clear();
      _page = 1;
    });
  }

  // ---- export, print, order (G3, G4, G6) -------------------------------------------------------------------------------

  void _snack(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(behavior: SnackBarBehavior.floating, content: Text(text)));

  String get _viewTitle => _attentionOn ? 'Stock that needs attention' : (_anythingSet ? 'Stock levels (filtered)' : 'Stock levels');

  String? get _viewNote {
    final parts = [
      if (_query.isNotEmpty) 'Search "$_query"',
      if (_statuses.isNotEmpty && !_attentionOn) 'Status: ${_statuses.map((s) => s.label).join(', ')}',
      if (_cats.isNotEmpty) 'Category: ${(_cats.toList()..sort()).join(', ')}',
    ];
    final read = _sheetReadAt ?? _loadedAt;
    return [...parts, if (read != null) 'Sheet read ${DateFormat('MMM d, h:mm a').format(read)}'].join('  ·  ');
  }

  static Future<bool> _saveCsv(String fileName, Uint8List bytes) async {
    final saved = await FilePicker.saveFile(fileName: fileName, bytes: bytes, type: FileType.custom, allowedExtensions: const ['csv'], dialogTitle: 'Export stock levels');
    // On the web the browser downloads the file and the picker always answers null, so that is a save too.
    return saved != null || kIsWeb;
  }

  Future<void> _export() async {
    final list = _shown;
    if (list.isEmpty) return _snack('Nothing to export: no parts match.');
    final fileName = 'stock-levels-${DateFormat('yyyy-MM-dd').format(DateTime.now())}.csv';
    try {
      final saved = await (widget.exporter ?? _saveCsv)(fileName, stockCsvBytes(list, withCost: _hasCost));
      if (saved) _snack('Exported ${_count.format(list.length)} ${list.length == 1 ? 'part' : 'parts'}');
    } catch (_) {
      _snack('Could not save the file. Try again.');
    }
  }

  Future<void> _print() async {
    final list = _shown;
    if (list.isEmpty) return _snack('Nothing to print: no parts match.');
    try {
      await Printing.layoutPdf(name: 'stock-levels.pdf', onLayout: (_) => buildStockListPdf(list, title: _viewTitle, note: _viewNote));
    } catch (_) {
      _snack('Could not open the print dialog. Try Export instead.');
    }
  }

  void _unmatched() => showUnmatchedCheckouts(context, onShowPart: _showPart);

  /// Start a purchase order for the parts in view that need attention, each at its To order quantity (G3).
  Future<void> _order() async {
    final parts = _shown.where((i) => i.status.needsAttention && !i.discontinued).toList();
    if (parts.isEmpty) {
      return _snack(_anythingSet ? 'No part in this view needs ordering.' : 'No part needs ordering right now.');
    }
    final router = GoRouter.maybeOf(context);
    if (router == null) return;
    final units = parts.fold<int>(0, (n, i) => n + i.toOrder);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        title: 'Start a purchase order',
        icon: accessIcon('purchase_orders'),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${_count.format(parts.length)} ${parts.length == 1 ? 'part' : 'parts'} that need attention in this view, '
              '${_count.format(units)} ${units == 1 ? 'unit' : 'units'} in all, each enough to get back to its reorder point. '
              'You pick the vendor and can change any line before saving.',
              style: CatalogUi.body,
            ),
            const SizedBox(height: 10),
            for (final i in parts.take(5)) Text('·  ${i.name}  ×${_count.format(i.toOrder)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: CatalogUi.meta),
            if (parts.length > 5) Text('…and ${parts.length - 5} more', style: CatalogUi.meta),
          ],
        ),
        actions: [AppButton.ghost('Cancel', () => Navigator.pop(ctx, false)), AppButton.ink('Start order', () => Navigator.pop(ctx, true))],
      ),
    );
    if (ok != true || !mounted) return;
    router.go(
      '/inventory/purchase-orders/new',
      extra: PurchaseOrder(
        id: 0,
        poNumber: 'Stock Levels',
        vendor: '',
        status: 'Draft',
        lines: [for (final i in parts) PoLine(name: i.name, sku: i.partNumber, qty: i.toOrder.toDouble(), unitCost: i.cost ?? 0)],
      ),
    );
  }

  // ---- table -----------------------------------------------------------------------------------------------------------

  double get _scale => MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);

  /// The table's columns for a list [width] wide, or null when the rows must stack.
  _Layout? _layout(double width) {
    final s = _scale;
    final cols = [
      for (final c in _allCols)
        if (_hasReorder || (c.key != 'reorder' && c.key != 'order')) c,
    ];
    final dropped = <String>{};
    double fixed(Iterable<_Col> cs) => cs.fold<double>(0, (n, c) => n + c.width * s) + cs.length * CatalogUi.gap + 2 * CatalogUi.side;
    var keep = cols.toList();
    for (final d in _dropOrder) {
      if (width - fixed(keep) >= _partMin * s) break;
      keep = keep.where((c) => c.key != d).toList();
      dropped.add(d);
    }
    var part = width - fixed(keep);
    if (part < _partMin * s) return null;
    final widths = {for (final c in keep) c.key: c.width * s};
    var flexKey = 'name';
    if (part > _partMax * s) {
      final extra = part - _partMax * s;
      if (widths.containsKey('category')) widths['category'] = widths['category']! + math.min(extra, 90 * s);
      part = _partMax * s;
      flexKey = 'status';
    }
    final out = <CatalogCol>[
      CatalogCol('PART', width: flexKey == 'name' ? null : part, sortKey: 'name'),
      for (final c in keep) CatalogCol(c.label, width: c.key == flexKey ? null : widths[c.key], right: c.right, sortKey: c.key == 'part' ? 'part' : (c.key == 'location' ? 'location' : c.key)),
    ];
    return _Layout(out, ['name', ...keep.map((c) => c.key)], dropped);
  }

  /// What a window [width] wide needs for the sidebar beside the table (To order may be dropped, nothing else).
  double get _sidebarNeeds {
    final s = _scale;
    final cols = _allCols.where((c) => c.key != 'order' && (_hasReorder || c.key != 'reorder'));
    return CatalogUi.sidebarWidth + cols.fold<double>(0, (n, c) => n + c.width * s) + cols.length * CatalogUi.gap + 2 * CatalogUi.side + _partMin * s;
  }

  /// [text] with the words being searched for marked (F9).
  TextSpan _marked(String text, TextStyle style) {
    final words = _words;
    if (words.isEmpty || text.isEmpty) return TextSpan(text: text, style: style);
    final lower = text.toLowerCase();
    final hit = List<bool>.filled(text.length, false);
    for (final w in words) {
      var at = lower.indexOf(w);
      while (at >= 0) {
        for (var k = at; k < at + w.length && k < hit.length; k++) {
          hit[k] = true;
        }
        at = lower.indexOf(w, at + w.length);
      }
    }
    if (!hit.contains(true)) return TextSpan(text: text, style: style);
    final mark = TextStyle(backgroundColor: DashUi.amber.withValues(alpha: 0.28), fontWeight: FontWeight.w700);
    final spans = <TextSpan>[];
    var start = 0;
    for (var k = 1; k <= text.length; k++) {
      if (k == text.length || hit[k] != hit[start]) {
        spans.add(TextSpan(text: text.substring(start, k), style: hit[start] ? mark : null));
        start = k;
      }
    }
    return TextSpan(style: style, children: spans);
  }

  Widget _cut(String text, TextStyle style, {int lines = 1, List<InlineSpan> after = const []}) => OverflowTooltip(
    message: text,
    child: Text.rich(TextSpan(children: [_marked(text, style), ...after]), maxLines: lines, overflow: TextOverflow.ellipsis),
  );

  Widget _quiet(String s) => s.isEmpty ? const Text('—', style: CatalogUi.cellQuiet) : _cut(s, CatalogUi.cellQuiet);

  Widget _number(int n, {bool strong = false}) =>
      Text(n > 0 || strong ? _count.format(n) : '—', maxLines: 1, style: strong ? CatalogUi.cellStrong : (n > 0 ? CatalogUi.cell : CatalogUi.cellQuiet));

  /// On hand: bold when the part needs attention. The colour is the status's job alone (L6).
  Widget _qtyText(StockItem i) => Text(
    _count.format(i.qty),
    maxLines: 1,
    style: i.status.needsAttention ? CatalogUi.cellStrong : (i.qty > 0 ? CatalogUi.cell : CatalogUi.cellQuiet),
  );

  (String, Color) _statusOf(StockItem i) =>
      _hasReorder ? (i.status.label, stockStatusColor(i.status)) : (i.qty > 0 ? 'In stock' : 'None on hand', i.qty > 0 ? DashUi.emeraldText : DashUi.slate);

  /// A status dot and label; the label wraps rather than overflowing a narrow column.
  Widget _statusText(StockItem i) {
    final (label, color) = _statusOf(i);
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

  static const _discontinued = WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: Padding(padding: EdgeInsets.only(left: 8), child: CatalogTag('Discontinued')),
  );

  Widget _cell(StockItem i, String key) => switch (key) {
    'name' => _cut(i.name, CatalogUi.name, lines: 2, after: i.discontinued ? const [_discontinued] : const []),
    'part' => _quiet(i.partNumber),
    'location' => _quiet(i.location),
    'category' => _cut(i.category, CatalogUi.cell),
    'qty' => _qtyText(i),
    'reorder' => _number(i.reorderPoint ?? 0),
    'order' => _number(i.toOrder, strong: i.toOrder > 0),
    _ => _statusText(i),
  };

  String _semantics(StockItem i) {
    final rp = i.reorderPoint ?? 0;
    return [
      i.name,
      if (i.discontinued) 'discontinued',
      i.partNumber.isEmpty ? 'no part number' : 'part number ${i.partNumber}',
      i.location.isEmpty ? 'no shelf' : 'shelf ${i.location}',
      i.category,
      '${_count.format(i.qty)} on hand',
      if (rp > 0) 'reorder point ${_count.format(rp)}',
      if (i.toOrder > 0) 'order ${_count.format(i.toOrder)}',
      _statusOf(i).$1,
    ].join(', ');
  }

  /// A row too narrow for the columns: the part and its status first, then part #, shelf and category, then counts.
  Widget _compactRow(StockItem i, int index) {
    final meta = [
      if (i.partNumber.isNotEmpty) 'Part # ${i.partNumber}',
      if (i.location.isNotEmpty) 'Shelf ${i.location}',
      i.category,
    ].join('  ·  ');
    const label = TextStyle(fontSize: 13, color: DashUi.slate, fontWeight: FontWeight.w400);
    final rp = i.reorderPoint ?? 0;
    return Semantics(
      button: true,
      label: _semantics(i),
      excludeSemantics: true,
      child: SelectionContainer.disabled(
        child: InkWell(
          mouseCursor: WidgetStateMouseCursor.clickable,
          onTap: () => _openPart(i),
          hoverColor: CatalogUi.hover,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            color: index.isOdd ? CatalogUi.stripe : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _cut(i.name, CatalogUi.name, lines: 2, after: i.discontinued ? const [_discontinued] : const [])),
                    const SizedBox(width: 12),
                    _statusText(i),
                  ],
                ),
                const SizedBox(height: 4),
                Text.rich(TextSpan(children: [_marked(meta, CatalogUi.meta)]), maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                // One line of text, so the labels and figures share a baseline (L10).
                Text.rich(
                  TextSpan(
                    style: CatalogUi.cell,
                    children: [
                      const TextSpan(text: 'On hand ', style: label),
                      TextSpan(text: _count.format(i.qty), style: i.status.needsAttention ? const TextStyle(fontWeight: FontWeight.w700) : null),
                      if (_hasReorder) ...[
                        const TextSpan(text: '      Reorder point ', style: label),
                        TextSpan(text: rp > 0 ? _count.format(rp) : '—', style: rp > 0 ? null : const TextStyle(color: DashUi.slate)),
                      ],
                      if (i.toOrder > 0) ...[
                        const TextSpan(text: '      To order ', style: label),
                        TextSpan(text: _count.format(i.toOrder), style: const TextStyle(fontWeight: FontWeight.w700)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// One part's row: opens the part's page; Ctrl+C on a row with the keyboard copies its name and part number (F4).
  Widget _row(StockItem i, int index, _Layout? layout) {
    if (layout == null) return _compactRow(i, index);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyC, control: true): () => copyStockText(context, [i.name, if (i.partNumber.isNotEmpty) i.partNumber].join('\t'), 'Part'),
        const SingleActivator(LogicalKeyboardKey.keyC, meta: true): () => copyStockText(context, [i.name, if (i.partNumber.isNotEmpty) i.partNumber].join('\t'), 'Part'),
      },
      child: CatalogRow(
        cols: layout.cols,
        cells: [for (final k in layout.keys) _cell(i, k)],
        index: index,
        onTap: () => _openPart(i),
        semanticLabel: _semantics(i),
      ),
    );
  }

  // ---- filters ---------------------------------------------------------------------------------------------------------

  /// All the filters. Stock status opens by default (U1); Category gets its own search box when it is long (U5).
  Widget _filterGroups() {
    final cats = _categoryCounts;
    final find = _catSearch.text.trim().toLowerCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_hasReorder)
          CatalogFilterGroup(
            title: 'Stock status',
            initiallyOpen: true,
            picked: _statuses.length,
            child: Column(
              children: [
                for (final s in StockStatus.values)
                  if (s != StockStatus.negative || _all.any((i) => i.status == StockStatus.negative))
                    // What the status means on hover (None on hand is not a shortage, for one).
                    Tooltip(
                      key: ValueKey('status-${s.name}'),
                      message: s.meaning,
                      waitDuration: const Duration(milliseconds: 600),
                      child: CatalogCheckRow(
                        label: s.filterLabel,
                        count: _statusCount(s),
                        selected: _statuses.contains(s),
                        onTap: () => _toggle(_statuses, s),
                        dot: stockStatusColor(s),
                        dim: _statusCount(s) == 0,
                      ),
                    ),
              ],
            ),
          ),
        CatalogFilterGroup(
          title: 'Category',
          initiallyOpen: false,
          picked: _cats.length,
          child: StatefulBuilder(
            builder: (context, setLocal) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (cats.length > 12)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
                    child: CatalogSearchField(
                      controller: _catSearch,
                      hint: 'Find a category',
                      height: 34,
                      onChanged: (_) => setLocal(() {}),
                      onClear: _catSearch.text.isEmpty
                          ? null
                          : () {
                              _catSearch.clear();
                              setLocal(() {});
                            },
                    ),
                  ),
                for (final (name, n) in cats)
                  if (find.isEmpty || name.toLowerCase().contains(find) || _cats.contains(name))
                    CatalogCheckRow(label: name, count: n, selected: _cats.contains(name), onTap: () => _toggle(_cats, name), dim: n == 0),
                if (find.isNotEmpty && !cats.any((c) => c.$1.toLowerCase().contains(find)))
                  const Padding(padding: EdgeInsets.fromLTRB(16, 4, 16, 8), child: Text('No category has that in its name.', style: CatalogUi.meta)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  /// The sidebar's top line: as tall as the command row beside it, so the two hairlines run as one.
  Widget _sidebarHeader({bool loading = false}) {
    return Container(
      height: CatalogUi.commandHeight * math.max(1, _scale * 0.85),
      padding: const EdgeInsets.fromLTRB(20, 0, 10, 0),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: DashUi.line))),
      child: Row(
        children: [
          const Icon(Icons.tune_rounded, size: 18, color: DashUi.slate),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('Filters', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: DashUi.ink)),
          ),
          // Only there when there is something to clear, so it never takes the title's room (L3).
          if (!loading && _anythingSet)
            TextButton(
              onPressed: _clearAll,
              style: TextButton.styleFrom(foregroundColor: DashUi.ink, padding: const EdgeInsets.symmetric(horizontal: 10), minimumSize: const Size(0, 32)),
              child: const Text('Clear all', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            ),
          IconButton(
            tooltip: 'Hide filters',
            visualDensity: VisualDensity.compact,
            onPressed: loading ? null : () => _setSidebarHidden(true),
            icon: const Icon(Icons.keyboard_double_arrow_left_rounded, size: 18, color: DashUi.slate),
          ),
        ],
      ),
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
            _sidebarHeader(),
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

  void _openFiltersDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AppDialog(
        title: 'Filters',
        icon: accessIcon('stock'),
        width: 420,
        // A fixed height, so the dialog doesn't jump as groups open and close (U8).
        body: SizedBox(
          height: (MediaQuery.sizeOf(ctx).height * 0.55).clamp(220.0, 520.0),
          child: ValueListenableBuilder<int>(
            valueListenable: _filterTick,
            builder: (_, _, _) => SingleChildScrollView(child: _filterGroups()),
          ),
        ),
        actions: [
          ValueListenableBuilder<int>(
            valueListenable: _filterTick,
            builder: (_, _, _) => AppButton.ghost('Clear all', _anythingSet ? _clearAll : null),
          ),
          AppButton.ink('Done', () => Navigator.pop(ctx)),
        ],
      ),
    );
  }

  /// The Filters button: on a window too narrow for the sidebar it opens the filters in a dialog; where the sidebar
  /// fits but was hidden, it brings the sidebar back and says so (U12).
  Widget _filterButton({bool reopensSidebar = false}) {
    final n = _filterCount;
    final label = reopensSidebar ? 'Show filters' : 'Filters';
    return SelectionContainer.disabled(
      child: Semantics(
        button: true,
        label: n == 0 ? label : '$label, $n set',
        excludeSemantics: true,
        child: Tooltip(
          message: reopensSidebar ? 'Show the filters beside the list' : '',
          child: OutlinedButton(
            onPressed: reopensSidebar ? () => _setSidebarHidden(false) : _openFiltersDialog,
            style: _outlined,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(reopensSidebar ? Icons.keyboard_double_arrow_right_rounded : Icons.tune_rounded, size: 18, color: DashUi.slate),
                const SizedBox(width: 8),
                Text(label),
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
      ),
    );
  }

  /// One click to the parts that are below zero, out or low (U1, U2), with how many there are.
  Widget _attentionButton() {
    final on = _attentionOn;
    final n = _attentionCount;
    return SelectionContainer.disabled(
      child: Semantics(
        button: true,
        toggled: on,
        label: 'Needs attention, ${_count.format(n)} parts',
        excludeSemantics: true,
        child: OutlinedButton(
          onPressed: _hasReorder ? _toggleAttention : null,
          style: _outlined.copyWith(
            backgroundColor: WidgetStatePropertyAll(on ? DashUi.ink : Colors.white),
            foregroundColor: WidgetStatePropertyAll(on ? Colors.white : DashUi.ink),
            side: WidgetStatePropertyAll(BorderSide(color: on ? DashUi.ink : DashUi.line)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: n > 0 ? (on ? Colors.white : DashUi.redText) : DashUi.muted, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              const Text('Needs attention'),
              const SizedBox(width: 8),
              Text(_count.format(n), style: TextStyle(fontFeatures: CatalogUi.figures, color: on ? Colors.white : DashUi.slate)),
            ],
          ),
        ),
      ),
    );
  }

  /// The filters that are on, each one a chip that takes it off.
  /// (Needs attention has no chip: its own button, inked while on, says it and takes it off.)
  List<({String group, String value, VoidCallback remove})> get _chips => [
    if (!_attentionOn)
      for (final s in StockStatus.values)
        if (_statuses.contains(s)) (group: 'Status', value: s.label, remove: () => _toggle(_statuses, s)),
    for (final c in _cats.toList()..sort()) (group: 'Category', value: c, remove: () => _toggle(_cats, c)),
  ];

  // ---- the command row -------------------------------------------------------------------------------------------------

  /// When the Sheet was read (F2): quiet while recent, amber with the age once it is old.
  InlineSpan _freshness() {
    final read = _sheetReadAt ?? _loadedAt;
    if (read == null) return const TextSpan();
    final age = DateTime.now().difference(read);
    final old = age >= _staleAfter;
    final mins = age.inMinutes;
    final ago = mins < 1 ? 'just now' : (mins < 60 ? '$mins min ago' : (mins < 120 ? '1 hr ago' : '${mins ~/ 60} hr ago'));
    return TextSpan(
      text: old ? '  ·  Sheet read $ago' : '  ·  Sheet read ${_time.format(read)}',
      style: TextStyle(fontWeight: old ? FontWeight.w700 : FontWeight.w400, color: old ? DashUi.amberText : DashUi.slate),
    );
  }

  TextSpan _countSpan(List<StockItem> shown) {
    final filtered = _anythingSet;
    const strong = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink, fontFeatures: CatalogUi.figures);
    final value = _hasCost ? shown.fold<double>(0, (n, i) => n + (i.value ?? 0)) : null;
    return TextSpan(
      style: const TextStyle(fontSize: 13.5, color: DashUi.slate, fontFeatures: CatalogUi.figures),
      children: [
        if (filtered) ...[
          TextSpan(text: '${_count.format(shown.length)} matching', style: strong),
          TextSpan(text: ' of ${_count.format(_all.length)}'),
        ] else
          TextSpan(text: shown.length == 1 ? '1 part' : '${_count.format(shown.length)} parts', style: strong.copyWith(color: DashUi.slate, fontWeight: FontWeight.w600)),
        if (value != null) TextSpan(text: '  ·  ${_money.format(value)} on hand'),
        _freshness(),
      ],
    );
  }

  /// How wide the count line is when nothing is cut.
  double _countWidth(List<StockItem> shown) {
    final p = TextPainter(
      text: TextSpan(style: DefaultTextStyle.of(context).style, children: [_countSpan(shown)]),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    return p.width + 2;
  }

  /// The chips and the count, sharing what is left of the command row: the count keeps its whole width up to about half,
  /// flush right; the chips get the rest (a "+N more" menu holds what doesn't fit).
  Widget _chipsAndCount(List<({String group, String value, VoidCallback remove})> chips, List<StockItem> shown) {
    return LayoutBuilder(builder: (context, c) {
      final room = math.max(0.0, c.maxWidth - 14);
      final countW = math.min(_countWidth(shown), chips.isEmpty ? room : room * 0.5);
      return Row(
        children: [
          Expanded(child: CatalogChipStrip(chips: chips)),
          const SizedBox(width: 14),
          SizedBox(width: countW, child: Align(alignment: Alignment.centerRight, child: _countLabel(shown))),
        ],
      );
    });
  }

  Widget _countLabel(List<StockItem> shown) {
    final read = _sheetReadAt ?? _loadedAt;
    return Semantics(
      liveRegion: true,
      child: Tooltip(
        message: read == null
            ? ''
            : 'The inventory sheet was read at ${DateFormat('h:mm:ss a').format(read)}'
                '${_loadedAt != null && _sheetReadAt != null ? '; this page loaded it at ${DateFormat('h:mm:ss a').format(_loadedAt!)}' : ''}. '
                'It reloads by itself every few minutes while you are on this page.',
        child: Text.rich(
          _countSpan(shown),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// The full hint only where it fits; a short one in a narrow box (L9).
  String _hint(double boxWidth) => boxWidth >= 370 * _scale ? 'Search part, part #, shelf or category' : 'Search parts';

  Widget _searchBox(double width, {double? boxWidth}) {
    final box = boxWidth ?? width;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _clearSearch},
      // Only the box redraws as you type (F12): the list waits for the pause.
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _search,
        builder: (_, v, _) => CatalogSearchField(
          controller: _search,
          focusNode: _searchFocus,
          hint: _hint(box),
          shortcutHint: box >= 370 * _scale,
          onClear: v.text.isEmpty ? null : _clearSearch,
          onSubmitted: (v) {
            _debounce?.cancel();
            _applyQuery(v);
          },
          onChanged: (v) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 250), () {
              if (mounted) _applyQuery(v);
            });
          },
        ),
      ),
    );
  }

  /// The command row: search, Needs attention, the filters that are on, the count. One line; on a narrow pane the
  /// count and chips go under it.
  Widget _commandRow({required bool filterButton, required bool sortMenu, required List<StockItem> shown, required double width, bool reopensSidebar = false}) {
    final chips = _chips;
    final small = width < 1100; // the count, Needs attention and the chips go on a second line
    final compact = width < 900;
    final searchWidth = (width * 0.34).clamp(240.0, 420.0);
    final line = Row(
      children: [
        if (small) Expanded(child: _searchBox(width, boxWidth: width - 240)) else SizedBox(width: searchWidth, child: _searchBox(width, boxWidth: searchWidth)),
        if (!small && _hasReorder) ...[const SizedBox(width: 10), _attentionButton()],
        if (filterButton) ...[const SizedBox(width: 10), _filterButton(reopensSidebar: reopensSidebar)],
        if (sortMenu) ...[const SizedBox(width: 8), _sortMenu(small)],
        // The chips take the room between; the count keeps its own, flush right, up to a third of the row.
        if (!small) ...[const SizedBox(width: 14), Expanded(child: _chipsAndCount(chips, shown))],
      ],
    );
    return Container(
      decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: DashUi.line))),
      padding: EdgeInsets.symmetric(horizontal: compact ? 12 : CatalogUi.side),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: CatalogUi.commandHeight * math.max(1, _scale * 0.85), child: line),
          if (small)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (_hasReorder) _attentionButton(),
                  _countLabel(shown),
                  for (final c in chips) CatalogFilterChip(key: ValueKey('${c.group}:${c.value}'), group: c.group, value: c.value, onRemove: c.remove),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _sortMenu(bool small) {
    final cols = _sorts.where((s) => _hasReorder || (s.$1 != 'reorder' && s.$1 != 'order')).toList();
    final label = cols.firstWhere((s) => s.$1 == _sortKey, orElse: () => cols.first).$2;
    return SelectionContainer.disabled(
      child: PopupMenuButton<String>(
        tooltip: 'Sort (pick the same one again to reverse it)',
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
        child: ClickCursor(
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: DashUi.line)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.swap_vert_rounded, size: 18, color: DashUi.slate),
                if (!small || label.length < 8) ...[
                  const SizedBox(width: 8),
                  Text(label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink)),
                ],
                const SizedBox(width: 4),
                Icon(_ascending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 14, color: DashUi.slate),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A failed refresh over rows that are still shown (L8): lined up with the table, on a tinted band, saying from when.
  Widget _staleNotice() {
    final read = _sheetReadAt ?? _loadedAt;
    return Semantics(
      liveRegion: true,
      child: Container(
        color: DashUi.red.withValues(alpha: 0.06),
        padding: const EdgeInsets.fromLTRB(CatalogUi.side, 6, CatalogUi.side - 8, 6),
        child: Row(
          children: [
            const Icon(Icons.error_outline_rounded, size: 18, color: DashUi.redText),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Couldn\'t refresh: $_error${read == null ? '' : ' The list below is from ${_time.format(read)}.'}',
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.redText),
              ),
            ),
            TextButton(
              onPressed: _busy ? null : _load,
              style: TextButton.styleFrom(foregroundColor: DashUi.redText),
              child: Text(_busy ? 'Trying…' : 'Try again'),
            ),
          ],
        ),
      ),
    );
  }

  // ---- build -----------------------------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final narrow = MediaQuery.sizeOf(context).width < 900;
    final ready = !_loading && _all.isNotEmpty;
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageBanner(
            title: 'Stock Levels',
            icon: accessIcon('stock'),
            activity: _activity,
            actions: [
              // There from the start, off until the list is in, so the ribbon keeps its height when it lands (L4).
              if (_canOrder && _hasReorder && !narrow)
                PageBanner.button(icon: Icons.add_shopping_cart_rounded, label: 'Order low stock', onPressed: ready ? _order : null),
              PageBanner.more(items: [
                if (_canOrder && _hasReorder && narrow) BannerMenuItem(icon: Icons.add_shopping_cart_rounded, label: 'Order low stock', onPressed: ready ? _order : null),
                BannerMenuItem(icon: Icons.file_download_outlined, label: 'Export CSV', onPressed: ready ? _export : null),
                BannerMenuItem(icon: Icons.print_outlined, label: 'Print this list', onPressed: ready ? _print : null),
                BannerMenuItem(icon: Icons.link_off_rounded, label: 'Checkouts that missed the shelf', onPressed: _all.isEmpty && _loading ? null : _unmatched),
              ]),
              // F1: off while any load is out, so a second click can't race the first.
              RibbonRefreshButton(onPressed: _busy ? null : _load),
            ],
          ),
          Expanded(
            child: PageSheet(child: LayoutBuilder(builder: (context, c) => _body(c.maxWidth))),
          ),
        ],
      ),
    );
  }

  Widget _body(double width) {
    final wide = width >= _sidebarNeeds;
    if (_loading) return _loadingView(width, wide);
    if (_error != null && _all.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          child: FlatEmpty(icon: Icons.cloud_off_rounded, title: 'Could not load stock levels', message: _error!, action: AppButton.ink('Try again', _busy ? null : _load)),
        ),
      );
    }
    if (_all.isEmpty) {
      return Center(
        child: FlatEmpty(
          icon: Icons.inventory_2_outlined,
          title: 'No parts on the inventory sheet',
          message: 'Parts appear here once they are added to the warehouse inventory sheet.',
          action: AppButton.ghost('Refresh', _busy ? null : _load),
        ),
      );
    }
    // The search box, the table and the pager come before the filters for the Tab key (U9).
    final list = FocusTraversalOrder(order: const NumericFocusOrder(1), child: FocusTraversalGroup(child: _listPane(filterButton: !wide || _sidebarHidden, reopensSidebar: wide && _sidebarHidden)));
    if (!wide || _sidebarHidden) return FocusTraversalGroup(policy: OrderedTraversalPolicy(), child: list);
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: CatalogUi.sidebarWidth,
            child: FocusTraversalOrder(order: const NumericFocusOrder(2), child: FocusTraversalGroup(child: _filterSidebar())),
          ),
          Expanded(child: list),
        ],
      ),
    );
  }

  /// Loading: the page's own frame (search box, sidebar, the columns the list will have) with pulsing rows, so nothing
  /// moves when the list lands (L4).
  Widget _loadingView(double width, bool wide) {
    final listWidth = wide ? width - CatalogUi.sidebarWidth : width;
    final layout = _layout(listWidth);
    final cols = layout?.cols ?? const [CatalogCol('PART')];
    final pane = Semantics(
      label: 'Loading stock levels',
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: CatalogUi.commandHeight * math.max(1, _scale * 0.85),
            padding: EdgeInsets.symmetric(horizontal: listWidth < 900 ? 12 : CatalogUi.side),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: DashUi.line))),
            child: Row(
              children: [
                if (listWidth < 1100)
                  Expanded(child: _searchBox(listWidth, boxWidth: listWidth - 240))
                else
                  SizedBox(width: (listWidth * 0.34).clamp(240.0, 420.0), child: _searchBox(listWidth, boxWidth: (listWidth * 0.34).clamp(240.0, 420.0))),
                const SizedBox(width: 14),
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: DashUi.slate)),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    _slow ? 'Still loading. The server can take up to a minute when it has just started.' : 'Loading stock levels',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: CatalogUi.meta.copyWith(fontSize: 13.5),
                  ),
                ),
              ],
            ),
          ),
          if (layout != null) CatalogTableHeader(cols: cols, sortKey: _sortKey, ascending: _ascending, onSort: (_) {}),
          Expanded(
            child: ClipRect(
              child: OverflowBox(alignment: Alignment.topCenter, maxHeight: double.infinity, child: CatalogSkeleton(cols: cols, rows: 24)),
            ),
          ),
        ],
      ),
    );
    if (!wide || _sidebarHidden) return pane;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: CatalogUi.sidebarWidth,
          decoration: const BoxDecoration(border: Border(right: BorderSide(color: DashUi.line))),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sidebarHeader(loading: true),
              const SizedBox(height: 10),
              for (final w in const [0.5, 0.7, 0.6, 0.55, 0.8, 0.45])
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  child: SkeletonPulse(
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: w,
                      child: Container(height: 11, decoration: BoxDecoration(color: DashUi.line, borderRadius: BorderRadius.circular(6))),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(child: pane),
      ],
    );
  }

  Widget _noMatches() {
    final q = _query.isNotEmpty;
    final f = _filterCount > 0;
    final (title, message, button) = switch ((q, f)) {
      (true, true) => ('No parts match "$_query" with these filters', 'Try other words, or take off a filter.', 'Clear search and filters'),
      (true, false) => ('No parts match "$_query"', 'Try other words, a part number or a shelf.', 'Clear search'),
      _ => ('No parts match these filters', 'Take off a filter to see more parts.', 'Clear filters'),
    };
    return Expanded(
      child: Center(
        child: SingleChildScrollView(
          child: FlatEmpty(icon: Icons.search_off_rounded, title: title, message: message, action: AppButton.ghost(button, _clearAll)),
        ),
      ),
    );
  }

  Widget _listPane({required bool filterButton, bool reopensSidebar = false}) {
    return LayoutBuilder(
      builder: (context, c) {
        final layout = _layout(c.maxWidth);
        final shown = _shown;
        final pages = shown.isEmpty ? 1 : (shown.length / _pageSize).ceil();
        final page = _page.clamp(1, pages);
        final start = (page - 1) * _pageSize;
        final rows = shown.skip(start).take(_pageSize).toList();
        final sortMenu = layout == null || layout.dropped.isNotEmpty;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _commandRow(filterButton: filterButton, sortMenu: sortMenu, shown: shown, width: c.maxWidth, reopensSidebar: reopensSidebar),
            if (_error != null) _staleNotice(),
            if (!_hasReorder)
              const Padding(
                padding: EdgeInsets.fromLTRB(CatalogUi.side, 10, CatalogUi.side, 4),
                child: Text('Low and out of stock appear once the server sends each part\'s reorder point.', style: CatalogUi.meta),
              ),
            if (shown.isEmpty)
              _noMatches()
            else ...[
              if (layout != null) CatalogTableHeader(key: const ValueKey('stock-header'), cols: layout.cols, sortKey: _sortKey, ascending: _ascending, onSort: _sort),
              Expanded(
                child: ListView.builder(
                  controller: _scroll,
                  itemCount: rows.length,
                  itemBuilder: (_, i) => flatRowEntrance(_rowsIn, i, _row(rows[i], i, layout)),
                ),
              ),
              CatalogPager(
                key: const ValueKey('stock-footer'),
                page: page,
                totalPages: pages,
                firstRow: start + 1,
                rowsShown: rows.length,
                pageSize: _pageSize,
                total: shown.length,
                compact: c.maxWidth < 760,
                sizesWhenCompact: true,
                onPage: (p) => _newView(() => _page = p),
                onPageSize: (s) {
                  _newView(() {
                    _pageSize = s;
                    _page = 1;
                  });
                  _savePrefs();
                },
              ),
            ],
          ],
        );
      },
    );
  }
}
