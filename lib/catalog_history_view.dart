import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'catalog_cleanup_view.dart' show catalogActionLabel;
import 'catalog_manage.dart';
import 'services/line_items_api.dart';
import 'widgets/app_dialog.dart';
import 'widgets/catalog_kit.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';

/// The Product Catalog's History view (Phase 3): the catalog's change log, newest first. Who changed what and when:
/// categories created, renamed, described, merged or deleted; changes to several products at once; one product added,
/// edited or deleted; groups marked reviewed. A row opens to show what changed (before and after). Cost values are
/// blank for anyone without the Line Items & Costs > View switch (the server leaves them out).
class CatalogHistoryView extends StatefulWidget {
  final CatalogManager manager;

  /// Product names by id, for the lines that list products.
  final Map<int, String> names;
  final void Function(int productId) onOpenProduct;
  const CatalogHistoryView({super.key, required this.manager, required this.names, required this.onOpenProduct});

  @override
  State<CatalogHistoryView> createState() => CatalogHistoryViewState();
}

class CatalogHistoryViewState extends State<CatalogHistoryView> {
  static final _day = DateFormat('EEE, MMM d, y');
  static final _time = DateFormat('h:mm a');
  static const _filters = [
    ('all', 'Everything'),
    ('category', 'Categories'),
    ('products.bulk', 'Several at once'),
    ('product', 'One product'),
    ('review', 'Reviews'),
  ];

  List<CatalogAuditEntry> _entries = const [];
  bool _more = false;
  bool _loading = true;
  bool _loadingMore = false;
  bool _needsServer = false;
  String? _error;
  String _filter = 'all';
  final Set<int> _open = {};

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// Loads the newest entries again (the page's Refresh, and after a change elsewhere on the page).
  Future<void> reload() async {
    setState(() {
      _loading = _entries.isEmpty;
      _error = null;
    });
    try {
      final r = await widget.manager.listAudit(limit: 100);
      if (!mounted) return;
      setState(() {
        _entries = r.entries;
        _more = r.more;
        _loading = false;
        _needsServer = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _needsServer = catalogNeedsServerUpdate(e);
        _error = catalogErrorText(e);
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _entries.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final r = await widget.manager.listAudit(limit: 100, before: _entries.last.id);
      if (!mounted) return;
      setState(() {
        _entries = [..._entries, ...r.entries];
        _more = r.more;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _error = catalogErrorText(e);
      });
    }
  }

  bool _matches(CatalogAuditEntry e) => switch (_filter) {
    'all' => true,
    'products.bulk' => e.action == 'products.bulk',
    _ => e.action.startsWith('$_filter.'),
  };

  static const _icons = {
    'category': Icons.folder_outlined,
    'products': Icons.library_add_check_outlined,
    'product': Icons.inventory_2_outlined,
    'review': Icons.task_alt_rounded,
  };

  String _value(String field, Object? v) {
    if (v == null) return '—';
    if (v is bool) return v ? 'Yes' : 'No';
    if (v is num && {'unitPrice', 'memberPrice', 'avgUnitCost', 'fixedCommission', 'fixedBonus'}.contains(field)) return dashMoney(v.toDouble());
    if (v is List) return v.isEmpty ? 'None' : v.map((x) => x is Map ? '${x['name']}${x['price'] != null ? ' ${dashMoney((x['price'] as num).toDouble())}' : ''}' : '$x').join(', ');
    final s = '$v';
    return s.isEmpty ? '—' : s;
  }

  static const _fieldNames = {
    'name': 'Name',
    'category': 'Category',
    'partNumber': 'Part #',
    'model': 'Model',
    'sku': 'SKU',
    'productType': 'Type',
    'description': 'Description',
    'purchaseDescription': 'Ordering notes',
    'relatedProducts': 'Related products',
    'unitPrice': 'Price',
    'memberPrice': 'Member price',
    'avgUnitCost': 'Unit cost',
    'isActive': 'Active',
    'isInventoryItem': 'Inventory item',
    'paysCommission': 'Pays commission',
    'fixedCommission': 'Fixed commission',
    'percentCommission': 'Commission %',
    'paysBonus': 'Pays bonus',
    'fixedBonus': 'Fixed bonus',
    'percentBonus': 'Bonus %',
    'paysHours': 'Pays hours',
    'vendors': 'Vendors',
  };

  /// What an entry changed, as lines to read when it is opened.
  List<Widget> _details(CatalogAuditEntry e) {
    final d = e.details;
    final out = <Widget>[];
    Widget line(String label, String text, {Widget? trailing, double labelWidth = 150}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(label, style: CatalogUi.meta.copyWith(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13.5, color: DashUi.ink, height: 1.35))),
          ?trailing,
        ],
      ),
    );
    final changes = d['changes'];
    if (changes is Map) {
      for (final c in changes.entries) {
        final field = c.key.toString();
        final pair = c.value;
        final label = _fieldNames[field] ?? field;
        if (pair == null) {
          out.add(line(label, 'Changed (hidden: needs the cost switch)'));
        } else if (pair is List && pair.length == 2) {
          out.add(line(label, e.action == 'product.create' ? _value(field, pair[1]) : '${_value(field, pair[0])}  →  ${_value(field, pair[1])}'));
        }
      }
    }
    final before = d['before'];
    if (before is Map && before.isNotEmpty) {
      final set = d['set'] is Map ? d['set'] as Map : const {};
      for (final b in before.entries) {
        final id = int.tryParse(b.key.toString());
        final was = b.value is Map ? b.value as Map : const {};
        final what = [
          if (set.containsKey('category')) '${was['category'] ?? 'No category'}  →  ${set['category']}',
          if (set.containsKey('isActive')) '${was['isActive'] == false ? 'Inactive' : 'Active'}  →  ${set['isActive'] == true ? 'Active' : 'Inactive'}',
        ].join('   ');
        out.add(
          line(
            (was['name'] ?? (id == null ? '' : widget.names[id]) ?? 'Product $id').toString(),
            what,
            labelWidth: 340, // a product's name, not a field's
            trailing: id == null || !widget.names.containsKey(id)
                ? null
                : TextButton(
                    onPressed: () => widget.onOpenProduct(id),
                    style: TextButton.styleFrom(foregroundColor: DashUi.ink, textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                    child: const Text('Open'),
                  ),
          ),
        );
      }
    }
    if (d['sources'] is List) {
      for (final s in (d['sources'] as List).whereType<Map>()) {
        out.add(line('Merged in', '${s['name']} (${catalogPlural((s['products'] as num?)?.toInt() ?? 0, 'product')})'));
      }
    }
    if (d['note'] is String && (d['note'] as String).isNotEmpty) out.add(line('Note', d['note'] as String));
    if (out.isEmpty && e.productIds.length == 1 && widget.names.containsKey(e.productIds.first)) {
      out.add(
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => widget.onOpenProduct(e.productIds.first),
            icon: const Icon(Icons.open_in_new_rounded, size: 15),
            label: const Text('Open the product'),
            style: TextButton.styleFrom(foregroundColor: DashUi.ink),
          ),
        ),
      );
    }
    return out;
  }

  Widget _row(CatalogAuditEntry e, int i) {
    final open = _open.contains(e.id);
    final family = e.action.split('.').first;
    final at = e.at;
    final details = open ? _details(e) : const <Widget>[];
    return Container(
      key: ValueKey('audit:${e.id}'),
      color: i.isOdd ? CatalogUi.stripe : Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => open ? _open.remove(e.id) : _open.add(e.id)),
            hoverColor: CatalogUi.hover,
            child: Container(
              constraints: const BoxConstraints(minHeight: CatalogUi.rowHeight),
              padding: const EdgeInsets.symmetric(horizontal: CatalogUi.side, vertical: 7),
              child: Row(
                children: [
                  SizedBox(
                    width: 170,
                    child: Text(
                      at == null ? '' : '${_day.format(at)}\n${_time.format(at)}',
                      style: CatalogUi.meta.copyWith(fontSize: 12.5, color: DashUi.ink, fontFeatures: CatalogUi.figures),
                    ),
                  ),
                  const SizedBox(width: CatalogUi.gap),
                  SizedBox(
                    width: 150,
                    child: Text(e.by.isEmpty ? '—' : e.by, maxLines: 1, overflow: TextOverflow.ellipsis, style: CatalogUi.cell.copyWith(fontSize: 13.5)),
                  ),
                  const SizedBox(width: CatalogUi.gap),
                  Icon(_icons[family] ?? Icons.history_rounded, size: 17, color: DashUi.slate),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 132,
                    child: Text(catalogActionLabel(e.action), style: CatalogUi.meta.copyWith(fontWeight: FontWeight.w700, color: DashUi.slate)),
                  ),
                  const SizedBox(width: CatalogUi.gap),
                  Expanded(
                    child: Text.rich(
                      catalogNameSpan(e.summary, const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: DashUi.ink, height: 1.3)),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: open ? 0.5 : 0,
                    duration: CatalogUi.motion(context),
                    child: const Icon(Icons.expand_more_rounded, size: 19, color: DashUi.slate),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: CatalogUi.motion(context, 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: !open
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.fromLTRB(CatalogUi.side + 170 + CatalogUi.gap, 0, CatalogUi.side, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: details.isEmpty ? [const Text('No more detail was kept for this change.', style: CatalogUi.meta)] : details,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.2, color: DashUi.slate)));
    }
    if (_needsServer) {
      return const Center(
        child: FlatEmpty(
          icon: Icons.history_rounded,
          title: 'The change log needs the server update',
          message: 'Once the server has it, every category change, change to several products and product edit is listed here.',
        ),
      );
    }
    if (_error != null && _entries.isEmpty) {
      return Center(
        child: FlatEmpty(icon: Icons.cloud_off_rounded, title: 'Could not load the change log', message: _error!, action: AppButton.ink('Try again', reload)),
      );
    }
    final shown = _entries.where(_matches).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CatalogPaneHeader(
          child: Row(
            children: [
              SizedBox(
                width: 560,
                child: AppSegmented<String>(value: _filter, options: _filters, onChanged: (v) => setState(() => _filter = v), dense: true),
              ),
              const Spacer(),
              Text(
                _entries.isEmpty ? '' : '${catalogPlural(shown.length, 'change')}${_more ? ' (newest first)' : ''}',
                style: CatalogUi.meta.copyWith(fontSize: 13.5, fontFeatures: CatalogUi.figures),
              ),
            ],
          ),
        ),
        CatalogTableHeader(
          cols: const [
            CatalogCol('WHEN', width: 170),
            CatalogCol('WHO', width: 150),
            CatalogCol('WHAT', width: 157),
            CatalogCol('CHANGE'),
          ],
          sortKey: '',
          ascending: false,
          onSort: (_) {},
        ),
        if (_error != null) FlatStaleNotice(message: '$_error The list below may be out of date.', busy: false, onRetry: reload),
        Expanded(
          child: shown.isEmpty
              ? Center(
                  child: FlatEmpty(
                    icon: Icons.history_rounded,
                    title: _entries.isEmpty ? 'No changes yet' : 'Nothing of this kind yet',
                    message: _entries.isEmpty
                        ? 'Category changes, changes to several products and product edits are listed here as they happen.'
                        : 'Pick Everything to see every change.',
                  ),
                )
              : ListView.builder(
                  itemCount: shown.length + (_more ? 1 : 0),
                  itemBuilder: (_, i) {
                    if (i == shown.length) {
                      return Padding(
                        padding: const EdgeInsets.all(12),
                        child: Center(
                          child: CatalogOutlineButton(
                            label: _loadingMore ? 'Loading…' : 'Load older changes',
                            icon: Icons.expand_more_rounded,
                            onPressed: _loadingMore ? null : _loadMore,
                          ),
                        ),
                      );
                    }
                    return _row(shown[i], i);
                  },
                ),
        ),
      ],
    );
  }
}
