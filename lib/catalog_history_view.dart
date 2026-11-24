import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'catalog_cleanup_view.dart' show catalogActionLabel;
import 'catalog_manage.dart';
import 'services/line_items_api.dart';
import 'widgets/app_dialog.dart';
import 'widgets/catalog_kit.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';
import 'widgets/page_selection.dart';
import 'theme/app_theme.dart';

/// The Product Catalog's History view (Phase 3): the catalog's change log, newest first. Who changed what and when:
/// categories created, renamed, described, merged or deleted; changes to several products at once; one product added,
/// edited or deleted; findings marked reviewed or to follow up. A row opens to show what changed (before and after).
/// Cost values are blank for anyone without the Line Items & Costs > View switch (the server leaves them out).
///
/// Filters (2026-11-18): the kind of change, who made it, when (a preset or a date range) and one product. They are
/// applied by the server, so "Load older" keeps to them, and checked again here (an older server ignores them).
class CatalogHistoryView extends StatefulWidget {
  final CatalogManager manager;

  /// Product names by id, for the lines that list products.
  final Map<int, String> names;
  final void Function(int productId) onOpenProduct;

  /// The day "today" starts on (tests pass a fixed one).
  final DateTime Function() now;
  const CatalogHistoryView({super.key, required this.manager, required this.names, required this.onOpenProduct, this.now = DateTime.now});

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

  static final _short = DateFormat('MMM d');
  static const _ranges = [('any', 'Any time'), ('today', 'Today'), ('7', 'Last 7 days'), ('30', 'Last 30 days'), ('month', 'This month')];

  List<CatalogAuditEntry> _entries = const [];
  bool _more = false;
  bool _loading = true;
  bool _loadingMore = false;
  bool _needsServer = false;
  String? _error;
  String _filter = 'all';
  final Set<int> _open = {};

  // The other filters: who, when (a preset key, or 'custom' with its dates), one product.
  String? _by;
  String _range = 'any';
  DateTimeRange? _custom;
  int? _productId;
  List<({String name, int changes})>? _people;

  /// Bumped by every reload, so an answer to an older filter never replaces a newer one.
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    reload();
    widget.manager
        .auditPeople()
        .then((p) {
          if (mounted) setState(() => _people = p);
        })
        .catchError((Object _) {});
  }

  /// The time range picked, as [from, to).
  (DateTime?, DateTime?) get _span {
    final now = widget.now();
    final today = DateTime(now.year, now.month, now.day);
    return switch (_range) {
      'today' => (today, null),
      '7' => (today.subtract(const Duration(days: 6)), null),
      '30' => (today.subtract(const Duration(days: 29)), null),
      'month' => (DateTime(now.year, now.month), null),
      'custom' when _custom != null => (
        DateTime(_custom!.start.year, _custom!.start.month, _custom!.start.day),
        DateTime(_custom!.end.year, _custom!.end.month, _custom!.end.day).add(const Duration(days: 1)),
      ),
      _ => (null, null),
    };
  }

  CatalogAuditFilter get _query {
    final (from, to) = _span;
    return CatalogAuditFilter(by: _by, from: from, to: to, productId: _productId, actions: _filter == 'all' ? const [] : [_filter]);
  }

  bool get _filtered => !_query.isEmpty;

  /// Loads the newest entries again (the page's Refresh, after a change elsewhere on the page, and on a new filter).
  Future<void> reload() async {
    final gen = ++_gen;
    setState(() {
      _loading = _entries.isEmpty;
      _error = null;
    });
    try {
      final r = await widget.manager.listAudit(limit: 100, filter: _query);
      if (!mounted || gen != _gen) return;
      setState(() {
        _entries = r.entries;
        _more = r.more;
        _loading = false;
        _needsServer = false;
      });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _loading = false;
        _needsServer = catalogNeedsServerUpdate(e);
        _error = catalogErrorText(e);
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _entries.isEmpty) return;
    final gen = _gen;
    setState(() => _loadingMore = true);
    try {
      final r = await widget.manager.listAudit(limit: 100, before: _entries.last.id, filter: _query);
      if (!mounted || gen != _gen) return;
      setState(() {
        _entries = [..._entries, ...r.entries];
        _more = r.more;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _loadingMore = false;
        _error = catalogErrorText(e);
      });
    }
  }

  bool _matches(CatalogAuditEntry e) => _query.matches(e);

  void _set(VoidCallback change) {
    setState(change);
    _open.clear();
    reload();
  }

  void _clearFilters() => _set(() {
    _filter = 'all';
    _by = null;
    _range = 'any';
    _custom = null;
    _productId = null;
  });

  Future<void> _pickRange(String v) async {
    if (v != 'custom') return _set(() => _range = v);
    final now = widget.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2026),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _custom,
      helpText: 'Changes between',
      saveText: 'Show',
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: Theme.of(context).colorScheme.copyWith(primary: DashUi.ink, onPrimary: Colors.white),
        ),
        child: child!,
      ),
    );
    if (picked == null) return;
    _set(() {
      _range = 'custom';
      _custom = picked;
    });
  }

  Future<void> _pickProduct() async {
    final id = await showDialog<int>(
      context: context,
      builder: (_) => _ProductPicker(names: widget.names),
    );
    if (id != null) _set(() => _productId = id);
  }

  String get _rangeLabel {
    if (_range == 'custom' && _custom != null) {
      final a = _custom!.start;
      final b = _custom!.end;
      return a == b ? _short.format(a) : '${_short.format(a)} – ${_short.format(b)}';
    }
    return _ranges.firstWhere((r) => r.$1 == _range, orElse: () => _ranges.first).$2;
  }

  /// Everyone who appears in the log (from the server; else from the entries loaded).
  List<String> get _peopleNames {
    final names =
        _people?.map((p) => p.name).toList() ??
        {
          for (final e in _entries)
            if (e.by.isNotEmpty) e.by,
        }.toList();
    if (_by != null && !names.contains(_by)) names.insert(0, _by!);
    return names;
  }

  Widget _filterBar(double width) {
    final compact = width < 1240;
    final kinds = AppSegmented<String>(value: _filter, options: compact ? _shortFilters : _filters, onChanged: (v) => _set(() => _filter = v), dense: true);
    final others = _otherFilters();
    if (width < 1000) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            kinds,
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: others),
          ],
        ),
      );
    }
    return Row(
      children: [
        SizedBox(width: compact ? 430 : 520, child: kinds),
        const SizedBox(width: 10),
        for (var i = 0; i < others.length; i++) ...[if (i > 0) const SizedBox(width: 6), Flexible(child: others[i])],
      ],
    );
  }

  /// Who, When, Product and Clear.
  List<Widget> _otherFilters() {
    return [
      _FilterMenu<String>(
        key: const ValueKey('history-who'),
        icon: Icons.person_outline_rounded,
        label: _by ?? 'Anyone',
        active: _by != null,
        items: [('', 'Anyone'), for (final n in _peopleNames) (n, n)],
        onSelected: (v) => _set(() => _by = v.isEmpty ? null : v),
      ),
      _FilterMenu<String>(
        key: const ValueKey('history-when'),
        icon: Icons.calendar_today_outlined,
        label: _rangeLabel,
        active: _range != 'any',
        items: [..._ranges, ('custom', 'Pick dates…')],
        onSelected: _pickRange,
      ),
      _FilterButton(
        key: const ValueKey('history-product'),
        icon: Icons.inventory_2_outlined,
        label: _productId == null ? 'Any product' : (widget.names[_productId] ?? 'Product $_productId'),
        active: _productId != null,
        onPressed: _pickProduct,
        onClear: _productId == null ? null : () => _set(() => _productId = null),
      ),
      if (_filtered)
        TextButton(
          key: const ValueKey('history-clear'),
          onPressed: _clearFilters,
          style: TextButton.styleFrom(
            foregroundColor: DashUi.slate,
            textStyle: const TextStyle(fontFamily: AppTheme.fontFamily, fontFamilyFallback: AppTheme.fontFamilyFallback, fontSize: 13, fontWeight: FontWeight.w700),
          ),
          child: const Text('Clear'),
        ),
    ];
  }

  static const _shortFilters = [('all', 'All'), ('category', 'Categories'), ('products.bulk', 'Several'), ('product', 'One product'), ('review', 'Reviews')];

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
    if (v is List) {
      return v.isEmpty
          ? 'None'
          : v.map((x) => x is Map ? '${x['name']}${x['price'] != null ? ' ${dashMoney((x['price'] as num).toDouble())}' : ''}' : '$x').join(', ');
    }
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
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 13.5, color: DashUi.ink, height: 1.35)),
          ),
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
                    style: TextButton.styleFrom(
                      foregroundColor: DashUi.ink,
                      textStyle: const TextStyle(fontFamily: AppTheme.fontFamily, fontFamilyFallback: AppTheme.fontFamilyFallback, fontSize: 12.5, fontWeight: FontWeight.w700),
                    ),
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
    if (d['newCategory'] is String) out.add(line('New category', '${d['newCategory']} (created from the product page)'));
    final prev = d['previous'];
    if (prev is Map) {
      final was = prev['status'] == 'follow_up' ? 'Follow up' : 'Reviewed';
      final note = (prev['note'] ?? '').toString();
      out.add(line('Mark before', '$was${prev['by'] != null ? ' by ${prev['by']}' : ''}${note.isEmpty ? '' : ': "$note"'}'));
    }
    if (d['pricing'] == true) out.add(line('Check', 'A pricing check (which one, and the note, need the cost switch)'));
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
            mouseCursor: WidgetStateMouseCursor.clickable,
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
                    child: Text(
                      catalogActionLabel(e.action),
                      style: CatalogUi.meta.copyWith(fontWeight: FontWeight.w700, color: DashUi.slate),
                    ),
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
      return const Center(
        child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.2, color: DashUi.slate)),
      );
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
          child: LayoutBuilder(
            builder: (context, box) => Row(
              children: [
                Expanded(child: _filterBar(box.maxWidth)),
                if (box.maxWidth >= 1180)
                  Text(
                    _entries.isEmpty ? '' : '${catalogPlural(shown.length, 'change')}${_more ? ' (newest first)' : ''}',
                    style: CatalogUi.meta.copyWith(fontSize: 13.5, fontFeatures: CatalogUi.figures),
                  ),
              ],
            ),
          ),
        ),
        CatalogTableHeader(
          cols: const [CatalogCol('WHEN', width: 170), CatalogCol('WHO', width: 150), CatalogCol('WHAT', width: 157), CatalogCol('CHANGE')],
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
                    title: _filtered ? 'No changes match these filters' : 'No changes yet',
                    message: _filtered
                        ? 'Try a longer time, another person or kind of change.'
                        : 'Category changes, changes to several products and product edits are listed here as they happen.',
                    action: _filtered ? AppButton.ink('Clear filters', _clearFilters) : null,
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

/// A compact filter that opens a menu ("Anyone", "Last 7 days"). [active] when it narrows the list.
class _FilterMenu<T> extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final List<(T, String)> items;
  final ValueChanged<T> onSelected;
  const _FilterMenu({super.key, required this.icon, required this.label, required this.active, required this.items, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      tooltip: '',
      onSelected: onSelected,
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 200, maxHeight: 420),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: DashUi.line),
      ),
      itemBuilder: (_) => [
        for (final (v, text) in items)
          PopupMenuItem<T>(
            value: v,
            height: 36,
            child: Text(text, style: const TextStyle(fontSize: 13.5, color: DashUi.ink)),
          ),
      ],
      child: ClickCursor(child: _FilterFace(
        icon: icon,
        label: label,
        active: active,
        trailing: const Icon(Icons.expand_more_rounded, size: 17, color: DashUi.slate),
      )),
    );
  }
}

/// A compact filter that opens a picker, with an x to clear it when set.
class _FilterButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onPressed;
  final VoidCallback? onClear;
  const _FilterButton({super.key, required this.icon, required this.label, required this.active, required this.onPressed, this.onClear});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      mouseCursor: WidgetStateMouseCursor.clickable,
      onTap: onPressed,
      borderRadius: BorderRadius.circular(9),
      child: _FilterFace(
        icon: icon,
        label: label,
        active: active,
        trailing: onClear == null
            ? const Icon(Icons.expand_more_rounded, size: 17, color: DashUi.slate)
            : InkWell(
              mouseCursor: WidgetStateMouseCursor.clickable,
                key: const ValueKey('history-product-clear'),
                onTap: onClear,
                borderRadius: BorderRadius.circular(6),
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(Icons.close_rounded, size: 15, color: DashUi.slate),
                ),
              ),
      ),
    );
  }
}

class _FilterFace extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final Widget trailing;
  const _FilterFace({required this.icon, required this.label, required this.active, required this.trailing});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.fromLTRB(9, 0, 6, 0),
      decoration: BoxDecoration(
        color: active ? CatalogUi.picked : Colors.white,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: active ? DashUi.ink.withValues(alpha: 0.35) : DashUi.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: active ? DashUi.ink : DashUi.slate),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, fontWeight: active ? FontWeight.w700 : FontWeight.w600, color: active ? DashUi.ink : DashUi.slate),
            ),
          ),
          const SizedBox(width: 4),
          trailing,
        ],
      ),
    );
  }
}

/// Picks one product to filter the log to, searched by name or product number.
class _ProductPicker extends StatefulWidget {
  final Map<int, String> names;
  const _ProductPicker({required this.names});

  @override
  State<_ProductPicker> createState() => _ProductPickerState();
}

class _ProductPickerState extends State<_ProductPicker> {
  final _search = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final words = _q.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final all = widget.names.entries.toList()..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
    final rows = words.isEmpty
        ? all.take(60).toList()
        : all.where((e) => words.every((w) => e.value.toLowerCase().contains(w) || '${e.key}' == w)).take(60).toList();
    return AppDialog(
      title: 'Changes to one product',
      icon: Icons.inventory_2_outlined,
      width: 560,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CatalogSearchField(
            controller: _search,
            hint: 'Find a product by name or number',
            height: 38,
            autofocus: true,
            onChanged: (v) => setState(() => _q = v),
            onClear: () {
              _search.clear();
              setState(() => _q = '');
            },
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 340,
            child: rows.isEmpty
                ? const Center(child: Text('No product matches', style: CatalogUi.meta))
                : ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      for (final r in rows)
                        InkWell(
                          mouseCursor: WidgetStateMouseCursor.clickable,
                          key: ValueKey('history-pick:${r.key}'),
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => Navigator.pop(context, r.key),
                          child: Container(
                            height: 38,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            alignment: Alignment.centerLeft,
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text.rich(
                                    catalogNameSpan(r.value, const TextStyle(fontSize: 14, color: DashUi.ink)),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  'No. ${r.key}',
                                  style: const TextStyle(fontSize: 12.5, color: DashUi.subtle, fontFeatures: CatalogUi.figures),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
      actions: [AppButton.ghost('Cancel', () => Navigator.pop(context))],
    );
  }
}
