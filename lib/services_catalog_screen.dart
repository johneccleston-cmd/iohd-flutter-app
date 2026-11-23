import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'config/access.dart';
import 'service_detail_screen.dart';
import 'services/line_items_api.dart';
import 'utils/product_csv.dart';
import 'widgets/app_dialog.dart';
import 'widgets/app_menu.dart';
import 'widgets/app_ribbon.dart';
import 'widgets/catalog_kit.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';
import 'widgets/focus_ring.dart';

/// Services Catalog: every service the office has put on a job or estimate line, with the price it usually charges.
/// Service Fusion has no price-list endpoint, so (like the job page's catalog search) the list is built from the
/// synced lines of the last 18 months. Click a service to open its own page (service_detail_screen.dart), where it can be
/// edited: the edit is saved in our own database as an override laid over what the lines say. Nothing here is ever
/// written back to Service Fusion.
///
/// Redesign (2026-11-19): search first, with the status as tabs beside it (Active / Inactive / All, each with how many
/// match); a Category column and the fixed service categories in the sidebar (with how many still have none); how much
/// a service is used as a sort, a filter and a quiet flag on the rarely used ones (the Times used / Last used columns
/// stay gone, USER RULE 11-19: the table's figures are Cost and Price); and pick boxes for moving several services to a
/// category or switching them on or off at once (each is the same one-service save the service page makes).
class ServicesCatalogScreen extends StatefulWidget {
  /// Swappable for tests; the real call is [LineItemsApi.listCatalog].
  final Future<({List<CatalogEntry> entries, bool canSeeCost, int historyDays})> Function()? load;

  /// Tests pass a fake for saving the export file; the app uses the save dialog.
  final Future<bool> Function(String fileName, Uint8List bytes)? exporter;

  /// Tests pass a fake for saving one service (the bulk changes); the app calls [LineItemsApi.saveService].
  final Future<CatalogEntry> Function(String key, Map<String, dynamic> fields)? saver;

  /// Whether the person may change services ([canEditServices]). Null: asked of the session.
  final bool? canEdit;
  const ServicesCatalogScreen({super.key, this.load, this.exporter, this.saver, this.canEdit});

  @override
  State<ServicesCatalogScreen> createState() => _ServicesCatalogScreenState();
}

/// The filters a count can leave out (each filter group counts as if its own picks were off).
enum _Facet { status, category, price }

/// A sort the menu offers: its key, its direction and how it reads.
typedef _SortOption = ({String key, bool ascending, String label});

class _ServicesCatalogScreenState extends State<ServicesCatalogScreen> with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  @override
  bool get wantKeepAlive => true;

  static const _tableWidth = 640.0; // below this the rows stack
  static const _categoryColumnFrom = 860.0; // the Category column needs this much room; below it the category goes under the name
  static const _bulkWorkers = 4; // saves running at once during a change to several services

  static const List<_SortOption> _sortOptions = [
    (key: 'name', ascending: true, label: 'Name A–Z'),
    (key: 'category', ascending: true, label: 'Category'),
    (key: 'uses', ascending: false, label: 'Most used'),
    (key: 'last', ascending: false, label: 'Recently used'),
    (key: 'last', ascending: true, label: 'Unused the longest'),
    (key: 'price', ascending: false, label: 'Highest price'),
    (key: 'price', ascending: true, label: 'Lowest price'),
    (key: 'cost', ascending: false, label: 'Highest cost'),
    (key: 'cost', ascending: true, label: 'Lowest cost'),
  ];

  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'services-search');
  final _scroll = ScrollController();
  final _activity = RibbonActivity();
  final _filterTick = ValueNotifier<int>(0); // tells the Filters dialog (narrow windows) to redraw
  late final _rowsIn = AnimationController(vsync: this, duration: const Duration(milliseconds: 460), value: 1);
  Timer? _slowTimer;
  Timer? _debounce;

  List<CatalogEntry> _all = const [];
  bool _canSeeCost = false;
  int _historyDays = 540;
  bool _loading = true;
  bool _slow = false; // the first load has taken long enough to say the server may be waking up
  String? _error;

  /// The server refused the list (403): this person's Services Catalog switch is off (Team).
  bool _noAccess = false;
  int _request = 0; // a late answer from an older request is dropped

  /// Services saved since the page opened, with when: a list read that started before a save must not undo it on screen.
  final Map<String, (CatalogEntry, DateTime)> _saved = {};

  String _query = '';
  String _sortKey = 'name';
  bool _ascending = true;
  int _page = 1;
  int _pageSize = 50;

  /// 'active' (the page's starting view), 'inactive' or 'all'. While searching on Active, inactive matches follow the
  /// active ones under their own label, so an old name still finds its service.
  String _status = 'active';

  // The filters. An empty group does not filter.
  final Set<String> _cats = {}; // a category of kServiceCategories, or '' for "No category"
  final Set<String> _price = {}; // priced | unpriced

  // Pick boxes (with Services Catalog > Update): the services picked, and the last one clicked (for Shift+click ranges).
  final Set<String> _selected = {};
  String? _anchor;
  bool _bulkRunning = false;

  /// The filter sidebar put away to give the table its room (kept while the app is open).
  static bool _sidebarHidden = false;

  final _hay = Expando<String>('service-search-text');

  bool get _canEdit => widget.canEdit ?? canEditServices();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    serviceChanged.addListener(_onServiceChanged);
    _fetch();
  }

  /// A service was saved or reset on its own page: show it in place, so the list keeps its order and its scroll.
  void _onServiceChanged() {
    final saved = serviceChanged.value;
    if (saved == null || !mounted) return;
    _keep(saved);
  }

  /// Puts a saved service in the list (and remembers it, see [_saved]).
  void _keep(CatalogEntry saved) {
    _saved[saved.key] = (saved, DateTime.now());
    setState(() => _all = [for (final x in _all) x.key == saved.key ? saved : x]);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    serviceChanged.removeListener(_onServiceChanged);
    _slowTimer?.cancel();
    _debounce?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    _filterTick.dispose();
    _rowsIn.dispose();
    _activity.dispose();
    super.dispose();
  }

  /// "/" jumps to the search box, while this page is the one on screen and no text box has the keyboard.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.character != '/' || !mounted) return false;
    if (!TickerMode.valuesOf(context).enabled) return false; // another tab of the app is showing
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false; // a dialog is on top
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null && (focused.widget is EditableText || focused.findAncestorWidgetOfExactType<EditableText>() != null)) return false;
    _searchFocus.requestFocus();
    return true;
  }

  Future<void> _fetch() async {
    final id = ++_request;
    final first = _all.isEmpty;
    final started = DateTime.now();
    _slowTimer?.cancel();
    if (first) {
      _slowTimer = Timer(const Duration(seconds: 8), () {
        if (mounted && _loading) setState(() => _slow = true);
      });
    }
    setState(() {
      _loading = first;
      _error = null;
    });
    _activity.setRefreshing(true);
    try {
      // Inactive too: switched off here, or taken over by a renamed line; kept with its history.
      final r = await (widget.load ?? () => LineItemsApi.listCatalog(kind: 'service', includeInactive: true))();
      if (!mounted || id != _request) return;
      setState(() {
        // A save that landed while this read was on its way is newer than what the read brought back.
        _all = [
          for (final e in r.entries)
            if (_saved[e.key] case (final s, final at) when at.isAfter(started)) s else e,
        ];
        _canSeeCost = r.canSeeCost;
        _historyDays = r.historyDays;
        _noAccess = false;
        _loading = false;
        _slow = false;
        final keys = {for (final e in _all) e.key};
        _selected.removeWhere((k) => !keys.contains(k)); // a service that is gone cannot stay picked
      });
      _activity.landed();
    } catch (e) {
      if (!mounted || id != _request) return;
      setState(() {
        _error = e is LineItemsException ? e.message : 'Could not load the services.';
        // No access (the switch is off, or was turned off since the page opened): nothing of the list stays on show.
        _noAccess = e is LineItemsException && e.status == 403;
        if (_noAccess) {
          _all = const [];
          _selected.clear();
        }
        _loading = false;
        _slow = false;
      });
    } finally {
      _slowTimer?.cancel();
      if (mounted && id == _request) _activity.setRefreshing(false);
    }
  }

  // ---- what a service is ----------------------------------------------------------------------------------------

  static String _groupOf(CatalogEntry e) => (e.group.isEmpty ? e.category : e.group).trim();

  /// Its category: one of the service categories, or '' while it is still in a Service Fusion group (or in none).
  static String _catOf(CatalogEntry e) {
    final g = _groupOf(e);
    return kServiceCategories.contains(g) ? g : '';
  }

  /// When it was last on a line (the Recently used / Unused the longest sorts). Rows don't print it (USER RULE
  /// 2026-11-19: no "Last used" text).
  static DateTime? _lastOf(CatalogEntry e) => e.lastUsed == null ? null : DateTime.tryParse(e.lastUsed!);

  /// What a search looks through: its name, description, category, other names and the names it replaced, folded so
  /// "liftmaster 6690" finds "LiftMaster | 8' 6690L" and "lift master" finds it too.
  String _hayOf(CatalogEntry e) =>
      _hay[e] ??= _fold('${e.name} ${e.description} ${_groupOf(e)} ${e.aliases.join(' ')} ${e.replaces.map((r) => r.name).join(' ')}');

  static String _fold(String s) => s.toLowerCase().replaceAll(RegExp(r"[^a-z0-9$.'&+]+"), ' ').trim();

  List<String> get _words => _fold(_query).split(' ').where((w) => w.isNotEmpty).toList();

  bool _hit(CatalogEntry e, List<String> words) {
    if (words.isEmpty) return true;
    final hay = _hayOf(e);
    final tight = hay.replaceAll(' ', '');
    return words.every((w) => hay.contains(w) || tight.contains(w));
  }

  bool _statusPasses(CatalogEntry e) => switch (_status) {
    'inactive' => !e.active,
    'all' => true,
    _ => e.active,
  };

  /// Whether [e] passes the search and every filter, leaving out [skip] (a filter group's own counts ignore its picks).
  bool _match(CatalogEntry e, List<String> words, {_Facet? skip}) {
    if (skip != _Facet.status && !_statusPasses(e)) return false;
    if (skip != _Facet.category && _cats.isNotEmpty && !_cats.contains(_catOf(e))) return false;
    if (skip != _Facet.price && _price.length == 1 && (e.rate != null) != _price.contains('priced')) return false;
    return _hit(e, words);
  }

  int _compare(CatalogEntry a, CatalogEntry b) {
    // Nothing to compare (no price, never used) always goes last, whichever way the column is sorted.
    int nullsLast<T extends Comparable<T>>(T? x, T? y) {
      if (x == null || y == null) return x == null ? (y == null ? 0 : 1) : -1;
      return _ascending ? x.compareTo(y) : y.compareTo(x);
    }

    final c = switch (_sortKey) {
      'cost' => nullsLast<num>(a.cost, b.cost),
      'price' => nullsLast<num>(a.rate, b.rate),
      'uses' => nullsLast<num>(a.uses, b.uses),
      'last' => nullsLast<DateTime>(_lastOf(a), _lastOf(b)),
      'category' => nullsLast<String>(_catOf(a).isEmpty ? null : _catOf(a).toLowerCase(), _catOf(b).isEmpty ? null : _catOf(b).toLowerCase()),
      _ => _ascending ? a.name.toLowerCase().compareTo(b.name.toLowerCase()) : b.name.toLowerCase().compareTo(a.name.toLowerCase()),
    };
    return c != 0 ? c : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  /// The list to show, in order, and where the inactive matches of a search on Active start (-1: none).
  ({List<CatalogEntry> rows, int extrasFrom}) _view() {
    final words = _words;
    final main = _all.where((e) => _match(e, words)).toList()..sort(_compare);
    if (_status != 'active' || words.isEmpty) return (rows: main, extrasFrom: -1);
    final extras = _all.where((e) => !e.active && _match(e, words, skip: _Facet.status)).toList()..sort(_compare);
    return (rows: [...main, ...extras], extrasFrom: extras.isEmpty ? -1 : main.length);
  }

  /// How many services each status tab holds with the search and the other filters as they are.
  ({int active, int inactive, int all}) _statusCounts() {
    final words = _words;
    var active = 0, all = 0;
    for (final e in _all) {
      if (!_match(e, words, skip: _Facet.status)) continue;
      all++;
      if (e.active) active++;
    }
    return (active: active, inactive: all - active, all: all);
  }

  /// How many services [value] of a filter group would show, with every other filter (and the search) as it is.
  Map<String, int> _facetCounts(_Facet facet, String Function(CatalogEntry) valueOf) {
    final words = _words;
    final out = <String, int>{};
    for (final e in _all) {
      if (!_match(e, words, skip: facet)) continue;
      final v = valueOf(e);
      out[v] = (out[v] ?? 0) + 1;
    }
    return out;
  }

  /// How many filters are set (the status tabs are not filters: they are always one of three).
  int get _filterCount => (_cats.isEmpty ? 0 : 1) + (_price.isEmpty ? 0 : 1);

  // ---- changing the view ------------------------------------------------------------------------------------------

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

  /// A header click: the same column again turns it around; another starts in its natural direction.
  void _sort(String key) => _newView(() {
    if (_sortKey == key) {
      _ascending = !_ascending;
    } else {
      _sortKey = key;
      _ascending = key == 'name' || key == 'category'; // words read A to Z first; figures and dates biggest first
    }
    _page = 1;
  });

  void _sortTo(_SortOption o) => _newView(() {
    _sortKey = o.key;
    _ascending = o.ascending;
    _page = 1;
  });

  void _toggle(Set<String> group, String value) => _newView(() {
    if (!group.remove(value)) group.add(value);
    _page = 1;
  });

  void _setStatus(String s) {
    if (s == _status) return;
    _newView(() {
      _status = s;
      _page = 1;
    });
  }

  void _resetFilters() {
    _newView(() {
      _cats.clear();
      _price.clear();
      _page = 1;
    });
  }

  void _clearAll() {
    _debounce?.cancel();
    _search.clear();
    _query = '';
    _status = 'active';
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

  // ---- open, export -----------------------------------------------------------------------------------------------

  static final _count = NumberFormat.decimalPattern();
  static String _plural(int n, String one, [String? many]) => '${_count.format(n)} ${n == 1 ? one : (many ?? '${one}s')}';

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 3), behavior: SnackBarBehavior.floating, width: 380));
  }

  /// A service opens on its own page (its row is handed over, so the page shows at once). Without a router (a test's
  /// bare page) it is pushed.
  void _open(CatalogEntry e) {
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      router.go(serviceLocation(e.key), extra: e);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ServiceDetailScreen(serviceKey: e.key, initial: e, loader: widget.load),
      ),
    );
  }

  static Future<bool> _saveCsv(String fileName, Uint8List bytes) async {
    final saved = await FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: const ['csv'],
      dialogTitle: 'Export services',
    );
    // On the web the browser downloads the file and the picker always answers null, so that is a save too.
    return saved != null || kIsWeb;
  }

  /// Saves [list] (every service the view shows, not just this page, or the picked ones) as a CSV file.
  Future<void> _export(List<CatalogEntry> list) async {
    if (list.isEmpty) {
      _snack('Nothing to export: no services match.');
      return;
    }
    final fileName = 'services-catalog-${DateFormat('yyyy-MM-dd').format(DateTime.now())}.csv';
    try {
      final saved = await (widget.exporter ?? _saveCsv)(fileName, productCatalogCsvBytes(servicesCatalogCsv(list, canSeeCost: _canSeeCost)));
      if (saved) _snack('Exported ${_plural(list.length, 'service')}');
    } catch (_) {
      _snack('Could not save the file. Try again.');
    }
  }

  // ---- changes to several services -------------------------------------------------------------------------------

  List<CatalogEntry> get _picked => [
    for (final e in _all)
      if (_selected.contains(e.key)) e,
  ];

  /// What the job lines say for [field] (the value a reset would bring back).
  static Object? _computed(CatalogEntry e, String field, Object? current) =>
      e.computed != null && e.computed!.containsKey(field) ? e.computed![field] : current;

  /// The save that puts [e] in [category] ('' = no category: back to its Service Fusion group), or null when it is
  /// there already. Like the service page, a value the job lines already have is sent as null (the edit is dropped).
  static Map<String, dynamic>? _categoryChange(CatalogEntry e, String category) {
    if (_catOf(e) == category) return null;
    if (category.isEmpty) return e.editedFields.contains('category') ? {'category': null} : null;
    final original = (_computed(e, 'category', _groupOf(e)) ?? '').toString().trim();
    return {'category': category == original ? null : category};
  }

  static Map<String, dynamic>? _statusChange(CatalogEntry e, bool active) {
    if (e.active == active) return null;
    return {'active': _computed(e, 'active', e.active) == active ? null : active};
  }

  /// Saves [change] for each of [targets] (a few at a time), with a progress dialog, then says how it went. A service
  /// that is already so is left alone; one that fails stays picked so it can be tried again.
  Future<void> _runBulk({required List<CatalogEntry> targets, required Map<String, dynamic>? Function(CatalogEntry) change, required String title, required String Function(int n) done}) async {
    final work = [
      for (final e in targets)
        if (change(e) case final c?) (e, c),
    ];
    final skipped = targets.length - work.length;
    if (work.isEmpty) {
      _snack(targets.length == 1 ? 'Nothing to change: it is like that already.' : 'Nothing to change: they are all like that already.');
      return;
    }
    final progress = ValueNotifier<int>(0);
    setState(() => _bulkRunning = true);
    // The progress dialog is pushed as a route and later removed as that route: the saves can finish before it has
    // even been built (a quick answer, or an instant 401), and it must still go away.
    final nav = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return PopScope(
          canPop: false,
          child: AppDialog(
            title: title,
            icon: accessIcon('services_catalog'),
            width: 420,
            body: ValueListenableBuilder<int>(
              valueListenable: progress,
              builder: (_, n, _) => Semantics(
                liveRegion: true,
                label: 'Saved $n of ${work.length}',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(value: work.isEmpty ? null : n / work.length, minHeight: 6, color: DashUi.ink, backgroundColor: DashUi.faint),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '${_count.format(n)} of ${_plural(work.length, 'service')} saved',
                      style: const TextStyle(fontSize: 13.5, color: DashUi.slate, fontFeatures: CatalogUi.figures),
                    ),
                  ],
                ),
              ),
            ),
            actions: const [],
          ),
        );
      },
    );
    unawaited(nav.push(route));
    final saver = widget.saver ?? LineItemsApi.saveService;
    final saved = <CatalogEntry>[];
    final failed = <(CatalogEntry, String)>[];
    var next = 0;
    Future<void> worker() async {
      while (next < work.length) {
        final (e, fields) = work[next++];
        try {
          saved.add(await saver(e.key, fields));
        } catch (err) {
          failed.add((e, err is LineItemsException ? err.message : 'Could not save.'));
          if (err is LineItemsException && err.status == 401) return; // signed out: the rest would fail the same way
        }
        progress.value++;
      }
    }

    await Future.wait([for (var i = 0; i < _bulkWorkers; i++) worker()]);
    if (route.isActive) nav.removeRoute(route);
    progress.dispose();
    if (!mounted) return;
    final now = DateTime.now();
    setState(() {
      _bulkRunning = false;
      final byKey = {for (final s in saved) s.key: s};
      for (final s in saved) {
        _saved[s.key] = (s, now);
      }
      _all = [for (final x in _all) byKey[x.key] ?? x];
      // Done (saved, or already so) is unpicked; only a failure stays picked, to try again.
      final failedKeys = {for (final (e, _) in failed) e.key};
      _selected.removeWhere((k) => !failedKeys.contains(k) && targets.any((e) => e.key == k));
    });
    if (failed.isEmpty) {
      final also = skipped > 0 ? ' (${_count.format(skipped)} ${skipped == 1 ? 'was' : 'were'} already so)' : '';
      _snack('${done(saved.length)}$also');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AppDialog(
        title: saved.isEmpty ? 'Nothing was saved' : '${_count.format(saved.length)} of ${_count.format(work.length)} saved',
        subtitle: '${_plural(failed.length, 'service')} could not be saved. They are still selected, so you can try again.',
        icon: Icons.error_outline_rounded,
        iconColor: DashUi.redText,
        width: 520,
        body: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (e, why) in failed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: e.name, style: const TextStyle(fontWeight: FontWeight.w700, color: DashUi.ink)),
                          TextSpan(text: '  $why', style: const TextStyle(color: DashUi.slate)),
                        ],
                      ),
                      style: const TextStyle(fontSize: 13.5, height: 1.35),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [AppButton.ink('OK', () => Navigator.pop(ctx))],
      ),
    );
  }

  /// Move to category: the categories to pick from (with how many of the picked services each already holds).
  Future<void> _bulkCategory() async {
    final picked = _picked;
    if (picked.isEmpty || _bulkRunning) return;
    final here = <String, int>{};
    for (final e in picked) {
      here[_catOf(e)] = (here[_catOf(e)] ?? 0) + 1;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) {
        String? pick;
        return StatefulBuilder(
          builder: (ctx, set) => AppDialog(
            title: 'Move ${_plural(picked.length, 'service')}',
            subtitle: 'Lines already on jobs and estimates do not change.',
            icon: Icons.drive_file_move_outline,
            width: 480,
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final c in [...kServiceCategories, ''])
                  _ChoiceRow(
                    key: ValueKey('move-to:$c'),
                    // The keyboard starts on the first choice (it started nowhere: Tab went to the close button first).
                    autofocus: c == kServiceCategories.first,
                    label: c.isEmpty ? 'No category' : c,
                    trailing: (here[c] ?? 0) == 0 ? null : (here[c] == picked.length ? 'all here now' : '${here[c]} here now'),
                    selected: pick == c,
                    onTap: () => set(() => pick = c),
                  ),
              ],
            ),
            actions: [
              AppButton.ghost('Cancel', () => Navigator.pop(ctx)),
              AppButton.ink('Move', pick == null ? null : () => Navigator.pop(ctx, pick)),
            ],
          ),
        );
      },
    );
    if (choice == null || !mounted) return;
    await _runBulk(
      targets: picked,
      change: (e) => _categoryChange(e, choice),
      title: 'Moving ${_plural(picked.length, 'service')}',
      done: (n) => choice.isEmpty ? 'Took ${_plural(n, 'service')} out of their category' : 'Moved ${_plural(n, 'service')} to $choice',
    );
  }

  /// Make active / inactive, after saying what it does.
  Future<void> _bulkStatus(bool active) async {
    final picked = _picked;
    if (picked.isEmpty || _bulkRunning) return;
    final n = picked.where((e) => e.active != active).length;
    final word = active ? 'active' : 'inactive';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        title: 'Make ${_plural(n == 0 ? picked.length : n, 'service')} $word?',
        icon: active ? Icons.check_circle_outline_rounded : Icons.do_not_disturb_on_outlined,
        width: 480,
        body: Text(
          [
            active
                ? 'They are offered again when lines are added to jobs and estimates.'
                : 'They stay in the catalog with their history, but are no longer offered when lines are added to jobs and estimates.',
            'Lines already on jobs and estimates do not change.',
            if (n < picked.length) '${_plural(picked.length - n, 'selected service')} ${picked.length - n == 1 ? 'is' : 'are'} $word already.',
          ].join(' '),
          style: const TextStyle(fontSize: 14, height: 1.45, color: DashUi.slate),
        ),
        actions: [
          AppButton.ghost('Cancel', () => Navigator.pop(ctx, false)),
          // Opens on the answer asked for (it can be undone the same way), so Enter confirms; Esc still cancels.
          AppButton.ink(active ? 'Make active' : 'Make inactive', n == 0 ? null : () => Navigator.pop(ctx, true), autofocus: n > 0),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _runBulk(
      targets: picked,
      change: (e) => _statusChange(e, active),
      title: 'Saving ${_plural(n, 'service')}',
      done: (k) => 'Made ${_plural(k, 'service')} $word',
    );
  }

  // ---- pick boxes -------------------------------------------------------------------------------------------------

  List<CatalogEntry> _shownNow = const [];
  List<CatalogEntry> _pageNow = const [];

  /// The selection bar rises where a snackbar floats: the first pick puts away a message still on show (the last
  /// change's result), so it never covers the bar's buttons.
  void _clearSnackOnFirstPick() {
    if (_selected.isEmpty) ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
  }

  Widget _pageBox() {
    final picked = _pageNow.where((e) => _selected.contains(e.key)).length;
    return CatalogSelectBox(
      key: const ValueKey('pick-page'),
      value: _pageNow.isEmpty || picked == 0 ? false : (picked == _pageNow.length ? true : null),
      semanticLabel: 'Select every service on this page',
      onChanged: (_) => setState(() {
        _clearSnackOnFirstPick();
        final now = _pageNow.map((e) => e.key).toList();
        if (now.any(_selected.contains)) {
          _selected.removeAll(now);
        } else {
          _selected.addAll(now);
        }
      }),
    );
  }

  Widget _pickBox(CatalogEntry e, int position) {
    return CatalogSelectBox(
      key: ValueKey('pick:${e.key}'),
      value: _selected.contains(e.key),
      semanticLabel: 'Select ${e.name}',
      onChanged: (on) => setState(() {
        _clearSnackOnFirstPick();
        // Shift+click picks (or unpicks) everything between the last one clicked and this one.
        final anchor = _anchor == null ? -1 : _shownNow.indexWhere((x) => x.key == _anchor);
        if (HardwareKeyboard.instance.isShiftPressed && anchor >= 0 && position >= 0 && position < _shownNow.length) {
          final from = anchor < position ? anchor : position;
          final to = anchor < position ? position : anchor;
          for (final x in _shownNow.sublist(from, to + 1)) {
            on ? _selected.add(x.key) : _selected.remove(x.key);
          }
        } else {
          on ? _selected.add(e.key) : _selected.remove(e.key);
        }
        _anchor = e.key;
      }),
    );
  }

  /// The bar that appears while services are picked: how many, pick every match, and what can be done with them. It
  /// floats over the list's foot so the list keeps its rows.
  Widget _selectionBar(List<CatalogEntry> shown) {
    final n = _selected.length;
    final shownKeys = {for (final e in shown) e.key};
    final hidden = _selected.where((k) => !shownKeys.contains(k)).length;
    final allShown = shown.every((e) => _selected.contains(e.key));
    final white = TextButton.styleFrom(
      foregroundColor: Colors.white,
      disabledForegroundColor: Colors.white.withValues(alpha: 0.4),
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      minimumSize: const Size(0, 36),
    );
    return LayoutBuilder(
      builder: (context, box) {
        // A narrow bar keeps its actions as icons (named in their tooltips) so the count keeps its room.
        final iconsOnly = box.maxWidth < MediaQuery.textScalerOf(context).scale(760);
        Widget action(String label, IconData icon, VoidCallback? onPressed, {required String key, FocusNode? focusNode}) => iconsOnly
            ? IconButton(
                key: ValueKey(key),
                focusNode: focusNode,
                onPressed: onPressed,
                tooltip: label,
                color: Colors.white,
                disabledColor: Colors.white.withValues(alpha: 0.4),
                icon: Icon(icon, size: 19),
              )
            : TextButton.icon(key: ValueKey(key), focusNode: focusNode, onPressed: onPressed, style: white, icon: Icon(icon, size: 17), label: Text(label));
        final busy = _bulkRunning;
        return Semantics(
          container: true,
          label: '${_plural(n, 'service')} selected',
          child: Container(
            key: const ValueKey('selection-bar'),
            height: 52,
            padding: const EdgeInsets.fromLTRB(6, 0, 10, 0),
            decoration: BoxDecoration(
              color: DashUi.ink,
              borderRadius: BorderRadius.circular(10),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.16), blurRadius: 16, offset: const Offset(0, 4))],
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Clear the selection',
                  onPressed: () => setState(_selected.clear),
                  icon: const Icon(Icons.close_rounded, size: 19, color: Colors.white),
                ),
                Text(
                  '${_count.format(n)} selected',
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
                      if (!allShown && shown.length > 1) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: TextButton(
                            key: const ValueKey('pick-all-matching'),
                            onPressed: () => setState(() => _selected.addAll(shown.map((e) => e.key))),
                            style: white.copyWith(
                              textStyle: const WidgetStatePropertyAll(
                                TextStyle(fontSize: 13, fontWeight: FontWeight.w700, decoration: TextDecoration.underline, decorationColor: Colors.white),
                              ),
                            ),
                            child: Text(
                              'Select all ${_count.format(shown.length)} ${_query.isEmpty && _filterCount == 0 ? 'services' : 'matching'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_canEdit) ...[
                  action('Move to category', Icons.drive_file_move_outline, busy ? null : _bulkCategory, key: 'bulk-category'),
                  // The shared menu (app_menu.dart): it rises above the bar, which sits at the foot of the pane.
                  AppMenu(
                    preferAbove: true,
                    alignEnd: true,
                    minWidth: 190,
                    semanticLabel: 'Status',
                    items: [
                      AppMenuItem(
                        key: const ValueKey('bulk-inactive'),
                        icon: Icons.do_not_disturb_on_outlined,
                        label: 'Make inactive',
                        onPressed: () => _bulkStatus(false),
                      ),
                      AppMenuItem(
                        key: const ValueKey('bulk-active'),
                        icon: Icons.check_circle_outline_rounded,
                        label: 'Make active',
                        onPressed: () => _bulkStatus(true),
                      ),
                    ],
                    builder: (context, menu) => action('Status', Icons.toggle_on_outlined, busy ? null : menu.toggle, key: 'bulk-status', focusNode: menu.focusNode),
                  ),
                  Container(width: 1, height: 22, margin: const EdgeInsets.symmetric(horizontal: 6), color: Colors.white.withValues(alpha: 0.18)),
                ],
                action('Export', Icons.file_download_outlined, () => _export(_picked), key: 'bulk-export'),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---- cells ------------------------------------------------------------------------------------------------------

  List<CatalogCol> _cols({required bool category}) => [
    const CatalogCol('SERVICE', sortKey: 'name'),
    if (category) const CatalogCol('CATEGORY', width: 196, sortKey: 'category'),
    if (_canSeeCost) const CatalogCol('COST', width: 100, right: true, sortKey: 'cost'),
    const CatalogCol('PRICE', width: 108, right: true, sortKey: 'price'),
  ];

  Widget _money(double? v) => Text(v == null ? '—' : dashMoney(v), maxLines: 1, style: v == null ? CatalogUi.cellQuiet : CatalogUi.cell);

  /// The price it starts new lines at; when it has none, why in a word (with the detail on hover).
  Widget _priceCell(CatalogEntry e) {
    final r = e.rate;
    if (r != null) {
      if ((r * 100).round() == 0) {
        return const Tooltip(
          message: 'Usually billed at no charge. New lines start without a price.',
          child: Text(r'$0.00', maxLines: 1, style: CatalogUi.cellQuiet),
        );
      }
      return Text(dashMoney(r), maxLines: 1, style: CatalogUi.cellStrong);
    }
    const quiet = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.slate, height: 1.3);
    if (e.priceStatus == 'recent_change') {
      return Tooltip(
        message: e.recentChange?.warning.isNotEmpty == true ? e.recentChange!.warning : 'Its newest prices moved away from its usual one. No price is filled in until it settles.',
        child: Text('Changed', maxLines: 1, style: quiet.copyWith(color: DashUi.amberText)),
      );
    }
    final lo = e.rateMin, hi = e.rateMax;
    if (lo != null && hi != null && lo != hi) {
      return Tooltip(
        message: 'Billed from ${dashMoney(lo)} to ${dashMoney(hi)}, with no usual price',
        child: const Text('Varies', maxLines: 1, style: quiet),
      );
    }
    return const Text('No price', maxLines: 1, style: quiet);
  }

  Widget _categoryCell(CatalogEntry e) {
    final c = _catOf(e);
    if (c.isNotEmpty) return Text(c, maxLines: 1, overflow: TextOverflow.ellipsis, style: CatalogUi.cell.copyWith(fontSize: 14));
    // A quiet dash, not the words on every row (most services have no category yet; the sidebar counts them).
    return const Tooltip(
      message: 'Not in a category yet',
      child: Text('—', maxLines: 1, style: CatalogUi.cellQuiet),
    );
  }

  /// What stands under a name: what replaced it, what it replaced, or its description.
  static String? _note(CatalogEntry e) {
    if (e.supersededBy case final by?) return 'Superseded by ${by.name}';
    if (e.replaces.isNotEmpty) return 'Replaces ${e.replaces.map((r) => r.name).join(', ')}';
    final d = e.description.trim().replaceAll(RegExp(r'\s+'), ' ');
    return d.isEmpty ? null : d;
  }

  /// The name with its tags, and one quiet line under it: the category (when there is no Category column) and its note.
  Widget _nameCell(CatalogEntry e, {required bool withCategory}) {
    final active = e.active;
    final note = _note(e);
    final cat = _catOf(e);
    final name = Text.rich(
      catalogNameSpan(e.name, active ? CatalogUi.name : CatalogUi.name.copyWith(color: DashUi.slate)),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
    const strong = TextStyle(fontWeight: FontWeight.w600, color: DashUi.slate);
    final parts = <InlineSpan>[
      // Only a real category: "No category" on every row would make each one two lines (the sidebar counts those).
      if (withCategory && cat.isNotEmpty) TextSpan(text: cat, style: strong),
      if (note != null) TextSpan(text: note),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // No "Edited" pill (USER RULE 2026-11-19: it looked sloppy); only Inactive is marked.
        if (!active)
          Row(
            children: [
              Flexible(child: name),
              const SizedBox(width: 8),
              const CatalogTag('Inactive'),
            ],
          )
        else
          name,
        if (parts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text.rich(
              TextSpan(
                children: [
                  for (var i = 0; i < parts.length; i++) ...[if (i > 0) const TextSpan(text: '  ·  ', style: TextStyle(color: DashUi.muted)), parts[i]],
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CatalogUi.meta,
            ),
          ),
      ],
    );
  }

  /// A row too narrow for the columns: the pick box, the service with its category under it, then its price and cost.
  Widget _compactRow(CatalogEntry e, int index, int position) {
    final picked = _selected.contains(e.key);
    return Semantics(
      button: true,
      selected: picked,
      label: 'Service ${e.name}',
      child: SelectionContainer.disabled(
        child: InkWell(
          onTap: () => _open(e),
          hoverColor: CatalogUi.hover,
          child: Container(
            padding: EdgeInsets.fromLTRB(_canEdit ? 6 : 16, 10, 16, 10),
            color: picked ? CatalogUi.picked : (index.isOdd ? CatalogUi.stripe : null),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_canEdit) ...[_pickBox(e, position), const SizedBox(width: 4)],
                Expanded(child: _nameCell(e, withCategory: true)),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _priceCell(e),
                    if (_canSeeCost && e.cost != null) ...[
                      const SizedBox(height: 4),
                      Text('Cost ${dashMoney(e.cost!)}', style: CatalogUi.meta.copyWith(fontFeatures: CatalogUi.figures)),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Above the inactive matches of a search on Active: they are found, but are not offered on new lines.
  Widget _extrasLabel(int n, bool compact) => Container(
    key: const ValueKey('inactive-matches'),
    padding: EdgeInsets.fromLTRB(compact ? 16 : CatalogUi.side, 14, CatalogUi.side, 8),
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(top: BorderSide(color: DashUi.line)),
    ),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(text: 'ALSO MATCHING: ${_count.format(n)} INACTIVE', style: CatalogUi.head),
          const TextSpan(text: '   Not offered when adding lines'),
        ],
      ),
      style: CatalogUi.meta,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
  );

  // ---- filters ----------------------------------------------------------------------------------------------------

  Widget _filterGroups() {
    final cats = _facetCounts(_Facet.category, _catOf);
    final priced = _facetCounts(_Facet.price, (e) => e.rate != null ? 'priced' : 'unpriced');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Every group starts closed (USER RULE 2026-11-19): the person opens the one they need.
        CatalogFilterGroup(
          title: 'Category',
          initiallyOpen: false,
          picked: _cats.length,
          child: Column(
            children: [
              for (final c in kServiceCategories) CatalogCheckRow(label: c, count: cats[c] ?? 0, selected: _cats.contains(c), onTap: () => _toggle(_cats, c)),
              CatalogCheckRow(
                key: const ValueKey('cat:none'),
                label: 'No category',
                count: cats[''] ?? 0,
                selected: _cats.contains(''),
                dot: (cats[''] ?? 0) > 0 ? DashUi.amber : null,
                onTap: () => _toggle(_cats, ''),
              ),
            ],
          ),
        ),
        CatalogFilterGroup(
          title: 'Price',
          initiallyOpen: false,
          picked: _price.isEmpty ? 0 : 1,
          child: Column(
            children: [
              CatalogCheckRow(label: 'Has a price', count: priced['priced'] ?? 0, selected: _price.contains('priced'), onTap: () => _toggle(_price, 'priced')),
              CatalogCheckRow(label: 'No price', count: priced['unpriced'] ?? 0, selected: _price.contains('unpriced'), onTap: () => _toggle(_price, 'unpriced')),
            ],
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

  static final ButtonStyle _outlined = OutlinedButton.styleFrom(
    minimumSize: const Size(0, 38),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    foregroundColor: DashUi.ink,
    backgroundColor: Colors.white,
    side: const BorderSide(color: DashUi.line),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
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
                    icon: accessIcon('services_catalog'),
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

  /// The filters that are on, each one a chip that takes it off.
  List<({String group, String value, VoidCallback remove})> get _chips => [
    for (final c in [...kServiceCategories, ''])
      if (_cats.contains(c)) (group: 'Category', value: c.isEmpty ? 'No category' : c, remove: () => _toggle(_cats, c)),
    for (final p in _price) (group: 'Price', value: p == 'priced' ? 'Has a price' : 'No price', remove: () => _toggle(_price, p)),
  ];

  // ---- the command row --------------------------------------------------------------------------------------------

  Widget _searchBox() {
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _clearSearch},
      child: CatalogSearchField(
        controller: _search,
        focusNode: _searchFocus,
        hint: 'Search services',
        onClear: _search.text.isEmpty ? null : _clearSearch,
        onSubmitted: (v) {
          _debounce?.cancel();
          _applyQuery(v);
        },
        onChanged: (v) {
          setState(() {}); // the clear button comes and goes with the text
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 200), () {
            if (mounted) _applyQuery(v);
          });
        },
      ),
    );
  }

  /// Active / Inactive / All, each with how many services it holds with the search and filters as they are: plain
  /// tabs whose ink underline sits on the command row's hairline ([height] is the row's), flush right.
  Widget _statusTabs({bool stretch = false, double height = CatalogUi.commandHeight - 1}) {
    final n = _statusCounts();
    final motion = CatalogUi.motion(context, 160);
    Widget tab(String value, String label, int count) {
      final on = _status == value;
      final text = Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 13.5, fontWeight: on ? FontWeight.w700 : FontWeight.w600, color: on ? DashUi.ink : DashUi.slate),
      );
      final body = SizedBox(
        height: height,
        child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: stretch ? 6 : 10),
              child: Center(
                widthFactor: 1,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // A stretched tab (a phone-narrow pane) shares a fixed width: its label gives way before its count.
                    if (stretch) Flexible(child: text) else text,
                    const SizedBox(width: 6),
                    Text(
                      _count.format(count),
                      maxLines: 1,
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: on ? DashUi.slate : DashUi.subtle, fontFeatures: CatalogUi.figures),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 4,
              right: 4,
              bottom: 0,
              child: AnimatedContainer(
                duration: motion,
                curve: Curves.easeOutCubic,
                height: 2,
                decoration: BoxDecoration(
                  color: on ? DashUi.ink : DashUi.ink.withValues(alpha: 0),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
                ),
              ),
            ),
          ],
        ),
      );
      final t = Semantics(
        container: true,
        button: true,
        inMutuallyExclusiveGroup: true,
        selected: on,
        label: '$label, ${_plural(count, 'service')}',
        excludeSemantics: true,
        // The shared keyboard ring, round the label and not the whole row height (UX audit 2026-11-20: the ink wash these
        // tabs used was painted under the white command row, so a focused tab looked like any other).
        child: FocusRing(
          borderRadius: BorderRadius.circular(6),
          outset: EdgeInsets.symmetric(vertical: -(height - 32) / 2),
          child: InkWell(
            key: ValueKey('status:$value'),
            onTap: () => _setStatus(value),
            splashFactory: NoSplash.splashFactory,
            hoverColor: Colors.transparent,
            focusColor: Colors.transparent,
            child: body,
          ),
        ),
      );
      return stretch ? Expanded(child: t) : t;
    }

    return SelectionContainer.disabled(
      child: Row(
        mainAxisSize: stretch ? MainAxisSize.max : MainAxisSize.min,
        children: [tab('active', 'Active', n.active), tab('inactive', 'Inactive', n.inactive), tab('all', 'All', n.all)],
      ),
    );
  }

  /// The sort: what the list is sorted by, and a menu of the sorts. [iconOnly] (a phone-narrow pane) shows just the
  /// icon, with the sort in its tooltip.
  Widget _sortMenu({bool iconOnly = false}) {
    final options = _sortOptions.where((o) => _canSeeCost || o.key != 'cost').toList();
    final current = options.where((o) => o.key == _sortKey && o.ascending == _ascending).firstOrNull;
    final label = current?.label ?? switch (_sortKey) {
      'name' => 'Name Z–A',
      'category' => 'Category Z–A',
      'uses' => 'Least used',
      _ => 'Custom',
    };
    // The shared menu (app_menu.dart, UX audit 2026-11-19). The old PopupMenuButton opened about 150 ms late, unrolled
    // for 350 ms with its rows fading in one by one, and its "Sort the list" tooltip sat over the menu it opened.
    return AppMenu(
      alignEnd: true,
      minWidth: 200,
      semanticLabel: 'Sort',
      items: [
        for (final o in options)
          AppMenuItem(
            key: ValueKey('sort:${o.label}'),
            label: o.label,
            selected: identical(o, current),
            onPressed: () => _sortTo(o),
          ),
      ],
      builder: (context, menu) => AppMenuTriggerButton(
        key: const ValueKey('sort-menu'),
        menu: menu,
        icon: Icons.swap_vert_rounded,
        label: iconOnly ? null : label,
        semanticLabel: 'Sorted by $label. Change the sort',
        tooltip: iconOnly ? 'Sorted: $label' : null,
      ),
    );
  }

  /// The command row: search, the filters that are on, the sort and the status tabs on one 52 px line. A narrower pane
  /// puts the tabs and the sort on a second line, and the chips under that.
  /// The search box's width on one command line [width] wide: about a third of it, giving way (down to 240) before the
  /// line has to break. The sort and the status tabs (and the Filters button) grow with the text size; it does not.
  double _searchWidth(double width, {required bool filterButton}) {
    final scale = MediaQuery.textScalerOf(context);
    final fixed = scale.scale(470) + (filterButton ? scale.scale(100) : 0);
    final third = (width * 0.32).clamp(240.0, 420.0);
    return width - third - fixed >= 120 ? third : (width - fixed - 120).clamp(240.0, 420.0);
  }

  /// Whether search, the sort, the status tabs (and the Filters button) fit on one line of a pane [width] wide, with
  /// room left for a chip.
  bool _fitsOneLine(double width, {required bool filterButton}) {
    final scale = MediaQuery.textScalerOf(context);
    final fixed = scale.scale(470) + (filterButton ? scale.scale(100) : 0);
    return width - _searchWidth(width, filterButton: filterButton) - fixed >= 60;
  }

  Widget _commandRow({required bool filterButton, required double width, bool reopensSidebar = false}) {
    final scale = MediaQuery.textScalerOf(context);
    final chips = _chips;
    final oneLine = _fitsOneLine(width, filterButton: filterButton);
    final searchWidth = _searchWidth(width, filterButton: filterButton);
    final narrow = width < scale.scale(_tableWidth);
    final side = width < scale.scale(_tableWidth) ? 12.0 : CatalogUi.side;
    if (oneLine) {
      return Container(
        height: CatalogUi.commandHeight,
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: DashUi.line)),
        ),
        padding: EdgeInsets.symmetric(horizontal: side),
        child: Row(
          children: [
            SizedBox(width: searchWidth, child: _searchBox()),
            if (filterButton) ...[const SizedBox(width: 10), _filterButton(reopensSidebar: reopensSidebar)],
            const SizedBox(width: 12),
            Expanded(child: CatalogChipStrip(chips: chips)),
            const SizedBox(width: 8),
            _sortMenu(),
            Container(width: 1, height: 20, margin: const EdgeInsets.symmetric(horizontal: 8), color: DashUi.line),
            _statusTabs(),
          ],
        ),
      );
    }
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: DashUi.line)),
      ),
      padding: EdgeInsets.symmetric(horizontal: side),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: CatalogUi.commandHeight,
            child: Row(
              children: [
                Expanded(child: _searchBox()),
                if (filterButton) ...[const SizedBox(width: 10), _filterButton(reopensSidebar: reopensSidebar)],
              ],
            ),
          ),
          if (chips.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [for (final c in chips) CatalogFilterChip(key: ValueKey('${c.group}:${c.value}'), group: c.group, value: c.value, onRemove: c.remove)],
              ),
            ),
          // The tabs' underline sits on the hairline under this line.
          Row(
            children: [
              // Only a phone-narrow pane stretches the tabs across; otherwise they keep their size.
              if (narrow) Expanded(child: _statusTabs(stretch: true, height: 39)) else ...[_statusTabs(height: 39), const Spacer()],
              const SizedBox(width: 8),
              _sortMenu(iconOnly: narrow),
            ],
          ),
        ],
      ),
    );
  }

  // ---- the list ---------------------------------------------------------------------------------------------------

  /// No match: says where matches are (another tab) and offers the way there, or to clear everything.
  Widget _noMatch() {
    final n = _statusCounts();
    final other = switch (_status) {
      'active' when n.inactive > 0 => ('inactive', 'Inactive', n.inactive),
      'inactive' when n.active > 0 => ('active', 'Active', n.active),
      _ => null,
    };
    final what = switch (_status) {
      'active' => 'No active services match',
      'inactive' => 'No inactive services match',
      _ => 'No services match',
    };
    return FlatEmpty(
      icon: Icons.search_off_rounded,
      title: what,
      message: other == null
          ? 'Try other words, or take off some filters.'
          : '${_plural(other.$3, '${other.$2.toLowerCase()} service')} ${other.$3 == 1 ? 'does' : 'do'}.',
      action: Wrap(
        spacing: 10,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: [
          if (other != null) AppButton.ink('Show ${other.$2.toLowerCase()}', () => _setStatus(other.$1)),
          AppButton.ghost('Clear search and filters', _clearAll),
        ],
      ),
    );
  }

  Widget _listPane({required bool filterButton, bool reopensSidebar = false}) {
    return LayoutBuilder(
      builder: (context, c) {
        final scale = MediaQuery.textScalerOf(context);
        final compact = c.maxWidth < scale.scale(_tableWidth);
        final withCategory = !compact && c.maxWidth >= scale.scale(_categoryColumnFrom);
        final view = _view();
        final shown = view.rows;
        final pages = shown.isEmpty ? 1 : (shown.length / _pageSize).ceil();
        final page = _page.clamp(1, pages);
        final start = (page - 1) * _pageSize;
        final rows = shown.skip(start).take(_pageSize).toList();
        _shownNow = shown;
        _pageNow = rows;
        final cols = _cols(category: withCategory);
        final picking = _selected.isNotEmpty;
        final pane = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _commandRow(filterButton: filterButton, width: c.maxWidth, reopensSidebar: reopensSidebar),
            if (_error != null) FlatStaleNotice(message: 'Could not refresh. These may be out of date.', busy: _loading, onRetry: _fetch),
            if (shown.isEmpty)
              Expanded(
                child: Center(child: SingleChildScrollView(child: _noMatch())),
              )
            else ...[
              if (!compact)
                CatalogTableHeader(
                  key: const ValueKey('services-header'),
                  cols: cols,
                  sortKey: _sortKey,
                  ascending: _ascending,
                  onSort: _sort,
                  leading: _canEdit ? _pageBox() : null,
                ),
              // Says how many match as the search and filters change (a screen reader hears the count, not the rows).
              Semantics(liveRegion: true, label: _query.isEmpty && _filterCount == 0 ? null : '${_plural(shown.length, 'service')} match', child: const SizedBox.shrink()),
              Expanded(
                child: ListView.builder(
                    controller: _scroll,
                    // Room under the last row for the selection bar, so it never covers a row that cannot scroll out.
                    padding: EdgeInsets.only(bottom: picking ? 72 : 0),
                    itemCount: rows.length,
                    itemBuilder: (_, i) {
                      final e = rows[i];
                      final position = start + i;
                      final Widget row = compact
                          ? KeyedSubtree(key: ValueKey('row:${e.key}'), child: _compactRow(e, i, position))
                          : CatalogRow(
                              key: ValueKey('row:${e.key}'),
                              cols: cols,
                              cells: [
                                _nameCell(e, withCategory: !withCategory),
                                if (withCategory) _categoryCell(e),
                                if (_canSeeCost) _money(e.cost),
                                _priceCell(e),
                              ],
                              index: i,
                              selected: _selected.contains(e.key),
                              leading: _canEdit ? _pickBox(e, position) : null,
                              semanticLabel: 'Service ${e.name}',
                              onTap: () => _open(e),
                            );
                      final labelled = position == view.extrasFrom
                          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [_extrasLabel(shown.length - view.extrasFrom, compact), row])
                          : row;
                      return flatRowEntrance(_rowsIn, i, labelled);
                    },
                ),
              ),
              CatalogPager(
                key: const ValueKey('services-footer'),
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
              left: 12,
              right: 12,
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
                        constraints: const BoxConstraints(maxWidth: 900),
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

  /// Loading: the page's own frame with pulsing rows, so nothing jumps when the list lands.
  Widget _loadingView(double width, bool wide) {
    final scale = MediaQuery.textScalerOf(context);
    final listWidth = wide ? width - _sidebarWidth : width;
    final table = listWidth >= scale.scale(_tableWidth);
    final cols = table ? _cols(category: listWidth >= scale.scale(_categoryColumnFrom)) : const [CatalogCol('SERVICE')];
    final pane = Semantics(
      label: 'Loading the services',
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
                    _slow ? 'Still loading. The server can take a moment when it has just started.' : 'Loading services',
                    style: CatalogUi.meta.copyWith(fontSize: 13.5),
                  ),
                ),
              ],
            ),
          ),
          if (table) CatalogTableHeader(cols: cols, sortKey: _sortKey, ascending: _ascending, onSort: (_) {}, leading: _canEdit ? const SizedBox(width: 16) : null),
          Expanded(
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.topCenter,
                maxHeight: double.infinity,
                child: CatalogSkeleton(cols: cols, rows: 24, lead: _canEdit && table),
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
          width: _sidebarWidth,
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

  /// The filter sidebar's width: the kit's 248, a little wider with larger text so the category names still fit.
  double get _sidebarWidth => MediaQuery.textScalerOf(context).scale(222).clamp(CatalogUi.sidebarWidth, 300.0);

  Widget _body(double width) {
    final scale = MediaQuery.textScalerOf(context);
    // Larger text needs the room too, so the sidebar gives way sooner: it shows only when the table and a one-line
    // command row still fit beside it (a second command line would cost rows on a short window).
    final sidebar = _sidebarWidth;
    final wide = width >= sidebar + scale.scale(_tableWidth) && _fitsOneLine(width - sidebar, filterButton: false);
    if (_noAccess && !_loading) {
      return const Center(
        child: FlatEmpty(
          icon: Icons.lock_outline_rounded,
          title: "You don't have access to the Services Catalog",
          message: 'Ask an admin to turn it on in Team.',
        ),
      );
    }
    if (_loading) return _loadingView(width, wide);
    if (_error != null && _all.isEmpty) {
      return Center(
        child: FlatEmpty(icon: Icons.cloud_off_rounded, title: 'Could not load the services', message: _error!, action: AppButton.ink('Try again', _fetch)),
      );
    }
    if (_all.isEmpty) {
      return Center(
        child: FlatEmpty(
          icon: Icons.handyman_outlined,
          title: 'No services yet',
          message: 'A service shows up here once it has been on a job line in the last ${(_historyDays / 30).round()} months.',
          action: AppButton.ghost('Refresh', _fetch),
        ),
      );
    }
    if (!wide) return _listPane(filterButton: true);
    if (_sidebarHidden) return _listPane(filterButton: true, reopensSidebar: true);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Two traversal groups (UX audit 2026-11-20): without them Tab went by height across the whole page, so it
        // zig-zagged between the filter rows and the table rows level with them.
        SizedBox(width: sidebar, child: FocusTraversalGroup(child: _filterSidebar())),
        Expanded(child: FocusTraversalGroup(child: _listPane(filterButton: false))),
      ],
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
            title: 'Services Catalog',
            icon: accessIcon('services_catalog'),
            activity: _activity,
            actions: [
              if (_all.isNotEmpty) RibbonGhostButton(icon: Icons.file_download_outlined, label: 'Export', onPressed: () => _export(_view().rows)),
              RibbonRefreshButton(onPressed: _loading ? null : _fetch),
            ],
          ),
          Expanded(
            child: PageSheet(child: LayoutBuilder(builder: (context, c) => _body(c.maxWidth))),
          ),
        ],
      ),
    );
  }
}

/// One choice of a pick-one list in a dialog (Move to category): a radio mark, the label and a count.
class _ChoiceRow extends StatelessWidget {
  final String label;
  final String? trailing;
  final bool selected;
  final VoidCallback onTap;
  final bool autofocus;
  const _ChoiceRow({super.key, required this.label, this.trailing, required this.selected, required this.onTap, this.autofocus = false});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      inMutuallyExclusiveGroup: true,
      checked: selected,
      label: label,
      excludeSemantics: true,
      child: FocusRing(
        child: InkWell(
        onTap: onTap,
        autofocus: autofocus,
        borderRadius: BorderRadius.circular(8),
        hoverColor: DashUi.faint,
        focusColor: Colors.transparent,
        child: AnimatedContainer(
          duration: CatalogUi.motion(context, 140),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(color: selected ? CatalogUi.picked : Colors.transparent, borderRadius: BorderRadius.circular(8)),
          child: Row(
            children: [
              Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded, size: 18, color: selected ? DashUi.ink : DashUi.fieldEdge),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: label, style: TextStyle(fontWeight: selected ? FontWeight.w700 : FontWeight.w600, color: DashUi.ink)),
                    ],
                  ),
                  style: const TextStyle(fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (trailing != null) Text(trailing!, style: const TextStyle(fontSize: 12.5, color: DashUi.subtle)),
            ],
          ),
        ),
      ),
      ),
    );
  }
}
