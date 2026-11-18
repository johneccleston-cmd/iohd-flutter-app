import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'catalog_categories_view.dart';
import 'catalog_cleanup_view.dart';
import 'catalog_history_view.dart';
import 'catalog_manage.dart';
import 'config/access.dart';
import 'config/auth_session.dart';
import 'product_detail_screen.dart';
import 'services/line_items_api.dart';
import 'utils/catalog_quality.dart';
import 'utils/product_csv.dart';
import 'widgets/app_dialog.dart';
import 'widgets/app_ribbon.dart';
import 'widgets/catalog_kit.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';

/// The office's product price list (backend /api/catalog/list?kind=product, from catalog_products): every product
/// with its part number, category, warehouse stock, cost, margin and price. Read-only; cost columns follow the Team
/// screen's Line Items & Costs > View switch.
///
/// Layout (Phase 1 redesign, 2026-11-16; pieces in widgets/catalog_kit.dart): a filter sidebar like Jobs (a Filters button
/// and dialog when the window is too narrow for it), a 52 px command row (search, the filters that are on as removable
/// chips, the count), a white small-caps header and 42 px rows. Several filters can be on at once: within one group the
/// picks add up (Category A or B), across groups they narrow (Category A and in inventory).
///
/// Clicking a product opens its own page, where Edit and Delete are (they follow the Line Items & Costs > Update switch).
/// New product and Export are in the ribbon: Export saves what the filters show as a CSV file. "/" jumps to the search.
///
/// Phase 3 (2026-11-16) adds the catalog's management as views of the same page, tabs on the ribbon: Products (the
/// list, now with picking several products to move them to a category, make them active or inactive, or export them),
/// Categories (rename, describe, merge, delete when empty, see naming questions), Cleanup (the data-quality checks; a
/// check opens the product list filtered to it, possible duplicates are gone through group by group) and History (the
/// change log). Changes need the Line Items & Costs > Update switch, as editing one product does; cost-based checks
/// need the View switch. Every change to several products is previewed and confirmed (see catalog_manage.dart).
class ProductCatalogScreen extends StatefulWidget {
  /// Tests pass a fake list; the app loads the real one.
  final Future<({List<CatalogEntry> entries, bool canSeeCost, int historyDays})> Function()? loader;

  /// Tests pass a fake for saving the export file; the app uses the save dialog.
  final Future<bool> Function(String fileName, Uint8List bytes)? exporter;

  /// The categories, bulk changes, reviews and change log. Tests pass a fake; with a fake [loader] and no manager the
  /// management calls are left out (as with a server older than Phase 3).
  final CatalogManager? manager;
  final CatalogView initialView;
  const ProductCatalogScreen({super.key, this.loader, this.exporter, this.manager, this.initialView = CatalogView.products});

  @override
  State<ProductCatalogScreen> createState() => _ProductCatalogScreenState();
}

class _ProductCatalogScreenState extends State<ProductCatalogScreen> with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  @override
  bool get wantKeepAlive => true;

  static const _tableWidth = 900.0; // below this the rows stack
  static const _topCategories = 8; // categories listed before "Show all"
  static const _sorts = [
    ('name', 'Product'),
    ('sku', 'Part #'),
    ('category', 'Category'),
    ('stock', 'In stock'),
    ('cost', 'Unit cost'),
    ('margin', 'Margin'),
    ('price', 'Price'),
  ];

  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'catalog-search');
  final _nameField = TextEditingController();
  final _partField = TextEditingController();
  final _catField = TextEditingController();
  final _scroll = ScrollController();
  final _activity = RibbonActivity();
  final _filterTick = ValueNotifier<int>(0); // tells the Filters dialog (narrow windows) to redraw
  late final _rowsIn = AnimationController(vsync: this, duration: const Duration(milliseconds: 460), value: 1);
  Timer? _slowTimer;
  Timer? _debounce;

  List<CatalogEntry> _all = const [];
  CatalogQuality _quality = CatalogQuality.empty;
  bool _canSeeCost = false;
  int _historyDays = 540;

  // Phase 3: the views, and what the management calls brought back (null / false: the server does not have them).
  late CatalogView _view = widget.initialView;
  late final Set<CatalogView> _visited = {widget.initialView};
  List<CatalogCategory>? _categories;
  List<CatalogReview> _reviews = const [];
  bool _reviewsLive = false;
  String? _categoryToOpen;
  final _categoriesKey = GlobalKey<State<CatalogCategoriesView>>();
  final _historyKey = GlobalKey<CatalogHistoryViewState>();

  /// Products picked for a change to several at once (their keys), and the last one clicked (for Shift+click ranges).
  final Set<String> _selected = {};
  String? _anchor;
  bool _loading = true;
  bool _slow = false;
  String? _error;

  String _query = '';
  String _sortKey = 'name';
  bool _ascending = true;
  int _page = 1;
  int _pageSize = 50;

  // The filters. An empty group does not filter; picking every option in a group filters nothing either.
  final Set<String> _cats = {};
  final Set<String> _inv = {}; // 'in' | 'out'
  final Set<String> _act = {'active'}; // 'active' | 'inactive': what the page showed before it had a filter
  final Set<String> _stockF = {}; // 'instock' | 'review'
  final Set<String> _attn = {}; // 'costabove' | 'nocost' | 'perjob' | 'dupe'
  String _nameFilter = '';
  String _partFilter = '';
  String _catQuery = '';
  bool _allCats = false;

  /// The filter sidebar put away to give the table its room (kept while the app is open).
  static bool _sidebarHidden = false;

  @override
  void initState() {
    super.initState();
    productCatalogChanged.addListener(_onProductChanged);
    HardwareKeyboard.instance.addHandler(_onKey);
    _load();
  }

  /// A product was added, saved or deleted on its own page: show it.
  void _onProductChanged() {
    if (mounted && !_loading) _load();
  }

  @override
  void dispose() {
    productCatalogChanged.removeListener(_onProductChanged);
    HardwareKeyboard.instance.removeHandler(_onKey);
    _slowTimer?.cancel();
    _debounce?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _nameField.dispose();
    _partField.dispose();
    _catField.dispose();
    _scroll.dispose();
    _filterTick.dispose();
    _rowsIn.dispose();
    _activity.dispose();
    super.dispose();
  }

  /// "/" jumps to the search box, while this page is the one on screen and no text box has the keyboard.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.character != '/' || !mounted || _view != CatalogView.products) return false;
    if (!TickerMode.valuesOf(context).enabled) return false; // another tab of the app is showing
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false; // a product page or a dialog is on top
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null && (focused.widget is EditableText || focused.findAncestorWidgetOfExactType<EditableText>() != null)) return false;
    _searchFocus.requestFocus();
    return true;
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
      final manager = _manager;
      // The list, and (alongside it) the categories and reviewed marks. Those two are extras: a server without them
      // (older than Phase 3) or a failure leaves the list working and the management parts read-only.
      final categories = manager == null ? Future.value(null) : manager.listCategories().then<List<CatalogCategory>?>((c) => c.categories).catchError((_) => null);
      final reviews = manager == null
          ? Future.value(null)
          : manager.listReviews().then<List<CatalogReview>?>((r) => r.reviews).catchError((_) => null);
      final r = await (widget.loader ?? () => LineItemsApi.listCatalog(kind: 'product', includeInactive: true))();
      final cats = await categories;
      final marks = await reviews;
      if (!mounted) return;
      setState(() {
        _all = r.entries;
        _canSeeCost = r.canSeeCost;
        _historyDays = r.historyDays;
        _categories = cats;
        _reviews = marks ?? const [];
        _reviewsLive = marks != null;
        _quality = catalogQuality(_all, withCost: _canSeeCost, reviews: _reviews);
        _loading = false;
        _cats.removeWhere((c) => !_all.any((e) => e.category == c)); // a category that is gone cannot stay picked
        _selected.removeWhere((k) => !_all.any((e) => e.key == k)); // nor a product that is gone
      });
      _historyKey.currentState?.reload();
      productCategories.value = [for (final (n, _) in _categoryCounts) n]; // the product page suggests these
      _activity.landed();
    } on LineItemsException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load the product catalog.';
      });
    } finally {
      _slowTimer?.cancel();
      _activity.setRefreshing(false);
    }
  }

  /// Every category with how many products it has, A to Z.
  List<(String, int)> get _categoryCounts {
    final counts = <String, int>{};
    for (final e in _all) {
      if (e.category.isNotEmpty) counts[e.category] = (counts[e.category] ?? 0) + 1;
    }
    final names = counts.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return [for (final n in names) (n, counts[n]!)];
  }

  /// Both options of a two-way filter picked is the same as neither.
  bool _narrows(Set<String> group) => group.length == 1;

  static double? _marginOf(CatalogEntry e) => catalogMargin(e.rate, e.cost)?.pct;

  bool _inStock(CatalogEntry e) => (e.stock ?? 0) > 0 && e.inventoryConflict == null;

  /// The list's "Needs attention" filters: every data-quality check (lib/utils/catalog_quality.dart) except the stock
  /// link one (that is the Stock group's "Stock needs review"), plus "Per-job price".
  bool _attention(String what, CatalogEntry e) {
    if (what == 'perjob') return e.rate == null;
    final check = CatalogCheck.byKey(what);
    return check != null && _quality.flags(check, e);
  }

  /// The management calls: the test's fake, the real server, or none (a test's fake list without a fake manager).
  CatalogManager? get _manager => widget.manager ?? (widget.loader == null ? const CatalogManager() : null);

  /// Categories, bulk changes and reviews need a Phase 3 server: it answers the categories call and dates every product.
  bool get _manageLive => _categories != null && _all.any((e) => e.updatedAt != null);

  List<CatalogEntry> get _shown {
    final words = _query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final nameWords = _nameFilter.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final part = _partFilter.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    final list = _all.where((e) {
      if (_cats.isNotEmpty && !_cats.contains(e.category)) return false;
      if (_narrows(_inv) && e.inInventory != _inv.contains('in')) return false;
      if (_narrows(_act) && e.active != _act.contains('active')) return false;
      if (_stockF.isNotEmpty && !((_stockF.contains('instock') && _inStock(e)) || (_stockF.contains('review') && e.inventoryConflict != null))) {
        return false;
      }
      if (_attn.isNotEmpty && !_attn.any((a) => _attention(a, e))) return false;
      if (part.isNotEmpty && !e.sku.toLowerCase().replaceAll(RegExp(r'\s+'), '').contains(part)) return false;
      if (nameWords.isNotEmpty) {
        final name = e.name.toLowerCase();
        if (!nameWords.every(name.contains)) return false;
      }
      if (words.isEmpty) return true;
      final hay = '${e.name} ${e.sku} ${e.category} ${e.model} ${e.description} ${[for (final v in e.vendors) v.name].join(' ')}'.toLowerCase();
      return words.every(hay.contains);
    }).toList();
    int cmpNum(double? a, double? b) => (a ?? double.negativeInfinity).compareTo(b ?? double.negativeInfinity);
    int cmp(CatalogEntry a, CatalogEntry b) => switch (_sortKey) {
      'sku' => a.sku.toLowerCase().compareTo(b.sku.toLowerCase()),
      'category' => a.category.toLowerCase().compareTo(b.category.toLowerCase()),
      'stock' => cmpNum(a.stock?.toDouble(), b.stock?.toDouble()),
      'cost' => cmpNum(a.cost, b.cost),
      'margin' => cmpNum(_marginOf(a), _marginOf(b)),
      'price' => cmpNum(a.rate, b.rate),
      _ => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    };
    list.sort((a, b) {
      final c = _ascending ? cmp(a, b) : cmp(b, a);
      return c != 0 ? c : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  /// How many filters are set to something other than the page's starting view (Active only, nothing else).
  int get _filterCount =>
      (_cats.isEmpty ? 0 : 1) +
      (_inv.isEmpty ? 0 : 1) +
      (_act.length == 1 && _act.contains('active') ? 0 : 1) +
      (_stockF.isEmpty ? 0 : 1) +
      (_attn.isEmpty ? 0 : 1) +
      (_nameFilter.isEmpty ? 0 : 1) +
      (_partFilter.isEmpty ? 0 : 1);

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
      // Text reads A to Z first; stock, cost, margin and price biggest first.
      _ascending = key == 'name' || key == 'sku' || key == 'category';
    }
    _page = 1;
  });

  void _toggle(Set<String> group, String value) => _newView(() {
    if (!group.remove(value)) group.add(value);
    _page = 1;
  });

  void _resetStatus() => _newView(() {
    _act
      ..clear()
      ..add('active');
    _page = 1;
  });

  void _clearName() {
    _nameField.clear();
    _newView(() {
      _nameFilter = '';
      _page = 1;
    });
  }

  void _clearPart() {
    _partField.clear();
    _newView(() {
      _partFilter = '';
      _page = 1;
    });
  }

  void _resetFilters() {
    _debounce?.cancel();
    _nameField.clear();
    _partField.clear();
    _newView(() {
      _cats.clear();
      _inv.clear();
      _stockF.clear();
      _attn.clear();
      _act
        ..clear()
        ..add('active');
      _nameFilter = '';
      _partFilter = '';
      _page = 1;
    });
  }

  void _clearAll() {
    _search.clear();
    _query = '';
    _resetFilters();
  }

  /// The columns for a table [width] wide: the product takes what the fixed columns leave.
  List<CatalogCol> _cols(double width) {
    // Under 1150 px the fixed columns tighten (a long category ends in "..."), so product names keep to one line more often.
    final roomy = width >= 1150;
    return [
      const CatalogCol('PRODUCT', sortKey: 'name'),
      CatalogCol('PART #', width: roomy ? 112 : 92, sortKey: 'sku'),
      CatalogCol('CATEGORY', width: roomy ? 196 : 150, sortKey: 'category'),
      CatalogCol('IN STOCK', width: roomy ? 72 : 68, right: true, sortKey: 'stock'),
      if (_canSeeCost) CatalogCol('UNIT COST', width: roomy ? 90 : 84, right: true, sortKey: 'cost'),
      if (_canSeeCost) CatalogCol('MARGIN', width: roomy ? 74 : 64, right: true, sortKey: 'margin'),
      CatalogCol('PRICE', width: roomy ? 96 : 90, right: true, sortKey: 'price'),
    ];
  }

  static final _count = NumberFormat.decimalPattern();

  // ---- New product, Export ----------------------------------------------------

  bool get _canEdit => AuthSession.instance.can('line_items', AccessAction.update);

  /// The catalog_products row behind an entry. Entries from the old sources (before the price list is loaded) have none,
  /// so they cannot be opened, edited or deleted.
  int? _idOf(CatalogEntry e) => e.kind == 'product' && e.key.startsWith('cat:') ? int.tryParse(e.key.substring(4)) : null;

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 3), behavior: SnackBarBehavior.floating, width: 320));
  }

  void _openEntry(CatalogEntry e) {
    final id = _idOf(e);
    final router = GoRouter.maybeOf(context);
    if (id == null || router == null) {
      _open(e); // nothing to open a page for: the short summary
      return;
    }
    router.go('/inventory/catalog/$id');
  }

  void _newProduct() => GoRouter.maybeOf(context)?.go('/inventory/catalog/new');

  static Future<bool> _saveCsv(String fileName, Uint8List bytes) async {
    final saved = await FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: const ['csv'],
      dialogTitle: 'Export products',
    );
    // On the web the browser downloads the file and the picker always answers null (audit B5), so that is a save too.
    return saved != null || kIsWeb;
  }

  /// Saves every product the filters show (not just this page), or the picked ones, as a CSV file.
  Future<void> _export([List<CatalogEntry>? only]) async {
    final list = only ?? _shown;
    if (list.isEmpty) {
      _snack('Nothing to export: no products match.');
      return;
    }
    final fileName = 'product-catalog-${DateFormat('yyyy-MM-dd').format(DateTime.now())}.csv';
    try {
      final saved = await (widget.exporter ?? _saveCsv)(fileName, productCatalogCsvBytes(productCatalogCsv(list, canSeeCost: _canSeeCost)));
      if (saved) _snack('Exported ${_count.format(list.length)} ${list.length == 1 ? 'product' : 'products'}');
    } catch (_) {
      _snack('Could not save the file. Try again.');
    }
  }

  // ---- views, picking several, changing several --------------------------------

  void _switchView(CatalogView v) {
    if (v == _view) return;
    setState(() {
      _view = v;
      _visited.add(v);
    });
  }

  /// From the Cleanup view: the product list with only [check] on (and the page's usual Active filter).
  void _showCheck(CatalogCheck check) {
    _search.clear();
    _query = '';
    _resetFilters();
    _newView(() {
      if (check == CatalogCheck.linkReview) {
        _stockF.add('review');
      } else {
        _attn.add(check.key);
      }
    });
    _switchView(CatalogView.products);
  }

  /// From the Categories view: the product list filtered to one category (active and inactive, as the category holds both).
  void _showCategory(String category) {
    _search.clear();
    _query = '';
    _resetFilters();
    _newView(() {
      _cats.add(category);
      _act.add('inactive');
    });
    _switchView(CatalogView.products);
  }

  void _openCategory(String? name) {
    setState(() => _categoryToOpen = name);
    _switchView(CatalogView.categories);
  }

  /// Pick boxes are for products with a row of their own (every product once the price list is loaded).
  bool get _selectable => _all.any((e) => _idOf(e) != null);

  /// The products listed now, in order (for Shift+click ranges), and the ones on this page (for the header box).
  List<CatalogEntry> _shownNow = const [];
  List<CatalogEntry> _pageNow = const [];

  Widget _pageBox() {
    final page = _pageNow.where((e) => _idOf(e) != null).toList();
    final picked = page.where((e) => _selected.contains(e.key)).length;
    return CatalogSelectBox(
      key: const ValueKey('pick-page'),
      value: page.isEmpty || picked == 0 ? false : (picked == page.length ? true : null),
      semanticLabel: 'Pick every product on this page',
      onChanged: (_) => setState(() {
        // The page as it is when clicked.
        final now = _pageNow.where((e) => _idOf(e) != null).map((e) => e.key).toList();
        if (now.any(_selected.contains)) {
          _selected.removeAll(now);
        } else {
          _selected.addAll(now);
        }
      }),
    );
  }

  Widget _pickBox(CatalogEntry e, int position) {
    if (_idOf(e) == null) return const SizedBox(width: 32);
    return CatalogSelectBox(
      key: ValueKey('pick:${e.key}'),
      value: _selected.contains(e.key),
      semanticLabel: 'Pick ${e.name}',
      onChanged: (on) => setState(() {
        // Shift+click picks (or unpicks) everything between the last one clicked and this one.
        final anchor = _anchor == null ? -1 : _shownNow.indexWhere((x) => x.key == _anchor);
        if (HardwareKeyboard.instance.isShiftPressed && anchor >= 0 && position >= 0 && position < _shownNow.length) {
          final from = anchor < position ? anchor : position;
          final to = anchor < position ? position : anchor;
          for (final x in _shownNow.sublist(from, to + 1)) {
            if (_idOf(x) == null) continue;
            on ? _selected.add(x.key) : _selected.remove(x.key);
          }
        } else {
          on ? _selected.add(e.key) : _selected.remove(e.key);
        }
        _anchor = e.key;
      }),
    );
  }

  List<CatalogEntry> get _picked => [
    for (final e in _all)
      if (_selected.contains(e.key)) e,
  ];

  Map<String, int> get _categoryCountsMap {
    final out = <String, int>{for (final (n, c) in _categoryCounts) n: c};
    for (final c in _categories ?? const <CatalogCategory>[]) {
      out.putIfAbsent(c.name, () => c.products); // an empty category can be moved into too
    }
    return out;
  }

  Future<void> _afterBulk(CatalogBulkOutcome? r, {bool clear = true}) async {
    if (r == null) return;
    if (r.reload) {
      await _load();
      _snack('The list is up to date again. Check the products and try once more.');
      return;
    }
    if (clear) setState(_selected.clear);
    _snack(r.skipped > 0 ? '${r.message} (${catalogPlural(r.skipped, 'was', 'were')} already so)' : r.message);
    await _load();
  }

  Future<void> _bulkCategory() async {
    final picked = _picked;
    if (picked.isEmpty || _manager == null) return;
    final r = await showBulkCategoryDialog(context, entries: picked, categories: _categoryCountsMap, manager: _manager!, canCreate: _canEdit);
    await _afterBulk(r);
  }

  Future<void> _bulkStatus(bool active) async {
    final picked = _picked;
    if (picked.isEmpty || _manager == null) return;
    final r = await showBulkStatusDialog(context, entries: picked, active: active, manager: _manager!);
    await _afterBulk(r);
  }

  /// The bar that appears while products are picked: how many (and how many the filters hide), pick every match, and
  /// what can be done with them. It floats over the list's foot so the list keeps its rows.
  Widget _selectionBar(List<CatalogEntry> shown) {
    final n = _selected.length;
    final shownKeys = {for (final e in shown) e.key};
    final hidden = _selected.where((k) => !shownKeys.contains(k)).length;
    final pickable = shown.where((e) => _idOf(e) != null).toList();
    final allShown = pickable.every((e) => _selected.contains(e.key));
    final tooMany = n > kCatalogBulkMax;
    final canChange = _canEdit && _manageLive && !tooMany;
    final why = !_canEdit
        ? 'Changing products needs the Line Items & Costs > Update switch'
        : (!_manageLive ? 'Needs the server update that adds changes to several products' : (tooMany ? 'Pick at most ${_count.format(kCatalogBulkMax)} products' : ''));
    final white = TextButton.styleFrom(
      foregroundColor: Colors.white,
      disabledForegroundColor: Colors.white.withValues(alpha: 0.4),
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      minimumSize: const Size(0, 36),
    );
    return LayoutBuilder(builder: (context, box) => _selectionBarBody(box.maxWidth, n, hidden, pickable, allShown, canChange, why, white));
  }

  Widget _selectionBarBody(double width, int n, int hidden, List<CatalogEntry> pickable, bool allShown, bool canChange, String why, ButtonStyle white) {
    // A narrow bar keeps its actions as icons (named in their tooltips) so the count and "Pick all" keep their room.
    final iconsOnly = width < 820;
    Widget action(String label, IconData icon, VoidCallback? onPressed, {String? key}) {
      final Widget b = iconsOnly
          ? IconButton(
              key: key == null ? null : ValueKey(key),
              onPressed: onPressed,
              tooltip: onPressed == null && why.isNotEmpty ? null : label,
              color: Colors.white,
              disabledColor: Colors.white.withValues(alpha: 0.4),
              icon: Icon(icon, size: 19),
            )
          : TextButton.icon(key: key == null ? null : ValueKey(key), onPressed: onPressed, style: white, icon: Icon(icon, size: 17), label: Text(label));
      return onPressed == null && why.isNotEmpty ? Tooltip(message: why, child: b) : b;
    }

    return Semantics(
      container: true,
      label: '${catalogPlural(n, 'product')} picked',
      child: Container(
        key: const ValueKey('selection-bar'),
        height: 52,
        padding: const EdgeInsets.fromLTRB(6, 0, 10, 0),
        decoration: BoxDecoration(
          color: DashUi.ink,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.22), blurRadius: 18, offset: const Offset(0, 6))],
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Clear the picks',
              onPressed: () => setState(_selected.clear),
              icon: const Icon(Icons.close_rounded, size: 19, color: Colors.white),
            ),
            Text(
              '${_count.format(n)} picked',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white, fontFeatures: CatalogUi.figures),
            ),
            Expanded(
              child: Row(
                children: [
                  if (hidden > 0) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        '${_count.format(hidden)} not in this view',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: Colors.white.withValues(alpha: 0.7), fontFeatures: CatalogUi.figures),
                      ),
                    ),
                  ],
                  if (!allShown && pickable.length > 1) ...[
                    const SizedBox(width: 6),
                    Flexible(
                      child: TextButton(
                        key: const ValueKey('pick-all-matching'),
                        onPressed: () => setState(() => _selected.addAll(pickable.map((e) => e.key))),
                        style: white.copyWith(foregroundColor: const WidgetStatePropertyAll(RibbonColors.live)),
                        child: Text(
                          'Pick all ${_count.format(pickable.length)} ${_query.isEmpty && _filterCount == 0 ? 'products' : 'matching'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            action('Move to category', Icons.drive_file_move_outline, canChange ? _bulkCategory : null, key: 'bulk-category'),
            MenuAnchor(
              alignmentOffset: const Offset(0, 6),
              menuChildren: [
                MenuItemButton(
                  key: const ValueKey('bulk-inactive'),
                  leadingIcon: const Icon(Icons.do_not_disturb_on_outlined, size: 18),
                  onPressed: () => _bulkStatus(false),
                  child: const Text('Make inactive'),
                ),
                MenuItemButton(
                  key: const ValueKey('bulk-active'),
                  leadingIcon: const Icon(Icons.check_circle_outline_rounded, size: 18),
                  onPressed: () => _bulkStatus(true),
                  child: const Text('Make active'),
                ),
              ],
              builder: (context, controller, _) => action(
                'Status',
                Icons.toggle_on_outlined,
                canChange ? () => controller.isOpen ? controller.close() : controller.open() : null,
                key: 'bulk-status',
              ),
            ),
            Container(width: 1, height: 22, margin: const EdgeInsets.symmetric(horizontal: 6), color: Colors.white.withValues(alpha: 0.18)),
            action('Export', Icons.file_download_outlined, () => _export(_picked), key: 'bulk-export'),
          ],
        ),
      ),
    );
  }

  // ---- cells ------------------------------------------------------------------

  Widget _money(double? v, {String none = '—', bool strong = false}) =>
      Text(v == null ? none : dashMoney(v), maxLines: 1, style: v == null ? CatalogUi.cellQuiet : (strong ? CatalogUi.cellStrong : CatalogUi.cell));

  Widget _nameCell(CatalogEntry e) {
    final name = Text.rich(catalogNameSpan(e.name, CatalogUi.name), maxLines: 2, overflow: TextOverflow.ellipsis);
    if (e.active) return name;
    // Inactive products only show when the Status filter lets them in, so they say what they are.
    return Row(
      children: [
        Flexible(child: name),
        const SizedBox(width: 8),
        const CatalogTag('Inactive'),
      ],
    );
  }

  Widget _stockCell(CatalogEntry e) {
    final conflict = e.inventoryConflict;
    if (conflict != null) {
      // Which inventory row is this product's needs a person: say so (the reason on hover), never show another's count.
      return Tooltip(
        message: inventoryConflictText(conflict),
        child: const CatalogTag('Review', tone: CatalogTone.warn),
      );
    }
    final s = e.stock;
    // Not kept in inventory and nothing on hand: there is no count to read, so a dash rather than a misleading 0.
    if (s == null || (s == 0 && !e.inInventory)) return const Text('—', style: CatalogUi.cellQuiet);
    // Out of stock is a plain quiet 0: a number to read, not a warning.
    return Text(_count.format(s), style: s > 0 ? CatalogUi.cell : CatalogUi.cellQuiet);
  }

  Widget _marginCell(CatalogEntry e) {
    final m = catalogMargin(e.rate, e.cost);
    if (m == null) return const Text('—', style: CatalogUi.cellQuiet);
    final tone = catalogMarginTone(m.pct);
    return Text(
      '${m.pct.toStringAsFixed(0)}%',
      style: CatalogUi.cell.copyWith(color: tone, fontWeight: tone == DashUi.ink ? FontWeight.w400 : FontWeight.w700),
    );
  }

  List<Widget> _cells(CatalogEntry e) => [
    _nameCell(e),
    Text(e.sku.isEmpty ? '—' : e.sku, maxLines: 1, overflow: TextOverflow.ellipsis, style: CatalogUi.cellQuiet),
    Text(e.category.isEmpty ? '—' : e.category, maxLines: 1, overflow: TextOverflow.ellipsis, style: CatalogUi.cell),
    _stockCell(e),
    if (_canSeeCost) _money(e.cost),
    if (_canSeeCost) _marginCell(e),
    _money(e.rate, none: 'Per job', strong: true),
  ];

  /// A row too narrow for the columns: the product and its price first, then part number and category, then stock and cost.
  Widget _compactRow(CatalogEntry e, int index, int position) {
    final meta = [if (e.sku.isNotEmpty) 'Part # ${e.sku}', if (e.category.isNotEmpty) e.category].join('  ·  ');
    return Semantics(
      button: true,
      label: 'Product ${e.name}',
      child: SelectionContainer.disabled(
        child: InkWell(
          onTap: () => _openEntry(e),
          hoverColor: CatalogUi.hover,
          child: Container(
            padding: EdgeInsets.fromLTRB(_selectable ? 8 : 16, 10, 16, 10),
            color: _selected.contains(e.key) ? CatalogUi.picked : (index.isOdd ? CatalogUi.stripe : null),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_selectable) ...[Transform.translate(offset: const Offset(0, -3), child: _pickBox(e, position)), const SizedBox(width: 4)],
                    Expanded(child: _nameCell(e)),
                    const SizedBox(width: 12),
                    _money(e.rate, none: 'Per job', strong: true),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: CatalogUi.meta),
                    ),
                    const SizedBox(width: 12),
                    const Text('Stock ', style: CatalogUi.meta),
                    _stockCell(e),
                    if (_canSeeCost) ...[const SizedBox(width: 14), const Text('Cost ', style: CatalogUi.meta), _money(e.cost)],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The short summary for an entry that has no page of its own (the old sources, or no router).
  void _open(CatalogEntry e) {
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.slate),
            ),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 14, color: DashUi.ink)),
          ),
        ],
      ),
    );
    final vendors = e.vendors.where((v) => (v.price ?? 0) > 0).toList();
    showDialog<void>(
      context: context,
      builder: (ctx) => AppDialog(
        title: e.name,
        subtitle: [if (e.category.isNotEmpty) e.category, if (e.sku.isNotEmpty) 'Part # ${e.sku}'].join('  ·  '),
        icon: accessIcon('catalog'),
        width: 560,
        body: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              row('Price', e.rate == null ? 'Priced per job' : dashMoney(e.rate!)),
              if (e.memberPrice != null && e.memberPrice! > 0) row('Member price', dashMoney(e.memberPrice!)),
              if (_canSeeCost) row('Unit cost', e.cost == null ? 'Not entered' : dashMoney(e.cost!)),
              row('In stock', e.stock == null ? 'Not in inventory' : _count.format(e.stock)),
              if (!e.active) row('Status', 'Inactive'),
              if (e.model.isNotEmpty) row('Model', e.model),
              if (_canSeeCost && vendors.isNotEmpty) row('Bought from', [for (final v in vendors) '${v.name} ${dashMoney(v.price!)}'].join('\n')),
              if (e.purchaseNote.isNotEmpty) row('Ordering', e.purchaseNote),
              if (e.description.isNotEmpty) row('Description', e.description),
            ],
          ),
        ),
        actions: [AppButton.ink('Close', () => Navigator.pop(ctx))],
      ),
    );
  }

  // ---- filters ----------------------------------------------------------------

  Widget _textFilter(TextEditingController c, String hint, String value, void Function(String) apply) {
    return CatalogSearchField(
      controller: c,
      hint: hint,
      height: 36,
      onClear: value.isEmpty && c.text.isEmpty
          ? null
          : () {
              c.clear();
              _debounce?.cancel();
              apply('');
            },
      onChanged: (v) {
        setState(() {}); // the clear button comes and goes with the text
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 250), () {
          if (mounted) apply(v);
        });
      },
      onSubmitted: (v) {
        _debounce?.cancel();
        apply(v);
      },
    );
  }

  /// The category list: the biggest ones (and any that are picked) first, then all of them A to Z on "Show all"; a
  /// search box narrows it when there are many.
  Widget _categoryList() {
    final cats = _categoryCounts;
    if (cats.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Text('No categories', style: CatalogUi.meta),
      );
    }
    final searching = _catQuery.isNotEmpty;
    final many = cats.length > _topCategories;
    List<(String, int)> rows;
    if (searching) {
      rows = cats.where((c) => c.$1.toLowerCase().contains(_catQuery)).toList();
    } else if (!many || _allCats) {
      rows = cats;
    } else {
      final byCount = [...cats]..sort((a, b) => b.$2 != a.$2 ? b.$2.compareTo(a.$2) : a.$1.toLowerCase().compareTo(b.$1.toLowerCase()));
      final top = byCount.take(_topCategories).toList();
      rows = [...top, ...byCount.skip(_topCategories).where((c) => _cats.contains(c.$1))];
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (many)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: CatalogSearchField(
              controller: _catField,
              hint: 'Find a category',
              height: 34,
              onChanged: (v) => setState(() => _catQuery = v.trim().toLowerCase()),
              onClear: () {
                _catField.clear();
                setState(() => _catQuery = '');
              },
            ),
          ),
        for (final (name, n) in rows) CatalogCheckRow(label: name, count: n, selected: _cats.contains(name), onTap: () => _toggle(_cats, name)),
        if (searching && rows.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Text('No category matches', style: CatalogUi.meta),
          ),
        if (many && !searching)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _allCats = !_allCats),
              iconAlignment: IconAlignment.end,
              icon: Icon(_allCats ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18),
              label: Text(_allCats ? 'Show fewer' : 'Show all ${cats.length}'),
              style: TextButton.styleFrom(
                foregroundColor: DashUi.ink,
                textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
              ),
            ),
          ),
      ],
    );
  }

  static String _attnLabel(String key) => key == 'perjob' ? 'Per-job price' : (CatalogCheck.byKey(key)?.label ?? key);
  static Color _attnDot(String key) => switch (CatalogCheck.byKey(key)) {
    CatalogCheck.costAbove || CatalogCheck.highMarkup => DashUi.red,
    CatalogCheck.dupeName || CatalogCheck.dupePart || CatalogCheck.similarName => DashUi.indigo,
    CatalogCheck.noCost || CatalogCheck.noPart || CatalogCheck.noCategory => DashUi.amber,
    CatalogCheck.categoryOdd => DashUi.sky,
    _ => DashUi.muted,
  };

  /// All the filters. The sidebar scrolls them as one; the narrow window's dialog shows the same.
  Widget _filterGroups() {
    final inInv = _all.where((e) => e.inInventory).length;
    final inactive = _all.where((e) => !e.active).length;
    final inStock = _all.where(_inStock).length;
    final review = _all.where((e) => e.inventoryConflict != null).length;
    // The checks that found something (or are on), so a clean check takes no room.
    final attn = [
      for (final c in _quality.checks)
        if (c != CatalogCheck.linkReview && (_all.any((e) => _attention(c.key, e)) || _attn.contains(c.key))) c.key,
      'perjob',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CatalogFilterGroup(title: 'Category', picked: _cats.length, child: _categoryList()),
        CatalogFilterGroup(
          title: 'Status',
          picked: _act.length == 1 && _act.contains('active') ? 0 : 1,
          child: Column(
            children: [
              CatalogCheckRow(label: 'Active', count: _all.length - inactive, selected: _act.contains('active'), onTap: () => _toggle(_act, 'active')),
              CatalogCheckRow(label: 'Inactive', count: inactive, selected: _act.contains('inactive'), onTap: () => _toggle(_act, 'inactive')),
            ],
          ),
        ),
        CatalogFilterGroup(
          title: 'Inventory',
          picked: _inv.length,
          child: Column(
            children: [
              CatalogCheckRow(label: 'In inventory', count: inInv, selected: _inv.contains('in'), onTap: () => _toggle(_inv, 'in')),
              CatalogCheckRow(label: 'Not in inventory', count: _all.length - inInv, selected: _inv.contains('out'), onTap: () => _toggle(_inv, 'out')),
            ],
          ),
        ),
        CatalogFilterGroup(
          title: 'Stock',
          picked: _stockF.length,
          child: Column(
            children: [
              CatalogCheckRow(label: 'In stock', count: inStock, selected: _stockF.contains('instock'), onTap: () => _toggle(_stockF, 'instock')),
              if (review > 0 || _stockF.contains('review'))
                CatalogCheckRow(
                  label: 'Stock needs review',
                  count: review,
                  dot: DashUi.amber,
                  selected: _stockF.contains('review'),
                  onTap: () => _toggle(_stockF, 'review'),
                ),
            ],
          ),
        ),
        CatalogFilterGroup(
          title: 'Needs attention',
          picked: _attn.length,
          child: Column(
            children: [
              for (final a in attn)
                CatalogCheckRow(
                  label: _attnLabel(a),
                  count: _all.where((e) => _attention(a, e)).length,
                  dot: _attnDot(a),
                  selected: _attn.contains(a),
                  onTap: () => _toggle(_attn, a),
                ),
            ],
          ),
        ),
        CatalogFilterGroup(
          title: 'Product name',
          picked: _nameFilter.isEmpty ? 0 : 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: _textFilter(_nameField, 'Name contains', _nameFilter, (v) {
              final t = v.trim();
              if (t == _nameFilter) return;
              _newView(() {
                _nameFilter = t;
                _page = 1;
              });
            }),
          ),
        ),
        CatalogFilterGroup(
          title: 'Part number',
          picked: _partFilter.isEmpty ? 0 : 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: _textFilter(_partField, 'Part # contains', _partFilter, (v) {
              final t = v.trim();
              if (t == _partFilter) return;
              _newView(() {
                _partFilter = t;
                _page = 1;
              });
            }),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _filterSidebar() {
    return Container(
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: DashUi.line)),
      ),
      // Not selectable text: the app-wide selection's I-beam would replace the click cursor.
      child: SelectionContainer.disabled(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // As tall as the command row beside it, so the two hairlines run as one.
            Container(
              height: CatalogUi.commandHeight,
              padding: const EdgeInsets.fromLTRB(20, 0, 10, 0),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: DashUi.line)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.tune_rounded, size: 18, color: DashUi.slate),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Filters',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: DashUi.ink),
                    ),
                  ),
                  AnimatedOpacity(
                    key: const ValueKey('clear-all'),
                    opacity: _filterCount == 0 ? 0 : 1,
                    duration: CatalogUi.motion(context),
                    child: TextButton(
                      onPressed: _filterCount == 0 ? null : _resetFilters,
                      style: TextButton.styleFrom(
                        foregroundColor: DashUi.ink,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 32),
                      ),
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
            Expanded(
              child: SingleChildScrollView(padding: const EdgeInsets.only(top: 6), child: _filterGroups()),
            ),
          ],
        ),
      ),
    );
  }

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
                    icon: accessIcon('catalog'),
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
                  child: Text(
                    '$n',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ),
              ],
            ],
          ),
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
    textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
  );

  /// The filters that are on, each one a chip that takes it off.
  List<({String group, String value, VoidCallback remove})> get _chips => [
    for (final c in _cats.toList()..sort()) (group: 'Category', value: c, remove: () => _toggle(_cats, c)),
    if (_act.length == 1 && _act.contains('inactive')) (group: 'Status', value: 'Inactive only', remove: _resetStatus),
    if (_act.length != 1) (group: 'Status', value: 'Active and inactive', remove: _resetStatus),
    for (final v in _inv) (group: 'Inventory', value: v == 'in' ? 'In inventory' : 'Not in inventory', remove: () => _toggle(_inv, v)),
    for (final v in _stockF) (group: 'Stock', value: v == 'instock' ? 'In stock' : 'Needs review', remove: () => _toggle(_stockF, v)),
    for (final v in _attn) (group: 'Attention', value: _attnLabel(v), remove: () => _toggle(_attn, v)),
    if (_nameFilter.isNotEmpty) (group: 'Name', value: '"$_nameFilter"', remove: _clearName),
    if (_partFilter.isNotEmpty) (group: 'Part #', value: '"$_partFilter"', remove: _clearPart),
  ];

  // ---- list -------------------------------------------------------------------

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
                Text(
                  ' of ${_count.format(_all.length)}',
                  style: const TextStyle(fontSize: 13.5, color: DashUi.slate, fontFeatures: CatalogUi.figures),
                ),
              ],
            )
          : Text(
              shown == 1 ? '1 product' : '${_count.format(shown)} products',
              style: strong.copyWith(color: DashUi.slate, fontWeight: FontWeight.w600),
            ),
    );
  }

  Widget _searchBox() {
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _clearSearch},
      child: CatalogSearchField(
        controller: _search,
        focusNode: _searchFocus,
        hint: 'Search name, part #, category or description',
        shortcutHint: true,
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
        if (!small) ...[const SizedBox(width: 14), Expanded(child: _ChipStrip(chips: chips)), const SizedBox(width: 14), _countLabel(shown)],
      ],
    );
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: DashUi.line)),
      ),
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

  Widget _sortMenu() {
    final cols = _sorts.where((s) => _canSeeCost || (s.$1 != 'cost' && s.$1 != 'margin')).toList();
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
                    child: Text(
                      name,
                      style: TextStyle(fontWeight: _sortKey == key ? FontWeight.w700 : FontWeight.w500, color: DashUi.ink),
                    ),
                  ),
                  if (_sortKey == key) Icon(_ascending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 16, color: DashUi.ink),
                ],
              ),
            ),
        ],
        child: Container(
          height: 38,
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
              Text(
                label,
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink),
              ),
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
    final dupes = _quality.groupCount(CatalogCheck.dupeName) + _quality.groupCount(CatalogCheck.dupePart) + _quality.groupCount(CatalogCheck.similarName);
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageBanner(
            title: 'Product Catalog',
            icon: accessIcon('catalog'),
            activity: _activity,
            titleTrailing: RibbonTabs<CatalogView>(
              value: _view,
              onChanged: _switchView,
              tabs: [
                const RibbonTab(CatalogView.products, 'Products'),
                const RibbonTab(CatalogView.categories, 'Categories'),
                RibbonTab(CatalogView.cleanup, 'Cleanup', badge: _loading ? null : dupes),
                const RibbonTab(CatalogView.history, 'History'),
              ],
            ),
            actions: [
              if (_view == CatalogView.products) ...[
                if (_all.isNotEmpty) RibbonGhostButton(icon: Icons.file_download_outlined, label: 'Export', onPressed: _export),
                if (_canEdit) PageBanner.button(icon: Icons.add_rounded, label: 'New product', onPressed: _newProduct),
              ],
              if (_view == CatalogView.categories && _canEdit && _manageLive)
                PageBanner.button(icon: Icons.create_new_folder_outlined, label: 'New category', onPressed: () => catalogNewCategory(_categoriesKey)),
              RibbonRefreshButton(onPressed: _loading ? null : _load),
            ],
          ),
          Expanded(
            child: PageSheet(child: LayoutBuilder(builder: (context, c) => _viewBody(c.maxWidth))),
          ),
        ],
      ),
    );
  }

  /// The view on screen. Views stay alive once opened (their picks and scroll survive a switch); the products view's
  /// loading and error states stand in for all of them, since they all read the same list.
  Widget _viewBody(double width) {
    if (_loading || (_error != null && _all.isEmpty) || _all.isEmpty) return _body(width);
    Widget lazy(CatalogView v, Widget Function() build) => _visited.contains(v) ? build() : const SizedBox.shrink();
    return IndexedStack(
      index: _view.index,
      sizing: StackFit.expand,
      children: [
        _body(width),
        lazy(
          CatalogView.categories,
          () => CatalogCategoriesView(
            key: _categoriesKey,
            entries: _all,
            categories: _categories,
            canEdit: _canEdit,
            manager: _manager ?? const CatalogManager(),
            initialCategory: _categoryToOpen,
            onChanged: _load,
            onShowInList: _showCategory,
            onShowUncategorized: () => _showCheck(CatalogCheck.noCategory),
            onOpenProduct: _openEntry,
            onSnack: _snack,
          ),
        ),
        lazy(
          CatalogView.cleanup,
          () => CatalogCleanupView(
            quality: _quality,
            entries: _all,
            canEdit: _canEdit && _manageLive,
            canSeeCost: _canSeeCost,
            reviewsLive: _reviewsLive,
            reviews: _reviews,
            categoryNamingIssues: categoryNameIssues([for (final (n, _) in _categoryCounts) n]).length,
            historyDays: _historyDays,
            manager: _manager ?? const CatalogManager(),
            onShowCheck: _showCheck,
            onShowCategoryNaming: () => _openCategory(null),
            onOpenProduct: _openEntry,
            onChanged: _load,
            onSnack: _snack,
          ),
        ),
        lazy(
          CatalogView.history,
          () => CatalogHistoryView(
            key: _historyKey,
            manager: _manager ?? const CatalogManager(),
            names: {
              for (final e in _all)
                if (_idOf(e) != null) _idOf(e)!: e.name,
            },
            onOpenProduct: (id) => GoRouter.maybeOf(context)?.go('/inventory/catalog/$id'),
          ),
        ),
      ],
    );
  }

  Widget _body(double width) {
    final scale = MediaQuery.textScalerOf(context);
    // Larger text needs the room too, so the sidebar and the columns give way sooner.
    final wide = width >= CatalogUi.sidebarWidth + scale.scale(_tableWidth);
    if (_loading) return _loadingView(width, wide);
    if (_error != null && _all.isEmpty) {
      return Center(
        child: FlatEmpty(icon: Icons.cloud_off_rounded, title: 'Could not load the catalog', message: _error!, action: AppButton.ink('Try again', _load)),
      );
    }
    if (_all.isEmpty) {
      return Center(
        child: FlatEmpty(
          icon: Icons.inventory_2_outlined,
          title: 'No products yet',
          message: 'The product price list has not been loaded.',
          action: AppButton.ghost('Refresh', _load),
        ),
      );
    }
    if (!wide) return _listPane(filterButton: true);
    if (_sidebarHidden) return _listPane(filterButton: true, reopensSidebar: true);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: CatalogUi.sidebarWidth, child: _filterSidebar()),
        Expanded(child: _listPane(filterButton: false)),
      ],
    );
  }

  /// Loading: the page's own frame with pulsing rows, so nothing jumps when the list lands.
  Widget _loadingView(double width, bool wide) {
    final listWidth = wide ? width - CatalogUi.sidebarWidth : width;
    // Stacked rows on a narrow window: one placeholder column, not the table's fixed ones.
    final cols = listWidth >= _tableWidth ? _cols(listWidth) : const [CatalogCol('PRODUCT')];
    final pane = Semantics(
      label: 'Loading the product catalog',
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: CatalogUi.commandHeight,
            padding: const EdgeInsets.symmetric(horizontal: CatalogUi.side),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: DashUi.line)),
            ),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: DashUi.slate)),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    _slow ? 'Still loading. The server can take a moment when it has just started.' : 'Loading the product catalog',
                    style: CatalogUi.meta.copyWith(fontSize: 13.5),
                  ),
                ),
              ],
            ),
          ),
          // The price list's products all have pick boxes: keep their lead so the columns don't shift when the list lands.
          if (listWidth >= _tableWidth)
            CatalogTableHeader(cols: cols, sortKey: _sortKey, ascending: _ascending, onSort: (_) {}, leading: const SizedBox(width: 16)),
          Expanded(
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.topCenter,
                maxHeight: double.infinity,
                child: CatalogSkeleton(cols: cols, rows: 24, lead: listWidth >= _tableWidth),
              ),
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
          decoration: const BoxDecoration(
            border: Border(right: BorderSide(color: DashUi.line)),
          ),
          alignment: Alignment.topLeft,
          child: Container(
            height: CatalogUi.commandHeight,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: DashUi.line)),
            ),
            child: const Row(
              children: [
                Icon(Icons.tune_rounded, size: 18, color: DashUi.slate),
                SizedBox(width: 8),
                Text(
                  'Filters',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: DashUi.ink),
                ),
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
        // Before the columns: the header's pick box reads the page.
        _shownNow = shown;
        _pageNow = rows;
        final cols = _cols(c.maxWidth);
        final picking = _selected.isNotEmpty;
        final pane = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _commandRow(filterButton: filterButton, compact: compact, shown: shown.length, width: c.maxWidth, reopensSidebar: reopensSidebar),
            if (_error != null) FlatStaleNotice(message: '$_error The list below may be out of date.', busy: false, onRetry: _load),
            if (shown.isEmpty)
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    child: FlatEmpty(
                      icon: Icons.search_off_rounded,
                      title: 'No products match',
                      message: 'Try other words, or take off some filters.',
                      action: AppButton.ghost('Clear search and filters', _clearAll),
                    ),
                  ),
                ),
              )
            else ...[
              if (!compact)
                CatalogTableHeader(
                  key: const ValueKey('catalog-header'),
                  cols: cols,
                  sortKey: _sortKey,
                  ascending: _ascending,
                  onSort: _sort,
                  leading: _selectable ? _pageBox() : null,
                ),
              Expanded(
                child: ListView.builder(
                  controller: _scroll,
                  // While products are picked the bar floats over the list's foot: room so the last row can scroll clear of it.
                  padding: EdgeInsets.only(bottom: picking ? 72 : 0),
                  itemCount: rows.length,
                  itemBuilder: (_, i) {
                    final e = rows[i];
                    final row = compact
                        ? KeyedSubtree(key: ValueKey('row:${e.key}'), child: _compactRow(e, i, start + i))
                        : CatalogRow(
                            key: ValueKey('row:${e.key}'),
                            cols: cols,
                            cells: _cells(e),
                            index: i,
                            selected: _selected.contains(e.key),
                            leading: _selectable ? _pickBox(e, start + i) : null,
                            semanticLabel: 'Product ${e.name}',
                            onTap: () => _openEntry(e),
                          );
                    return flatRowEntrance(_rowsIn, i, row);
                  },
                ),
              ),
              CatalogPager(
                key: const ValueKey('catalog-footer'),
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
        return Stack(
          children: [
            Positioned.fill(child: pane),
            Positioned(
              left: 16,
              right: 16,
              bottom: CatalogUi.footerHeight + 12,
              child: IgnorePointer(
                ignoring: !picking,
                child: AnimatedSlide(
                  offset: picking ? Offset.zero : const Offset(0, 0.4),
                  duration: CatalogUi.motion(context, 220),
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    opacity: picking ? 1 : 0,
                    duration: CatalogUi.motion(context, 180),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 980),
                        child: picking ? _selectionBar(shown) : const SizedBox(height: 52),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The filters that are on, as chips on one line: as many as fit, then "+N more", which lists the rest to take off.
class _ChipStrip extends StatelessWidget {
  final List<({String group, String value, VoidCallback remove})> chips;
  const _ChipStrip({required this.chips});

  static const _gap = 6.0;

  static double _width(BuildContext context, String group, String value) {
    final p = TextPainter(
      text: TextSpan(
        children: [
          TextSpan(
            text: '$group  ',
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
          TextSpan(
            text: value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ],
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    return p.width + 11 + 4 + 20 + 5 + 2; // padding, gap, the x, padding, rounding
  }

  @override
  Widget build(BuildContext context) {
    if (chips.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, c) {
        const moreWidth = 84.0;
        var used = 0.0;
        var fit = 0;
        for (var i = 0; i < chips.length; i++) {
          final w = _width(context, chips[i].group, chips[i].value) + (i > 0 ? _gap : 0);
          final reserve = i < chips.length - 1 ? moreWidth + _gap : 0;
          if (used + w + reserve > c.maxWidth) break;
          used += w;
          fit++;
        }
        final hidden = chips.skip(fit).toList();
        return ClipRect(
          child: Row(
            children: [
              for (var i = 0; i < fit; i++) ...[
                if (i > 0) const SizedBox(width: _gap),
                Flexible(
                  child: CatalogFilterChip(
                    key: ValueKey('${chips[i].group}:${chips[i].value}'),
                    group: chips[i].group,
                    value: chips[i].value,
                    onRemove: chips[i].remove,
                  ),
                ),
              ],
              if (hidden.isNotEmpty) ...[
                if (fit > 0) const SizedBox(width: _gap),
                MenuAnchor(
                  alignmentOffset: const Offset(0, 4),
                  menuChildren: [
                    for (final h in hidden)
                      MenuItemButton(
                        onPressed: h.remove,
                        trailingIcon: const Icon(Icons.close_rounded, size: 16, color: DashUi.slate),
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '${h.group}  ',
                                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: DashUi.slate),
                              ),
                              TextSpan(
                                text: h.value,
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.ink),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                  builder: (context, controller, _) => TextButton(
                    onPressed: () => controller.isOpen ? controller.close() : controller.open(),
                    style: TextButton.styleFrom(
                      foregroundColor: DashUi.ink,
                      minimumSize: const Size(0, 30),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                        side: const BorderSide(color: DashUi.line),
                      ),
                      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                    child: Text('+${hidden.length} more'),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
