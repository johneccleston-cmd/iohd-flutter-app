import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'catalog_manage.dart';
import 'services/line_items_api.dart';
import 'utils/catalog_quality.dart';
import 'widgets/app_dialog.dart';
import 'widgets/catalog_kit.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';
import 'theme/app_theme.dart';

/// The Product Catalog's Categories view (Phase 3): every category with how many products it holds, naming questions
/// (the same name typed two ways, a word written two ways across the list), empty and one-product categories, and for
/// one category: rename, describe, merge into another, delete when empty, and move some of its products elsewhere.
///
/// A product's category is still its own text, so renaming or merging a category moves its products in one server
/// transaction (every product or none) and changes nothing else about them. Changing categories follows the Team
/// screen's Product Catalog switches (Create adds, Update renames, describes and merges, Delete removes); everyone with
/// the page can look.
class CatalogCategoriesView extends StatefulWidget {
  /// Every product loaded (active and inactive).
  final List<CatalogEntry> entries;

  /// The server's categories, or null when the server is older than Phase 3 (the view then reads them from the
  /// products and cannot change them).
  final List<CatalogCategory>? categories;
  final bool canEdit;

  /// New categories (Product Catalog > Create) and deleting one (> Delete). Null: the same as [canEdit].
  final bool? canCreate;
  final bool? canDelete;
  final CatalogManager manager;

  /// After a change: reload the products and categories. Returns when they are back.
  final Future<void> Function() onChanged;
  final void Function(String category) onShowInList;
  final VoidCallback onShowUncategorized;
  final void Function(CatalogEntry product) onOpenProduct;
  final void Function(String message) onSnack;

  /// Picked from outside (the Cleanup view's naming questions).
  final String? initialCategory;
  const CatalogCategoriesView({
    super.key,
    required this.entries,
    required this.categories,
    required this.canEdit,
    this.canCreate,
    this.canDelete,
    required this.manager,
    required this.onChanged,
    required this.onShowInList,
    required this.onShowUncategorized,
    required this.onOpenProduct,
    required this.onSnack,
    this.initialCategory,
  });

  @override
  State<CatalogCategoriesView> createState() => _CatalogCategoriesViewState();
}

class _CatalogCategoriesViewState extends State<CatalogCategoriesView> {
  static const _listWidth = 320.0;
  static final _count = NumberFormat.decimalPattern();
  static final _when = DateFormat('MMM d, y');

  final _search = TextEditingController();
  String _query = '';
  bool _bySize = false;
  String? _selected;
  final Set<String> _picked = {};

  @override
  void initState() {
    super.initState();
    _selected = widget.initialCategory;
  }

  @override
  void didUpdateWidget(CatalogCategoriesView old) {
    super.didUpdateWidget(old);
    if (widget.initialCategory != null && widget.initialCategory != old.initialCategory) {
      _selected = widget.initialCategory;
      _picked.clear();
    }
    // A category that is gone (renamed, merged, deleted) cannot stay open.
    if (_selected != null && !_cats.any((c) => c.name == _selected)) _selected = null;
    _picked.removeWhere((k) => !widget.entries.any((e) => e.key == k && e.category == _selected));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool get _live => widget.categories != null;
  bool get _canChange => widget.canEdit && _live;
  bool get _canDelete => (widget.canDelete ?? widget.canEdit) && _live;

  /// The categories: the server's, or (an older server) the products' own.
  List<CatalogCategory> get _cats {
    if (widget.categories != null) return widget.categories!;
    final byName = <String, List<CatalogEntry>>{};
    for (final e in widget.entries) {
      if (e.category.trim().isNotEmpty) (byName[e.category.trim()] ??= []).add(e);
    }
    return [
      for (final e in byName.entries)
        CatalogCategory(
          name: e.key,
          products: e.value.length,
          active: e.value.where((x) => x.active).length,
          productIds: [
            for (final x in e.value)
              if (x.productId != null) x.productId!,
          ]..sort(),
        ),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  Map<String, int> get _counts => {for (final c in _cats) c.name: c.products};

  List<CategoryNameIssue> get _issues => categoryNameIssues([for (final c in _cats) c.name]);

  int get _uncategorized => widget.entries.where((e) => e.category.trim().isEmpty).length;

  void _select(String? name) => setState(() {
    _selected = name;
    _picked.clear();
  });

  Future<void> _after(String message, {String? select}) async {
    await widget.onChanged();
    if (!mounted) return;
    setState(() {
      if (select != null) _selected = select;
      _picked.clear();
    });
    widget.onSnack(message);
  }

  // ---- actions ------------------------------------------------------------------------------------------------------

  String? _nameProblem(String v, {String? current}) {
    if (v.isEmpty) return 'Give the category a name.';
    if (current != null && v == current) return 'Type the new name.';
    for (final c in _cats) {
      if (c.name != current && catalogNorm(c.name) == catalogNorm(v)) {
        return 'There is already a category called "${c.name}".${current != null ? ' To put the two together, use Merge.' : ''}';
      }
    }
    return null;
  }

  Future<void> _newCategory() async {
    String made = '';
    final ok = await showCatalogFormDialog(
      context,
      title: 'New category',
      icon: Icons.create_new_folder_outlined,
      fieldLabel: 'Name',
      help: 'Products are filed under it from their own page, or by moving several at once.',
      withDescription: true,
      saveLabel: 'Create category',
      validate: (v) => _nameProblem(v),
      action: (v, d) async {
        await widget.manager.createCategory(v, description: d.isEmpty ? null : d);
        made = v;
      },
    );
    if (ok) await _after('Created the category $made', select: made);
  }

  Future<void> _rename(CatalogCategory c) async {
    String to = '';
    final ok = await showCatalogFormDialog(
      context,
      title: 'Rename category',
      subtitle: c.name,
      icon: Icons.drive_file_rename_outline_rounded,
      fieldLabel: 'New name',
      initial: c.name,
      saveLabel: 'Rename',
      validate: (v) => _nameProblem(v, current: c.name),
      note: (v) => AppNotice(
        c.products == 0
            ? 'No products are in it yet.'
            : '${catalogPlural(c.products, 'product')} ${c.products == 1 ? 'moves' : 'move'} with it, all at once. Nothing else about ${c.products == 1 ? 'it' : 'them'} changes.',
      ),
      action: (v, _) async {
        await widget.manager.renameCategory(c.name, v, expectedProductIds: c.productIds);
        to = v;
      },
    );
    if (ok) await _after('Renamed ${c.name} to $to', select: to);
  }

  Future<void> _describe(CatalogCategory c) async {
    final ok = await showCatalogFormDialog(
      context,
      title: c.description.isEmpty ? 'Describe this category' : 'Edit the description',
      subtitle: c.name,
      icon: Icons.notes_rounded,
      fieldLabel: 'Description',
      help: 'What belongs in it, so products are filed the same way. Leave it empty to remove it.',
      initial: c.description,
      multiline: true,
      saveLabel: 'Save description',
      validate: (v) => v == c.description ? 'Change the text first.' : null,
      action: (v, _) => widget.manager.describeCategory(c.name, v.isEmpty ? null : v, expectedUpdatedAt: c.saved ? c.updatedAt : null),
    );
    if (ok) await _after('Saved the description of ${c.name}');
  }

  Future<void> _merge(List<String> sources, {String? suggestTarget}) async {
    final r = await showDialog<String>(
      context: context,
      builder: (_) => _MergeDialog(
        categories: _cats,
        sources: sources,
        suggestTarget: suggestTarget,
        manager: widget.manager,
      ),
    );
    if (r != null) await _after('Merged into $r', select: r);
  }

  Future<void> _delete(CatalogCategory c) async {
    final ok = await confirmCatalogAction(
      context,
      title: 'Delete this category?',
      subtitle: c.name,
      icon: Icons.delete_outline_rounded,
      danger: true,
      message: 'It has no products, so nothing else changes. You can create it again at any time.',
      confirmLabel: 'Delete category',
    );
    if (!ok) return;
    try {
      await widget.manager.deleteCategory(c.name);
      await _after('Deleted the category ${c.name}', select: null);
      if (mounted) setState(() => _selected = null);
    } catch (e) {
      widget.onSnack(catalogErrorText(e));
    }
  }

  Future<void> _movePicked(CatalogCategory from) async {
    final picked = widget.entries.where((e) => _picked.contains(e.key)).toList();
    if (picked.isEmpty) return;
    final r = await showBulkCategoryDialog(
      context,
      entries: picked,
      categories: _counts,
      manager: widget.manager,
      canCreate: widget.canCreate ?? widget.canEdit,
      exclude: from.name,
    );
    if (r == null) return;
    if (r.reload) {
      await widget.onChanged();
      return;
    }
    await _after(r.message);
  }

  // ---- the list -----------------------------------------------------------------------------------------------------

  Widget _categoryList(Set<String> flagged) {
    final q = _query.trim().toLowerCase();
    final rows = _cats.where((c) => q.isEmpty || c.name.toLowerCase().contains(q)).toList();
    if (_bySize) rows.sort((a, b) => b.products != a.products ? b.products.compareTo(a.products) : a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final total = _cats.fold<int>(0, (n, c) => n + c.products);
    return Container(
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: DashUi.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CatalogPaneHeader(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: CatalogSearchField(
                    controller: _search,
                    hint: 'Find a category',
                    onChanged: (v) => setState(() => _query = v),
                    onClear: _search.text.isEmpty
                        ? null
                        : () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: _bySize ? 'Sorted by size: sort A to Z' : 'Sorted A to Z: sort by size',
                  onPressed: () => setState(() => _bySize = !_bySize),
                  icon: Icon(_bySize ? Icons.sort_rounded : Icons.sort_by_alpha_rounded, size: 19, color: DashUi.slate),
                ),
              ],
            ),
          ),
          Container(
            height: CatalogUi.headerHeight,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.centerLeft,
            child: CatalogLabel(
              '${_cats.length} CATEGORIES',
              trailing: Text('${_count.format(total)} products', style: CatalogUi.meta.copyWith(fontFeatures: CatalogUi.figures)),
            ),
          ),
          Expanded(
            child: rows.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No category matches', style: CatalogUi.meta),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    itemCount: rows.length,
                    itemBuilder: (_, i) => _CategoryRow(
                      key: ValueKey('category:${rows[i].name}'),
                      category: rows[i],
                      selected: rows[i].name == _selected,
                      flagged: flagged.contains(rows[i].name),
                      onTap: () => _select(rows[i].name == _selected ? null : rows[i].name),
                    ),
                  ),
          ),
          if (_uncategorized > 0)
            InkWell(
              mouseCursor: WidgetStateMouseCursor.clickable,
              onTap: widget.onShowUncategorized,
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: DashUi.line)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.folder_off_outlined, size: 17, color: DashUi.amberText),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'No category',
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink),
                      ),
                    ),
                    Text(
                      _count.format(_uncategorized),
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.ink),
                    ),
                    const SizedBox(width: 6),
                    const Icon(Icons.arrow_forward_rounded, size: 15, color: DashUi.slate),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---- the overview (nothing picked) --------------------------------------------------------------------------------

  Widget _overview(List<CategoryNameIssue> issues) {
    final empty = _cats.where((c) => c.isEmpty).toList();
    final single = _cats.where((c) => c.products == 1).toList();
    final clean = issues.isEmpty && empty.isEmpty;
    Widget chip(String name) => _NameChip(name: name, onTap: () => _select(name));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CatalogPaneHeader(
          child: Row(
            children: [
              const Text(
                'All categories',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: DashUi.ink),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Pick one on the left to rename it, describe it, merge it or move its products.',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CatalogUi.meta.copyWith(fontSize: 13.5),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(CatalogUi.side, 4, CatalogUi.side, 20),
            children: [
              if (!_live)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: AppNotice(
                    'Creating, renaming and merging categories needs the server update. Until then this list is read from the products.',
                    kind: AppNoticeKind.warning,
                  ),
                )
              else if (!widget.canEdit)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: AppNotice('You can look at the categories. Changing them needs the Product Catalog > Update switch on the Team screen.'),
                ),
              const _Heading('Naming to check', 'Categories that look like one written two ways, or a word spelt two ways across the list.'),
              if (issues.isEmpty)
                const _AllGood('Category names are consistent.')
              else
                for (final issue in issues)
                  _IssueBlock(
                    key: ValueKey('naming:${issue.names.join('|')}'),
                    icon: issue.kind == 'abbreviation' ? Icons.spellcheck_rounded : Icons.call_merge_rounded,
                    message: issue.message,
                    chips: [for (final n in issue.names) chip(n)],
                    action: !_canChange
                        ? null
                        : issue.kind == 'abbreviation'
                        ? (issue.names.length == 1
                              ? CatalogOutlineButton(
                                  label: 'Rename…',
                                  dense: true,
                                  icon: Icons.drive_file_rename_outline_rounded,
                                  onPressed: () => _rename(_cats.firstWhere((c) => c.name == issue.names.first)),
                                )
                              : null)
                        : CatalogOutlineButton(label: 'Merge…', dense: true, icon: Icons.call_merge_rounded, onPressed: () => _merge(issue.names)),
                  ),
              if (empty.isNotEmpty) ...[
                const _Heading('Empty', 'Categories with no products. Delete one, or file products in it.'),
                for (final c in empty)
                  _IssueBlock(
                    key: ValueKey('empty:${c.name}'),
                    icon: Icons.folder_open_outlined,
                    message: c.name,
                    chips: const [],
                    action: _canDelete
                        ? CatalogOutlineButton(label: 'Delete…', dense: true, danger: true, icon: Icons.delete_outline_rounded, onPressed: () => _delete(c))
                        : null,
                  ),
              ],
              if (single.isNotEmpty) ...[
                const _Heading('One product', 'Small categories are often a product filed by mistake. Open one to merge it or move its product.'),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(spacing: 6, runSpacing: 6, children: [for (final c in single) chip(c.name)]),
                ),
              ],
              if (clean && single.isEmpty) const _AllGood('Nothing to tidy: every category has products and the names agree.'),
            ],
          ),
        ),
      ],
    );
  }

  // ---- one category -------------------------------------------------------------------------------------------------

  Widget _detail(CatalogCategory c, List<CategoryNameIssue> issues) {
    final products = widget.entries.where((e) => e.category.trim() == c.name).toList()
      ..sort((a, b) => a.active != b.active ? (a.active ? -1 : 1) : a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final mine = issues.where((i) => i.names.contains(c.name)).toList();
    final pickedHere = products.where((e) => _picked.contains(e.key)).toList();
    final allPicked = products.isNotEmpty && pickedHere.length == products.length;
    final canPick = _canChange && products.any((e) => e.updatedAt != null);
    const actionGap = SizedBox(width: 8);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(CatalogUi.side, 14, CatalogUi.side, 14),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: DashUi.line)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'All categories',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _select(null),
                    icon: const Icon(Icons.arrow_back_rounded, size: 19, color: DashUi.slate),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: DashUi.ink, letterSpacing: -0.2),
                    ),
                  ),
                  if (c.isEmpty) ...[const SizedBox(width: 10), const CatalogTag('Empty', tone: CatalogTone.warn)],
                  const Spacer(),
                  if (c.products > 0)
                    TextButton.icon(
                      onPressed: () => widget.onShowInList(c.name),
                      iconAlignment: IconAlignment.end,
                      icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                      label: const Text('Show in product list'),
                      style: TextButton.styleFrom(foregroundColor: DashUi.ink, textStyle: const TextStyle(fontFamily: AppTheme.fontFamily, fontFamilyFallback: AppTheme.fontFamilyFallback, fontSize: 13, fontWeight: FontWeight.w700)),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 44, top: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      [
                        catalogPlural(c.products, 'product'),
                        if (c.products > 0) '${_count.format(c.active)} active',
                        if (c.inactive > 0) '${_count.format(c.inactive)} inactive',
                        if (c.saved && c.updatedBy != null)
                          'changed by ${c.updatedBy}${DateTime.tryParse(c.updatedAt ?? '') != null ? ' on ${_when.format(DateTime.parse(c.updatedAt!).toLocal())}' : ''}',
                      ].join('  ·  '),
                      style: CatalogUi.meta.copyWith(fontSize: 13.5, fontFeatures: CatalogUi.figures),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      c.description.isEmpty ? 'No description yet.' : c.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: c.description.isEmpty ? CatalogUi.meta.copyWith(fontStyle: FontStyle.italic) : CatalogUi.body.copyWith(fontSize: 14),
                    ),
                    for (final i in mine)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: AppNotice(
                          i.kind == 'abbreviation'
                              ? '${i.message}. Renaming this one would make the list agree.'
                              : '${i.message}: ${i.names.where((n) => n != c.name).join(', ')}. If they are one category, merge them.',
                          kind: AppNoticeKind.warning,
                        ),
                      ),
                    if (_canChange) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 0,
                        runSpacing: 8,
                        children: [
                          CatalogOutlineButton(label: 'Rename', icon: Icons.drive_file_rename_outline_rounded, onPressed: () => _rename(c)),
                          actionGap,
                          CatalogOutlineButton(label: 'Describe', icon: Icons.notes_rounded, onPressed: () => _describe(c)),
                          actionGap,
                          CatalogOutlineButton(
                            label: 'Merge into…',
                            icon: Icons.call_merge_rounded,
                            onPressed: _cats.length < 2 ? null : () => _merge([c.name]),
                          ),
                          actionGap,
                          Tooltip(
                            message: c.isEmpty ? '' : 'Move or merge its products first',
                            child: CatalogOutlineButton(
                              label: 'Delete',
                              icon: Icons.delete_outline_rounded,
                              danger: c.isEmpty,
                              onPressed: c.isEmpty ? () => _delete(c) : null,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        // The products in it, with picking for "move to another category".
        Container(
          height: CatalogUi.headerHeight + 4,
          padding: EdgeInsets.fromLTRB(canPick ? 12 : CatalogUi.side, 0, CatalogUi.side, 0),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: DashUi.line)),
          ),
          child: Row(
            children: [
              if (canPick) ...[
                CatalogSelectBox(
                  value: allPicked ? true : (pickedHere.isEmpty ? false : null),
                  semanticLabel: 'Pick every product in ${c.name}',
                  onChanged: (_) => setState(() {
                    if (allPicked || pickedHere.isNotEmpty) {
                      _picked.removeAll(products.map((e) => e.key));
                    } else {
                      _picked.addAll(products.map((e) => e.key));
                    }
                  }),
                ),
                const SizedBox(width: 6),
              ],
              Text(pickedHere.isEmpty ? 'PRODUCTS' : '${pickedHere.length} PICKED', style: CatalogUi.head),
              const Spacer(),
              if (pickedHere.isNotEmpty) ...[
                TextButton(
                  onPressed: () => setState(() => _picked.clear()),
                  style: TextButton.styleFrom(foregroundColor: DashUi.slate, textStyle: const TextStyle(fontFamily: AppTheme.fontFamily, fontFamilyFallback: AppTheme.fontFamilyFallback, fontSize: 13, fontWeight: FontWeight.w700)),
                  child: const Text('Clear'),
                ),
                const SizedBox(width: 6),
                CatalogOutlineButton(
                  key: const ValueKey('move-picked'),
                  label: 'Move to another category…',
                  dense: true,
                  icon: Icons.drive_file_move_outline,
                  onPressed: () => _movePicked(c),
                ),
              ] else
                const Text('PRICE', style: CatalogUi.head),
            ],
          ),
        ),
        Expanded(
          child: products.isEmpty
              ? const Center(
                  child: FlatEmpty(
                    icon: Icons.folder_open_outlined,
                    title: 'No products in it',
                    message: 'File products here from their own page, or move several at once from the product list.',
                  ),
                )
              : ListView.builder(
                  itemCount: products.length,
                  itemBuilder: (_, i) {
                    final e = products[i];
                    final on = _picked.contains(e.key);
                    return _ProductLine(
                      key: ValueKey('category-product:${e.key}'),
                      entry: e,
                      index: i,
                      picked: on,
                      onPick: canPick && e.updatedAt != null ? (v) => setState(() => v ? _picked.add(e.key) : _picked.remove(e.key)) : null,
                      onOpen: () => widget.onOpenProduct(e),
                    );
                  },
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final issues = _issues;
    final flagged = {for (final i in issues) ...i.names};
    final cats = _cats;
    final current = _selected == null ? null : cats.where((c) => c.name == _selected).firstOrNull;
    return LayoutBuilder(
      builder: (context, box) {
        final narrow = box.maxWidth < 760;
        final right = current == null ? _overview(issues) : _detail(current, issues);
        if (narrow) return current == null ? _categoryList(flagged) : right;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: math.min(_listWidth, box.maxWidth * 0.36), child: _categoryList(flagged)),
            Expanded(
              child: AnimatedSwitcher(
                duration: CatalogUi.motion(context, 200),
                child: KeyedSubtree(key: ValueKey(current?.name ?? '-overview-'), child: right),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Called by the page's ribbon button.
  Future<void> newCategory() => _newCategory();
}

/// The page's ribbon button reaches the view's "New category" through this key.
typedef CatalogCategoriesKey = GlobalKey<State<CatalogCategoriesView>>;

/// Opens the New category dialog of the view behind [key].
Future<void> catalogNewCategory(CatalogCategoriesKey key) async {
  final s = key.currentState;
  if (s is _CatalogCategoriesViewState) await s.newCategory();
}

class _CategoryRow extends StatefulWidget {
  final CatalogCategory category;
  final bool selected;
  final bool flagged;
  final VoidCallback onTap;
  const _CategoryRow({super.key, required this.category, required this.selected, required this.flagged, required this.onTap});

  @override
  State<_CategoryRow> createState() => _CategoryRowState();
}

class _CategoryRowState extends State<_CategoryRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.category;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: '${c.name}, ${catalogPlural(c.products, 'product')}${widget.flagged ? ', naming to check' : ''}',
      excludeSemantics: true,
      child: InkWell(
        mouseCursor: WidgetStateMouseCursor.clickable,
        onTap: widget.onTap,
        onHover: (v) => setState(() => _hover = v),
        borderRadius: BorderRadius.circular(8),
        hoverColor: Colors.transparent,
        child: AnimatedContainer(
          duration: CatalogUi.motion(context, 120),
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: widget.selected ? CatalogUi.picked : (_hover ? DashUi.faint : Colors.transparent),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  c.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, fontWeight: widget.selected ? FontWeight.w800 : FontWeight.w600, color: DashUi.ink),
                ),
              ),
              if (widget.flagged)
                Tooltip(
                  message: 'Naming to check',
                  child: Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.only(left: 8),
                    decoration: const BoxDecoration(color: DashUi.amber, shape: BoxShape.circle),
                  ),
                ),
              if (c.isEmpty) ...[const SizedBox(width: 8), const CatalogTag('Empty', tone: CatalogTone.warn)],
              const SizedBox(width: 10),
              SizedBox(
                width: 36,
                child: Text(
                  c.products == 0 ? '–' : NumberFormat.decimalPattern().format(c.products),
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: widget.selected ? DashUi.ink : DashUi.subtle,
                    fontFeatures: CatalogUi.figures,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProductLine extends StatelessWidget {
  final CatalogEntry entry;
  final int index;
  final bool picked;
  final ValueChanged<bool>? onPick;
  final VoidCallback onOpen;
  const _ProductLine({super.key, required this.entry, required this.index, required this.picked, required this.onPick, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final e = entry;
    return Semantics(
      button: true,
      label: 'Product ${e.name}',
      child: InkWell(
        mouseCursor: WidgetStateMouseCursor.clickable,
        onTap: onOpen,
        hoverColor: picked ? CatalogUi.pickedHover : CatalogUi.hover,
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: EdgeInsets.fromLTRB(onPick == null ? CatalogUi.side : 12, 4, CatalogUi.side, 4),
          color: picked ? CatalogUi.picked : (index.isOdd ? CatalogUi.stripe : Colors.white),
          child: Row(
            children: [
              if (onPick != null) ...[CatalogSelectBox(value: picked, onChanged: onPick!, semanticLabel: 'Pick ${e.name}'), const SizedBox(width: 6)],
              Expanded(
                child: Text.rich(
                  catalogNameSpan(e.name, CatalogUi.name.copyWith(fontSize: 13.5, color: e.active ? DashUi.ink : DashUi.subtle)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!e.active) ...[const SizedBox(width: 8), const CatalogTag('Inactive')],
              const SizedBox(width: 12),
              SizedBox(
                width: 96,
                child: Text(
                  e.sku.isEmpty ? '—' : e.sku,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CatalogUi.cellQuiet.copyWith(fontSize: 13),
                ),
              ),
              SizedBox(
                width: 84,
                child: Text(
                  e.rate == null ? 'No price' : dashMoney(e.rate!),
                  textAlign: TextAlign.right,
                  style: e.rate == null ? CatalogUi.cellQuiet.copyWith(fontSize: 13.5) : CatalogUi.cellStrong.copyWith(fontSize: 13.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  final String title;
  final String caption;
  const _Heading(this.title, this.caption);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(), style: CatalogUi.head),
          const SizedBox(height: 2),
          Text(caption, style: CatalogUi.meta),
        ],
      ),
    );
  }
}

class _AllGood extends StatelessWidget {
  final String text;
  const _AllGood(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.check_circle_outline_rounded, size: 17, color: DashUi.emeraldText),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13.5, color: DashUi.ink))),
        ],
      ),
    );
  }
}

/// One naming question or empty category: an icon, the message, the categories it is about, and its action.
class _IssueBlock extends StatelessWidget {
  final IconData icon;
  final String message;
  final List<Widget> chips;
  final Widget? action;
  const _IssueBlock({super.key, required this.icon, required this.message, required this.chips, this.action});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        border: Border.all(color: DashUi.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 18, color: DashUi.amberText),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink, height: 1.35),
                ),
                if (chips.isNotEmpty) ...[const SizedBox(height: 6), Wrap(spacing: 6, runSpacing: 6, children: chips)],
              ],
            ),
          ),
          if (action != null) ...[const SizedBox(width: 10), action!],
        ],
      ),
    );
  }
}

class _NameChip extends StatelessWidget {
  final String name;
  final VoidCallback onTap;
  const _NameChip({required this.name, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Open the category $name',
      excludeSemantics: true,
      child: InkWell(
        mouseCursor: WidgetStateMouseCursor.clickable,
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(999)),
          child: Text(
            name,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: DashUi.ink),
          ),
        ),
      ),
    );
  }
}

/// Merges categories: which ones (ticks), into which (an existing one or a new name), then what moves, then confirm.
/// Pops with the target's name when done.
class _MergeDialog extends StatefulWidget {
  final List<CatalogCategory> categories;
  final List<String> sources;
  final String? suggestTarget;
  final CatalogManager manager;
  const _MergeDialog({required this.categories, required this.sources, required this.suggestTarget, required this.manager});

  @override
  State<_MergeDialog> createState() => _MergeDialogState();
}

class _MergeDialogState extends State<_MergeDialog> {
  late final Set<String> _from = {...widget.sources};
  final _search = TextEditingController();
  String _query = '';
  String? _into;
  bool _preview = false;
  bool _ticked = false;
  bool _busy = false;
  String? _error;

  /// A naming question offers its names as both: tick the ones to fold in, pick the one to keep.
  bool get _fromGroup => widget.sources.length > 1;

  @override
  void initState() {
    super.initState();
    if (_fromGroup) {
      // Keep the biggest by default: the fewest products move.
      final biggest = widget.categories.where((c) => widget.sources.contains(c.name)).reduce((a, b) => b.products > a.products ? b : a);
      _into = widget.suggestTarget ?? biggest.name;
      _from.remove(_into);
    } else {
      _into = widget.suggestTarget;
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  CatalogCategory? _cat(String name) => widget.categories.where((c) => c.name == name).firstOrNull;
  List<int> get _ids => [for (final s in _from) ...?_cat(s)?.productIds]..sort();
  int get _moving => _ids.length;

  Future<void> _apply() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.manager.mergeCategories(_from.toList()..sort(), _into!, expectedProductIds: _ids);
      if (mounted) Navigator.pop(context, r.category.name);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = catalogErrorText(e);
      });
    }
  }

  Widget _pick() {
    final q = _query.trim().toLowerCase();
    final candidates = widget.categories.where((c) => !_from.contains(c.name) && (q.isEmpty || c.name.toLowerCase().contains(q))).toList();
    final typed = _query.trim().replaceAll(RegExp(r'\s+'), ' ');
    final offerNew = typed.isNotEmpty && !widget.categories.any((c) => catalogNorm(c.name) == catalogNorm(typed));
    Widget option(String name, String? count, {bool isNew = false}) {
      final on = _into == name;
      return InkWell(
        mouseCursor: WidgetStateMouseCursor.clickable,
        key: ValueKey('merge-into:$name'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() {
          _into = name;
          // From a naming question: the one kept is no longer folded in, the others are.
          if (_fromGroup) {
            _from
              ..clear()
              ..addAll(widget.sources)
              ..remove(name);
          }
        }),
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(color: on ? CatalogUi.picked : Colors.transparent, borderRadius: BorderRadius.circular(8)),
          child: Row(
            children: [
              Icon(on ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded, size: 18, color: on ? DashUi.ink : DashUi.fieldEdge),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isNew ? 'A new category: "$name"' : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, fontWeight: on ? FontWeight.w700 : FontWeight.w500, color: DashUi.ink),
                ),
              ),
              if (count != null) Text(count, style: CatalogUi.meta),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_fromGroup) ...[
          const AppFieldLabel('Fold in', help: 'Their products move into the category you keep, and they are removed.'),
          for (final s in widget.sources)
            if (s != _into)
              CatalogCheckRow(
                key: ValueKey('merge-from:$s'),
                label: s,
                count: _cat(s)?.products ?? 0,
                selected: _from.contains(s),
                onTap: () => setState(() => _from.contains(s) ? _from.remove(s) : _from.add(s)),
              ),
          const SizedBox(height: 12),
          const AppFieldLabel('Keep'),
          for (final s in widget.sources) option(s, '${_cat(s)?.products ?? 0}'),
        ] else ...[
          AppFieldLabel('Merge "${widget.sources.first}" into', help: 'Its products move there and "${widget.sources.first}" is removed.'),
          CatalogSearchField(
            controller: _search,
            hint: 'Find a category, or type a new one',
            autofocus: true,
            onChanged: (v) => setState(() => _query = v),
            onClear: () {
              _search.clear();
              setState(() => _query = '');
            },
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: math.min(280, (candidates.length + (offerNew ? 1 : 0)) * 36.0 + 4),
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                if (offerNew) option(typed, null, isNew: true),
                for (final c in candidates) option(c.name, '${c.products}'),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _review() {
    final big = _moving >= kCatalogBulkConfirmAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: catalogPlural(_moving, 'product'),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              TextSpan(text: _moving == 1 ? ' moves into ' : ' move into '),
              TextSpan(
                text: _into,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              TextSpan(text: _cat(_into!) == null ? ' (a new category)' : ''),
              const TextSpan(text: ', all at once.'),
            ],
          ),
          style: const TextStyle(fontSize: 14, color: DashUi.ink, height: 1.4),
        ),
        const SizedBox(height: 10),
        for (final s in (_from.toList()..sort()))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                const Icon(Icons.subdirectory_arrow_right_rounded, size: 16, color: DashUi.slate),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(s, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.ink)),
                ),
                Text('${catalogPlural(_cat(s)?.products ?? 0, 'product')}, then removed', style: CatalogUi.meta),
              ],
            ),
          ),
        const SizedBox(height: 10),
        const AppNotice('Only the category changes. Prices, costs, stock, inventory links and everything else stay exactly as they are.'),
        if (big)
          InkWell(
            mouseCursor: WidgetStateMouseCursor.clickable,
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _ticked = !_ticked),
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  CatalogCheckBox(_ticked),
                  const SizedBox(width: 10),
                  Text('I have checked this ${catalogPlural(_moving, 'product')} move', style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.ink)),
                ],
              ),
            ),
          ),
        if (_error != null) ...[const SizedBox(height: 10), AppNotice(_error!, kind: AppNoticeKind.error)],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ready = _into != null && _from.isNotEmpty && !_from.contains(_into);
    final big = _moving >= kCatalogBulkConfirmAt;
    return AppDialog(
      title: _preview ? 'Check the merge' : 'Merge categories',
      subtitle: _preview ? 'Into $_into' : null,
      icon: Icons.call_merge_rounded,
      width: 560,
      body: _preview ? _review() : _pick(),
      actions: [
        if (_preview) AppButton.ghost('Back', _busy ? null : () => setState(() => _preview = false)) else AppButton.ghost('Cancel', () => Navigator.pop(context)),
        if (_preview)
          AppButton.ink(
            _busy ? 'Merging…' : (_moving == 0 ? 'Merge' : 'Merge ${catalogPlural(_moving, 'product')}'),
            _busy || (big && !_ticked) ? null : _apply,
            icon: _busy ? null : Icons.call_merge_rounded,
          )
        else
          AppButton.ink('Review the merge', ready ? () => setState(() => _preview = true) : null, icon: Icons.arrow_forward_rounded),
      ],
    );
  }
}
