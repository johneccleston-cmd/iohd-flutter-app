import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../services/line_items_api.dart';
import '../utils/line_item_math.dart';
import 'catalog_search_field.dart';
import 'dashboard_kit.dart';

// The line-item table on the job and estimate pages. It takes the height its lines need: the page around it scrolls.
//
// Read-only (Service Fusion's items, an accepted option, someone who can't edit): plain rows and the figures.
// Editable: rows stay compact until clicked; the clicked row opens its fields in place (Tab moves across them, Esc
// closes it). New lines come from the catalog search under the last line (so the next one goes in where the eye already
// is), or as a custom line or a discount. Lines can be dragged by their handle, or moved with Alt+Up / Alt+Down.
// Everything is a draft until Save (Ctrl+S), and the totals underneath follow every keystroke. Costs, extended costs,
// profit and margin only show when [showCost] is on, on a tinted band and panel of their own so they never read as prices.

/// One figure in the summary under Service Fusion's own items, shown as Service Fusion has it. [internal] figures (its
/// cost) go in the admins-only panel, apart from what the customer is charged.
class LineSummaryRow {
  final String label;
  final int cents;
  final bool strong;
  final bool internal;
  const LineSummaryRow(this.label, this.cents, {this.strong = false, this.internal = false});
}

/// Lets the page drive an editor's Save and Discard from outside it (the page's floating save bar), and hear when its
/// draft, saving state or error change. With a controller the editor shows no Save buttons or error of its own.
class LineItemsController extends ChangeNotifier {
  _LineItemsEditorState? _state;

  bool get dirty => _state?._dirty ?? false;
  bool get saving => _state?._saving ?? false;
  String? get error => _state?._error;

  Future<void> save() async => _state?._save();
  void discard() => _state?._discard();

  void _ping() {
    // A change made while the page is building is passed on after the frame.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => notifyListeners());
    } else {
      notifyListeners();
    }
  }
}

class LineItemsEditor extends StatefulWidget {
  /// The saved lines (for read-only views, the lines to show).
  final List<LineDraft> lines;
  final double? taxRate;
  final bool editable;
  final bool showCost;

  /// Saves the lines and tax rate; returns an error to show, or null when it worked.
  final Future<String?> Function(List<LineDraft> lines, double? taxRate)? onSave;
  final ValueChanged<bool>? onDirtyChanged;

  /// A strip above the table: where the lines come from, a lock, an action.
  final Widget? banner;

  /// Read-only figures to show instead of computed totals (Service Fusion's own subtotal, charges and total).
  final List<LineSummaryRow>? summary;

  /// Read-only only: each line's amount as its source has it (Service Fusion's own line totals, in cents), so the
  /// table adds up to [summary] even where a line's total isn't exactly quantity x rate.
  final List<int>? fixedAmounts;
  final String emptyTitle;
  final String emptyMessage;

  /// Swappable for tests; the real search is [LineItemsApi.searchCatalog].
  final Future<List<CatalogEntry>> Function(String q)? search;

  /// The page's handle on Save and Discard (see [LineItemsController]).
  final LineItemsController? controller;

  /// Under the totals: anything that belongs with this set of lines (an estimate option's notes for the customer).
  final Widget? footer;

  const LineItemsEditor({
    super.key,
    required this.lines,
    required this.taxRate,
    required this.editable,
    required this.showCost,
    this.onSave,
    this.onDirtyChanged,
    this.banner,
    this.summary,
    this.fixedAmounts,
    this.emptyTitle = 'No line items yet',
    this.emptyMessage = 'Search the catalog below to add the first one.',
    this.search,
    this.controller,
    this.footer,
  });

  @override
  State<LineItemsEditor> createState() => _LineItemsEditorState();
}

class _Row {
  final int uid;
  LineDraft line;
  _Row(this.uid, this.line);
}

/// Which columns fit, and how wide they are.
class _Cols {
  final bool cost;
  final bool skuColumn; // its own column, or under the name when there isn't room
  final bool unitColumn;
  final bool handle;

  /// Too narrow for columns (a small window): each line stacks its figures under its name.
  final bool stacked;
  const _Cols({required this.cost, required this.skuColumn, required this.unitColumn, required this.handle, this.stacked = false});

  static const handleW = 26.0, skuW = 104.0, qtyW = 66.0, unitW = 54.0, rateW = 100.0, amountW = 108.0, costW = 92.0, extW = 100.0;
  static const taxW = 40.0, menuW = 36.0;

  static _Cols of(double width, {required bool cost, required bool editable}) {
    var fixed = qtyW + rateW + amountW + taxW + (editable ? handleW + menuW : 0) + (cost ? costW + extW : 0);
    if (width - fixed < 260) return _Cols(cost: cost, skuColumn: false, unitColumn: false, handle: editable, stacked: true);
    final unit = width - fixed - unitW >= 300;
    if (unit) fixed += unitW;
    final sku = width - fixed - skuW >= 300;
    return _Cols(cost: cost, skuColumn: sku, unitColumn: unit, handle: editable);
  }
}

const _figures = [FontFeature.tabularFigures()];
const _head = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.slate, letterSpacing: 0.6);
const _headInternal = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.subtle, letterSpacing: 0.6);
const _cell = TextStyle(fontSize: 13.5, color: DashUi.ink, height: 1.3, fontFeatures: _figures);
const _cellMuted = TextStyle(fontSize: 13.5, color: DashUi.subtle, height: 1.3, fontFeatures: _figures);

/// The band behind the cost columns, and the internal figures' panel: costs are ours, never the customer's.
const _costBand = Color(0xFFF5F7FA);

class _LineItemsEditorState extends State<LineItemsEditor> {
  late List<_Row> _rows;
  late double? _tax;
  late final TextEditingController _taxText;
  int _nextUid = 0;
  int? _active; // the row with its fields open
  String _focusField = 'name';
  int? _flash; // a row just added, lit for a moment
  Timer? _flashTimer;
  final Map<int, Set<String>> _invalid = {};
  bool _saving = false;
  bool _savePending = false;
  String? _error;
  bool _wasDirty = false;
  final _searchFocus = FocusNode(debugLabel: 'catalog search');
  final _flashKey = GlobalKey(debugLabel: 'new line');

  @override
  void initState() {
    super.initState();
    _taxText = TextEditingController();
    widget.controller?._state = this;
    _reset();
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    widget.controller?._ping();
  }

  void _reset() {
    _rows = [for (final l in widget.lines) _Row(_nextUid++, l)];
    _tax = widget.taxRate;
    _taxText.text = _tax == null ? '' : _trimRate(_tax!);
    _active = null;
    _invalid.clear();
    _error = null;
  }

  static String _trimRate(double r) => r.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '');

  @override
  void didUpdateWidget(LineItemsEditor old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      if (old.controller?._state == this) old.controller!._state = null;
      widget.controller?._state = this;
    }
    if (!identical(old.lines, widget.lines) || old.taxRate != widget.taxRate || old.editable != widget.editable) {
      // New saved lines arrived (our save, a refresh, someone else's change). Keep an unsaved draft unless it was ours
      // that just landed.
      if (!_dirty || _savePending || !widget.editable) {
        _savePending = false;
        _reset();
        // This runs while the page is building, so the page hears about it after the frame.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _notifyDirty();
          widget.controller?._ping();
        });
      }
    }
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) widget.controller!._state = null;
    _flashTimer?.cancel();
    _taxText.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // ---- draft state ------------------------------------------------------------------------------------------------

  List<LineDraft> get _lines => [for (final r in _rows) r.line];

  bool get _dirty {
    if (!widget.editable) return false;
    if (_invalid.values.any((s) => s.isNotEmpty)) return true;
    if ((_tax == null) != (widget.taxRate == null) || (_tax != null && (_tax! * 10000).round() != (widget.taxRate! * 10000).round())) return true;
    if (_rows.length != widget.lines.length) return true;
    for (var i = 0; i < _rows.length; i++) {
      if (!_rows[i].line.sameAs(widget.lines[i])) return true;
    }
    return false;
  }

  void _notifyDirty() {
    final d = _dirty;
    if (d != _wasDirty) {
      _wasDirty = d;
      widget.onDirtyChanged?.call(d);
    }
  }

  void _changed(VoidCallback fn) {
    setState(() {
      fn();
      _error = null;
    });
    _notifyDirty();
  }

  void _add(LineDraft line) {
    final row = _Row(_nextUid++, line);
    _changed(() {
      _rows.add(row);
      _flash = row.uid;
    });
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted && _flash == row.uid) setState(() => _flash = null);
    });
    // The new line, and the search under it, stay in view clear of the page's save bar: the page scrolls just enough.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _flashKey.currentContext;
      final row = ctx?.findRenderObject();
      if (ctx == null || row is! RenderBox || !mounted) return;
      // The page's scroll, past the list's own (which never scrolls).
      var page = Scrollable.maybeOf(ctx);
      while (page != null && page.widget.physics is NeverScrollableScrollPhysics) {
        page = Scrollable.maybeOf(page.context);
      }
      final box = page?.context.findRenderObject();
      if (page == null || box is! RenderBox) return;
      const room = 150.0; // the search row, and the save bar floating over the bottom
      final rowBottom = row.localToGlobal(Offset(0, row.size.height)).dy;
      final viewBottom = box.localToGlobal(Offset(0, box.size.height)).dy;
      final by = rowBottom - (viewBottom - room);
      if (by <= 0) return;
      final pos = page.position;
      final to = (pos.pixels + by).clamp(pos.minScrollExtent, pos.maxScrollExtent);
      if (MediaQuery.disableAnimationsOf(context)) {
        pos.jumpTo(to);
      } else {
        pos.animateTo(to, duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
      }
    });
  }

  void _pick(CatalogChoice c) {
    if (c.entry != null) {
      _add(c.entry!.toLine());
    } else if (c.custom != null) {
      final row = _Row(_nextUid++, LineDraft(name: c.custom!, quantity: 1, source: 'manual'));
      _changed(() => _rows.add(row));
      _open(row.uid, 'rate');
    }
  }

  void _addDiscount() {
    final row = _Row(_nextUid++, const LineDraft(kind: LineKind.discount, name: 'Discount', quantity: 1, source: 'manual'));
    _changed(() => _rows.add(row));
    _open(row.uid, 'rate');
  }

  void _open(int uid, String field) {
    setState(() {
      _active = uid;
      _focusField = field;
    });
  }

  void _close(int uid) {
    if (_active == uid) setState(() => _active = null);
  }

  void _move(int from, int to) {
    if (to < 0 || to >= _rows.length || from == to) return;
    _changed(() {
      final r = _rows.removeAt(from);
      _rows.insert(to, r);
    });
  }

  void _remove(int index) {
    final removed = _rows[index];
    _changed(() {
      _rows.removeAt(index);
      _invalid.remove(removed.uid);
      if (_active == removed.uid) _active = null;
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Removed "${removed.line.name}". It is gone once you save.'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              if (!mounted) return;
              _changed(() => _rows.insert(index.clamp(0, _rows.length), removed));
            },
          ),
        ),
      );
  }

  void _duplicate(int index) {
    final copy = _Row(_nextUid++, _rows[index].line.copyWith(id: null));
    _changed(() => _rows.insert(index + 1, copy));
  }

  void _setInvalid(int uid, String field, bool bad) {
    final set = _invalid.putIfAbsent(uid, () => <String>{});
    final changed = bad ? set.add(field) : set.remove(field);
    if (changed) {
      setState(() {});
      _notifyDirty();
    }
  }

  void _discard() {
    setState(_reset);
    _notifyDirty();
  }

  String? _problem() {
    for (var i = 0; i < _rows.length; i++) {
      final r = _rows[i];
      final bad = _invalid[r.uid] ?? const <String>{};
      if (bad.isNotEmpty) return 'Line ${i + 1}: ${bad.map(_fieldName).join(', ')} ${bad.length == 1 ? "isn't" : "aren't"} a valid number.';
      if (r.line.name.trim().isEmpty) return 'Line ${i + 1} needs a name.';
      if (r.line.isDiscount && (r.line.rate == null || r.line.rate! <= 0)) return 'Discount "${r.line.name}" needs an amount above \$0.';
    }
    if (_taxText.text.trim().isNotEmpty && (_tax == null || _tax! < 0 || _tax! > 30)) return 'Tax rate must be between 0% and 30%.';
    return null;
  }

  static String _fieldName(String f) => switch (f) {
    'qty' => 'quantity',
    'rate' => 'rate',
    'cost' => 'cost',
    _ => f,
  };

  Future<void> _save() async {
    if (_saving || !_dirty || widget.onSave == null) return;
    final problem = _problem();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _active = null;
      _savePending = true;
    });
    final err = await widget.onSave!(_lines, _tax);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (err != null) {
        _savePending = false;
        _error = err;
      }
    });
  }

  // ---- build ------------------------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final totals = computeLineTotals(_lines, _tax);
    final editable = widget.editable;
    return Shortcuts(
      shortcuts: const {SingleActivator(LogicalKeyboardKey.keyS, control: true): _SaveIntent()},
      child: Actions(
        actions: {_SaveIntent: CallbackAction<_SaveIntent>(onInvoke: (_) => _save())},
        child: Focus(
          autofocus: false,
          child: LayoutBuilder(
            builder: (context, c) {
              final cols = _Cols.of(c.maxWidth - 32, cost: widget.showCost, editable: editable);
              final narrow = c.maxWidth < 720;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  ?widget.banner,
                  // With a controller the page's save bar says what went wrong, next to its Save button.
                  if (_error != null && widget.controller == null)
                    Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 10), child: _InlineNotice(_error!, error: true)),
                  _table(cols, totals),
                  if (editable) _addRow(narrow: c.maxWidth < 700),
                  if (widget.summary != null) _SummaryBar(rows: widget.summary!, narrow: narrow) else _totalsBlock(totals, narrow: narrow),
                  ?widget.footer,
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// The column headings and the lines. Costs run down a tinted band of their own.
  Widget _table(_Cols cols, LineTotals totals) {
    final table = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!cols.stacked) _header(cols) else const Divider(height: 1, color: DashUi.line),
        if (_rows.isEmpty) _empty() else _list(cols, totals),
      ],
    );
    if (!cols.cost || cols.stacked || _rows.isEmpty) return table;
    return Stack(
      children: [
        Positioned(
          top: 0,
          bottom: 0,
          right: 16 + _Cols.taxW + (cols.handle ? _Cols.menuW : 0),
          width: _Cols.costW + _Cols.extW,
          child: const DecoratedBox(
            decoration: BoxDecoration(
              color: _costBand,
              borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
            ),
          ),
        ),
        table,
      ],
    );
  }

  /// Unsaved-changes mark, Discard and Save, for an editor the page doesn't drive (no [LineItemsEditor.controller]).
  List<Widget> _ownSaveButtons() => [
    const SizedBox(width: 12),
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: const Text(
        'Unsaved changes',
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.amberText),
      ),
    ),
    const SizedBox(width: 6),
    TextButton(onPressed: _saving ? null : _discard, child: const Text('Discard')),
    Tooltip(
      message: 'Save (Ctrl+S)',
      child: FilledButton.icon(
        onPressed: _saving ? null : _save,
        icon: _saving
            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.check_rounded, size: 18),
        label: Text(_saving ? 'Saving' : 'Save'),
      ),
    ),
  ];

  /// Under the last line: the catalog search (it keeps focus, so lines go in one after another) and Discount.
  Widget _addRow({bool narrow = false}) {
    final search = CatalogSearchField(onPick: _pick, showCost: widget.showCost, search: widget.search, focusNode: _searchFocus);
    final discount = Tooltip(
      message: 'Add a discount line (taken off the total)',
      child: OutlinedButton.icon(
        onPressed: _addDiscount,
        icon: const Icon(Icons.percent_rounded, size: 16),
        label: const Text('Discount'),
        style: _quietButton,
      ),
    );
    final saves = widget.controller == null && _dirty ? _ownSaveButtons() : const <Widget>[];
    if (narrow) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            search,
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [discount, ...saves]),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: search),
            ),
          ),
          const SizedBox(width: 8),
          discount,
          ...saves,
        ],
      ),
    );
  }

  Widget _header(_Cols cols) {
    Widget h(String t, double w, {bool right = true, String? tip, bool internal = false}) => SizedBox(
      width: w,
      child: Tooltip(
        message: tip ?? '',
        child: Text(
          t,
          textAlign: right ? TextAlign.right : TextAlign.left,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.fade,
          style: internal ? _headInternal : _head,
        ),
      ),
    );
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: DashUi.line)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 9),
      child: Row(
        children: [
          if (cols.handle) const SizedBox(width: _Cols.handleW),
          const Expanded(child: Text('ITEM', style: _head)),
          if (cols.skuColumn) h('SKU', _Cols.skuW, right: false),
          h('QTY', _Cols.qtyW),
          if (cols.unitColumn)
            const SizedBox(
              width: _Cols.unitW,
              child: Padding(
                padding: EdgeInsets.only(left: 10),
                child: Text('UNIT', style: _head),
              ),
            ),
          h('RATE', _Cols.rateW, tip: 'Selling price per unit'),
          h('AMOUNT', _Cols.amountW, tip: 'Quantity x rate: what the customer pays for the line'),
          if (cols.cost) ...[
            h('COST', _Cols.costW, tip: 'Internal cost per unit. Never shown to customers.', internal: true),
            h('EXT. COST', _Cols.extW, tip: 'Quantity x cost', internal: true),
          ],
          h('TAX', _Cols.taxW, tip: 'Taxable line'),
          if (cols.handle) const SizedBox(width: _Cols.menuW),
        ],
      ),
    );
  }

  Widget _empty() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.receipt_long_outlined, size: 30, color: DashUi.muted),
        const SizedBox(height: 8),
        Text(
          widget.emptyTitle,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: DashUi.ink),
        ),
        const SizedBox(height: 4),
        Text(
          widget.emptyMessage,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: DashUi.slate),
        ),
      ],
    ),
  );

  /// The lines, laid out at their full height (the page scrolls, not the table).
  Widget _list(_Cols cols, LineTotals totals) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    Widget row(int i) {
      final r = _rows[i];
      final fixed = widget.fixedAmounts;
      final figures = !widget.editable && fixed != null && i < fixed.length ? LineFigures(fixed[i], totals.lines[i].extCostCents) : totals.lines[i];
      final active = widget.editable && _active == r.uid;
      final child = active
          ? _EditRow(
              key: ValueKey('edit-${r.uid}'),
              index: i,
              line: r.line,
              figures: figures,
              cols: cols,
              focusField: _focusField,
              invalid: _invalid[r.uid] ?? const {},
              onChanged: (l) => _changed(() => r.line = l),
              onInvalid: (f, bad) => _setInvalid(r.uid, f, bad),
              onDone: () => _close(r.uid),
              onMove: (d) => _move(i, i + d),
              onMenu: (a) => _menu(a, i),
            )
          : _ViewRow(
              key: ValueKey('view-${r.uid}'),
              index: i,
              line: r.line,
              figures: figures,
              cols: cols,
              editable: widget.editable,
              invalid: (_invalid[r.uid] ?? const {}).isNotEmpty,
              onOpen: widget.editable ? (f) => _open(r.uid, f) : null,
              onMenu: (a) => _menu(a, i),
            );
      return KeyedSubtree(
        key: ValueKey(r.uid),
        child: AnimatedContainer(
          key: _flash == r.uid ? _flashKey : null,
          duration: reduce ? Duration.zero : const Duration(milliseconds: 500),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            // Clear, so the cost band shows through; an open row and a just-added one are lit.
            color: _flash == r.uid ? const Color(0xFFEFF6FF) : (active ? DashUi.faint.withValues(alpha: 0.55) : DashUi.faint.withValues(alpha: 0)),
            border: const Border(bottom: BorderSide(color: DashUi.line)),
          ),
          child: child,
        ),
      );
    }

    if (!widget.editable) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (var i = 0; i < _rows.length; i++) row(i)]);
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: _rows.length,
      onReorderItem: _move,
      proxyDecorator: (child, _, anim) => Material(elevation: 6, shadowColor: Colors.black26, color: Colors.white, child: child),
      itemBuilder: (_, i) => row(i),
    );
  }

  void _menu(String action, int index) {
    switch (action) {
      case 'up':
        _move(index, index - 1);
      case 'down':
        _move(index, index + 1);
      case 'duplicate':
        _duplicate(index);
      case 'remove':
        _remove(index);
    }
  }

  /// What the customer is charged (a receipt: items, discounts, tax, the total), and beside it, for admins, what it
  /// costs us and what is left, on a panel marked internal.
  Widget _totalsBlock(LineTotals t, {bool narrow = false}) {
    final editable = widget.editable;
    final taxField = editable
        ? Padding(
            padding: const EdgeInsets.only(left: 8),
            child: SizedBox(
              width: 66,
              child: TextField(
                key: const ValueKey('tax-rate'),
                controller: _taxText,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: DashUi.ink, fontFeatures: _figures),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                decoration: _inlineDeco(hint: '0', suffix: '%', error: _taxText.text.trim().isNotEmpty && _tax == null),
                onChanged: (v) => _changed(() => _tax = v.trim().isEmpty ? null : double.tryParse(v.trim())),
              ),
            ),
          )
        : null;
    final notes = [
      if (t.unpricedLines > 0) '${t.unpricedLines} line${t.unpricedLines == 1 ? '' : 's'} not priced yet',
      if (widget.showCost && t.missingCostLines > 0) '${t.missingCostLines} line${t.missingCostLines == 1 ? '' : 's'} with no cost (profit is overstated)',
    ];
    final receipt = _Receipt(
      rows: [
        _ReceiptRow('Items', centsMoney(t.itemsCents)),
        if (t.discountCents > 0 || _rows.any((r) => r.line.isDiscount)) _ReceiptRow('Discounts', centsMoney(-t.discountCents), tone: DashUi.redText),
        _ReceiptRow(
          _tax == null || editable ? 'Tax' : 'Tax ${_trimRate(_tax!)}%',
          centsMoney(t.taxCents),
          extra: taxField,
          tip: 'Tax rate x taxable lines (less taxable discounts)',
        ),
        _ReceiptRow('Total', centsMoney(t.totalCents), strong: true),
      ],
    );
    final internal = widget.showCost ? _InternalPanel(cost: t.costCents, profit: t.profitCents, margin: t.marginPct, net: t.itemsCents - t.discountCents) : null;
    final note = notes.isEmpty
        ? null
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(Icons.info_outline_rounded, size: 15, color: DashUi.amberText),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  notes.join('  ·  '),
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: DashUi.amberText, height: 1.35),
                ),
              ),
            ],
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (note != null) ...[note, const SizedBox(height: 10)],
                receipt,
                if (internal != null) ...[const SizedBox(height: 14), internal],
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (note != null) ...[note, const SizedBox(height: 12)],
                      if (internal != null) ConstrainedBox(constraints: const BoxConstraints(maxWidth: 440), child: internal),
                    ],
                  ),
                ),
                const SizedBox(width: 32),
                SizedBox(width: 300, child: receipt),
              ],
            ),
    );
  }

  static final _quietButton = OutlinedButton.styleFrom(
    minimumSize: const Size(0, 38),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    foregroundColor: DashUi.ink,
    side: const BorderSide(color: DashUi.line),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
  );
}

class _SaveIntent extends Intent {
  const _SaveIntent();
}

InputDecoration _inlineDeco({String? hint, String? suffix, String? prefix, bool error = false}) {
  OutlineInputBorder b(Color c, [double w = 1]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(6),
    borderSide: BorderSide(color: c, width: w),
  );
  return InputDecoration(
    isDense: true,
    filled: true,
    fillColor: const Color(0xFFF8FAFC),
    hintText: hint,
    hintStyle: const TextStyle(fontSize: 12.5, color: DashUi.muted),
    suffixText: suffix,
    prefixText: prefix,
    prefixStyle: const TextStyle(fontSize: 12.5, color: DashUi.subtle),
    suffixStyle: const TextStyle(fontSize: 12, color: DashUi.slate),
    contentPadding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
    border: b(DashUi.line),
    enabledBorder: b(error ? DashUi.red : DashUi.line, error ? 1.4 : 1),
    focusedBorder: b(error ? DashUi.red : DashUi.ink, 1.4),
  );
}

/// A row with its fields closed: the line as text. Clicking a cell opens the row with that field focused.
class _ViewRow extends StatelessWidget {
  final int index;
  final LineDraft line;
  final LineFigures figures;
  final _Cols cols;
  final bool editable;
  final bool invalid;
  final void Function(String field)? onOpen;
  final ValueChanged<String> onMenu;
  const _ViewRow({
    super.key,
    required this.index,
    required this.line,
    required this.figures,
    required this.cols,
    required this.editable,
    required this.invalid,
    required this.onOpen,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    Widget tap(String field, Widget child) => onOpen == null
        ? child
        : MouseRegion(
            cursor: SystemMouseCursors.text,
            child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => onOpen!(field), child: child),
          );
    Widget num(String field, double w, String text, {TextStyle style = _cell}) => SizedBox(
      width: w,
      child: tap(field, Text(text, textAlign: TextAlign.right, style: style)),
    );
    final discount = line.isDiscount;
    final meta = [if (!cols.skuColumn && line.sku.isNotEmpty) 'SKU ${line.sku}', if (discount) 'Discount'].join('  ·  ');
    if (cols.stacked) {
      // A small window: the name and amount on top, quantity x rate (and cost) under the name.
      String money(double? v) => v == null ? '' : centsMoney((v * 100).round());
      final figuresLine = [
        if (discount) 'Discount' else '${qtyText(line.quantity)}${line.unit.isEmpty ? '' : ' ${line.unit}'} x ${line.rate == null ? 'not priced' : money(line.rate)}',
        if (line.sku.isNotEmpty) 'SKU ${line.sku}',
        if (cols.cost && !discount) 'cost ${line.cost == null ? '—' : money(line.cost)}${figures.extCostCents == null ? '' : ' (${centsMoney(figures.extCostCents!)})'}',
        if (line.taxable) 'taxable',
      ].join('  ·  ');
      return Semantics(
        label: 'Line ${index + 1}: ${line.name}',
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (cols.handle) _Handle(index: index),
              Expanded(
                child: tap(
                  'name',
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(line.name.isEmpty ? 'Unnamed line' : line.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink, height: 1.3)),
                      if (line.description.trim().isNotEmpty)
                        Text(line.description.trim(), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: DashUi.slate, height: 1.35)),
                      Text(figuresLine, style: TextStyle(fontSize: 12, color: line.rate == null && !discount ? DashUi.amberText : DashUi.subtle, fontFeatures: _figures)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              tap(
                'rate',
                Text(
                  centsMoney(figures.amountCents),
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: discount ? DashUi.redText : DashUi.ink, fontFeatures: _figures),
                ),
              ),
              if (cols.handle) _RowMenu(index: index, onMenu: onMenu),
            ],
          ),
        ),
      );
    }
    return Semantics(
      label: 'Line ${index + 1}: ${line.name}',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (cols.handle) _Handle(index: index),
            Expanded(
              child: tap(
                'name',
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (invalid)
                          const Padding(
                            padding: EdgeInsets.only(right: 6),
                            child: Icon(Icons.error_outline_rounded, size: 15, color: DashUi.red),
                          ),
                        Flexible(
                          child: Text(
                            line.name.isEmpty ? 'Unnamed line' : line.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: line.name.isEmpty ? DashUi.subtle : DashUi.ink, height: 1.3),
                          ),
                        ),
                      ],
                    ),
                    if (line.description.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          line.description.trim(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5, color: DashUi.slate, height: 1.35),
                        ),
                      ),
                    if (meta.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          meta,
                          style: TextStyle(
                            fontSize: 12,
                            color: discount ? DashUi.redText : DashUi.subtle,
                            fontWeight: discount ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (cols.skuColumn)
              SizedBox(
                width: _Cols.skuW,
                child: tap(
                  'sku',
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(line.sku.isEmpty ? '—' : line.sku, maxLines: 1, overflow: TextOverflow.ellipsis, style: line.sku.isEmpty ? _cellMuted : _cell),
                  ),
                ),
              ),
            num('qty', _Cols.qtyW, discount ? '' : qtyText(line.quantity)),
            if (cols.unitColumn)
              SizedBox(
                width: _Cols.unitW,
                child: tap(
                  'unit',
                  Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Text(discount ? '' : line.unit, style: _cellMuted),
                  ),
                ),
              ),
            num(
              'rate',
              _Cols.rateW,
              // "Not priced" is a to-do on lines edited here; a read-only line with no rate just has none.
              discount ? '' : (line.rate == null ? (editable ? 'Not priced' : '—') : centsMoney((line.rate! * 100).round())),
              style: line.rate == null && !discount && editable ? const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.amberText) : _cell,
            ),
            num(
              'rate',
              _Cols.amountW,
              centsMoney(figures.amountCents),
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: discount ? DashUi.redText : DashUi.ink, height: 1.3, fontFeatures: _figures),
            ),
            if (cols.cost) ...[
              num('cost', _Cols.costW, discount ? '' : (line.cost == null ? '—' : centsMoney((line.cost! * 100).round())), style: _cellMuted),
              num('cost', _Cols.extW, figures.extCostCents == null ? (discount ? '' : '—') : centsMoney(figures.extCostCents!), style: _cellMuted),
            ],
            SizedBox(
              width: _Cols.taxW,
              child: Align(
                alignment: Alignment.topRight,
                child: line.taxable
                    ? const Tooltip(
                        message: 'Taxable',
                        child: Icon(Icons.check_rounded, size: 17, color: DashUi.slate),
                      )
                    : const SizedBox(height: 17),
              ),
            ),
            if (cols.handle) _RowMenu(index: index, onMenu: onMenu),
          ],
        ),
      ),
    );
  }
}

class _Handle extends StatelessWidget {
  final int index;
  const _Handle({required this.index});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: _Cols.handleW,
    child: ReorderableDragStartListener(
      index: index,
      child: const MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Tooltip(
          message: 'Drag to reorder (or Alt+Up / Alt+Down)',
          waitDuration: Duration(milliseconds: 600),
          child: Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.drag_indicator_rounded, size: 18, color: DashUi.muted),
          ),
        ),
      ),
    ),
  );
}

class _RowMenu extends StatelessWidget {
  final int index;
  final ValueChanged<String> onMenu;
  const _RowMenu({required this.index, required this.onMenu});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: _Cols.menuW,
    child: Align(
      alignment: Alignment.topRight,
      child: PopupMenuButton<String>(
        tooltip: 'Line ${index + 1} actions',
        padding: EdgeInsets.zero,
        iconSize: 18,
        icon: const Icon(Icons.more_horiz_rounded, color: DashUi.slate),
        style: IconButton.styleFrom(minimumSize: const Size(28, 24), padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
        onSelected: onMenu,
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'up', height: 36, child: Text('Move up')),
          PopupMenuItem(value: 'down', height: 36, child: Text('Move down')),
          PopupMenuItem(value: 'duplicate', height: 36, child: Text('Duplicate line')),
          PopupMenuDivider(),
          PopupMenuItem(
            value: 'remove',
            height: 36,
            child: Text(
              'Remove line',
              style: TextStyle(color: DashUi.redText, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    ),
  );
}

/// A row with its fields open. Values apply to the draft as they are typed; a number that doesn't parse is marked and
/// blocks Save until it is fixed. Esc, or clicking outside the row, closes it.
class _EditRow extends StatefulWidget {
  final int index;
  final LineDraft line;
  final LineFigures figures;
  final _Cols cols;
  final String focusField;
  final Set<String> invalid;
  final ValueChanged<LineDraft> onChanged;
  final void Function(String field, bool bad) onInvalid;
  final VoidCallback onDone;
  final ValueChanged<int> onMove;
  final ValueChanged<String> onMenu;
  const _EditRow({
    super.key,
    required this.index,
    required this.line,
    required this.figures,
    required this.cols,
    required this.focusField,
    required this.invalid,
    required this.onChanged,
    required this.onInvalid,
    required this.onDone,
    required this.onMove,
    required this.onMenu,
  });

  @override
  State<_EditRow> createState() => _EditRowState();
}

class _EditRowState extends State<_EditRow> {
  late final Map<String, TextEditingController> _c;
  late final Map<String, FocusNode> _f;

  static String _money(double? v) => v == null ? '' : v.toStringAsFixed(2);

  @override
  void initState() {
    super.initState();
    final l = widget.line;
    _c = {
      'name': TextEditingController(text: l.name),
      'description': TextEditingController(text: l.description),
      'sku': TextEditingController(text: l.sku),
      'qty': TextEditingController(text: qtyText(l.quantity)),
      'unit': TextEditingController(text: l.unit),
      'rate': TextEditingController(text: _money(l.rate)),
      'cost': TextEditingController(text: _money(l.cost)),
    };
    _f = {for (final k in _c.keys) k: FocusNode(debugLabel: 'line ${widget.index + 1} $k')};
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final node = _f[widget.focusField] ?? _f['name']!;
      node.requestFocus();
      final c = _c[widget.focusField];
      if (c != null) c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);
    });
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    for (final f in _f.values) {
      f.dispose();
    }
    super.dispose();
  }

  void _text(String field, String v) {
    final l = widget.line;
    widget.onChanged(switch (field) {
      'name' => l.copyWith(name: v),
      'description' => l.copyWith(description: v),
      'sku' => l.copyWith(sku: v),
      _ => l.copyWith(unit: v),
    });
  }

  void _number(String field, String v) {
    final empty = v.trim().isEmpty;
    final l = widget.line;
    if (field == 'qty') {
      final q = parseQty(v);
      final ok = q != null && q >= 0 && q <= 9999.999;
      widget.onInvalid('qty', !ok);
      if (ok) widget.onChanged(l.copyWith(quantity: q));
      return;
    }
    final m = parseMoney(v);
    final ok = empty || (m != null && m.abs() <= 999999.99 && (field != 'cost' || m >= 0));
    widget.onInvalid(field, !ok);
    if (!ok) return;
    widget.onChanged(field == 'rate' ? l.copyWith(rate: empty ? null : m) : l.copyWith(cost: empty ? null : m));
  }

  KeyEventResult _keys(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      widget.onDone();
      return KeyEventResult.handled;
    }
    final alt = HardwareKeyboard.instance.isAltPressed;
    if (alt && e.logicalKey == LogicalKeyboardKey.arrowUp) {
      widget.onMove(-1);
      return KeyEventResult.handled;
    }
    if (alt && e.logicalKey == LogicalKeyboardKey.arrowDown) {
      widget.onMove(1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _field(String key, {String? hint, bool right = false, bool numeric = false, bool money = false, int maxLines = 1, TextStyle? style, String? label}) =>
      Semantics(
        label: label,
        child: TextField(
          key: ValueKey('line-${widget.index}-$key'),
          controller: _c[key],
          focusNode: _f[key],
          textAlign: right ? TextAlign.right : TextAlign.left,
          minLines: 1,
          maxLines: maxLines,
          style: style ?? const TextStyle(fontSize: 13.5, color: DashUi.ink, fontFeatures: _figures),
          keyboardType: numeric ? const TextInputType.numberWithOptions(decimal: true, signed: true) : TextInputType.text,
          inputFormatters: numeric ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,$\-]'))] : null,
          decoration: _inlineDeco(hint: hint, prefix: money ? r'$' : null, error: widget.invalid.contains(key)),
          onChanged: (v) => numeric ? _number(key, v) : _text(key, v),
          onSubmitted: (_) => widget.onDone(),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final cols = widget.cols;
    final l = widget.line;
    final discount = l.isDiscount;
    Widget box(double w, Widget child) => SizedBox(
      width: w,
      child: Padding(padding: const EdgeInsets.only(left: 6), child: child),
    );
    if (cols.stacked) {
      // A small window: the name and description across the row, the figures wrapping underneath.
      Widget labelled(String label, double w, Widget field) => SizedBox(
        width: w,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: DashUi.slate)),
            const SizedBox(height: 2),
            field,
          ],
        ),
      );
      return Focus(
        onKeyEvent: _keys,
        onFocusChange: (has) {
          if (!has) widget.onDone();
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (cols.handle) _Handle(index: widget.index),
                  Expanded(
                    child: _field(
                      'name',
                      hint: discount ? 'What the discount is for' : 'Item name',
                      label: 'Line ${widget.index + 1} name',
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink),
                    ),
                  ),
                  if (cols.handle) _RowMenu(index: widget.index, onMenu: widget.onMenu),
                ],
              ),
              if (!discount) ...[
                const SizedBox(height: 4),
                _field(
                  'description',
                  hint: 'Description or notes (optional)',
                  maxLines: 4,
                  label: 'Line ${widget.index + 1} description',
                  style: const TextStyle(fontSize: 12.5, color: DashUi.slate, height: 1.35),
                ),
              ],
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.end,
                children: [
                  if (discount)
                    labelled('Amount', 120, _field('rate', hint: 'Amount', right: true, numeric: true, money: true, label: 'Discount amount'))
                  else ...[
                    labelled('Qty', 70, _field('qty', hint: '1', right: true, numeric: true, label: 'Quantity')),
                    labelled('Unit', 60, _field('unit', hint: 'ea', label: 'Unit')),
                    labelled('Rate', 110, _field('rate', hint: 'Price', right: true, numeric: true, money: true, label: 'Rate')),
                    if (cols.cost) labelled('Cost', 100, _field('cost', hint: 'Cost', right: true, numeric: true, money: true, label: 'Unit cost')),
                    labelled('SKU', 120, _field('sku', hint: 'SKU', label: 'SKU')),
                  ],
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: l.taxable,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: (v) => widget.onChanged(l.copyWith(taxable: v == true)),
                      ),
                      Text(discount ? 'Off taxable items' : 'Taxable', style: const TextStyle(fontSize: 12.5, color: DashUi.slate)),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      centsMoney(widget.figures.amountCents),
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: discount ? DashUi.redText : DashUi.ink, fontFeatures: _figures),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    return Focus(
      onKeyEvent: _keys,
      onFocusChange: (has) {
        if (!has) widget.onDone();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (cols.handle)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _Handle(index: widget.index),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _field(
                    'name',
                    hint: discount ? 'What the discount is for' : 'Item name',
                    label: 'Line ${widget.index + 1} name',
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink),
                  ),
                  if (!discount) ...[
                    const SizedBox(height: 4),
                    // The SKU sits beside the description when it has no column of its own, so the row stays two lines.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _field(
                            'description',
                            hint: 'Description or notes (optional)',
                            maxLines: 4,
                            label: 'Line ${widget.index + 1} description',
                            style: const TextStyle(fontSize: 12.5, color: DashUi.slate, height: 1.35),
                          ),
                        ),
                        if (!cols.skuColumn) ...[
                          const SizedBox(width: 6),
                          SizedBox(
                            width: 120,
                            child: _field(
                              'sku',
                              hint: 'SKU',
                              label: 'Line ${widget.index + 1} SKU',
                              style: const TextStyle(fontSize: 12.5, color: DashUi.ink),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (cols.skuColumn) box(_Cols.skuW, discount ? const SizedBox() : _field('sku', hint: 'SKU', label: 'SKU')),
            box(_Cols.qtyW, discount ? const SizedBox() : _field('qty', hint: '1', right: true, numeric: true, label: 'Quantity')),
            if (cols.unitColumn) box(_Cols.unitW, discount ? const SizedBox() : _field('unit', hint: 'ea', label: 'Unit')),
            box(_Cols.rateW, discount ? const SizedBox() : _field('rate', hint: 'Price', right: true, numeric: true, money: true, label: 'Rate')),
            SizedBox(
              width: _Cols.amountW,
              child: discount
                  ? Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: _field('rate', hint: 'Amount', right: true, numeric: true, money: true, label: 'Discount amount'),
                    )
                  : Padding(
                      padding: const EdgeInsets.only(top: 7),
                      child: Text(
                        centsMoney(widget.figures.amountCents),
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: DashUi.ink, fontFeatures: _figures),
                      ),
                    ),
            ),
            if (cols.cost) ...[
              box(_Cols.costW, discount ? const SizedBox() : _field('cost', hint: 'Cost', right: true, numeric: true, money: true, label: 'Unit cost')),
              SizedBox(
                width: _Cols.extW,
                child: Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Text(
                    widget.figures.extCostCents == null ? '' : centsMoney(widget.figures.extCostCents!),
                    textAlign: TextAlign.right,
                    style: _cellMuted,
                  ),
                ),
              ),
            ],
            SizedBox(
              width: _Cols.taxW,
              child: Align(
                alignment: Alignment.topRight,
                child: Tooltip(
                  message: discount ? 'Comes off taxable items (lowers the tax)' : 'Taxable line',
                  child: Checkbox(
                    value: l.taxable,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (v) => widget.onChanged(l.copyWith(taxable: v == true)),
                  ),
                ),
              ),
            ),
            if (cols.handle)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: _RowMenu(index: widget.index, onMenu: widget.onMenu),
              ),
          ],
        ),
      ),
    );
  }
}

/// Service Fusion's own figures under its read-only items, laid out like our totals: what it charges as a receipt, its
/// cost on the internal panel.
class _SummaryBar extends StatelessWidget {
  final List<LineSummaryRow> rows;
  final bool narrow;
  const _SummaryBar({required this.rows, this.narrow = false});

  @override
  Widget build(BuildContext context) {
    final charged = rows.where((r) => !r.internal).toList();
    final internal = rows.where((r) => r.internal).toList();
    final receipt = _Receipt(
      rows: [
        for (final r in charged) _ReceiptRow(r.label, centsMoney(r.cents), strong: r.strong, tone: r.cents < 0 ? DashUi.redText : null, tip: r.label),
      ],
    );
    final panel = internal.isEmpty
        ? null
        : _InternalPanel(
            figures: [for (final r in internal) (r.label, centsMoney(r.cents), null)],
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [receipt, if (panel != null) ...[const SizedBox(height: 14), panel]],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: panel == null ? const SizedBox() : ConstrainedBox(constraints: const BoxConstraints(maxWidth: 440), child: panel),
                  ),
                ),
                const SizedBox(width: 32),
                SizedBox(width: 340, child: receipt),
              ],
            ),
    );
  }
}

class _ReceiptRow {
  final String label;
  final String value;
  final Color? tone;
  final bool strong;
  final String? tip;
  final Widget? extra;
  const _ReceiptRow(this.label, this.value, {this.tone, this.strong = false, this.tip, this.extra});
}

/// What the customer is charged, one figure a line, the total last and largest under a rule.
class _Receipt extends StatelessWidget {
  final List<_ReceiptRow> rows;
  const _Receipt({required this.rows});

  @override
  Widget build(BuildContext context) {
    Widget line(_ReceiptRow r) {
      final row = Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Flexible(
            child: Text(
              r.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: r.strong ? 14 : 13.5,
                fontWeight: r.strong ? FontWeight.w800 : FontWeight.w600,
                color: r.strong ? DashUi.ink : DashUi.slate,
              ),
            ),
          ),
          ?r.extra,
          const Spacer(),
          const SizedBox(width: 12),
          _CountUp(
            text: r.value,
            style: TextStyle(
              fontSize: r.strong ? 24 : 14.5,
              fontWeight: r.strong ? FontWeight.w800 : FontWeight.w700,
              color: r.tone ?? DashUi.ink,
              letterSpacing: r.strong ? -0.5 : 0,
              fontFeatures: _figures,
            ),
          ),
        ],
      );
      return Tooltip(
        message: r.tip ?? '',
        waitDuration: const Duration(milliseconds: 500),
        child: Padding(padding: EdgeInsets.symmetric(vertical: r.strong ? 2 : 4), child: row),
      );
    }

    final body = rows.where((r) => !r.strong).toList();
    final totals = rows.where((r) => r.strong).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final r in body) line(r),
        if (totals.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.only(top: 6, bottom: 6),
            child: Divider(height: 1, thickness: 1.5, color: DashUi.ink),
          ),
          for (final r in totals) line(r),
        ],
      ],
    );
  }
}

/// Cost, gross profit and margin, on a tinted panel marked internal: admins see it, customers never do. A bar under
/// the figures shows how much of what is charged (before tax) is left after cost.
class _InternalPanel extends StatelessWidget {
  final List<(String, String, Color?)> figures;
  final double? share; // profit / net, 0..1, when there is one to show
  const _InternalPanel._({required this.figures, this.share});

  factory _InternalPanel({List<(String, String, Color?)>? figures, int? cost, int? profit, double? margin, int? net}) {
    if (figures != null) return _InternalPanel._(figures: figures);
    return _InternalPanel._(
      figures: [
        ('Cost', centsMoney(cost ?? 0), null),
        ('Gross profit', centsMoney(profit ?? 0), (profit ?? 0) < 0 ? DashUi.redText : DashUi.emeraldText),
        ('Margin', margin == null ? '—' : '${margin.toStringAsFixed(1)}%', margin != null && margin < 0 ? DashUi.redText : null),
      ],
      share: net == null || net <= 0 || profit == null ? null : (profit / net).clamp(0.0, 1.0),
    );
  }

  static const _tips = {
    'Cost': 'Internal cost of every line (quantity x cost). Never on customer documents.',
    'Gross profit': 'Items less discounts, less cost. Sales tax is not profit.',
    'Margin': 'Gross profit / (items - discounts)',
  };

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: _costBand,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DashUi.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Row(
            children: [
              Icon(Icons.lock_outline_rounded, size: 14, color: DashUi.subtle),
              SizedBox(width: 6),
              Flexible(
                child: Text(
                  'Internal: not on customer documents',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.subtle),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 28,
            runSpacing: 8,
            children: [
              for (final f in figures)
                Tooltip(
                  message: _tips[f.$1] ?? '',
                  waitDuration: const Duration(milliseconds: 500),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        f.$1,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: DashUi.slate),
                      ),
                      _CountUp(
                        text: f.$2,
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: f.$3 ?? DashUi.ink, fontFeatures: _figures),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          if (share != null) ...[
            const SizedBox(height: 10),
            Semantics(
              label: 'Profit is ${(share! * 100).toStringAsFixed(0)}% of the price before tax',
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: share!),
                duration: reduce ? Duration.zero : const Duration(milliseconds: 520),
                curve: Curves.easeOutCubic,
                builder: (_, v, _) => ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: SizedBox(
                    height: 6,
                    child: Row(
                      children: [
                        // Containers, not bare ColoredBoxes: those would take the row's minimum height (none).
                        if (v < 1) Expanded(flex: ((1 - v) * 1000).round().clamp(1, 1000), child: Container(color: DashUi.line)),
                        if (v > 0) Expanded(flex: (v * 1000).round().clamp(1, 1000), child: Container(color: DashUi.emerald)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            const Row(
              children: [
                Text('Cost', style: TextStyle(fontSize: 12, color: DashUi.subtle)),
                Spacer(),
                Text('Left after cost', style: TextStyle(fontSize: 12, color: DashUi.subtle)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _InlineNotice extends StatelessWidget {
  final String text;
  final bool error;
  const _InlineNotice(this.text, {this.error = false});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: error ? const Color(0xFFFEF2F2) : const Color(0xFFF8FAFC),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: error ? const Color(0xFFFECACA) : DashUi.line),
    ),
    child: Row(
      children: [
        Icon(error ? Icons.error_outline_rounded : Icons.info_outline_rounded, size: 16, color: error ? DashUi.redText : DashUi.slate),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: error ? DashUi.redText : DashUi.slate),
          ),
        ),
      ],
    ),
  );
}

/// A figure that rolls to its new value when it changes (a quick count, off with reduce motion).
class _CountUp extends StatefulWidget {
  final String text;
  final TextStyle style;
  const _CountUp({required this.text, required this.style});

  @override
  State<_CountUp> createState() => _CountUpState();
}

class _CountUpState extends State<_CountUp> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 320), value: 1);
  String _from = '';

  @override
  void didUpdateWidget(_CountUp old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text && !MediaQuery.disableAnimationsOf(context)) {
      _from = old.text;
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, _) {
      final t = Curves.easeOutCubic.transform(_c.value);
      if (t >= 1 || _from.isEmpty) return Text(widget.text, style: widget.style);
      return ClipRect(
        child: Stack(
          alignment: Alignment.centerRight,
          children: [
            Opacity(opacity: 0, child: Text(widget.text.length >= _from.length ? widget.text : _from, style: widget.style)),
            Transform.translate(
              offset: Offset(0, -10 * t),
              child: Opacity(
                opacity: 1 - t,
                child: Text(_from, style: widget.style),
              ),
            ),
            Transform.translate(
              offset: Offset(0, 10 * (1 - t)),
              child: Opacity(
                opacity: t,
                child: Text(widget.text, style: widget.style),
              ),
            ),
          ],
        ),
      );
    },
  );
}
