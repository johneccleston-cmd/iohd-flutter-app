import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'catalog_compare.dart';
import 'catalog_manage.dart';
import 'product_detail_screen.dart' show inventoryConflictText;
import 'services/line_items_api.dart';
import 'utils/catalog_quality.dart';
import 'widgets/app_dialog.dart';
import 'widgets/catalog_kit.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';

/// The Product Catalog's Cleanup view (Phase 3, refined 2026-11-18): one compact list of every data-quality check with
/// its count, and beside it the picked check's findings to go through one at a time.
///
/// Every check opens beside the list with three tabs: To review, Follow up and Reviewed. A finding is a group of
/// possible duplicates (same name, same part #, similar names) or one product under one check (no part #, no cost,
/// cost at or above price, possibly obsolete...). A person with the Update switch can mark a finding reviewed (fine as
/// it is) or to follow up (still to sort out), with an optional note; every mark, change and undo is kept and shown in
/// its history. Duplicates can be compared side by side. A possibly obsolete product shows its last job and estimate in
/// all of Service Fusion's history and its stock row.
///
/// Nothing is merged, deleted, re-linked or made inactive for anyone: making a product inactive is a person's choice,
/// after a preview, and no product is picked as "the one that owns" a stock row.
class CatalogCleanupView extends StatefulWidget {
  final CatalogQuality quality;
  final List<CatalogEntry> entries;
  final bool canEdit;
  final bool canSeeCost;

  /// The server keeps reviewed marks (Phase 3 server).
  final bool reviewsLive;

  /// The marks, for who marked a finding and when.
  final List<CatalogReview> reviews;
  final int categoryNamingIssues;
  final int historyDays;
  final CatalogManager manager;
  final void Function(CatalogCheck check) onShowCheck;
  final VoidCallback onShowCategoryNaming;
  final void Function(CatalogEntry product) onOpenProduct;
  final Future<void> Function() onChanged;
  final void Function(String message) onSnack;

  /// The check open beside the list at first (tests and links); else the first with duplicates to look at.
  final CatalogCheck? initialCheck;
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
    this.initialCheck,
  });

  @override
  State<CatalogCleanupView> createState() => _CatalogCleanupViewState();
}

/// The tabs of a check's findings.
enum _Tab { open, followUp, reviewed }

class _CatalogCleanupViewState extends State<CatalogCleanupView> {
  static const _paneWidth = 344.0;
  static final _count = NumberFormat.decimalPattern();
  static final _when = DateFormat('MMM d');
  static final _day = DateFormat('MMM d, y');
  static final _month = DateFormat('MMM y');

  late CatalogCheck? _check = widget.initialCheck;
  _Tab _tab = _Tab.open;

  // Sales across all history for the possibly obsolete products (loaded when that check is opened).
  Map<int, CatalogSale>? _sales;
  DateTime? _salesSince;
  bool _salesLoading = false;
  String? _salesError;
  bool _salesNeedServer = false;

  CatalogQuality get _q => widget.quality;
  bool get _canMark => widget.canEdit && widget.reviewsLive;

  /// The check shown beside the list: the one picked, else the first with groups to look at.
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

  @override
  void initState() {
    super.initState();
    if (_current == CatalogCheck.obsolete) _loadSales();
  }

  @override
  void didUpdateWidget(CatalogCleanupView old) {
    super.didUpdateWidget(old);
    // A reload can bring new obsolete products: fetch the ones not loaded yet.
    if (_current == CatalogCheck.obsolete && _sales != null && _obsoleteIds.any((id) => !_sales!.containsKey(id))) _loadSales();
  }

  void _pick(CatalogCheck c) {
    setState(() {
      _check = c;
      _tab = _Tab.open;
    });
    if (c == CatalogCheck.obsolete && _sales == null && !_salesLoading) _loadSales();
  }

  // ---- possibly obsolete: sales across all history -------------------------------------------------------------------

  List<int> get _obsoleteIds => [
    for (final e in [
      ...?_q.flagged[CatalogCheck.obsolete]?.map(_byKey),
      ...?_q.followUpItems[CatalogCheck.obsolete],
      ...?_q.reviewedItems[CatalogCheck.obsolete],
    ])
      if (e?.productId != null) e!.productId!,
  ];

  late Map<String, CatalogEntry> _entryByKey = {for (final e in widget.entries) e.key: e};
  List<CatalogEntry>? _entriesSeen;
  CatalogEntry? _byKey(String key) {
    if (!identical(_entriesSeen, widget.entries)) {
      _entriesSeen = widget.entries;
      _entryByKey = {for (final e in widget.entries) e.key: e};
    }
    return _entryByKey[key];
  }

  Future<void> _loadSales() async {
    final ids = _obsoleteIds;
    if (ids.isEmpty) return;
    setState(() {
      _salesLoading = true;
      _salesError = null;
    });
    try {
      final out = <int, CatalogSale>{};
      DateTime? since;
      for (var i = 0; i < ids.length; i += 1000) {
        final r = await widget.manager.productSales(ids.sublist(i, i + 1000 > ids.length ? ids.length : i + 1000));
        out.addAll(r.sales);
        since ??= r.since;
      }
      if (!mounted) return;
      setState(() {
        _sales = out;
        _salesSince = since;
        _salesLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _salesLoading = false;
        _salesNeedServer = catalogNeedsServerUpdate(e);
        _salesError = _salesNeedServer ? 'The last job and estimate need the server update.' : catalogErrorText(e);
      });
    }
  }

  // ---- the checks ---------------------------------------------------------------------------------------------------

  Widget _row(CatalogCheck c) {
    final grouped = c.grouped;
    final n = _q.openCount(c);
    final follow = _q.followUpCount(c);
    final reviewed = _q.reviewedCount(c);
    final parts = [
      if (grouped && n > 0) '${catalogPlural(n, 'group')} · ${catalogPlural(_q.productCount(c), 'product')}',
      if (follow > 0) '$follow to follow up',
    ];
    return CatalogIssueRow(
      key: ValueKey('check:${c.key}'),
      label: c.label,
      caption: _caption(c),
      detail: parts.isEmpty ? null : parts.join(' · '),
      count: n,
      dot: _dots[c]!,
      selected: c == _current && (_wide || _check != null),
      onTap: n == 0 && follow == 0 && reviewed == 0 && !grouped ? null : () => _pick(c),
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
    final follow = _q.followUpTotal;
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
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Catalog health',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: DashUi.ink),
                      ),
                    ),
                    if (follow > 0)
                      CatalogTag('$follow to follow up', key: const ValueKey('follow-up-total'), tone: CatalogTone.warn, icon: Icons.flag_outlined),
                  ],
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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

  // ---- marks ----------------------------------------------------------------------------------------------------------

  String _lapses(CatalogCheck c) => switch (c) {
    _ when c.grouped => 'The mark comes off if a product joins or leaves the group.',
    CatalogCheck.costAbove || CatalogCheck.highMarkup => 'The mark comes off if the price or cost changes.',
    CatalogCheck.categoryOdd => 'The mark comes off if its category changes.',
    CatalogCheck.linkReview => 'The mark comes off if the stock problem changes.',
    _ => 'It stays with this product while the check still applies.',
  };

  Future<void> _mark({
    required CatalogCheck check,
    required String issueKey,
    required String signature,
    String? basis,
    required String title,
    required String status,
    CatalogReview? current,
  }) async {
    final r = await showFindingMarkDialog(
      context,
      manager: widget.manager,
      issueKey: issueKey,
      signature: signature,
      basis: basis,
      title: '${check.label}: $title',
      label: '${check.label} $title',
      status: status,
      current: current,
      lapses: _lapses(check),
    );
    if (r == null) return;
    await widget.onChanged();
    if (r.reload) return;
    widget.onSnack(r.review?.followUp == true || (r.review == null && status == 'follow_up') ? 'Marked to follow up: $title' : 'Marked as reviewed: $title');
  }

  Future<void> _unmark(String issueKey, String title, CatalogReview? current) async {
    try {
      await widget.manager.clearReview(issueKey, expectedStamp: current?.stamp);
      await widget.onChanged();
      widget.onSnack('Back on the list: $title');
    } on LineItemsException catch (e) {
      if (e.status == 409 || e.status == 404) await widget.onChanged();
      widget.onSnack(e.status == 409 ? 'Someone else changed that mark. The list is up to date now.' : catalogErrorText(e));
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

  Future<void> _compare(CatalogIssueGroup g) async {
    final a = await showCatalogCompareDialog(
      context,
      group: g,
      canSeeCost: widget.canSeeCost,
      canEdit: widget.canEdit,
      historyDays: widget.historyDays,
      loadSales: widget.reviewsLive ? widget.manager.productSales : null,
    );
    if (a == null || !mounted) return;
    switch (a.kind) {
      case CatalogCompareKind.open:
        widget.onOpenProduct(a.entry);
      case CatalogCompareKind.deactivate:
        await _makeInactive(a.entry);
    }
  }

  /// A mark as a tag: "Follow up · Ann, Nov 18".
  Widget _markTag(CatalogReview r, {bool short = false}) => CatalogTag(
    '${r.followUp ? 'Follow up' : 'Reviewed'}${r.reviewedBy != null && !short ? ' · ${r.reviewedBy}' : ''}${r.reviewedAt != null ? '${short ? ' · ' : ', '}${_when.format(r.reviewedAt!)}' : ''}',
    tone: r.followUp ? CatalogTone.warn : CatalogTone.good,
    icon: r.followUp ? Icons.flag_outlined : Icons.check_rounded,
  );

  Widget _textButton(String label, VoidCallback onPressed, {Key? key}) => TextButton(
    key: key,
    onPressed: onPressed,
    style: TextButton.styleFrom(
      foregroundColor: DashUi.slate,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      minimumSize: const Size(0, 32),
      textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
    ),
    child: Text(label),
  );

  // ---- the pane beside the list -------------------------------------------------------------------------------------

  Widget _tabs(CatalogCheck c, {double width = 372}) {
    final open = _q.openCount(c);
    final follow = _q.followUpCount(c);
    final reviewed = _q.reviewedCount(c);
    return SizedBox(
      width: width,
      child: AppSegmented<_Tab>(
        key: const ValueKey('cleanup-tabs'),
        value: _tab,
        options: [(_Tab.open, 'To review $open'), (_Tab.followUp, 'Follow up $follow'), (_Tab.reviewed, 'Reviewed $reviewed')],
        onChanged: (t) => setState(() => _tab = t),
        dense: true,
      ),
    );
  }

  Widget _paneHeader(CatalogCheck c) => LayoutBuilder(builder: (context, box) => _paneHeaderIn(c, box.maxWidth));

  /// The check's name, what it finds, its tabs and "In the list". Under 900 px the tabs get a line of their own.
  Widget _paneHeaderIn(CatalogCheck c, double width) {
    final open = _q.openCount(c);
    final what = c.grouped ? catalogPlural(open, 'group') : catalogPlural(open, 'product');
    if (width < 900) {
      return CatalogPaneHeader(
        padding: const EdgeInsets.fromLTRB(CatalogUi.side, 8, CatalogUi.side, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    c.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: DashUi.ink),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    open == 0 ? '' : '$what to look at',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: CatalogUi.meta.copyWith(fontSize: 13.5),
                  ),
                ),
                if (open > 0)
                  IconButton(
                    key: const ValueKey('show-in-list'),
                    tooltip: 'Show these products in the product list',
                    onPressed: () => widget.onShowCheck(c),
                    icon: const Icon(Icons.arrow_forward_rounded, size: 18, color: DashUi.ink),
                  ),
              ],
            ),
            if (widget.reviewsLive) ...[const SizedBox(height: 6), _tabs(c, width: double.infinity)],
          ],
        ),
      );
    }
    return CatalogPaneHeader(
      child: Row(
        children: [
          Text(
            c.label,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: DashUi.ink),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              open == 0 ? _caption(c) : '$what to look at · ${_caption(c)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CatalogUi.meta.copyWith(fontSize: 13.5),
            ),
          ),
          const SizedBox(width: 8),
          if (widget.reviewsLive) _tabs(c),
          if (open > 0) ...[
            const SizedBox(width: 4),
            Tooltip(
              message: 'Show these products in the product list',
              child: TextButton.icon(
                key: const ValueKey('show-in-list'),
                onPressed: () => widget.onShowCheck(c),
                iconAlignment: IconAlignment.end,
                icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                label: const Text('In the list'),
                style: TextButton.styleFrom(
                  foregroundColor: DashUi.ink,
                  textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _empty(CatalogCheck c) {
    final (title, message) = switch (_tab) {
      _Tab.followUp => ('Nothing to follow up', 'Mark a finding "Follow up" when it still needs someone to sort it out. It stays here until then.'),
      _Tab.reviewed => ('Nothing marked reviewed', 'Findings marked "Reviewed: fine as it is" are kept here, with who marked them and why.'),
      _Tab.open when c.grouped => (
        'Nothing to look at',
        'No active products share ${c == CatalogCheck.dupePart ? 'a part number' : 'a name'}${c == CatalogCheck.similarName ? ' written two ways' : ''}.',
      ),
      _Tab.open => ('Nothing to look at', 'No active product is flagged by this check.'),
    };
    return Center(
      child: FlatEmpty(icon: _tab == _Tab.followUp ? Icons.flag_outlined : Icons.task_alt_rounded, title: title, message: message),
    );
  }

  Widget _pane() {
    final c = _current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _paneHeader(c),
        Expanded(child: c.grouped ? _groups(c) : _findings(c)),
      ],
    );
  }

  // ---- one grouped check's groups -----------------------------------------------------------------------------------

  Widget _groups(CatalogCheck c) {
    final shown =
        switch (_tab) {
          _Tab.open => _q.groups[c],
          _Tab.followUp => _q.followUpGroups[c],
          _Tab.reviewed => _q.reviewedGroups[c],
        } ??
        const <CatalogIssueGroup>[];
    if (shown.isEmpty) return _empty(c);
    return ListView(
      padding: const EdgeInsets.fromLTRB(CatalogUi.side, 12, CatalogUi.side, 20),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'Nothing here is merged or deleted for you. Compare the products side by side, open one to fix its name or part '
            'number, make the extra one inactive, or mark the group when they are right as they are.',
            style: CatalogUi.meta.copyWith(fontSize: 13),
          ),
        ),
        for (final g in shown) _group(g),
      ],
    );
  }

  /// A mark that no longer applies (the finding changed since): said in the To review tab, so it is never silent.
  Widget _lapsed(CatalogReview r) => Padding(
    padding: const EdgeInsets.only(top: 3),
    child: Row(
      children: [
        const Icon(Icons.update_rounded, size: 14, color: DashUi.amberText),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            '${r.followUp ? 'Marked to follow up' : 'Reviewed'}${r.reviewedBy == null ? '' : ' by ${r.reviewedBy}'}'
            '${r.reviewedAt == null ? '' : ' on ${_when.format(r.reviewedAt!)}'}; it changed since, so it is back to look at',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: CatalogUi.meta.copyWith(fontSize: 12.5, color: DashUi.amberText),
          ),
        ),
      ],
    ),
  );

  Widget _group(CatalogIssueGroup g) {
    // The tabs come from the quality, which already compared the mark with the group: in To review a mark is one that
    // lapsed (shown as such, with nothing to undo); elsewhere it is the mark that set the group aside.
    final mark = _q.marks[g.issueKey];
    final marked = _tab == _Tab.open ? null : mark;
    final lapsed = _tab == _Tab.open ? mark : null;
    final title = switch (g.check) {
      CatalogCheck.dupePart => 'Part # ${g.title}',
      CatalogCheck.similarName => 'Looks alike: ${g.why ?? 'similar'}',
      _ => g.title,
    };
    void markAs(String status) =>
        _mark(check: g.check, issueKey: g.issueKey, signature: g.signature, basis: g.basis, title: g.title, status: status, current: mark);
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
            // Wide: one line. Narrow (a small window): the title, then the actions under it, right-aligned.
            child: LayoutBuilder(
              builder: (context, box) {
                final wide = box.maxWidth >= 760;
                final actions = <Widget>[
                  if (marked != null) wide ? Flexible(child: _markTag(marked)) : _markTag(marked),
                  CatalogOutlineButton(
                    key: ValueKey('compare:${g.issueKey}'),
                    label: 'Compare',
                    dense: true,
                    icon: Icons.compare_arrows_rounded,
                    onPressed: () => _compare(g),
                  ),
                  if (_canMark && marked == null)
                    CatalogOutlineButton(
                      key: ValueKey('followup:${g.issueKey}'),
                      label: 'Follow up…',
                      dense: true,
                      icon: Icons.flag_outlined,
                      onPressed: () => markAs('follow_up'),
                    ),
                  if (_canMark && (marked == null || marked.followUp))
                    CatalogOutlineButton(
                      key: ValueKey('review:${g.issueKey}'),
                      label: 'Mark reviewed…',
                      dense: true,
                      icon: Icons.task_alt_rounded,
                      onPressed: () => markAs('reviewed'),
                    ),
                  if (_canMark && marked != null) ...[
                    _textButton('Undo', () => _unmark(g.issueKey, g.title, marked), key: ValueKey('undo:${g.issueKey}')),
                    _textButton(
                      'History',
                      () => showFindingHistoryDialog(context, manager: widget.manager, issueKey: g.issueKey, title: '${g.check.label}: ${g.title}'),
                      key: ValueKey('history:${g.issueKey}'),
                    ),
                  ],
                ];
                final head = <Widget>[
                  Expanded(
                    child: Text.rich(
                      catalogNameSpan(title, const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: DashUi.ink)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(catalogPlural(g.products.length, 'product'), style: CatalogUi.meta),
                ];
                if (wide) {
                  return Row(
                    children: [
                      ...head,
                      const SizedBox(width: 10),
                      for (var i = 0; i < actions.length; i++) ...[if (i > 0) const SizedBox(width: 6), actions[i]],
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: head),
                    const SizedBox(height: 6),
                    Wrap(alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, runSpacing: 6, children: actions),
                  ],
                );
              },
            ),
          ),
          if (marked != null && marked.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: Text('"${marked.note}"', style: CatalogUi.meta.copyWith(fontStyle: FontStyle.italic)),
            ),
          if (lapsed != null) Padding(key: ValueKey('lapsed:${g.issueKey}'), padding: const EdgeInsets.fromLTRB(14, 0, 14, 8), child: _lapsed(lapsed)),
          const Divider(height: 1, color: DashUi.line),
          for (var i = 0; i < g.products.length; i++) _member(g.products[i], i, last: i == g.products.length - 1),
        ],
      ),
    );
  }

  Widget _stockText(CatalogEntry e) {
    final conflict = e.inventoryConflict;
    if (conflict != null) {
      return Tooltip(
        message: inventoryConflictText(conflict),
        child: const CatalogTag('Stock: review', tone: CatalogTone.warn),
      );
    }
    if (e.stock != null && (e.stock! > 0 || e.inInventory)) {
      return Text(
        '${_count.format(e.stock)} on hand',
        style: CatalogUi.meta.copyWith(color: DashUi.ink, fontFeatures: CatalogUi.figures),
      );
    }
    return const Text('No stock', style: CatalogUi.meta);
  }

  Widget _inactiveButton(CatalogEntry e) => TextButton(
    key: ValueKey('deactivate:${e.key}'),
    onPressed: () => _makeInactive(e),
    style: TextButton.styleFrom(
      foregroundColor: DashUi.slate,
      textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
      padding: const EdgeInsets.symmetric(horizontal: 8),
    ),
    child: const Text('Make inactive…'),
  );

  Widget _member(CatalogEntry e, int i, {required bool last}) {
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
              SizedBox(
                width: 108,
                child: Align(alignment: Alignment.centerLeft, child: _stockText(e)),
              ),
              SizedBox(
                width: 124,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: !e.active
                      ? const CatalogTag('Inactive')
                      : widget.canEdit && e.updatedAt != null
                      ? _inactiveButton(e)
                      : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- one product at a time ----------------------------------------------------------------------------------------

  List<CatalogEntry> _items(CatalogCheck c) {
    final list = switch (_tab) {
      _Tab.open => [
        for (final k in _q.flagged[c] ?? const <String>{})
          if (_byKey(k) != null) _byKey(k)!,
      ],
      _Tab.followUp => [...?_q.followUpItems[c]],
      _Tab.reviewed => [...?_q.reviewedItems[c]],
    };
    int byName(CatalogEntry a, CatalogEntry b) => a.name.toLowerCase().compareTo(b.name.toLowerCase());
    if (c == CatalogCheck.obsolete && _sales != null) {
      DateTime? last(CatalogEntry e) {
        final s = _sales![e.productId];
        final j = s?.lastJobAt;
        final q = s?.lastEstimateAt;
        return j == null ? q : (q == null || j.isAfter(q) ? j : q);
      }

      return list..sort((a, b) {
        final x = last(a);
        final y = last(b);
        if (x != null && y != null) return y.compareTo(x);
        if (x != null || y != null) return x != null ? -1 : 1;
        return byName(a, b);
      });
    }
    return list..sort(byName);
  }

  /// The columns a check adds between the product and its actions: (header, width, value).
  List<(String, double, Widget Function(CatalogEntry e))> _columns(CatalogCheck c) {
    Widget money(double? v, {String none = '—'}) => Text(
      v == null ? none : dashMoney(v),
      textAlign: TextAlign.right,
      style: v == null ? CatalogUi.cellQuiet.copyWith(fontSize: 13.5) : CatalogUi.cellStrong.copyWith(fontSize: 13.5),
    );
    Widget two(String top, String? bottom, {bool quiet = false}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(top, maxLines: 1, overflow: TextOverflow.ellipsis, style: (quiet ? CatalogUi.cellQuiet : CatalogUi.cell).copyWith(fontSize: 13.5)),
        if (bottom != null) Text(bottom, maxLines: 1, overflow: TextOverflow.ellipsis, style: CatalogUi.meta.copyWith(fontSize: 12.5)),
      ],
    );
    switch (c) {
      case CatalogCheck.obsolete:
        String since() => _salesSince == null ? 'on record' : 'since ${_month.format(_salesSince!)}';
        Widget sale(CatalogEntry e, {required bool job}) {
          if (_salesError != null) return two('—', null, quiet: true);
          final s = _sales?[e.productId];
          if (_sales == null) return two('…', null, quiet: true);
          final at = job ? s?.lastJobAt : s?.lastEstimateAt;
          final no = job ? s?.lastJob : s?.lastEstimate;
          final n = job ? (s?.jobs ?? 0) : (s?.estimates ?? 0);
          if (at == null) return two('None ${since()}', null, quiet: true);
          return two(_day.format(at), '${job ? 'Job' : 'Estimate'} ${no ?? ''} · ${catalogPlural(n, job ? 'job' : 'estimate')}');
        }

        return [
          ('LAST JOB', 150, (e) => sale(e, job: true)),
          ('LAST ESTIMATE', 150, (e) => sale(e, job: false)),
          (
            'STOCK',
            150,
            (e) {
              final s = _sales?[e.productId]?.stock;
              if (e.inventoryConflict != null) return two('Needs review', 'Stock link', quiet: true);
              if (s == null) return two(e.inInventory ? 'No stock row' : 'Not kept in stock', null, quiet: true);
              return two(
                '${_count.format(s.qty ?? 0)} on hand${s.location == null ? '' : ' · ${s.location}'}',
                s.updatedAt == null ? 'Row #${s.itemId}' : 'Row #${s.itemId}, updated ${_day.format(s.updatedAt!)}',
              );
            },
          ),
        ];
      case CatalogCheck.costAbove || CatalogCheck.highMarkup:
        return [
          ('PRICE', 96, (e) => money(e.rate, none: 'Per job')),
          ('COST', 96, (e) => money(e.cost)),
          (
            'MARGIN',
            84,
            (e) {
              final p = e.rate;
              final cost = e.cost;
              final m = p == null || cost == null || p <= 0 ? null : ((p - cost) / p * 100).round();
              return Text(
                m == null ? '—' : '$m%',
                textAlign: TextAlign.right,
                style: CatalogUi.cellStrong.copyWith(fontSize: 13.5, color: m != null && m <= 0 ? DashUi.redText : DashUi.ink),
              );
            },
          ),
        ];
      case CatalogCheck.categoryOdd:
        return [('USUALLY IN', 220, (e) => two(_q.usualCategory[e.key] ?? '—', 'Most products named like it'))];
      case CatalogCheck.linkReview:
        return [
          (
            'WHY',
            300,
            (e) => Text(
              inventoryConflictText(e.inventoryConflict ?? '').replaceFirst('Not shown: ', ''),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: CatalogUi.meta.copyWith(color: DashUi.ink),
            ),
          ),
        ];
      default:
        return [('PRICE', 96, (e) => money(e.rate, none: 'Per job')), ('STOCK', 120, _stockText)];
    }
  }

  double get _actionsWidth => switch (_tab) {
    _Tab.open => 262.0,
    _Tab.followUp => 220.0,
    _Tab.reviewed => 110.0,
  };

  Widget _findings(CatalogCheck c) => LayoutBuilder(builder: (context, box) => _findingsIn(c, box.maxWidth));

  /// A check's products at [width]: the check's columns give way (down to 60%) before the product name gets narrower
  /// than 240 px, so nothing spills over at any window size.
  Widget _findingsIn(CatalogCheck c, double width) {
    final items = _items(c);
    final wanted = _columns(c);
    final fixed = wanted.fold<double>(0, (n, col) => n + col.$2 + 12) + 12 + _actionsWidth + 2 * CatalogUi.side;
    final squeeze = width - fixed >= 240
        ? 1.0
        : ((width - 240 - (fixed - wanted.fold<double>(0, (n, col) => n + col.$2))) / wanted.fold<double>(1, (n, col) => n + col.$2)).clamp(0.6, 1.0);
    final cols = [for (final col in wanted) (col.$1, (col.$2 * squeeze).floorToDouble(), col.$3)];
    final intro = c == CatalogCheck.obsolete
        ? 'On no job in $_window and none on hand. Last job and estimate are from every Service Fusion job'
              '${_salesSince == null ? '' : ' since ${_month.format(_salesSince!)}'}. Nothing is made inactive for you: '
              'mark it reviewed to keep it, mark it to follow up, or make it inactive yourself after a preview.'
        : 'Go through them one at a time: open a product to fix it, or mark it reviewed when it is right as it is, or to '
              'follow up when someone still has to sort it out.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(CatalogUi.side, 10, CatalogUi.side, 8),
          child: Text(intro, style: CatalogUi.meta.copyWith(fontSize: 13)),
        ),
        if (c == CatalogCheck.obsolete && _salesError != null)
          _salesNeedServer
              ? Padding(padding: const EdgeInsets.fromLTRB(CatalogUi.side, 0, CatalogUi.side, 8), child: AppNotice(_salesError!))
              : FlatStaleNotice(message: _salesError!, busy: _salesLoading, onRetry: _loadSales),
        Container(
          height: CatalogUi.headerHeight,
          padding: const EdgeInsets.symmetric(horizontal: CatalogUi.side),
          decoration: const BoxDecoration(
            color: DashUi.faint,
            border: Border.symmetric(horizontal: BorderSide(color: DashUi.line)),
          ),
          child: Row(
            children: [
              const Expanded(child: Text('PRODUCT', style: CatalogUi.head)),
              for (final col in cols) ...[
                const SizedBox(width: 12),
                SizedBox(
                  width: col.$2,
                  child: Text(col.$1, style: CatalogUi.head, textAlign: {'PRICE', 'COST', 'MARGIN'}.contains(col.$1) ? TextAlign.right : TextAlign.left),
                ),
              ],
              SizedBox(width: 12 + _actionsWidth),
            ],
          ),
        ),
        Expanded(
          child: items.isEmpty ? _empty(c) : ListView.builder(itemCount: items.length, itemBuilder: (_, i) => _finding(c, items[i], i, cols)),
        ),
      ],
    );
  }

  Widget _finding(CatalogCheck c, CatalogEntry e, int i, List<(String, double, Widget Function(CatalogEntry e))> cols) {
    final key = catalogFindingKey(c, e);
    final mark = _q.markOf(c, e);
    final marked = _tab == _Tab.open ? null : mark;
    final lapsed = _tab == _Tab.open ? mark : null;
    final markable = _canMark && key != null;
    void markAs(String status) => _mark(
      check: c,
      issueKey: key!,
      signature: '${e.productId}',
      basis: catalogFindingBasis(c, e, usual: _q.usualCategory[e.key]),
      title: e.name,
      status: status,
      current: mark,
    );
    return Material(
      key: ValueKey('finding:${c.key}:${e.key}'),
      color: i.isOdd ? CatalogUi.stripe : Colors.white,
      child: InkWell(
        onTap: () => widget.onOpenProduct(e),
        hoverColor: CatalogUi.hover,
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: CatalogUi.side, vertical: 6),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: DashUi.faint)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
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
                    if (lapsed != null) KeyedSubtree(key: ValueKey('lapsed:$key'), child: _lapsed(lapsed)),
                    if (marked != null) ...[
                      const SizedBox(height: 3),
                      // A short tag (what and when); who and why beside it, the full note in the tooltip.
                      Row(
                        children: [
                          Flexible(flex: 3, child: _markTag(marked, short: true)),
                          const SizedBox(width: 8),
                          Flexible(
                            flex: 2,
                            child: Tooltip(
                              message: marked.note.isEmpty ? (marked.reviewedBy ?? '') : '${marked.reviewedBy ?? ''}: "${marked.note}"',
                              waitDuration: const Duration(milliseconds: 500),
                              child: Text.rich(
                                TextSpan(
                                  children: [
                                    if (marked.reviewedBy != null)
                                      TextSpan(
                                        text: marked.note.isEmpty ? marked.reviewedBy : '${marked.reviewedBy}: ',
                                        style: const TextStyle(fontWeight: FontWeight.w700, color: DashUi.slate),
                                      ),
                                    if (marked.note.isNotEmpty)
                                      TextSpan(
                                        text: '"${marked.note}"',
                                        style: const TextStyle(fontStyle: FontStyle.italic),
                                      ),
                                  ],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: CatalogUi.meta.copyWith(fontSize: 12.5),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              for (final col in cols) ...[
                const SizedBox(width: 12),
                SizedBox(
                  width: col.$2,
                  child: Align(alignment: {'PRICE', 'COST', 'MARGIN'}.contains(col.$1) ? Alignment.centerRight : Alignment.centerLeft, child: col.$3(e)),
                ),
              ],
              const SizedBox(width: 12),
              SizedBox(
                width: _actionsWidth,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!e.active) ...[const CatalogTag('Inactive'), const SizedBox(width: 6)],
                      if (markable && marked == null)
                        CatalogOutlineButton(key: ValueKey('followup:$key'), label: 'Follow up…', dense: true, onPressed: () => markAs('follow_up')),
                      if (markable && (marked == null || marked.followUp)) ...[
                        const SizedBox(width: 6),
                        CatalogOutlineButton(
                          key: ValueKey('review:$key'),
                          label: marked == null ? 'Reviewed…' : 'Mark reviewed…',
                          dense: true,
                          onPressed: () => markAs('reviewed'),
                        ),
                      ],
                      if (markable && marked != null) _textButton('Undo', () => _unmark(key, e.name, marked), key: ValueKey('undo:$key')),
                      _moreMenu(c, e, key, marked),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The rest of what can be done with one finding: open it, see its marks' history, make it inactive (with a preview).
  Widget _moreMenu(CatalogCheck c, CatalogEntry e, String? key, CatalogReview? mark) {
    return PopupMenuButton<String>(
      key: ValueKey('more:${c.key}:${e.key}'),
      tooltip: 'More',
      icon: const Icon(Icons.more_horiz_rounded, size: 19, color: DashUi.slate),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 200),
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: DashUi.line),
      ),
      onSelected: (v) {
        switch (v) {
          case 'open':
            widget.onOpenProduct(e);
          case 'history':
            showFindingHistoryDialog(context, manager: widget.manager, issueKey: key!, title: '${c.label}: ${e.name}');
          case 'inactive':
            _makeInactive(e);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 'open',
          height: 38,
          child: Text('Open the product', style: TextStyle(fontSize: 13.5, color: DashUi.ink)),
        ),
        if (key != null && widget.reviewsLive)
          const PopupMenuItem(
            value: 'history',
            height: 38,
            child: Text('Review history', style: TextStyle(fontSize: 13.5, color: DashUi.ink)),
          ),
        if (widget.canEdit && e.active && e.updatedAt != null)
          const PopupMenuItem(
            value: 'inactive',
            height: 38,
            child: Text('Make inactive…', style: TextStyle(fontSize: 13.5, color: DashUi.ink)),
          ),
      ],
    );
  }

  /// Both panes fit (the checks and a check's findings side by side).
  bool _wide = true;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        _wide = box.maxWidth >= 860;
        if (!_wide) {
          // Too narrow for both: the checks, then the findings under them.
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
                    Expanded(child: _pane()),
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
                child: KeyedSubtree(key: ValueKey('pane:${_current.key}:${_tab.name}'), child: _pane()),
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
  'review.follow_up' => 'Follow up',
  'review.clear' => 'Mark taken off',
  _ => action,
};
