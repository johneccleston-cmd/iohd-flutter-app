import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'config/access.dart';
import 'config/auth_session.dart';
import 'purchase_order_pdf.dart';
import 'purchase_orders_api.dart';
import 'services/line_items_api.dart' show CatalogEntry, LineItemsApi;
import 'theme/app_theme.dart';
import 'utils/line_item_math.dart' show centsMoney;
import 'widgets/app_dialog.dart';
import 'widgets/app_ribbon.dart';
import 'widgets/catalog_kit.dart' hide CatalogSearchField;
import 'widgets/catalog_search_field.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';
import 'widgets/leave_guard.dart';
import 'widgets/line_table_style.dart';

/// The PO's own routes under /inventory/purchase-orders: `new` (a Duplicate passes the PO to copy as `extra`) and `<id>`.
/// Leaving with unsaved changes asks first (the page registers with LeaveGuard).
List<RouteBase> purchaseOrderRoutes() => [
  GoRoute(
    path: 'new',
    onExit: (context, state) => LeaveGuard.confirm(),
    builder: (context, state) {
      final template = state.extra is PurchaseOrder ? state.extra as PurchaseOrder : null;
      return PurchaseOrderDetailScreen(key: ValueKey('po-new-${identityHashCode(template)}'), template: template);
    },
  ),
  GoRoute(
    path: ':id',
    onExit: (context, state) => LeaveGuard.confirm(),
    builder: (context, state) {
      final id = int.tryParse(state.pathParameters['id'] ?? '') ?? -1;
      // A PO just created arrives with itself, so the page doesn't load it again.
      final shown = state.extra is PurchaseOrder && (state.extra as PurchaseOrder).id == id ? state.extra as PurchaseOrder : null;
      return PurchaseOrderDetailScreen(key: ValueKey('po-$id'), orderId: id, initial: shown);
    },
  ),
];

/// One purchase order: what was ordered from whom, where it stands, and what has arrived. Built like the product page
/// (a header band, then the order's parts on the left and a rail on the right with where it stands and the order's
/// facts), so the two Inventory record pages read alike. Reading and editing keep the same two columns.
///
/// What it does: edit (vendor, numbers, dates, parts from the catalog, shipping, notes), mark a draft ordered, receive
/// some or all of it, cancel, duplicate it as a new PO, print or save it as a PDF for the vendor, and delete it.
class PurchaseOrderDetailScreen extends StatefulWidget {
  /// Null: a new PO.
  final int? orderId;

  /// A new PO filled in from this one (Duplicate): its vendor, parts and shipping.
  final PurchaseOrder? template;

  /// The PO as it was just saved, shown at once instead of loaded.
  final PurchaseOrder? initial;

  /// Swappable for tests; the real search is the catalog's, products only.
  final Future<List<CatalogEntry>> Function(String q)? catalogSearch;

  const PurchaseOrderDetailScreen({super.key, this.orderId, this.template, this.initial, this.catalogSearch});

  @override
  State<PurchaseOrderDetailScreen> createState() => _PurchaseOrderDetailScreenState();
}

/// A line while the PO is being edited: its quantity and unit cost are boxes.
class _LineDraft {
  final String sku;
  final int? productId;
  final double received;
  final TextEditingController name;
  final TextEditingController qty;
  final TextEditingController cost;
  final Key key = UniqueKey();

  _LineDraft({required String name, this.sku = '', this.productId, required double qty, double? cost, this.received = 0})
    : name = TextEditingController(text: name),
      qty = TextEditingController(text: _plainNumber(qty)),
      cost = TextEditingController(text: cost == null ? '' : _moneyText(cost));

  factory _LineDraft.of(PoLine l) => _LineDraft(name: l.name, sku: l.sku, productId: l.productId, qty: l.qty, cost: l.unitCost, received: l.received);

  bool get custom => productId == null;
  double? get qtyValue => double.tryParse(qty.text.trim().replaceAll(',', ''));
  double? get costValue {
    final t = cost.text.trim().replaceAll(RegExp(r'[\$,\s]'), '');
    return t.isEmpty ? 0 : double.tryParse(t);
  }

  bool get qtyOk => (qtyValue ?? 0) > 0 && qtyValue! <= 100000;
  bool get costOk => costValue != null && costValue! >= 0;

  PoLine toLine({bool allIn = false}) {
    final q = qtyValue ?? 0;
    return PoLine(name: name.text.trim(), sku: sku, productId: productId, qty: q, unitCost: costValue ?? 0, received: allIn ? q : received.clamp(0, q));
  }

  void dispose() {
    name.dispose();
    qty.dispose();
    cost.dispose();
  }
}

String _plainNumber(double v) => v == v.roundToDouble() ? v.round().toString() : v.toString();

/// A cost as it is typed: two decimals, more only when it really has them (a 4-decimal unit cost stays exact).
String _moneyText(double v) {
  final two = v.toStringAsFixed(2);
  return double.parse(two) == v ? two : v.toString();
}

class _PurchaseOrderDetailScreenState extends State<PurchaseOrderDetailScreen> {
  final _session = AuthSession.instance;
  final _activity = RibbonActivity();
  final _scroll = ScrollController();

  PurchaseOrder? _po; // as saved
  bool _linesSupported = true;
  bool _loading = false;
  String? _error; // nothing to show
  int? _errorStatus;
  bool _editing = false;
  bool _busy = false; // a save or an action is out
  String? _saveError;
  bool _conflict = false;
  bool _tried = false; // Save was pressed: show what needs fixing

  final _number = TextEditingController();
  final _vendor = TextEditingController();
  final _vendorRef = TextEditingController();
  final _job = TextEditingController();
  final _notes = TextEditingController();
  final _shipping = TextEditingController();
  final _total = TextEditingController();
  final _vendorFocus = FocusNode();
  late DateTime _ordered = _today;
  DateTime? _expected;
  DateTime? _received;
  String _status = 'Open';
  List<_LineDraft> _lines = [];
  final Set<String> _vendors = {};
  String _saved = ''; // the form as saved, to tell when something changed
  VoidCallback? _unguard;

  DateTime get _today => poToday();
  bool get _isNew => _po == null && widget.orderId == null;
  bool get _canCreate => _session.can('purchase_orders', AccessAction.create);
  bool get _canUpdate => _session.can('purchase_orders', AccessAction.update);
  bool get _canDelete => _session.can('purchase_orders', AccessAction.delete);

  @override
  void initState() {
    super.initState();
    for (final c in [_number, _vendor, _vendorRef, _job, _notes, _shipping, _total]) {
      c.addListener(_typed);
    }
    _unguard = LeaveGuard.register(canLeave: _confirmLeave, holdsWork: () => mounted && _editing && _changed);
    final initial = widget.initial;
    if (initial != null) {
      _po = initial;
      _fill(initial);
    } else if (widget.orderId == null) {
      _fill(null);
      _saved = _form; // a blank form: anything typed is a change
      final t = widget.template;
      if (t != null) {
        _vendor.text = t.vendor;
        _shipping.text = t.shipping > 0 ? _moneyText(t.shipping) : '';
        _lines = [for (final l in t.lines) _LineDraft.of(l.copyWith(received: 0))];
        if (t.lines.isEmpty && t.total > 0) _total.text = _moneyText(t.total);
      }
      _editing = true; // after filling in, so the boxes' listeners don't rebuild mid-setup
    } else {
      _load();
    }
    _loadVendors();
  }

  @override
  void dispose() {
    _unguard?.call();
    for (final c in [_number, _vendor, _vendorRef, _job, _notes, _shipping, _total]) {
      c.dispose();
    }
    for (final l in _lines) {
      l.dispose();
    }
    _vendorFocus.dispose();
    _activity.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _typed() {
    if (mounted && _editing) setState(() {});
  }

  // ---- data ------------------------------------------------------------------------------------------------------

  Future<void> _load() async {
    final id = widget.orderId;
    if (id == null) return;
    final refresh = _po != null;
    if (refresh) _activity.setRefreshing(true);
    setState(() {
      _loading = !refresh;
      _error = null;
      _errorStatus = null;
    });
    try {
      final r = await PoApi.get(id);
      if (!mounted) return;
      _activity.setRefreshing(false);
      if (refresh) _activity.landed();
      setState(() {
        _po = r.order;
        _linesSupported = r.linesSupported;
        _loading = false;
        _conflict = false;
        _saveError = null;
        if (!_editing) _fill(r.order);
      });
    } on PoApiError catch (e) {
      if (!mounted) return;
      _activity.setRefreshing(false);
      if (e.status == 401) return;
      setState(() {
        _loading = false;
        if (refresh) {
          _saveError = "Couldn't refresh. ${e.message}";
        } else {
          _error = e.message;
          _errorStatus = e.status;
        }
      });
    }
  }

  /// The vendors already on POs, offered as the vendor box is typed in (and whether the server keeps line items, for
  /// a new PO, which has nothing else to ask).
  Future<void> _loadVendors() async {
    try {
      final r = await PoApi.list();
      if (!mounted) return;
      setState(() {
        _vendors.addAll([for (final o in r.orders) if (o.vendor.trim().isNotEmpty) o.vendor.trim()]);
        if (_isNew && _linesSupported != r.linesSupported) {
          // What Save sends depends on it, so an untouched form stays untouched (no "discard?" over nothing).
          final untouched = !_changed;
          _linesSupported = r.linesSupported;
          if (untouched) _saved = _form;
        }
      });
    } on PoApiError {
      // Only suggestions: the box works without them.
    }
  }

  /// Puts [p] in every box (null: a blank new PO).
  void _fill(PurchaseOrder? p) {
    _number.text = p?.poNumber ?? '';
    _vendor.text = p?.vendor ?? '';
    _vendorRef.text = p?.vendorRef ?? '';
    _job.text = p?.jobNumber ?? '';
    _notes.text = p?.notes ?? '';
    _shipping.text = (p?.shipping ?? 0) > 0 ? _moneyText(p!.shipping) : '';
    _total.text = p != null && p.lines.isEmpty && p.total > 0 ? _moneyText(p.total) : '';
    _status = p?.status.isNotEmpty == true ? p!.status : 'Open';
    _ordered = p?.orderDate ?? _today;
    _expected = p?.expectedDate;
    _received = p?.receivedDate;
    for (final l in _lines) {
      l.dispose();
    }
    _lines = [for (final l in p?.lines ?? const <PoLine>[]) _LineDraft.of(l)];
    _tried = false;
    _saved = _form;
  }

  double? _moneyIn(TextEditingController c) {
    final t = c.text.trim().replaceAll(RegExp(r'[\$,\s]'), '');
    return t.isEmpty ? 0 : double.tryParse(t);
  }

  int get _linesCents => _lines.fold(0, (s, l) => s + l.toLine().amountCents);
  int get _draftTotalCents => _lines.isEmpty ? ((_moneyIn(_total) ?? 0) * 100).round() : _linesCents + ((_moneyIn(_shipping) ?? 0) * 100).round();

  /// What Save sends. A PO saved as Received has everything in.
  Map<String, dynamic> _body() {
    final allIn = _status == 'Received';
    return {
      'poNumber': _number.text.trim(),
      'vendor': _vendor.text.trim(),
      'status': _status,
      'orderDate': poIso(_ordered),
      'expectedDate': _expected == null ? '' : poIso(_expected!),
      'receivedDate': allIn ? poIso(_received ?? _today) : '',
      'notes': _notes.text.trim(),
      'total': _draftTotalCents / 100,
      if (_linesSupported) ...{
        'vendorRef': _vendorRef.text.trim(),
        'jobNumber': _job.text.trim(),
        'shipping': _lines.isEmpty ? 0 : (_moneyIn(_shipping) ?? 0),
        'lines': [for (final l in _lines) l.toLine(allIn: allIn).toJson()],
      },
    };
  }

  String get _form => json.encode(_body());
  bool get _changed => _form != _saved;

  /// What has to be fixed before Save, by field ('line<i>' for a line's boxes).
  Map<String, String> get _problems {
    final p = <String, String>{};
    if (_vendor.text.trim().isEmpty) p['vendor'] = 'Enter the vendor.';
    if (!_isNew && _number.text.trim().isEmpty) p['number'] = 'Enter the PO number.';
    if (_expected != null && _expected!.isBefore(_ordered)) p['expected'] = "The expected date can't be before the order date.";
    if (_lines.isEmpty) {
      final t = _moneyIn(_total);
      if (t == null || t < 0) {
        p['total'] = 'Enter the total as a number, like 1250.00.';
      } else if (t == 0 && _status != 'Draft' && _status != 'Canceled' && _linesSupported) {
        p['total'] = 'Add the parts being ordered, or enter the PO total.';
      }
    } else if (_moneyIn(_shipping) == null || _moneyIn(_shipping)! < 0) {
      p['shipping'] = 'Enter shipping as a number.';
    }
    for (var i = 0; i < _lines.length; i++) {
      final l = _lines[i];
      if (l.name.text.trim().isEmpty) {
        p['line$i'] = 'Line ${i + 1} needs a name.';
      } else if (!l.qtyOk) {
        p['line$i'] = 'Line ${i + 1}: enter a quantity above 0.';
      } else if (!l.costOk) {
        p['line$i'] = 'Line ${i + 1}: enter the unit cost as a number.';
      }
    }
    return p;
  }

  // ---- actions ---------------------------------------------------------------------------------------------------

  void _say(String text, {bool error = false}) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(behavior: SnackBarBehavior.floating, backgroundColor: error ? DashUi.red : null, content: Text(text)),
      );
  }

  void _toList() {
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      router.go('/inventory/purchase-orders');
    } else {
      Navigator.maybePop(context);
    }
  }

  Future<bool> _askDiscard({String why = 'If you leave now they are lost.'}) async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        title: 'Discard your changes?',
        subtitle: _isNew ? 'This purchase order has not been saved.' : '${_po?.poNumber ?? 'This PO'} has changes that are not saved.',
        icon: Icons.edit_off_rounded,
        body: Text(why, style: const TextStyle(fontSize: 14, color: DashUi.slate)),
        actions: [
          AppButton.ghost('Keep editing', () => Navigator.pop(ctx, false), autofocus: true),
          AppButton.ink('Discard changes', () => Navigator.pop(ctx, true), danger: true),
        ],
      ),
    );
    return discard == true;
  }

  Future<bool> _confirmLeave() async {
    if (!mounted || !_editing || !_changed) return true;
    return _askDiscard();
  }

  Future<void> _cancelEdit() async {
    if (_changed && !await _askDiscard(why: 'Your changes to this purchase order will be lost.')) return;
    if (!mounted) return;
    if (_isNew) {
      _saved = _form; // nothing left to guard
      _toList();
      return;
    }
    setState(() {
      _editing = false;
      _saveError = null;
      _conflict = false;
      _fill(_po);
    });
  }

  void _startEditing() => setState(() {
    _editing = true;
    _saveError = null;
  });

  Future<void> _save() async {
    if (_busy) return;
    final problems = _problems;
    setState(() {
      _tried = true;
      _saveError = null;
    });
    if (problems.isNotEmpty) return;
    final wasNew = _isNew;
    setState(() => _busy = true);
    try {
      final body = _body();
      final saved = wasNew ? await PoApi.create(body) : await PoApi.update(_po!.id, {...body, 'updatedAt': ?_po!.updatedAt});
      if (!mounted) return;
      setState(() {
        _po = saved;
        _editing = false;
        _busy = false;
        _conflict = false;
        _fill(saved);
      });
      _say(wasNew ? '${saved.poNumber} created.' : '${saved.poNumber} saved.');
      if (wasNew) GoRouter.maybeOf(context)?.go('/inventory/purchase-orders/${saved.id}', extra: saved);
    } on PoApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _saveError = e.message;
        _conflict = e.conflict;
      });
    }
  }

  void _shortcutSave() {
    if (_editing && (_isNew || _changed)) _save();
  }

  /// Sends [body] for the saved PO (an action: Mark ordered, Receive, Cancel, Reopen). True when it worked.
  Future<bool> _apply(Map<String, dynamic> body, String done) async {
    setState(() {
      _busy = true;
      _saveError = null;
      _conflict = false;
    });
    try {
      final saved = await PoApi.update(_po!.id, body);
      if (!mounted) return false;
      setState(() {
        _po = saved;
        _busy = false;
        _fill(saved);
      });
      _say(done);
      return true;
    } on PoApiError catch (e) {
      if (!mounted) return false;
      setState(() {
        _busy = false;
        _saveError = e.message;
        _conflict = e.conflict;
      });
      return false;
    }
  }

  Future<void> _markOrdered() async {
    final po = _po!;
    await _apply(po.toBody(status: 'Open', orderDate: _today), '${po.poNumber} is marked as ordered today.');
  }

  Future<void> _receive() async {
    final po = _po!;
    if (po.lines.isEmpty) {
      final date = await showDialog<DateTime>(context: context, builder: (_) => _ReceiveAllDialog(po: po, today: _today));
      if (date == null || !mounted) return;
      await _apply(po.toBody(status: 'Received', receivedDate: date), '${po.poNumber} is received.');
      return;
    }
    final got = await showDialog<({List<double> now, DateTime date})>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ReceiveDialog(po: po, today: _today),
    );
    if (got == null || !mounted) return;
    final lines = [for (var i = 0; i < po.lines.length; i++) po.lines[i].copyWith(received: po.lines[i].received + got.now[i])];
    final allIn = lines.every((l) => l.complete);
    final units = got.now.fold<double>(0, (s, v) => s + v);
    final left = lines.fold<double>(0, (s, l) => s + l.remaining);
    await _apply(
      po.toBody(status: allIn ? 'Received' : 'Open', lines: lines, receivedDate: got.date, clearReceived: !allIn),
      allIn
          ? 'Everything is in. ${po.poNumber} is marked Received.'
          : 'Received ${poQty(units)} ${units == 1 ? 'unit' : 'units'}. ${poQty(left)} still on order.',
    );
  }

  Future<void> _cancelPo() async {
    final po = _po!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        title: 'Cancel ${po.poNumber}?',
        subtitle: po.vendor,
        icon: Icons.block_rounded,
        iconColor: DashUi.redText,
        body: const Text(
          'It stays on file as canceled and stops counting as on order. You can reopen it later.',
          style: TextStyle(fontSize: 14, color: DashUi.slate, height: 1.4),
        ),
        actions: [
          AppButton.ghost('Keep PO', () => Navigator.pop(ctx, false), autofocus: true),
          AppButton.ink('Cancel PO', () => Navigator.pop(ctx, true), danger: true),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _apply(po.toBody(status: 'Canceled', clearReceived: true), '${po.poNumber} is canceled.');
  }

  Future<void> _reopen() async {
    final po = _po!;
    await _apply(po.toBody(status: 'Open', clearReceived: true), '${po.poNumber} is open again.');
  }

  Future<void> _delete() async {
    final po = _po!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        title: 'Delete ${po.poNumber}?',
        subtitle: po.vendor,
        icon: Icons.delete_outline_rounded,
        iconColor: DashUi.redText,
        body: const Text(
          "The PO and its parts are removed for good. This can't be undone. To keep it on file, cancel it instead.",
          style: TextStyle(fontSize: 14, color: DashUi.slate, height: 1.4),
        ),
        actions: [
          AppButton.ghost('Keep PO', () => Navigator.pop(ctx, false), autofocus: true),
          AppButton.ink('Delete PO', () => Navigator.pop(ctx, true), danger: true),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await PoApi.delete(po.id);
      if (!mounted) return;
      setState(() => _busy = false);
      _toList();
      messenger?.showSnackBar(SnackBar(behavior: SnackBarBehavior.floating, content: Text('${po.poNumber} deleted.')));
    } on PoApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _saveError = e.message;
      });
    }
  }

  void _duplicate() {
    final po = _po!;
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      router.go('/inventory/purchase-orders/new', extra: po);
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => PurchaseOrderDetailScreen(template: po, catalogSearch: widget.catalogSearch)));
    }
  }

  /// A part picked from the catalog: the vendor's own price when this vendor sells it, else its first vendor's price,
  /// else the catalog's cost. With no vendor yet, the product's first vendor is filled in. The same product again adds
  /// one to its line instead of a second line.
  void _addPick(CatalogChoice choice) {
    final e = choice.entry;
    final custom = choice.custom;
    if (e == null && (custom == null || custom.trim().isEmpty)) return;
    setState(() {
      if (e == null) {
        _lines.add(_LineDraft(name: custom!.trim(), qty: 1));
        return;
      }
      for (final v in e.vendors) {
        if (v.name.trim().isNotEmpty) _vendors.add(v.name.trim());
      }
      final pid = e.productId;
      final same = pid == null ? null : _lines.where((l) => l.productId == pid).firstOrNull;
      if (same != null) {
        same.qty.text = _plainNumber((same.qtyValue ?? 0) + 1);
        _say('Added one more ${e.name}.');
        return;
      }
      final vendor = _vendor.text.trim().toLowerCase();
      final priced = [for (final v in e.vendors) if (v.price != null && v.price! > 0) v];
      final mine = priced.where((v) => v.name.trim().toLowerCase() == vendor).firstOrNull;
      double? cost = mine?.price;
      if (cost == null && vendor.isEmpty && priced.isNotEmpty) {
        _vendor.text = priced.first.name.trim();
        cost = priced.first.price;
      }
      cost ??= priced.isNotEmpty ? priced.first.price : e.cost;
      _lines.add(_LineDraft(name: e.name, sku: e.sku, productId: pid, qty: 1, cost: cost));
    });
  }

  void _removeLine(int i) => setState(() => _lines.removeAt(i).dispose());

  // ---- build -------------------------------------------------------------------------------------------------------

  static const _maxContent = 1440.0;

  @override
  Widget build(BuildContext context) {
    final po = _po;
    return Scaffold(
      backgroundColor: Colors.white,
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): _shortcutSave,
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _shortcutSave,
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppRibbon(
              title: 'PURCHASE ORDER',
              kind: _isNew ? 'NEW' : po?.poNumber.toUpperCase(),
              icon: accessIcon('purchase_orders'),
              compactSide: 16,
              activity: _activity,
              controls: _controls(),
            ),
            if (_busy) const LinearProgressIndicator(minHeight: 3, color: DashUi.ink, backgroundColor: Colors.transparent),
            Expanded(child: PageSheet(child: _body0())),
          ],
        ),
      ),
    );
  }

  List<Widget> _controls() {
    const gap = SizedBox(width: 8);
    final width = MediaQuery.sizeOf(context).width;
    // Room on the ribbon: Back only on a wide window; on a phone-width one the main actions go to the top of More.
    final showBack = width >= 900;
    final phone = width < AppRibbon.compactWidth;
    final back = RibbonGhostButton(icon: Icons.arrow_back_rounded, label: 'All POs', onPressed: () => LeaveGuard.leave(_toList));
    if (_editing) {
      return [
        RibbonGhostButton(icon: Icons.close_rounded, label: 'Cancel', onPressed: _busy ? null : _cancelEdit),
        gap,
        PageBanner.button(
          icon: Icons.check_rounded,
          label: _busy ? 'Saving...' : (_isNew ? 'Create PO' : 'Save'),
          onPressed: _busy || (!_isNew && !_changed) ? null : _save,
        ),
      ];
    }
    final po = _po;
    if (po == null) return [back];
    final stage = po.stage(_today);
    final primary = !_canUpdate
        ? null
        : switch (stage) {
            PoStage.draft => PageBanner.button(icon: Icons.send_rounded, label: 'Mark ordered', onPressed: _busy ? null : _markOrdered),
            PoStage.open || PoStage.partial || PoStage.late =>
              PageBanner.button(icon: Icons.move_to_inbox_rounded, label: 'Receive', onPressed: _busy ? null : _receive),
            _ => null,
          };
    final edit = !_canUpdate
        ? null
        : (primary == null
              ? PageBanner.button(icon: Icons.edit_rounded, label: 'Edit', onPressed: _busy ? null : _startEditing)
              : RibbonGhostButton(icon: Icons.edit_rounded, label: 'Edit', onPressed: _busy ? null : _startEditing));
    final more = <BannerMenuItem>[
      if (phone && _canUpdate) ...[
        if (stage == PoStage.draft) BannerMenuItem(icon: Icons.send_rounded, label: 'Mark ordered', onPressed: _busy ? null : _markOrdered),
        if (stage == PoStage.open || stage == PoStage.partial || stage == PoStage.late)
          BannerMenuItem(icon: Icons.move_to_inbox_rounded, label: 'Receive', onPressed: _busy ? null : _receive),
        BannerMenuItem(icon: Icons.edit_rounded, label: 'Edit', onPressed: _busy ? null : _startEditing),
      ],
      BannerMenuItem(icon: Icons.picture_as_pdf_outlined, label: 'Print or save PDF', onPressed: () => showPurchaseOrderPdf(context, po)),
      if (_canCreate) BannerMenuItem(icon: Icons.content_copy_rounded, label: 'Duplicate as new PO', onPressed: _busy ? null : _duplicate),
      if (_canUpdate && (po.isDraft || po.isOpen)) BannerMenuItem(icon: Icons.block_rounded, label: 'Cancel PO', onPressed: _busy ? null : _cancelPo),
      if (_canUpdate && po.isCanceled) BannerMenuItem(icon: Icons.undo_rounded, label: 'Reopen PO', onPressed: _busy ? null : _reopen),
      if (_canDelete) BannerMenuItem(icon: Icons.delete_outline_rounded, label: 'Delete PO', danger: true, onPressed: _busy ? null : _delete),
    ];
    return [
      if (showBack) ...[back, gap],
      if (primary != null && !phone) ...[primary, gap],
      if (edit != null && !phone) ...[edit, gap],
      PageBanner.more(items: more),
      gap,
      PageBanner.refresh(onPressed: _loading || _busy ? null : _load),
    ];
  }

  Widget _body0() {
    if (_loading) return const _DetailSkeleton();
    if (_error != null && _po == null) {
      final gone = _errorStatus == 404;
      return Center(
        child: FlatEmpty(
          icon: gone ? Icons.search_off_rounded : (_errorStatus == 403 ? Icons.lock_outline_rounded : Icons.cloud_off_rounded),
          title: gone ? 'That purchase order is not on file' : "This purchase order couldn't be loaded",
          message: _error!,
          action: gone || _errorStatus == 403 ? AppButton.ink('Back to purchase orders', _toList) : AppButton.ink('Try again', _load),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        final width = c.maxWidth.clamp(0.0, _maxContent);
        final two = width >= 1000;
        final rail = (width * 0.34).clamp(340.0, 440.0);
        final side = width < 600 ? 16.0 : 28.0;
        final mainWidth = (two ? width - rail : width) - side * 2;
        Widget band(Widget child) => Center(child: SizedBox(width: width, child: child));
        final main = _main(side, mainWidth);
        final railBody = _rail(side);
        return SingleChildScrollView(
          controller: _scroll,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_saveError != null || (_tried && _problems.isNotEmpty)) band(_notice(side)),
              DecoratedBox(
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: DashUi.line))),
                child: band(_editing ? _editHeader(side) : _readHeader(side)),
              ),
              band(
                two
                    ? Stack(
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: main),
                              SizedBox(width: rail, child: railBody),
                            ],
                          ),
                          // The rail's edge runs the full height of the two columns, however long either one is.
                          Positioned(top: 0, bottom: 0, right: rail, child: const SizedBox(width: 1, child: ColoredBox(color: DashUi.line))),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // On one column where it stands comes first: it is what a person opens a PO to see.
                          railBody,
                          Container(
                            decoration: const BoxDecoration(border: Border(top: BorderSide(color: DashUi.line))),
                            margin: const EdgeInsets.only(top: 22),
                            child: main,
                          ),
                        ],
                      ),
              ),
              const SizedBox(height: 28),
              // Room for the catalog search's results when it is near the bottom.
              if (_editing && _linesSupported) const CatalogSearchRoom(),
            ],
          ),
        );
      },
    );
  }

  // ---- shared pieces -----------------------------------------------------------------------------------------------

  Widget _notice(double side) {
    final n = _problems.length;
    final message = _saveError ?? (n == 1 ? 'One thing needs a fix before this can be saved.' : '$n things need a fix before this can be saved.');
    final warn = _saveError == null || _conflict;
    final fg = warn ? AppTheme.notesText : DashUi.redText;
    final lines = [
      for (final e in _problems.entries)
        if (e.key.startsWith('line')) e.value,
    ];
    return Semantics(
      liveRegion: true,
      child: Container(
        margin: EdgeInsets.fromLTRB(side, 16, side, 0),
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        decoration: BoxDecoration(
          color: warn ? AppTheme.notesBg : DashUi.red.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: warn ? AppTheme.notesStroke : DashUi.red.withValues(alpha: 0.25)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(_conflict ? Icons.sync_problem_rounded : Icons.error_outline_rounded, size: 20, color: fg),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(message, style: TextStyle(color: fg, fontSize: 14, fontWeight: FontWeight.w600, height: 1.35)),
                  if (_saveError == null)
                    for (final l in lines.take(4))
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(l, style: TextStyle(color: fg, fontSize: 13, height: 1.35)),
                      ),
                ],
              ),
            ),
            if (_conflict)
              TextButton(
                onPressed: () async {
                  if (_editing && _changed && !await _askDiscard(why: 'Reloading shows the PO as it is saved now, and your changes are lost.')) return;
                  if (!mounted) return;
                  setState(() => _editing = false);
                  _load();
                },
                style: TextButton.styleFrom(foregroundColor: DashUi.ink),
                child: const Text('Reload PO', style: TextStyle(fontWeight: FontWeight.w700)),
              )
            else if (_saveError != null)
              IconButton(
                tooltip: 'Dismiss',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.close_rounded, size: 18, color: fg),
                onPressed: () => setState(() => _saveError = null),
              ),
          ],
        ),
      ),
    );
  }

  /// A block in either column: a small-caps label, then its content.
  Widget _section(String label, Widget child, {required double side, String? note, Widget? trailing, double top = 22}) => Padding(
    padding: EdgeInsets.fromLTRB(side, top, side, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CatalogLabel(label, note: note, trailing: trailing),
        const SizedBox(height: 12),
        child,
      ],
    ),
  );

  Widget _rule(double side) => Padding(
    padding: EdgeInsets.fromLTRB(side, 22, side, 0),
    child: const Divider(height: 1, color: DashUi.line),
  );

  /// A fact to read: its label, then the value.
  Widget _fact(String label, String value, {Widget? custom, bool quiet = false}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.slate)),
      const SizedBox(height: 4),
      custom ??
          SelectableText(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: quiet ? FontWeight.w500 : FontWeight.w600,
              color: quiet ? DashUi.subtle : DashUi.ink,
              height: 1.3,
              fontFeatures: CatalogUi.figures,
            ),
          ),
    ],
  );

  /// Children two to a row.
  Widget _pairs(List<Widget> children, {double gap = 16, double runGap = 18}) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += 2) {
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: children[i]),
            SizedBox(width: gap),
            Expanded(child: i + 1 < children.length ? children[i + 1] : const SizedBox()),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (var i = 0; i < rows.length; i++) ...[if (i > 0) SizedBox(height: runGap), rows[i]]],
    );
  }

  Widget _label(String text, {bool optional = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(text: text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.ink)),
          if (optional) const TextSpan(text: '  optional', style: TextStyle(fontSize: 12, color: DashUi.subtle)),
        ],
      ),
    ),
  );

  String? _err(String key) => _tried ? _problems[key] : null;

  Widget _textField(
    TextEditingController c, {
    String? hint,
    String? error,
    String? helper,
    int lines = 1,
    String? prefix,
    bool numeric = false,
    TextAlign align = TextAlign.start,
    FocusNode? focus,
  }) {
    final field = TextField(
      controller: c,
      focusNode: focus,
      minLines: lines,
      maxLines: lines == 1 ? 1 : lines + 4,
      style: CatalogUi.fieldText,
      textAlign: align,
      cursorWidth: CatalogUi.cursorWidth,
      cursorRadius: CatalogUi.cursorRadius,
      textAlignVertical: lines == 1 ? TextAlignVertical.center : null,
      keyboardType: numeric ? const TextInputType.numberWithOptions(decimal: true) : (lines > 1 ? TextInputType.multiline : null),
      inputFormatters: numeric ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,$]'))] : null,
      decoration: catalogFieldDecoration(hint: hint, error: error, prefix: prefix, filled: true, padding: lines > 1 ? const EdgeInsets.all(12) : null),
    );
    if (helper == null || error != null) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field,
        Padding(padding: const EdgeInsets.only(top: 4, left: 2), child: Text(helper, style: CatalogUi.meta.copyWith(fontSize: 12.5))),
      ],
    );
  }

  Widget _dateField(DateTime? value, ValueChanged<DateTime?> onPicked, {bool clearable = false, String? error, String empty = 'Not set'}) {
    Future<void> pick() async {
      final now = _today;
      final d = await showDatePicker(
        context: context,
        initialDate: value ?? now,
        firstDate: DateTime(now.year - 5),
        lastDate: DateTime(now.year + 5),
      );
      if (d != null) onPicked(d);
    }

    return Semantics(
      button: true,
      child: InkWell(
        mouseCursor: WidgetStateMouseCursor.clickable,
        borderRadius: BorderRadius.circular(10),
        onTap: pick,
        child: InputDecorator(
          isEmpty: false,
          decoration: catalogFieldDecoration(
            error: error,
            filled: true,
            suffixIcon: clearable && value != null
                ? IconButton(
                    tooltip: 'Clear the date',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded, size: 18, color: DashUi.slate),
                    onPressed: () => onPicked(null),
                  )
                : const Padding(padding: EdgeInsets.only(right: 10), child: Icon(Icons.calendar_today_rounded, size: 17, color: DashUi.slate)),
            suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
          ),
          child: Text(
            value == null ? empty : poDate.format(value),
            style: value == null ? CatalogUi.fieldHint : CatalogUi.fieldText,
          ),
        ),
      ),
    );
  }

  // ---- the header band ---------------------------------------------------------------------------------------------

  Widget _readHeader(double side) {
    final po = _po!;
    final stage = po.stage(_today);
    final job = po.jobNumber.trim();
    final made = po.createdAt;
    final by = po.createdBy.trim();
    final history = [
      if (made != null) 'Created${by.isEmpty ? '' : ' by $by'} on ${poDate.format(made)}',
      if (po.updatedBy.trim().isNotEmpty && po.updatedBy != po.createdBy) 'last changed by ${po.updatedBy.trim()}',
    ].join(', ');
    return Padding(
      padding: EdgeInsets.fromLTRB(side, 22, side, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 14,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SelectableText(
                po.poNumber,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: DashUi.ink, letterSpacing: -0.4, height: 1.2),
              ),
              _StagePill(stage),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 18,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.storefront_rounded, size: 17, color: DashUi.subtle),
                  const SizedBox(width: 6),
                  Text(po.vendor, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: DashUi.ink)),
                ],
              ),
              if (po.vendorRef.trim().isNotEmpty) _meta('Vendor order #', po.vendorRef.trim()),
              if (job.isNotEmpty)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('For job ', style: TextStyle(fontSize: 13.5, color: DashUi.slate)),
                    FlatLink(job, tip: 'Open job $job', onTap: () => LeaveGuard.leave(() => context.go('/jobs/${Uri.encodeComponent(job)}'))),
                  ],
                ),
              if (history.isNotEmpty)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.history_rounded, size: 15, color: DashUi.subtle),
                    const SizedBox(width: 4),
                    Flexible(child: Text(history, style: CatalogUi.meta)),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _meta(String label, String value) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('$label ', style: const TextStyle(fontSize: 13.5, color: DashUi.slate)),
      Text(value, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink, fontFeatures: CatalogUi.figures)),
    ],
  );

  Widget _editHeader(double side) => Padding(
    padding: EdgeInsets.fromLTRB(side, 22, side, 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _isNew ? (widget.template == null ? 'New purchase order' : 'New purchase order from ${widget.template!.poNumber}') : 'Editing ${_po!.poNumber}',
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: DashUi.ink, letterSpacing: -0.4, height: 1.2),
        ),
        const SizedBox(height: 6),
        Text(
          _isNew
              ? 'Pick the vendor and add the parts you are ordering. Save it as a draft until it is sent. Ctrl+S saves.'
              : 'Change anything below, then Save. Ctrl+S saves.',
          style: CatalogUi.meta,
        ),
      ],
    ),
  );

  // ---- the parts -----------------------------------------------------------------------------------------------------

  Widget _main(double side, double width) {
    final narrow = width < 560;
    final lineCount = _editing ? _lines.length : (_po?.lines.length ?? 0);
    final units = _editing ? _lines.fold<double>(0, (s, l) => s + (l.qtyValue ?? 0)) : (_po?.unitsOrdered ?? 0);
    final note = lineCount == 0 ? null : '${lineCount == 1 ? '1 line' : '$lineCount lines'}  ·  ${poQty(units)} ${units == 1 ? 'unit' : 'units'}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(
          'ITEMS',
          side: side,
          note: note,
          !_linesSupported
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const AppNotice(
                      'Parts can be listed on a PO once the server is updated. Until then a PO keeps its total only.',
                      kind: AppNoticeKind.warning,
                    ),
                    const SizedBox(height: 16),
                    _totals(narrow),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_editing) ..._editLines(narrow) else _readLines(narrow),
                    const SizedBox(height: 18),
                    _totals(narrow),
                  ],
                ),
        ),
        _section(
          'NOTES',
          side: side,
          top: 30,
          _editing
              ? _textField(_notes, hint: 'Anything the office or warehouse should know: delivery, who ordered it, backorders.', lines: 3)
              : (_po!.notes.trim().isEmpty
                    ? const Text('No notes.', style: CatalogUi.cellQuiet)
                    : SelectableText(_po!.notes.trim(), style: CatalogUi.body)),
        ),
      ],
    );
  }

  static const _qtyWidth = 92.0;
  static const _costWidth = 124.0;
  static const _amountWidth = 112.0;
  static const _gotWidth = 120.0;

  Widget _head(String text, {double? width, bool right = false}) {
    final t = Text(text, textAlign: right ? TextAlign.right : TextAlign.left, style: LineTable.head.copyWith(fontSize: 12.5));
    return width == null ? Expanded(child: t) : SizedBox(width: width, child: t);
  }

  Widget _headRow(List<Widget> cells) => Container(
    padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
    decoration: const BoxDecoration(
      color: DashUi.faint,
      border: Border(bottom: BorderSide(color: DashUi.line)),
    ),
    child: Row(children: cells),
  );

  Widget _tableFrame(List<Widget> children) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: DashUi.line)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
  );

  Widget _itemName(String name, String sku, {bool quiet = false}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text.rich(catalogNameSpan(name, LineTable.name.copyWith(color: quiet ? DashUi.slate : DashUi.ink)), maxLines: 3, overflow: TextOverflow.ellipsis),
      if (sku.trim().isNotEmpty) ...[
        const SizedBox(height: 1),
        Text('Part # ${sku.trim()}', style: LineTable.meta.copyWith(color: DashUi.slate)),
      ],
    ],
  );

  Widget _receivedCell(PoLine l, {required bool draft}) {
    if (draft) return const Text('—', style: LineTable.quiet);
    if (l.complete) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_rounded, size: 16, color: DashUi.emeraldDeep),
          const SizedBox(width: 5),
          Text('All in', style: LineTable.amount.copyWith(color: DashUi.emeraldText)),
        ],
      );
    }
    final part = l.qty <= 0 ? 0.0 : (l.received / l.qty).clamp(0.0, 1.0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('${poQty(l.received)} of ${poQty(l.qty)}', style: l.received > 0 ? LineTable.amount.copyWith(color: DashUi.amberText) : LineTable.quiet),
        if (l.received > 0) ...[
          const SizedBox(width: 8),
          SizedBox(width: 28, child: _Meter(part: part, tone: DashUi.amber, height: 4)),
        ],
      ],
    );
  }

  Widget _readLines(bool narrow) {
    final po = _po!;
    if (po.lines.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: DashUi.line)),
        child: Row(
          children: [
            const Icon(Icons.list_alt_rounded, size: 22, color: DashUi.subtle),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _canUpdate ? 'No parts are listed on this PO. Edit it to add them from the catalog.' : 'No parts are listed on this PO.',
                style: CatalogUi.cellQuiet,
              ),
            ),
          ],
        ),
      );
    }
    final draft = po.isDraft;
    if (narrow) {
      return _tableFrame([
        for (var i = 0; i < po.lines.length; i++)
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: i.isOdd ? LineTable.stripe : null,
              border: i == 0 ? null : Border(top: BorderSide(color: LineTable.rowRule)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _itemName(po.lines[i].name, po.lines[i].sku)),
                    const SizedBox(width: 12),
                    Text(centsMoney(po.lines[i].amountCents), style: LineTable.amount),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text('${poQty(po.lines[i].qty)} × ${centsMoney((po.lines[i].unitCost * 100).round())}', style: LineTable.quiet),
                    ),
                    _receivedCell(po.lines[i], draft: draft),
                  ],
                ),
              ],
            ),
          ),
      ]);
    }
    return _tableFrame([
      _headRow([
        _head('ITEM'),
        _head('QTY', width: _qtyWidth, right: true),
        const SizedBox(width: 16),
        _head('RECEIVED', width: _gotWidth),
        _head('UNIT COST', width: _costWidth, right: true),
        _head('AMOUNT', width: _amountWidth, right: true),
      ]),
      for (var i = 0; i < po.lines.length; i++)
        Container(
          padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
          decoration: BoxDecoration(
            color: i.isOdd ? LineTable.stripe : null,
            border: i == 0 ? null : Border(top: BorderSide(color: LineTable.rowRule)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _itemName(po.lines[i].name, po.lines[i].sku)),
              SizedBox(width: _qtyWidth, child: Text(poQty(po.lines[i].qty), textAlign: TextAlign.right, style: LineTable.cell)),
              const SizedBox(width: 16),
              SizedBox(width: _gotWidth, child: Align(alignment: Alignment.centerLeft, child: _receivedCell(po.lines[i], draft: draft))),
              SizedBox(
                width: _costWidth,
                child: Text(centsMoney((po.lines[i].unitCost * 100).round()), textAlign: TextAlign.right, style: LineTable.cell),
              ),
              SizedBox(width: _amountWidth, child: Text(centsMoney(po.lines[i].amountCents), textAlign: TextAlign.right, style: LineTable.amount)),
            ],
          ),
        ),
    ]);
  }

  Widget _box(TextEditingController c, {required bool ok, String? prefix, String? semantic, int decimals = 2}) => Semantics(
    label: semantic,
    textField: true,
    child: TextField(
      controller: c,
      textAlign: TextAlign.right,
      style: LineTable.cell,
      cursorWidth: CatalogUi.cursorWidth,
      cursorRadius: CatalogUi.cursorRadius,
      textAlignVertical: TextAlignVertical.center,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp('^\\\$?[0-9,]*\\.?[0-9]{0,$decimals}'))],
      onChanged: (_) => setState(() {}),
      decoration: catalogFieldDecoration(
        error: !ok && _tried ? ' ' : null,
        errorText: false,
        prefix: prefix,
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
    ),
  );

  List<Widget> _editLines(bool narrow) {
    Widget remove(int i) => IconButton(
      tooltip: 'Remove this line',
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.close_rounded, size: 18, color: DashUi.slate),
      onPressed: () => _removeLine(i),
    );
    Widget name(int i) {
      final l = _lines[i];
      if (!l.custom) return _itemName(l.name.text, l.sku);
      return TextField(
        controller: l.name,
        style: LineTable.name,
        onChanged: (_) => setState(() {}),
        decoration: catalogFieldDecoration(
          hint: 'What is being ordered',
          height: 36,
          error: _tried && l.name.text.trim().isEmpty ? ' ' : null,
          errorText: false,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        ),
      );
    }

    Widget amount(int i) {
      final l = _lines[i];
      final blank = l.cost.text.trim().isEmpty;
      return Text(
        blank || !l.qtyOk || !l.costOk ? '—' : centsMoney(l.toLine().amountCents),
        textAlign: TextAlign.right,
        style: blank ? LineTable.quiet : LineTable.amount,
      );
    }

    final rows = <Widget>[];
    for (var i = 0; i < _lines.length; i++) {
      final l = _lines[i];
      final problem = _err('line$i');
      final row = narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: name(i)), remove(i)]),
                const SizedBox(height: 8),
                Row(
                  children: [
                    SizedBox(width: 84, child: _box(l.qty, ok: l.qtyOk, semantic: 'Quantity', decimals: 3)),
                    const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('×', style: LineTable.quiet)),
                    SizedBox(width: 120, child: _box(l.cost, ok: l.costOk, prefix: '\$ ', semantic: 'Unit cost', decimals: 4)),
                    const SizedBox(width: 12),
                    Expanded(child: amount(i)),
                  ],
                ),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: name(i)),
                const SizedBox(width: 12),
                SizedBox(width: _qtyWidth, child: _box(l.qty, ok: l.qtyOk, semantic: 'Quantity for ${l.name.text}', decimals: 3)),
                const SizedBox(width: 10),
                SizedBox(width: _costWidth, child: _box(l.cost, ok: l.costOk, prefix: '\$ ', semantic: 'Unit cost for ${l.name.text}', decimals: 4)),
                SizedBox(width: _amountWidth, child: amount(i)),
                const SizedBox(width: 4),
                SizedBox(width: 36, child: remove(i)),
              ],
            );
      rows.add(
        Container(
          key: l.key,
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
          decoration: BoxDecoration(border: i == 0 ? null : Border(top: BorderSide(color: LineTable.rowRule))),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              row,
              if (problem != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(problem, style: const TextStyle(fontSize: 12.5, color: DashUi.redText)),
                ),
              if (l.received > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${poQty(l.received)} already received', style: LineTable.meta.copyWith(color: DashUi.amberText)),
                ),
            ],
          ),
        ),
      );
    }
    final search = CatalogSearchField(
      onPick: _addPick,
      showCost: true,
      search: widget.catalogSearch ?? (q) => LineItemsApi.searchCatalog(q, kind: 'product'),
      hint: _lines.isEmpty ? 'Add a part: search products by name or part number' : 'Add another part',
    );
    return [
      if (_lines.isNotEmpty)
        _tableFrame([
          if (!narrow)
            _headRow([
              _head('ITEM'),
              const SizedBox(width: 12),
              _head('QTY', width: _qtyWidth, right: true),
              const SizedBox(width: 10),
              _head('UNIT COST', width: _costWidth, right: true),
              _head('AMOUNT', width: _amountWidth, right: true),
              const SizedBox(width: 40),
            ]),
          ...rows,
        ]),
      if (_lines.isNotEmpty) const SizedBox(height: 12),
      search,
      const SizedBox(height: 6),
      const Text(
        "Picking a part fills in this vendor's price from the catalog. Not in the catalog? Type its name and choose Add a custom line.",
        style: TextStyle(fontSize: 12.5, color: DashUi.slate, height: 1.4),
      ),
    ];
  }

  Widget _sumRow(String label, Widget value, {bool strong = false}) => Padding(
    padding: EdgeInsets.only(top: strong ? 10 : 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: strong ? 15 : 14, fontWeight: strong ? FontWeight.w800 : FontWeight.w600, color: strong ? DashUi.ink : DashUi.slate),
          ),
        ),
        const SizedBox(width: 16),
        SizedBox(width: 150, child: Align(alignment: Alignment.centerRight, child: value)),
      ],
    ),
  );

  Widget _totals(bool narrow) {
    Text money(int cents, {bool strong = false}) => Text(
      centsMoney(cents),
      style: strong
          ? const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: DashUi.ink, letterSpacing: -0.3, fontFeatures: CatalogUi.figures)
          : LineTable.amount.copyWith(fontSize: 14),
    );
    final List<Widget> rows;
    if (_editing) {
      if (_lines.isEmpty) {
        rows = [
          _sumRow('PO total', SizedBox(width: 150, child: _box(_total, ok: _err('total') == null, prefix: '\$ ', semantic: 'PO total'))),
          if (_err('total') != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_err('total')!, textAlign: TextAlign.right, style: const TextStyle(fontSize: 12.5, color: DashUi.redText)),
            )
          else if (_linesSupported)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Add the parts above, or type the total if you are not listing them.',
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 12.5, color: DashUi.slate),
              ),
            ),
        ];
      } else {
        rows = [
          _sumRow('Parts', money(_linesCents)),
          _sumRow('Shipping & fees', SizedBox(width: 130, child: _box(_shipping, ok: _err('shipping') == null, prefix: '\$ ', semantic: 'Shipping and fees'))),
          const Padding(padding: EdgeInsets.only(top: 10), child: Divider(height: 1, color: DashUi.line)),
          _sumRow('Total', money(_draftTotalCents, strong: true), strong: true),
        ];
      }
    } else {
      final po = _po!;
      final cents = (po.total * 100).round();
      rows = po.lines.isEmpty
          ? [_sumRow('PO total', money(cents, strong: true), strong: true)]
          : [
              _sumRow('Parts', money(po.lines.fold(0, (s, l) => s + l.amountCents))),
              if (po.shipping > 0) _sumRow('Shipping & fees', money((po.shipping * 100).round())),
              const Padding(padding: EdgeInsets.only(top: 10), child: Divider(height: 1, color: DashUi.line)),
              _sumRow('Total', money(cents, strong: true), strong: true),
            ];
    }
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: narrow ? double.infinity : 380),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
      ),
    );
  }

  // ---- the rail ------------------------------------------------------------------------------------------------------

  Widget _rail(double side) => _editing ? _editRail(side) : _readRail(side);

  Widget _readRail(double side) {
    final po = _po!;
    final today = _today;
    final stage = po.stage(today);
    final ordered = po.orderDate;
    final received = po.receivedDate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(padding: EdgeInsets.fromLTRB(side, 22, side, 0), child: _PoBanner.of(po, today)),
        _section(
          'PO TOTAL',
          side: side,
          note: po.lines.isEmpty ? null : (po.shipping > 0 ? 'incl. ${dashMoney(po.shipping)} shipping' : null),
          Text(
            dashMoney(po.total),
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.6,
              height: 1.1,
              color: po.isCanceled ? DashUi.subtle : DashUi.ink,
              decoration: po.isCanceled ? TextDecoration.lineThrough : null,
              decorationColor: DashUi.muted,
              fontFeatures: CatalogUi.figures,
            ),
          ),
        ),
        if (po.lines.isNotEmpty && !po.isDraft && !po.isCanceled) ...[
          _section(
            'RECEIVED',
            side: side,
            note: '${poQty(po.unitsReceived)} of ${poQty(po.unitsOrdered)} units',
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Meter(
                  part: po.unitsOrdered <= 0 ? 0 : (po.unitsReceived / po.unitsOrdered).clamp(0.0, 1.0),
                  tone: stage == PoStage.received ? DashUi.emeraldDeep : (po.anyReceived ? DashUi.amber : DashUi.line),
                  height: 8,
                ),
                const SizedBox(height: 8),
                Text(
                  po.allReceived
                      ? 'Every part is in.'
                      : '${po.lines.where((l) => l.complete).length} of ${po.lines.length} lines complete',
                  style: CatalogUi.meta,
                ),
              ],
            ),
          ),
        ],
        _rule(side),
        _section(
          'ORDER',
          side: side,
          _pairs([
            _fact('Vendor', po.vendor),
            _fact('Vendor order #', po.vendorRef.trim().isEmpty ? 'Not entered' : po.vendorRef.trim(), quiet: po.vendorRef.trim().isEmpty),
            _fact(po.isDraft ? 'Started' : 'Ordered', ordered == null ? 'Not set' : poDate.format(ordered), quiet: ordered == null),
            _fact('Expected', po.expectedDate == null ? 'Not set' : poDate.format(po.expectedDate!), quiet: po.expectedDate == null),
            if (received != null) _fact('Received', poDate.format(received)),
            _fact(
              'For job',
              '',
              custom: po.jobNumber.trim().isEmpty
                  ? const Text('Not tied to a job', style: TextStyle(fontSize: 15, color: DashUi.subtle, height: 1.3))
                  : FlatLink(po.jobNumber.trim(), tip: 'Open job ${po.jobNumber.trim()}', onTap: () => LeaveGuard.leave(() => context.go('/jobs/${Uri.encodeComponent(po.jobNumber.trim())}'))),
            ),
          ]),
        ),
      ],
    );
  }

  static const _statusHelp = {
    'Draft': 'Being put together. Not counted as on order until it is marked ordered.',
    'Open': 'Ordered and waiting on parts. Counts as on order.',
    'Received': 'Everything is in. Every line is marked received.',
    'Canceled': 'Kept on file, not counted as on order.',
  };

  Widget _editRail(double side) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(
          'STATUS',
          side: side,
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppSegmented<String>(
                value: _status,
                options: [for (final s in kPoStatuses) (s, s)],
                onChanged: (s) => setState(() {
                  _status = s;
                  if (s == 'Received') _received ??= _today;
                }),
              ),
              const SizedBox(height: 8),
              Text(_statusHelp[_status] ?? '', style: CatalogUi.meta.copyWith(fontSize: 12.5)),
            ],
          ),
        ),
        _section(
          'ORDER',
          side: side,
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _label('Vendor'),
              _VendorField(controller: _vendor, focusNode: _vendorFocus, vendors: _vendors, error: _err('vendor')),
              const SizedBox(height: 16),
              _label('PO number', optional: _isNew),
              _textField(
                _number,
                hint: _isNew ? 'Numbered when saved' : null,
                error: _err('number'),
                helper: _isNew ? 'Leave blank to number it automatically, like PO-${_today.year}-1001.' : null,
              ),
              if (_linesSupported) ...[
                const SizedBox(height: 16),
                _pairs(gap: 12, runGap: 16, [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [_label('Vendor order #', optional: true), _textField(_vendorRef, hint: 'Their confirmation #')],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [_label('For job #', optional: true), _textField(_job, hint: 'Job number')],
                  ),
                ]),
              ],
              const SizedBox(height: 16),
              _pairs(gap: 12, runGap: 16, [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _label(_status == 'Draft' ? 'Started' : 'Ordered'),
                    _dateField(_ordered, (d) => setState(() => _ordered = d ?? _ordered)),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _label('Expected', optional: true),
                    _dateField(_expected, (d) => setState(() => _expected = d), clearable: true, error: _err('expected')),
                  ],
                ),
                if (_status == 'Received')
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [_label('Received'), _dateField(_received ?? _today, (d) => setState(() => _received = d ?? _received))],
                  ),
              ]),
            ],
          ),
        ),
      ],
    );
  }
}

// ---- small pieces ----------------------------------------------------------------------------------------------------

/// The PO's state as a tinted pill with a dot, next to its number.
class _StagePill extends StatelessWidget {
  final PoStage stage;
  const _StagePill(this.stage);

  @override
  Widget build(BuildContext context) {
    final tone = stage.tone;
    return Semantics(
      label: 'Status: ${stage.label}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(9, 4, 11, 4),
        decoration: BoxDecoration(color: tone.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(999)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 7, height: 7, decoration: BoxDecoration(color: tone, shape: BoxShape.circle)),
            const SizedBox(width: 7),
            Text(stage.label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: tone)),
          ],
        ),
      ),
    );
  }
}

/// A slim bar filled to [part] (0 to 1), grown in when it first shows. Still with reduced motion.
class _Meter extends StatelessWidget {
  final double part;
  final Color tone;
  final double height;
  const _Meter({required this.part, required this.tone, this.height = 6});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      value: '${(part * 100).round()}%',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(height),
        child: SizedBox(
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: DashUi.faint),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: part),
                duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 600),
                curve: Curves.easeOutCubic,
                builder: (_, v, _) => FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: v,
                  child: ColoredBox(color: tone),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The card at the top of the rail saying where the PO stands, tinted in its tone (the job page's timing card).
class _PoBanner extends StatelessWidget {
  final Color tone;
  final IconData icon;
  final String headline;
  final String detail;
  const _PoBanner({required this.tone, required this.icon, required this.headline, required this.detail});

  factory _PoBanner.of(PurchaseOrder po, DateTime today) {
    String day(DateTime d) => _weekday(d);
    final ordered = po.orderDate;
    final expected = po.expectedDate;
    final inSoFar = po.lines.isNotEmpty && po.anyReceived ? '${poQty(po.unitsReceived)} of ${poQty(po.unitsOrdered)} units in' : '';
    String join(List<String> parts) => parts.where((p) => p.isNotEmpty).join('  ·  ');
    switch (po.stage(today)) {
      case PoStage.draft:
        return _PoBanner(
          tone: DashUi.slate,
          icon: Icons.edit_note_rounded,
          headline: 'Draft, not ordered yet',
          detail: 'Mark it ordered once it has gone to ${po.vendor}.',
        );
      case PoStage.canceled:
        return const _PoBanner(tone: DashUi.slate, icon: Icons.block_rounded, headline: 'Canceled', detail: 'Kept on file. Not counted as on order.');
      case PoStage.received:
        final r = po.receivedDate;
        final took = r != null && ordered != null ? poDaysBetween(ordered, r) : null;
        return _PoBanner(
          tone: DashUi.emeraldDeep,
          icon: Icons.task_alt_rounded,
          headline: r == null ? 'Received' : 'Received ${day(r)}',
          detail: join([
            if (ordered != null) 'Ordered ${poShortDate.format(ordered)}',
            if (took != null && took >= 0) took == 0 ? 'came the same day' : 'took ${poSpan(took)}',
          ]),
        );
      case PoStage.late:
        final d = po.daysLate(today)!;
        return _PoBanner(
          tone: DashUi.red,
          icon: Icons.schedule_rounded,
          headline: '${poSpan(d)[0].toUpperCase()}${poSpan(d).substring(1)} past due',
          detail: join(['Expected ${day(expected!)}', inSoFar, if (ordered != null && inSoFar.isEmpty) 'Ordered ${poShortDate.format(ordered)}']),
        );
      case PoStage.partial:
      case PoStage.open:
        final partial = po.stage(today) == PoStage.partial;
        if (expected == null) {
          final since = ordered == null ? null : poDaysBetween(ordered, today);
          return _PoBanner(
            tone: partial ? DashUi.amber : DashUi.indigo,
            icon: partial ? Icons.inventory_2_outlined : Icons.local_shipping_outlined,
            headline: partial ? 'Partly received' : (since == null || since <= 0 ? 'Ordered today' : 'Ordered ${poSpan(since)} ago'),
            detail: join([inSoFar, 'No expected date set']),
          );
        }
        final d = -po.daysLate(today)!; // days to go
        return _PoBanner(
          tone: partial ? DashUi.amber : (d <= 1 ? DashUi.blue : DashUi.indigo),
          icon: partial ? Icons.inventory_2_outlined : Icons.local_shipping_outlined,
          headline: partial ? 'Partly received' : (d == 0 ? 'Due today' : (d == 1 ? 'Due tomorrow' : 'Due in ${poSpan(d)}')),
          detail: join(['Expected ${day(expected)}', inSoFar, if (ordered != null && inSoFar.isEmpty) 'Ordered ${poShortDate.format(ordered)}']),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ink = Color.lerp(tone, Colors.black, 0.3)!;
    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
        decoration: BoxDecoration(
          color: tone.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: tone.withValues(alpha: 0.22)),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: tone.withValues(alpha: 0.12), shape: BoxShape.circle),
              child: Icon(icon, size: 20, color: tone),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(headline, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: ink, letterSpacing: -0.2)),
                  if (detail.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(detail, style: const TextStyle(fontSize: 13.5, color: DashUi.slate, height: 1.35)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Fri, Nov 28": a day near enough to read with its weekday.
String _weekday(DateTime d) => '${const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.weekday - 1]}, ${poShortDate.format(d)}';

/// The vendor box: type a name, or pick one already used on a PO or listed on a part.
class _VendorField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final Set<String> vendors;
  final String? error;
  const _VendorField({required this.controller, required this.focusNode, required this.vendors, this.error});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => RawAutocomplete<String>(
        textEditingController: controller,
        focusNode: focusNode,
        optionsBuilder: (v) {
          final q = v.text.trim().toLowerCase();
          final all = vendors.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
          return [
            for (final name in all)
              if (name.toLowerCase().contains(q) && name.toLowerCase() != q) name,
          ].take(8);
        },
        fieldViewBuilder: (context, ctl, focus, submit) => TextField(
          controller: ctl,
          focusNode: focus,
          style: CatalogUi.fieldText,
          cursorWidth: CatalogUi.cursorWidth,
          cursorRadius: CatalogUi.cursorRadius,
          textAlignVertical: TextAlignVertical.center,
          textCapitalization: TextCapitalization.words,
          onSubmitted: (_) => submit(),
          decoration: catalogFieldDecoration(
            hint: 'Who the order is placed with',
            error: error,
            filled: true,
            prefixIcon: const Icon(Icons.storefront_rounded, size: 18, color: DashUi.slate),
            prefixIconConstraints: const BoxConstraints(minWidth: 40),
          ),
        ),
        optionsViewBuilder: (context, pick, options) => Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Material(
              color: Colors.white,
              elevation: 6,
              shadowColor: Colors.black.withValues(alpha: 0.12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: DashUi.line)),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: c.maxWidth, maxHeight: 280),
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  shrinkWrap: true,
                  children: [
                    for (final o in options)
                      InkWell(
                        onTap: () => pick(o),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          child: Row(
                            children: [
                              const Icon(Icons.storefront_outlined, size: 16, color: DashUi.subtle),
                              const SizedBox(width: 10),
                              Expanded(child: Text(o, style: CatalogUi.fieldText, maxLines: 1, overflow: TextOverflow.ellipsis)),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The receive dialogs' date button: ink on white with the hairline edge.
final ButtonStyle _dateButton = OutlinedButton.styleFrom(
  foregroundColor: DashUi.ink,
  side: const BorderSide(color: DashUi.line),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
  // A button's textStyle replaces the theme's whole, so it names the app's font (as PageBanner's buttons do).
  textStyle: const TextStyle(fontFamily: AppTheme.fontFamily, fontFamilyFallback: AppTheme.fontFamilyFallback, fontWeight: FontWeight.w700),
);

/// What arrived: for each line still due, how many came in now (everything still due to start with), and the date.
class _ReceiveDialog extends StatefulWidget {
  final PurchaseOrder po;
  final DateTime today;
  const _ReceiveDialog({required this.po, required this.today});

  @override
  State<_ReceiveDialog> createState() => _ReceiveDialogState();
}

class _ReceiveDialogState extends State<_ReceiveDialog> {
  late final List<TextEditingController> _now = [
    for (final l in widget.po.lines) TextEditingController(text: l.complete ? '' : poQty(l.remaining).replaceAll(',', '')),
  ];
  late DateTime _date = widget.today;

  @override
  void dispose() {
    for (final c in _now) {
      c.dispose();
    }
    super.dispose();
  }

  double _value(int i) => double.tryParse(_now[i].text.trim()) ?? 0;
  bool _over(int i) => _value(i) > widget.po.lines[i].remaining + 1e-9;
  double get _units => [for (var i = 0; i < _now.length; i++) _value(i)].fold(0, (s, v) => s + v);
  bool get _valid => !List.generate(_now.length, _over).any((o) => o) && _units > 0;

  void _fillAll(bool all) => setState(() {
    for (var i = 0; i < _now.length; i++) {
      final l = widget.po.lines[i];
      _now[i].text = all && !l.complete ? poQty(l.remaining).replaceAll(',', '') : '';
    }
  });

  @override
  Widget build(BuildContext context) {
    final po = widget.po;
    final after = [for (var i = 0; i < po.lines.length; i++) po.lines[i].remaining - (_over(i) ? 0 : _value(i))];
    final left = after.fold<double>(0, (s, v) => s + (v > 0 ? v : 0));
    Widget head(String t, {double? w, bool right = false}) {
      final text = Text(t, textAlign: right ? TextAlign.right : TextAlign.left, style: CatalogUi.head);
      return w == null ? Expanded(child: text) : SizedBox(width: w, child: text);
    }

    return AppDialog(
      title: 'Receive items',
      subtitle: '${po.poNumber}  ·  ${po.vendor}',
      icon: Icons.move_to_inbox_rounded,
      width: 660,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Enter how many of each part arrived.', style: TextStyle(fontSize: 14, color: DashUi.slate)),
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: DashUi.ink),
                onPressed: () => _fillAll(true),
                child: const Text('Everything still due', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: DashUi.slate),
                onPressed: () => _fillAll(false),
                child: const Text('Clear', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: DashUi.line))),
            child: Row(
              children: [
                head('ITEM'),
                head('ORDERED', w: 74, right: true),
                head('IN SO FAR', w: 84, right: true),
                const SizedBox(width: 16),
                head('ARRIVED NOW', w: 112),
              ],
            ),
          ),
          for (var i = 0; i < po.lines.length; i++)
            Container(
              padding: const EdgeInsets.fromLTRB(4, 9, 4, 9),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: LineTable.rowRule))),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text.rich(
                          catalogNameSpan(po.lines[i].name, LineTable.name.copyWith(color: po.lines[i].complete ? DashUi.slate : DashUi.ink)),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (po.lines[i].sku.isNotEmpty) Text('Part # ${po.lines[i].sku}', style: LineTable.meta.copyWith(color: DashUi.slate)),
                      ],
                    ),
                  ),
                  SizedBox(width: 74, child: Text(poQty(po.lines[i].qty), textAlign: TextAlign.right, style: LineTable.cell)),
                  SizedBox(width: 84, child: Text(poQty(po.lines[i].received), textAlign: TextAlign.right, style: LineTable.quiet)),
                  const SizedBox(width: 16),
                  SizedBox(
                    width: 112,
                    child: po.lines[i].complete
                        ? const Row(
                            children: [
                              Icon(Icons.check_circle_rounded, size: 16, color: DashUi.emeraldDeep),
                              SizedBox(width: 6),
                              Text('All in', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.emeraldText)),
                            ],
                          )
                        : Semantics(
                            label: 'Arrived now: ${po.lines[i].name}',
                            textField: true,
                            child: TextField(
                              controller: _now[i],
                              autofocus: i == po.lines.indexWhere((l) => !l.complete),
                              textAlign: TextAlign.right,
                              style: LineTable.cell,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^[0-9]*\.?[0-9]{0,3}'))],
                              onChanged: (_) => setState(() {}),
                              decoration: catalogFieldDecoration(
                                hint: '0',
                                height: 36,
                                error: _over(i) ? 'Only ${poQty(po.lines[i].remaining)} due' : null,
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('Date received', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.ink)),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                style: _dateButton,
                icon: const Icon(Icons.calendar_today_rounded, size: 16),
                label: Text(poDate.format(_date)),
                onPressed: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: _date,
                    firstDate: DateTime(widget.today.year - 2),
                    lastDate: widget.today,
                  );
                  if (d != null) setState(() => _date = d);
                },
              ),
            ],
          ),
        ],
      ),
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_valid)
            AppNotice(
              left <= 1e-9 ? 'Everything will be in, so the PO is marked Received.' : '${poQty(left)} ${left == 1 ? 'unit stays' : 'units stay'} on order.',
              kind: left <= 1e-9 ? AppNoticeKind.success : AppNoticeKind.info,
            ),
          const SizedBox(height: 8),
          const AppNotice('This records what arrived on the PO. Stock levels in Inventory are not changed.'),
        ],
      ),
      actions: [
        AppButton.ghost('Cancel', () => Navigator.pop(context)),
        AppButton.ink(
          _units <= 0 ? 'Receive' : 'Receive ${poQty(_units)} ${_units == 1 ? 'unit' : 'units'}',
          _valid ? () => Navigator.pop(context, (now: [for (var i = 0; i < _now.length; i++) _value(i)], date: _date)) : null,
          icon: Icons.move_to_inbox_rounded,
        ),
      ],
    );
  }
}

/// A PO with no parts listed is received all at once: just the date.
class _ReceiveAllDialog extends StatefulWidget {
  final PurchaseOrder po;
  final DateTime today;
  const _ReceiveAllDialog({required this.po, required this.today});

  @override
  State<_ReceiveAllDialog> createState() => _ReceiveAllDialogState();
}

class _ReceiveAllDialogState extends State<_ReceiveAllDialog> {
  late DateTime _date = widget.today;

  @override
  Widget build(BuildContext context) => AppDialog(
    title: 'Mark ${widget.po.poNumber} received?',
    subtitle: widget.po.vendor,
    icon: Icons.move_to_inbox_rounded,
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('No parts are listed on this PO, so the whole order is marked as in.', style: TextStyle(fontSize: 14, color: DashUi.slate, height: 1.4)),
        const SizedBox(height: 14),
        Row(
          children: [
            const Text('Date received', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.ink)),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              style: _dateButton,
              icon: const Icon(Icons.calendar_today_rounded, size: 16),
              label: Text(poDate.format(_date)),
              onPressed: () async {
                final d = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(widget.today.year - 2), lastDate: widget.today);
                if (d != null) setState(() => _date = d);
              },
            ),
          ],
        ),
      ],
    ),
    actions: [
      AppButton.ghost('Cancel', () => Navigator.pop(context)),
      AppButton.ink('Mark received', () => Navigator.pop(context, _date), icon: Icons.move_to_inbox_rounded, autofocus: true),
    ],
  );
}

/// Placeholder shaped like the page (header, parts table, rail) while the PO loads.
class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton();

  @override
  Widget build(BuildContext context) {
    Widget bar(double w, [double h = 12]) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(color: DashUi.line, borderRadius: BorderRadius.circular(6)),
    );
    return Semantics(
      label: 'Loading the purchase order',
      liveRegion: true,
      child: SkeletonPulse(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 26, 28, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [bar(190, 24), const SizedBox(width: 14), bar(80, 22)]),
              const SizedBox(height: 14),
              Wrap(spacing: 14, runSpacing: 8, children: [bar(140, 16), bar(120), bar(200)]),
              const SizedBox(height: 34),
              LayoutBuilder(
                builder: (context, c) => Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Align(alignment: Alignment.centerLeft, child: bar(60)),
                          const SizedBox(height: 14),
                          Container(height: 38, decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(8))),
                          for (var i = 0; i < 4; i++)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                              child: Row(children: [Expanded(child: Align(alignment: Alignment.centerLeft, child: bar(260))), bar(50), const SizedBox(width: 40), bar(80)]),
                            ),
                        ],
                      ),
                    ),
                    if (c.maxWidth >= 900) ...[
                      const SizedBox(width: 48),
                      SizedBox(
                        width: 340,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(height: 64, decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(8))),
                            const SizedBox(height: 24),
                            bar(70),
                            const SizedBox(height: 12),
                            bar(160, 28),
                            const SizedBox(height: 24),
                            bar(240),
                            const SizedBox(height: 10),
                            bar(200),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
