import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'catalog_manage.dart';
import 'product_detail_screen.dart' show inventoryConflictText;
import 'services/line_items_api.dart';
import 'utils/catalog_quality.dart';
import 'widgets/app_dialog.dart';
import 'widgets/catalog_kit.dart';
import 'widgets/dashboard_kit.dart';

/// Comparing possible duplicates side by side (refinement 2026-11-18): every detail that tells two products apart, one
/// column per product, with the rows that differ tinted. Nothing is merged, deleted or re-linked here; the dialog only
/// opens a product or starts "Make inactive" (which has its own preview). Costs, margin and vendors are rows only for
/// people with the Line Items & Costs > View switch (the server does not send them to anyone else).

/// What the person chose in the comparison.
enum CatalogCompareKind { open, deactivate }

typedef CatalogCompareAction = ({CatalogCompareKind kind, CatalogEntry entry});

Future<CatalogCompareAction?> showCatalogCompareDialog(
  BuildContext context, {
  required CatalogIssueGroup group,
  required bool canSeeCost,
  required bool canEdit,
  required int historyDays,
  Future<({DateTime? since, Map<int, CatalogSale> sales})> Function(List<int> ids)? loadSales,
}) {
  return showDialog<CatalogCompareAction>(
    context: context,
    builder: (_) => _CompareDialog(group: group, canSeeCost: canSeeCost, canEdit: canEdit, historyDays: historyDays, loadSales: loadSales),
  );
}

class _CompareDialog extends StatefulWidget {
  final CatalogIssueGroup group;
  final bool canSeeCost;
  final bool canEdit;
  final int historyDays;
  final Future<({DateTime? since, Map<int, CatalogSale> sales})> Function(List<int> ids)? loadSales;
  const _CompareDialog({required this.group, required this.canSeeCost, required this.canEdit, required this.historyDays, this.loadSales});

  @override
  State<_CompareDialog> createState() => _CompareDialogState();
}

/// One row of the comparison: a label and each product's value. [key] names it for tests.
class _Line {
  final String key;
  final String label;
  final List<String> values;

  /// Rows like the name and the product number always differ and say nothing by differing.
  final bool compare;
  const _Line(this.key, this.label, this.values, {this.compare = true});

  bool get differs => compare && values.map((v) => v.trim().toLowerCase()).toSet().length > 1;
}

class _CompareDialogState extends State<_CompareDialog> {
  static final _day = DateFormat('MMM d, y');
  static final _count = NumberFormat.decimalPattern();
  static const _labelWidth = 150.0;
  static const _colMin = 210.0;

  Map<int, CatalogSale>? _sales;
  bool _salesFailed = false;

  List<CatalogEntry> get _products => widget.group.products;

  @override
  void initState() {
    super.initState();
    final ids = [
      for (final e in _products)
        if (e.productId != null) e.productId!,
    ];
    if (widget.loadSales != null && ids.isNotEmpty) {
      widget.loadSales!(ids)
          .then((r) {
            if (mounted) setState(() => _sales = r.sales);
          })
          .catchError((Object _) {
            if (mounted) setState(() => _salesFailed = true);
          });
    }
  }

  String _money(double? v) => v == null ? '—' : dashMoney(v);

  String _stockLink(CatalogEntry e) {
    if (e.inventoryConflict != null) return 'Needs review: ${inventoryConflictText(e.inventoryConflict!).replaceFirst('Not shown: ', '')}';
    if (e.inventoryItemId == null) return 'No inventory row';
    return switch (e.inventoryLink) {
      'id' => 'Its own inventory row (#${e.inventoryItemId})',
      'name' => 'Row #${e.inventoryItemId}, found by name until the link backfill',
      _ => 'Inventory row #${e.inventoryItemId}',
    };
  }

  String _lastJob(CatalogEntry e) {
    if (widget.loadSales == null) return '—';
    if (_salesFailed) return 'Could not load';
    final s = _sales?[e.productId];
    if (_sales == null) return '…';
    if (s == null || s.lastJobAt == null) return 'None on record';
    return '${_day.format(s.lastJobAt!)}${s.lastJob == null ? '' : ' (job ${s.lastJob})'} · ${catalogPlural(s.jobs, 'job')} in all';
  }

  String _vendors(CatalogEntry e) =>
      e.vendors.isEmpty ? 'None' : e.vendors.map((v) => v.price == null ? v.name : '${v.name} ${dashMoney(v.price!)}').join('\n');

  String _margin(CatalogEntry e) {
    final c = e.cost;
    final p = e.rate;
    if (c == null || p == null || p <= 0) return '—';
    return '${((p - c) / p * 100).round()}%';
  }

  List<_Line> get _lines {
    List<String> of(String Function(CatalogEntry e) f) => [for (final e in _products) f(e)];
    final months = (widget.historyDays / 30).round();
    return [
      _Line('name', 'Name', of((e) => e.name), compare: false),
      _Line('part', 'Part #', of((e) => e.sku.isEmpty ? 'None' : e.sku)),
      _Line('category', 'Category', of((e) => e.category.isEmpty ? 'No category' : e.category)),
      _Line('status', 'Status', of((e) => e.active ? 'Active' : 'Inactive')),
      _Line('price', 'Price', of((e) => e.rate == null ? 'No price' : dashMoney(e.rate!))),
      _Line('member', 'Member price', of((e) => _money(e.memberPrice))),
      if (widget.canSeeCost) ...[
        _Line('cost', 'Cost', of((e) => _money(e.cost))),
        _Line('margin', 'Margin', of(_margin)),
        _Line('vendors', 'Vendors', of(_vendors)),
      ],
      _Line('kept', 'Kept in stock', of((e) => e.inventoryItem == null ? '—' : (e.inventoryItem! ? 'Yes' : 'No'))),
      _Line('link', 'Inventory row', of(_stockLink)),
      _Line('stock', 'On hand', of((e) => e.inventoryConflict != null ? 'Not shown' : (e.stock == null ? '—' : _count.format(e.stock)))),
      _Line(
        'uses',
        'Jobs in $months months',
        of((e) => e.uses == 0 ? 'None' : '${_count.format(e.uses)}${e.lastUsed == null ? '' : ', last ${_day.format(DateTime.parse(e.lastUsed!))}'}'),
      ),
      if (widget.loadSales != null) _Line('last_job', 'Last job ever', of(_lastJob)),
      _Line('model', 'Model', of((e) => e.model.isEmpty ? '—' : e.model)),
      _Line('id', 'Product no.', of((e) => e.productId == null ? '—' : '${e.productId}'), compare: false),
      _Line(
        'changed',
        'Last changed',
        of((e) {
          final t = e.updatedAt == null ? null : DateTime.tryParse(e.updatedAt!)?.toLocal();
          return t == null ? '—' : _day.format(t);
        }),
        compare: false,
      ),
    ];
  }

  Widget _cell(String text, {required bool strong, required double width}) => SizedBox(
    width: width,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
      child: strong
          ? Text.rich(catalogNameSpan(text, const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink, height: 1.3)))
          : Text(
              text,
              style: const TextStyle(fontSize: 13.5, color: DashUi.ink, height: 1.35, fontFeatures: CatalogUi.figures),
            ),
    ),
  );

  Widget _table(double colWidth) {
    final lines = _lines;
    final differs = lines.where((l) => l.differs).length;
    final tint = DashUi.amber.withValues(alpha: 0.07);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < lines.length; i++)
          Container(
            key: ValueKey('compare-row:${lines[i].key}'),
            decoration: BoxDecoration(
              color: lines[i].differs ? tint : (i.isOdd ? CatalogUi.stripe : Colors.white),
              border: const Border(bottom: BorderSide(color: DashUi.faint)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: _labelWidth,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 8, 7),
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            lines[i].label,
                            style: CatalogUi.meta.copyWith(fontWeight: FontWeight.w700, color: DashUi.slate),
                          ),
                        ),
                        if (lines[i].differs) ...[
                          const SizedBox(width: 6),
                          Semantics(
                            label: 'differs',
                            child: Container(
                              width: 7,
                              height: 7,
                              decoration: const BoxDecoration(color: DashUi.amber, shape: BoxShape.circle),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                for (final v in lines[i].values) _cell(v, strong: lines[i].key == 'name', width: colWidth),
              ],
            ),
          ),
        // What can be done with each product. Nothing here merges or deletes.
        Row(
          children: [
            const SizedBox(width: _labelWidth),
            for (final e in _products)
              SizedBox(
                width: colWidth,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 10, 6, 2),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      CatalogOutlineButton(
                        key: ValueKey('compare-open:${e.key}'),
                        label: 'Open',
                        icon: Icons.open_in_new_rounded,
                        dense: true,
                        onPressed: () => Navigator.pop(context, (kind: CatalogCompareKind.open, entry: e)),
                      ),
                      if (widget.canEdit && e.active && e.updatedAt != null)
                        CatalogOutlineButton(
                          key: ValueKey('compare-deactivate:${e.key}'),
                          label: 'Make inactive…',
                          dense: true,
                          onPressed: () => Navigator.pop(context, (kind: CatalogCompareKind.deactivate, entry: e)),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 2),
        Semantics(
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              differs == 0 ? 'Nothing compared here differs.' : '${catalogPlural(differs, 'detail')} differ${differs == 1 ? 's' : ''} (tinted rows).',
              style: CatalogUi.meta,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context).width;
    final n = _products.length;
    final width = math.min(1160.0, screen - 48);
    // The columns share the dialog; past four products they keep their width and the table scrolls sideways.
    final room = width - 48 - 2 - _labelWidth - 1; // the dialog's padding, the table's border, and a pixel to spare
    final colWidth = math.max(_colMin, room / n);
    final scrolls = colWidth * n > room + 0.5;
    final g = widget.group;
    final title = switch (g.check) {
      CatalogCheck.dupePart => 'Part # ${g.title}',
      CatalogCheck.similarName => 'Names that look alike (${g.why ?? 'similar'})',
      _ => g.title,
    };
    final table = _table(colWidth);
    return AppDialog(
      title: 'Compare side by side',
      subtitle: '${g.check.label}: $title · ${catalogPlural(n, 'product')}',
      icon: Icons.compare_arrows_rounded,
      width: width,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Nothing is merged or deleted. Compare the details, then open a product to fix it, or make the extra one inactive '
            '(you see a preview first).${widget.canSeeCost ? '' : ' Costs, margin and vendors need the Line Items & Costs > View switch.'}',
            style: CatalogUi.meta.copyWith(fontSize: 13),
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: DashUi.line),
              borderRadius: BorderRadius.circular(10),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: scrolls
                  ? Scrollbar(
                      child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: table),
                    )
                  : table,
            ),
          ),
        ],
      ),
      actions: [AppButton.ink('Close', () => Navigator.pop(context))],
    );
  }
}
