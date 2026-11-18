import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'catalog_manage.dart';
import 'product_detail_screen.dart' show inventoryConflictText;
import 'services/line_items_api.dart';
import 'utils/catalog_quality.dart';
import 'widgets/catalog_kit.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';

/// The Product Catalog's Cleanup view (Phase 3): one compact list of every data-quality check with its count, and the
/// possible duplicates to go through one group at a time.
///
/// A check about single products (no part #, no cost, cost above price...) opens the product list with that filter on,
/// where each product is fixed on its own page. A check about groups (same name, same part #, similar names) opens its
/// groups beside the list: each product can be opened or made inactive (after a preview), and a group that is fine as
/// it is can be marked reviewed. Nothing is merged, deleted or re-linked for anyone, and no product is picked as "the
/// one that owns" a stock row: those are a person's calls, made on the product's own page.
class CatalogCleanupView extends StatefulWidget {
  final CatalogQuality quality;
  final List<CatalogEntry> entries;
  final bool canEdit;
  final bool canSeeCost;

  /// The server keeps reviewed marks (Phase 3 server).
  final bool reviewsLive;

  /// The reviewed marks, for who reviewed a group and when.
  final List<CatalogReview> reviews;
  final int categoryNamingIssues;
  final int historyDays;
  final CatalogManager manager;
  final void Function(CatalogCheck check) onShowCheck;
  final VoidCallback onShowCategoryNaming;
  final void Function(CatalogEntry product) onOpenProduct;
  final Future<void> Function() onChanged;
  final void Function(String message) onSnack;
  const CatalogCleanupView({
    super.key,
    required this.quality,
    required this.entries,
    required this.canEdit,
    required this.canSeeCost,
    required this.reviewsLive,
    required this.reviews,
    required this.categoryNamingIssues,
    required this.historyDays,
    required this.manager,
    required this.onShowCheck,
    required this.onShowCategoryNaming,
    required this.onOpenProduct,
    required this.onChanged,
    required this.onSnack,
  });

  @override
  State<CatalogCleanupView> createState() => _CatalogCleanupViewState();
}

class _CatalogCleanupViewState extends State<CatalogCleanupView> {
  static const _paneWidth = 344.0;
  static final _count = NumberFormat.decimalPattern();
  static final _when = DateFormat('MMM d');

  CatalogCheck? _check;
  bool _showReviewed = false;

  CatalogQuality get _q => widget.quality;

  /// The grouped check shown beside the list: the one picked, else the first with groups to look at.
  CatalogCheck get _current {
    if (_check != null) return _check!;
    for (final c in [CatalogCheck.dupeName, CatalogCheck.dupePart, CatalogCheck.similarName]) {
      if (_q.groupCount(c) > 0) return c;
    }
    return CatalogCheck.dupeName;
  }

  String get _window {
    final months = (widget.historyDays / 30).round();
    return months >= 2 ? '$months months' : '${widget.historyDays} days';
  }

  String _caption(CatalogCheck c) => c == CatalogCheck.obsolete ? 'No job in $_window, none on hand' : c.caption;

  static const _dots = {
    CatalogCheck.dupeName: DashUi.indigo,
    CatalogCheck.dupePart: DashUi.indigo,
    CatalogCheck.similarName: DashUi.indigo,
    CatalogCheck.noPart: DashUi.amber,
    CatalogCheck.noCost: DashUi.amber,
    CatalogCheck.noCategory: DashUi.amber,
    CatalogCheck.costAbove: DashUi.red,
    CatalogCheck.highMarkup: DashUi.red,
    CatalogCheck.categoryOdd: DashUi.sky,
    CatalogCheck.linkReview: DashUi.amber,
    CatalogCheck.obsolete: DashUi.muted,
  };

  // ---- the checks ---------------------------------------------------------------------------------------------------

  Widget _row(CatalogCheck c) {
    final grouped = c.grouped;
    final n = grouped ? _q.groupCount(c) : _q.productCount(c);
    final detail = grouped && n > 0 ? '${catalogPlural(n, 'group')} · ${catalogPlural(_q.productCount(c), 'product')}' : null;
    return CatalogIssueRow(
      key: ValueKey('check:${c.key}'),
      label: c.label,
      caption: _caption(c),
      detail: detail,
      count: n,
      dot: _dots[c]!,
      selected: grouped && c == _current && (_wide || _check != null),
      opensList: !grouped,
      onTap: n == 0 && !grouped
          ? null
          : () {
              if (grouped) {
                setState(() {
                  _check = c;
                  _showReviewed = false;
                });
              } else {
                widget.onShowCheck(c);
              }
            },
    );
  }

  Widget _checks() {
    final has = _q.checks.toSet();
    List<Widget> section(String label, List<CatalogCheck> checks) {
      final shown = checks.where(has.contains).toList();
      if (shown.isEmpty) return const [];
      return [CatalogSectionLabel(label), for (final c in shown) _row(c)];
    }

    final withIssues = _q.productsWithIssues;
    return Container(
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: DashUi.line)),
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Catalog health',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: DashUi.ink),
                ),
                const SizedBox(height: 2),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: _count.format(withIssues),
                        style: const TextStyle(fontWeight: FontWeight.w800, color: DashUi.ink),
                      ),
                      TextSpan(text: ' of ${_count.format(_q.checked)} active products to look at'),
                    ],
                  ),
                  style: CatalogUi.meta.copyWith(fontSize: 13, fontFeatures: CatalogUi.figures),
                ),
              ],
            ),
          ),
          ...section('POSSIBLE DUPLICATES', [CatalogCheck.dupeName, CatalogCheck.dupePart, CatalogCheck.similarName]),
          ...section(_q.withCost ? 'MISSING DETAILS AND PRICING' : 'MISSING DETAILS', [
            CatalogCheck.noPart,
            CatalogCheck.noCost,
            CatalogCheck.noCategory,
            CatalogCheck.costAbove,
            CatalogCheck.highMarkup,
          ]),
          CatalogSectionLabel('FILING AND STOCK'),
          _row(CatalogCheck.categoryOdd),
          CatalogIssueRow(
            key: const ValueKey('check:category_naming'),
            label: 'Category names',
            caption: 'One category written two ways',
            count: widget.categoryNamingIssues,
            dot: DashUi.sky,
            opensList: true,
            onTap: widget.categoryNamingIssues == 0 ? null : widget.onShowCategoryNaming,
          ),
          _row(CatalogCheck.linkReview),
          _row(CatalogCheck.obsolete),
          if (_q.nameLinked > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(Icons.link_rounded, size: 16, color: DashUi.amberText),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${catalogPlural(_q.nameLinked, 'product')} find their stock by name until the inventory link backfill runs. '
                      'Renaming one before then can lose its stock count.',
                      style: CatalogUi.meta,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ---- one check's groups -------------------------------------------------------------------------------------------

  CatalogReview? _reviewOf(CatalogIssueGroup g) => widget.reviews.where((r) => r.issueKey == g.issueKey).firstOrNull;

  Future<void> _markReviewed(CatalogIssueGroup g) async {
    final ok = await showCatalogFormDialog(
      context,
      title: 'Mark this group as reviewed?',
      subtitle: '${g.check.label}: ${g.title}',
      icon: Icons.task_alt_rounded,
      fieldLabel: 'Note (optional)',
      help: 'Why it is fine as it is, for whoever looks next. The group comes back if a product joins or leaves it.',
      multiline: true,
      saveLabel: 'Mark reviewed',
      action: (note, _) => widget.manager.markReviewed(g.issueKey, g.signature, note: note.isEmpty ? null : note, label: '${g.check.label} ${g.title}'),
    );
    if (!ok) return;
    await widget.onChanged();
    widget.onSnack('Marked as reviewed: ${g.title}');
  }

  Future<void> _unmark(CatalogIssueGroup g) async {
    try {
      await widget.manager.clearReview(g.issueKey);
      await widget.onChanged();
      widget.onSnack('Back on the list: ${g.title}');
    } catch (e) {
      widget.onSnack(catalogErrorText(e));
    }
  }

  Future<void> _makeInactive(CatalogEntry e) async {
    final r = await showBulkStatusDialog(context, entries: [e], active: false, manager: widget.manager);
    if (r == null) return;
    await widget.onChanged();
    if (!r.reload) widget.onSnack('${e.name} is now inactive');
  }

  Widget _groups() {
    final c = _current;
    final open = _q.groups[c] ?? const <CatalogIssueGroup>[];
    final reviewed = _q.reviewedGroups[c] ?? const <CatalogIssueGroup>[];
    final shown = [...open, if (_showReviewed) ...reviewed];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CatalogPaneHeader(
          child: Row(
            children: [
              Text(
                c.label,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: DashUi.ink),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  open.isEmpty ? _caption(c) : '${catalogPlural(open.length, 'group')} to look at · ${_caption(c)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CatalogUi.meta.copyWith(fontSize: 13.5),
                ),
              ),
              if (reviewed.isNotEmpty)
                TextButton(
                  key: const ValueKey('show-reviewed'),
                  onPressed: () => setState(() => _showReviewed = !_showReviewed),
                  style: TextButton.styleFrom(foregroundColor: DashUi.ink, textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                  child: Text(_showReviewed ? 'Hide reviewed' : 'Show ${reviewed.length} reviewed'),
                ),
              if (open.isNotEmpty)
                TextButton.icon(
                  onPressed: () => widget.onShowCheck(c),
                  iconAlignment: IconAlignment.end,
                  icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                  label: const Text('Show in product list'),
                  style: TextButton.styleFrom(foregroundColor: DashUi.ink, textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                ),
            ],
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? Center(
                  child: FlatEmpty(
                    icon: Icons.task_alt_rounded,
                    title: reviewed.isEmpty ? 'Nothing to look at' : 'All reviewed',
                    message: reviewed.isEmpty
                        ? 'No active products share ${c == CatalogCheck.dupePart ? 'a part number' : 'a name'}${c == CatalogCheck.similarName ? ' written two ways' : ''}.'
                        : '${catalogPlural(reviewed.length, 'group')} ${reviewed.length == 1 ? 'was' : 'were'} marked as fine as it is.',
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(CatalogUi.side, 12, CatalogUi.side, 20),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Nothing here is merged or deleted for you. Open each product to compare them; make the extra one '
                        'inactive, fix its name or part number, or mark the group reviewed when they are right as they are.',
                        style: CatalogUi.meta.copyWith(fontSize: 13),
                      ),
                    ),
                    for (final g in shown) _group(g),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _group(CatalogIssueGroup g) {
    final review = _reviewOf(g);
    final isReviewed = review != null && review.signature == g.signature;
    final title = switch (g.check) {
      CatalogCheck.dupePart => 'Part # ${g.title}',
      CatalogCheck.similarName => 'Looks alike: ${g.why ?? 'similar'}',
      _ => g.title,
    };
    return Container(
      key: ValueKey('group:${g.issueKey}'),
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        border: Border.all(color: DashUi.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text.rich(
                    catalogNameSpan(title, const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: DashUi.ink)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(catalogPlural(g.products.length, 'product'), style: CatalogUi.meta),
                const SizedBox(width: 10),
                if (isReviewed) ...[
                  CatalogTag(
                    'Reviewed${review.reviewedBy != null ? ' by ${review.reviewedBy}' : ''}${review.reviewedAt != null ? ', ${_when.format(review.reviewedAt!)}' : ''}',
                    tone: CatalogTone.good,
                    icon: Icons.check_rounded,
                  ),
                  if (widget.canEdit && widget.reviewsLive)
                    TextButton(
                      onPressed: () => _unmark(g),
                      style: TextButton.styleFrom(foregroundColor: DashUi.slate, textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                      child: const Text('Undo'),
                    ),
                ] else if (widget.canEdit && widget.reviewsLive)
                  CatalogOutlineButton(
                    key: ValueKey('review:${g.issueKey}'),
                    label: 'Mark reviewed…',
                    dense: true,
                    icon: Icons.task_alt_rounded,
                    onPressed: () => _markReviewed(g),
                  ),
              ],
            ),
          ),
          if (isReviewed && review.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: Text('"${review.note}"', style: CatalogUi.meta.copyWith(fontStyle: FontStyle.italic)),
            ),
          const Divider(height: 1, color: DashUi.line),
          for (var i = 0; i < g.products.length; i++) _member(g.products[i], i, last: i == g.products.length - 1),
        ],
      ),
    );
  }

  Widget _member(CatalogEntry e, int i, {required bool last}) {
    final conflict = e.inventoryConflict;
    Widget stock;
    if (conflict != null) {
      stock = Tooltip(
        message: inventoryConflictText(conflict),
        child: const CatalogTag('Stock: review', tone: CatalogTone.warn),
      );
    } else if (e.stock != null && (e.stock! > 0 || e.inInventory)) {
      stock = Text('${_count.format(e.stock)} on hand', style: CatalogUi.meta.copyWith(color: DashUi.ink, fontFeatures: CatalogUi.figures));
    } else {
      stock = const Text('No stock', style: CatalogUi.meta);
    }
    return Material(
      color: i.isOdd ? CatalogUi.stripe : Colors.white,
      borderRadius: last ? const BorderRadius.vertical(bottom: Radius.circular(12)) : null,
      child: InkWell(
        key: ValueKey('member:${e.key}'),
        onTap: () => widget.onOpenProduct(e),
        hoverColor: CatalogUi.hover,
        borderRadius: last ? const BorderRadius.vertical(bottom: Radius.circular(12)) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
          child: Row(
            children: [
              Expanded(
                flex: 6,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(catalogNameSpan(e.name, CatalogUi.name.copyWith(fontSize: 13.5)), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(
                      [
                        if (e.sku.isNotEmpty) 'Part # ${e.sku}' else 'No part #',
                        e.category.isEmpty ? 'No category' : e.category,
                        if (e.productId != null) 'No. ${e.productId}',
                      ].join('  ·  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: CatalogUi.meta.copyWith(fontSize: 12.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 92,
                child: Text(
                  e.rate == null ? 'Per job' : dashMoney(e.rate!),
                  textAlign: TextAlign.right,
                  style: e.rate == null ? CatalogUi.cellQuiet.copyWith(fontSize: 13.5) : CatalogUi.cellStrong.copyWith(fontSize: 13.5),
                ),
              ),
              if (widget.canSeeCost)
                SizedBox(
                  width: 92,
                  child: Text(
                    e.cost == null ? 'No cost' : 'cost ${dashMoney(e.cost!)}',
                    textAlign: TextAlign.right,
                    style: CatalogUi.meta.copyWith(fontFeatures: CatalogUi.figures),
                  ),
                ),
              const SizedBox(width: 14),
              SizedBox(width: 108, child: Align(alignment: Alignment.centerLeft, child: stock)),
              SizedBox(
                width: 124,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: !e.active
                      ? const CatalogTag('Inactive')
                      : widget.canEdit && e.updatedAt != null
                      ? TextButton(
                          key: ValueKey('deactivate:${e.key}'),
                          onPressed: () => _makeInactive(e),
                          style: TextButton.styleFrom(
                            foregroundColor: DashUi.slate,
                            textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          child: const Text('Make inactive…'),
                        )
                      : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Both panes fit (the checks and a check's groups side by side).
  bool _wide = true;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        _wide = box.maxWidth >= 860;
        if (!_wide) {
          // Too narrow for both: the checks, then the groups under them.
          return _check == null
              ? _checks()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => setState(() => _check = null),
                        icon: const Icon(Icons.arrow_back_rounded, size: 16),
                        label: const Text('All checks'),
                        style: TextButton.styleFrom(foregroundColor: DashUi.ink),
                      ),
                    ),
                    Expanded(child: _groups()),
                  ],
                );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: _paneWidth, child: _checks()),
            Expanded(
              child: AnimatedSwitcher(
                duration: CatalogUi.motion(context, 200),
                child: KeyedSubtree(key: ValueKey('groups:${_current.key}:$_showReviewed'), child: _groups()),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Plain words for the change log's actions (the History view and tests share them).
String catalogActionLabel(String action) => switch (action) {
  'category.create' => 'New category',
  'category.rename' => 'Category renamed',
  'category.update' => 'Category described',
  'category.merge' => 'Categories merged',
  'category.delete' => 'Category deleted',
  'products.bulk' => 'Several products',
  'product.create' => 'Product added',
  'product.update' => 'Product edited',
  'product.delete' => 'Product deleted',
  'review.mark' => 'Marked reviewed',
  'review.clear' => 'Review undone',
  _ => action,
};
