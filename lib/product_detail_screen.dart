import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'catalog_manage.dart' show showCategoryPickerDialog;
import 'config/access.dart';
import 'config/auth_session.dart';
import 'services/line_items_api.dart';
import 'theme/app_theme.dart';
import 'widgets/app_dialog.dart';
import 'widgets/app_ribbon.dart';
import 'widgets/catalog_kit.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';
import 'widgets/leave_guard.dart';

/// Bumped whenever a product is added, saved or deleted, so the Product Catalog list (kept alive under this page)
/// reloads and shows the change when you come back to it.
final ValueNotifier<int> productCatalogChanged = ValueNotifier<int>(0);

/// The catalog's categories, A to Z, as the Product Catalog list last loaded them: the product page's category picker
/// falls back to them when the server has no categories call (one older than Phase 3).
final ValueNotifier<List<String>> productCategories = ValueNotifier<List<String>>(const []);

/// The Product Catalog's sub-routes: `/inventory/catalog/new` and `/inventory/catalog/:id` (`?edit=1` opens it for editing).
List<RouteBase> productDetailRoutes() => [
  GoRoute(
    path: 'new',
    // Leaving with typed-in changes asks first (the page registers with LeaveGuard).
    onExit: (context, state) => LeaveGuard.confirm(),
    builder: (context, state) => const ProductDetailScreen(key: ValueKey('product-new')),
  ),
  GoRoute(
    path: ':id',
    onExit: (context, state) => LeaveGuard.confirm(),
    builder: (context, state) {
      final id = int.tryParse(state.pathParameters['id'] ?? '');
      return ProductDetailScreen(
        key: ValueKey('product-$id'),
        productId: id ?? -1,
        startEditing: state.uri.queryParameters['edit'] == '1',
      );
    },
  ),
];

/// Why a product's stock is not shown, in plain words (the server's `inventoryConflict` codes; see CatalogEntry).
String inventoryConflictText(String code) => switch (code) {
  'duplicate_name' => 'Not shown: another product has the same name, so its inventory row can\'t be told apart.',
  'name_row_linked_elsewhere' => 'Not shown: the inventory row with this name belongs to another product.',
  'shared_link' => 'Not shown: another product is linked to the same inventory row.',
  'linked_row_missing' => 'Not shown: its inventory row is gone or inactive.',
  'ambiguous_name' => 'Not shown: more than one inventory row has this name.',
  _ => 'Not shown: which inventory row is this product\'s needs checking.',
};

/// Asks before a product is deleted. True when the person confirmed. Used by the list's Delete button and the page's.
Future<bool> confirmDeleteProduct(BuildContext context, String name) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AppDialog(
      title: 'Delete this product?',
      subtitle: name,
      icon: Icons.delete_outline_rounded,
      iconColor: DashUi.redText,
      width: 480,
      body: const Text(
        'It comes off the price list for good, so it is no longer offered on new estimates and jobs. Lines already on '
        'estimates and jobs keep what they have. To keep it but stop offering it, switch it to Inactive instead.',
        style: TextStyle(fontSize: 14, height: 1.4, color: DashUi.slate),
      ),
      actions: [
        AppButton.ghost('Cancel', () => Navigator.pop(ctx, false)),
        AppButton.ink('Delete product', () => Navigator.pop(ctx, true), icon: Icons.delete_outline_rounded, danger: true),
      ],
    ),
  );
  return ok == true;
}

/// One product's own page: its details to read, and the same fields to edit (Edit in the ribbon). A new product
/// (`productId` null) opens straight into editing. Edits are saved to our own price list only.
class ProductDetailScreen extends StatefulWidget {
  /// Null: a new product. Negative: a link that is not a product number.
  final int? productId;
  final bool startEditing;

  /// Tests pass fakes; the app talks to the backend. [saver] gets only the fields that changed (all filled-in ones for a
  /// new product), and `confirmDuplicate` once the person said to save despite another product with the same name or part #.
  final Future<ProductPage> Function(int id)? loader;
  final Future<ProductRecord> Function(int? id, Map<String, dynamic> fields, String? expectedUpdatedAt, {bool confirmDuplicate})? saver;
  final Future<void> Function(int id)? deleter;

  /// The categories the Category picker offers, with their product counts (null: not known). Tests pass a fake; the
  /// app asks the server.
  final Future<Map<String, int?>> Function()? categoriesLoader;

  const ProductDetailScreen({super.key, this.productId, this.startEditing = false, this.loader, this.saver, this.deleter, this.categoriesLoader});

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  static const _textKeys = ['name', 'category', 'partNumber', 'model', 'sku', 'productType', 'description', 'purchaseDescription', 'relatedProducts'];
  static const _numKeys = [
    'unitPrice', 'memberPrice', 'avgUnitCost', 'fixedCommission', 'percentCommission', 'fixedBonus', 'percentBonus', 'paysHours',
    'v0Price', 'v1Price', 'v2Price',
  ];
  static const _vendorKeys = ['v0Name', 'v1Name', 'v2Name'];
  static final _count = NumberFormat.decimalPattern();

  final Map<String, TextEditingController> _c = {
    for (final k in [..._textKeys, ..._numKeys, ..._vendorKeys]) k: TextEditingController(),
  };
  bool _active = true;
  bool _invItem = false;
  bool _paysCommission = false;
  bool _paysBonus = false;

  ProductPage? _page;
  bool _loading = true;
  String? _error;
  int? _errorStatus;
  bool _editing = false;
  bool _saving = false;
  String? _saveError;
  bool _conflict = false;
  Map<String, String> _errors = {};
  Map<String, Object?> _original = {};

  /// A category the person chose to create in the picker ("Create ... as a new category"); sent as createCategory
  /// with the save, so the server makes it. Any other category must already exist.
  String? _newCategory;
  VoidCallback? _unguard;

  bool get _isNew => widget.productId == null;
  bool get _canSeeCost => _page?.canSeeCost ?? false;
  bool get _canEdit => _page?.canEdit ?? false;

  /// What the form says right now: every field's text, and the switches.
  Map<String, Object?> _values() => {
    for (final e in _c.entries) e.key: e.value.text.trim(),
    'isActive': _active,
    'isInventoryItem': _invItem,
    'paysCommission': _paysCommission,
    'paysBonus': _paysBonus,
  };

  bool get _changed {
    if (!_editing) return false;
    final now = _values();
    return now.length != _original.length || now.entries.any((e) => _original[e.key] != e.value);
  }

  @override
  void initState() {
    super.initState();
    for (final c in _c.values) {
      c.addListener(_onEdit);
    }
    _unguard = LeaveGuard.register(canLeave: _confirmLeave, holdsWork: () => mounted && _changed);
    if (_isNew) {
      _page = (
        product: const ProductRecord(),
        stock: null,
        canSeeCost: AuthSession.instance.can('line_items', AccessAction.view),
        canEdit: AuthSession.instance.can('catalog', AccessAction.create), // a new product: Product Catalog > Create
        inventoryConflict: null,
      );
      _loading = false;
      _editing = true;
      _original = _values();
    } else {
      _editing = widget.startEditing;
      _load();
    }
  }

  @override
  void dispose() {
    _unguard?.call();
    _categoryFocus.dispose();
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onEdit() {
    if (mounted && _editing) setState(() {});
  }

  /// Leaving the page with changes asks first. Discard also drops the changes: the page stays alive behind the other
  /// tabs (the shell's indexed stack), so a kept draft would ask again on every later page change (bug 2026-11-20).
  Future<bool> _confirmLeave() async {
    if (!mounted || !_changed) return true;
    if (!await _askDiscard()) return false;
    if (mounted) setState(_dropEdits);
    return true;
  }

  Future<bool> _askDiscard({String why = 'If you leave now they are lost.'}) async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        title: 'Discard your changes?',
        subtitle: 'This product has changes that are not saved.',
        icon: Icons.edit_off_rounded,
        width: 460,
        body: Text(why, style: const TextStyle(fontSize: 14, color: DashUi.slate)),
        actions: [
          AppButton.ghost('Keep editing', () => Navigator.pop(ctx, false)),
          AppButton.ink('Discard changes', () => Navigator.pop(ctx, true), danger: true),
        ],
      ),
    );
    return discard == true;
  }

  // ---- data -----------------------------------------------------------------

  Future<void> _load() async {
    final id = widget.productId;
    if (id == null) return;
    setState(() {
      _loading = _page == null;
      _error = null;
      _errorStatus = null;
    });
    try {
      final page = await (widget.loader ?? LineItemsApi.getProduct)(id);
      if (!mounted) return;
      setState(() {
        _page = page;
        _loading = false;
        _conflict = false;
        _saveError = null;
        _fill(page.product);
        if (!page.canEdit) _editing = false;
      });
    } on LineItemsException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
        _errorStatus = e.status;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load the product.';
      });
    }
  }

  /// The most decimal places a price, cost or percent may have (the server's limit too; the price list's costs go to 5).
  static const _maxDecimals = 6;

  /// Money exactly as stored: at least 2 decimals, never rounded ($23.32465 stays 23.32465, not 23.32).
  static String _exact(double? v) {
    if (v == null) return '';
    var s = v.toStringAsFixed(_maxDecimals).replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    final dot = s.indexOf('.');
    return dot < 0 ? '$s.00' : (s.length - dot - 1 < 2 ? '${s}0' : s);
  }

  /// A price, cost or member price: 0 is how the price list says "none" (priced per job, not set, not entered), as the
  /// list treats it, so the box is left empty (its hint says which) rather than showing a made-up $0.00.
  static String _priceText(double? v) => v == null || v == 0 ? '' : _exact(v);
  static String _plain(double? v) => v == null ? '' : (v == v.roundToDouble() ? v.toInt().toString() : v.toString());
  static final _preciseFormat = NumberFormat('#,##0.00####', 'en_US');

  /// Money for reading: cents as everywhere else, but a sub-cent cost keeps every decimal ($23.32465).
  static String _preciseMoney(double v) => _exact(v).split('.')[1].length <= 2 ? dashMoney(v) : '\$${_preciseFormat.format(v)}';

  /// Puts a saved product into the form (and takes the unsaved edits out of it).
  void _fill(ProductRecord r) {
    _newCategory = null; // saved, discarded or reloaded: a new category picked before is no longer pending
    void set(String k, String v) => _c[k]!.text = v;
    set('name', r.name);
    set('category', r.category);
    set('partNumber', r.partNumber);
    set('model', r.model);
    set('sku', r.sku);
    set('productType', r.productType);
    set('description', r.description);
    set('purchaseDescription', r.purchaseDescription);
    set('relatedProducts', r.relatedProducts);
    set('unitPrice', _priceText(r.unitPrice));
    set('memberPrice', _priceText(r.memberPrice));
    set('avgUnitCost', _priceText(r.avgUnitCost));
    set('fixedCommission', _exact(r.fixedCommission));
    set('percentCommission', _plain(r.percentCommission));
    set('fixedBonus', _exact(r.fixedBonus));
    set('percentBonus', _plain(r.percentBonus));
    set('paysHours', _plain(r.paysHours));
    for (var i = 0; i < 3; i++) {
      final v = i < r.vendors.length ? r.vendors[i] : null;
      set('v${i}Name', v?.name ?? '');
      set('v${i}Price', _priceText(v?.price));
    }
    _active = r.isActive;
    _invItem = r.isInventoryItem;
    _paysCommission = r.paysCommission;
    _paysBonus = r.paysBonus;
    _errors = {};
    _original = _values();
  }

  double? _num(String key, double max, Map<String, String> errors, String what) {
    final raw = _c[key]!.text.trim().replaceAll(RegExp(r'[\$,\s]'), '');
    if (raw.isEmpty) return null;
    final n = double.tryParse(raw);
    if (n == null || n < 0 || n > max) {
      errors[key] = '$what must be a number from 0 to ${_count.format(max)}.';
      return null;
    }
    // Refused rather than rounded: a cost is kept exactly as typed.
    if (raw.contains('.') && raw.split('.')[1].length > _maxDecimals) {
      errors[key] = '$what can have at most $_maxDecimals decimal places.';
      return null;
    }
    return n;
  }

  /// The request for Save, or null (with the problems shown on their fields) when something is not right.
  ///
  /// An edit sends ONLY the fields that changed, so nothing the person didn't touch is ever rewritten (it used to send
  /// every field, which rounded 113 sub-cent costs and turned empty fields into blanks on every save). A new product
  /// sends what was filled in.
  Map<String, dynamic>? _body() {
    final errors = <String, String>{};
    final now = _values();
    bool changed(String k) => _isNew || _original[k] != now[k];
    if (_c['name']!.text.trim().isEmpty) errors['name'] = 'Give the product a name.';
    final body = <String, dynamic>{
      for (final k in _textKeys)
        if (changed(k)) k: _c[k]!.text.trim(),
    };
    void number(String k, double max, String what) {
      if (changed(k)) body[k] = _num(k, max, errors, what);
    }

    number('unitPrice', 10000000, 'The price');
    number('memberPrice', 10000000, 'The member price');
    if (changed('isActive')) body['isActive'] = _active;
    if (changed('isInventoryItem')) body['isInventoryItem'] = _invItem;
    if (_canSeeCost) {
      number('avgUnitCost', 10000000, 'The cost');
      if (changed('paysCommission')) body['paysCommission'] = _paysCommission;
      number('fixedCommission', 10000000, 'The fixed commission');
      number('percentCommission', 100, 'The commission percent');
      if (changed('paysBonus')) body['paysBonus'] = _paysBonus;
      number('fixedBonus', 10000000, 'The fixed bonus');
      number('percentBonus', 100, 'The bonus percent');
      number('paysHours', 1000, 'The hours');
      // The vendors go as one list, so any change to one of them sends all three (each exactly as shown).
      if ([for (var i = 0; i < 3; i++) ...['v${i}Name', 'v${i}Price']].any(changed)) {
        body['vendors'] = [
          for (var i = 0; i < 3; i++)
            if (_c['v${i}Name']!.text.trim().isNotEmpty)
              {'name': _c['v${i}Name']!.text.trim(), 'price': _num('v${i}Price', 10000000, errors, 'The vendor price')},
        ];
      }
    }
    if (_isNew) body.removeWhere((k, v) => v == null || v == '');
    if (_newCategory != null && body['category'] == _newCategory) body['createCategory'] = true;
    setState(() => _errors = errors);
    return errors.isEmpty ? body : null;
  }

  /// Another product already has the name or part number: show them and let the person decide. True = save anyway.
  Future<bool> _confirmDuplicate(LineItemsException e) async {
    final what = e.message.contains('part number') ? 'part number' : 'name';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        title: 'Another product has this $what',
        icon: Icons.content_copy_rounded,
        width: 520,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final d in e.duplicates)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  d.partNumber == null || d.partNumber!.isEmpty ? d.name : '${d.name}  ·  Part # ${d.partNumber}',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: DashUi.ink),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              what == 'name'
                  ? 'Products with the same name can\'t be told apart in stock: neither shows a stock count until one is renamed. Save it anyway?'
                  : 'Two products would have the same part number. Save it anyway?',
              style: const TextStyle(fontSize: 14, height: 1.4, color: DashUi.slate),
            ),
          ],
        ),
        actions: [
          AppButton.ghost('Go back', () => Navigator.pop(ctx, false)),
          AppButton.ink('Save anyway', () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _save({bool confirmDuplicate = false}) async {
    if (_saving) return;
    final body = _body();
    if (body == null) return;
    setState(() {
      _saving = true;
      _saveError = null;
      _conflict = false;
    });
    final id = widget.productId;
    try {
      final saver = widget.saver ??
          (int? id, Map<String, dynamic> f, String? at, {bool confirmDuplicate = false}) => id == null
              ? LineItemsApi.createProduct(f, confirmDuplicate: confirmDuplicate)
              : LineItemsApi.updateProduct(id, f, expectedUpdatedAt: at, confirmDuplicate: confirmDuplicate);
      final saved = await saver(id, body, _page?.product.updatedAt, confirmDuplicate: confirmDuplicate);
      if (!mounted) return;
      productCatalogChanged.value++;
      setState(() {
        _saving = false;
        _editing = false;
        _page = (product: saved, stock: _page?.stock, canSeeCost: _canSeeCost, canEdit: _canEdit, inventoryConflict: _page?.inventoryConflict);
        _fill(saved);
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(id == null ? 'Product added' : 'Saved'), duration: const Duration(seconds: 2), behavior: SnackBarBehavior.floating, width: 220));
      if (id == null && saved.id != null) _go('/inventory/catalog/${saved.id}');
    } on LineItemsException catch (e) {
      if (!mounted) return;
      if (e.code == 'DUPLICATE' && !confirmDuplicate) {
        setState(() => _saving = false);
        if (await _confirmDuplicate(e) && mounted) await _save(confirmDuplicate: true);
        return;
      }
      if (e.code == 'CATEGORY_UNKNOWN') {
        // The category is not one the catalog has (someone deleted it, or an old page typed it): pick again.
        setState(() {
          _saving = false;
          _errors = {..._errors, 'category': e.message};
          _saveError = e.message;
        });
        return;
      }
      setState(() {
        _saving = false;
        _saveError = e.message;
        _conflict = e.status == 409 && e.code != 'DUPLICATE';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = 'Could not save. Check your connection and try again.';
      });
    }
  }

  Future<void> _delete() async {
    final id = widget.productId;
    final p = _page?.product;
    if (id == null || p == null) return;
    if (!await confirmDeleteProduct(context, p.name)) return;
    try {
      await (widget.deleter ?? LineItemsApi.deleteProduct)(id);
      if (!mounted) return;
      productCatalogChanged.value++;
      _toList();
    } on LineItemsException catch (e) {
      if (!mounted) return;
      // Still in use (saved lines, a stock row, billed history): the server keeps it, and the safe way out is Inactive
      // (P&S round 2 finalization B6, 2026-11-23). Nothing changes unless the person says so.
      if (e.code == 'IN_USE') {
        await _offerInactive(p, e.message);
        return;
      }
      setState(() => _saveError = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saveError = 'Could not delete the product. Try again.');
    }
  }

  /// A product the server would not delete because it is still in use ([why] is its reason, in words): say so, and
  /// offer to make it inactive instead (out of every picker, history kept). An inactive one only hears why.
  Future<void> _offerInactive(ProductRecord p, String why) async {
    final canDeactivate = p.isActive;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        title: 'This product is still in use',
        subtitle: p.name,
        icon: Icons.inventory_2_outlined,
        width: 500,
        body: Text(
          canDeactivate ? why : '$why It is inactive already.',
          style: const TextStyle(fontSize: 14, height: 1.4, color: DashUi.slate),
        ),
        actions: [
          if (canDeactivate) ...[
            AppButton.ghost('Keep it', () => Navigator.pop(ctx, false)),
            AppButton.ink('Make inactive', () => Navigator.pop(ctx, true), autofocus: true),
          ] else
            AppButton.ink('OK', () => Navigator.pop(ctx, false), autofocus: true),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final id = widget.productId;
    try {
      final saver = widget.saver ??
          (int? id, Map<String, dynamic> f, String? at, {bool confirmDuplicate = false}) =>
              LineItemsApi.updateProduct(id!, f, expectedUpdatedAt: at, confirmDuplicate: confirmDuplicate);
      final saved = await saver(id, const {'isActive': false}, _page?.product.updatedAt);
      if (!mounted) return;
      productCatalogChanged.value++;
      setState(() {
        _page = (product: saved, stock: _page?.stock, canSeeCost: _canSeeCost, canEdit: _canEdit, inventoryConflict: _page?.inventoryConflict);
        _fill(saved);
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('${p.name} is inactive now: it is no longer offered on new estimates and jobs, and keeps its history.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } on LineItemsException catch (e) {
      if (!mounted) return;
      setState(() {
        _saveError = e.message;
        _conflict = e.status == 409;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _saveError = 'Could not make the product inactive. Try again.');
    }
  }

  // ---- moving around ----------------------------------------------------------

  void _go(String location) {
    final router = GoRouter.maybeOf(context);
    if (router != null) router.go(location);
  }

  void _toList() {
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      router.go('/inventory/catalog');
    } else {
      Navigator.maybePop(context);
    }
  }

  Future<void> _cancelEdit() async {
    if (_changed && !await _askDiscard()) return;
    if (!mounted) return;
    if (_isNew) {
      _toList();
      return;
    }
    setState(_dropEdits);
  }

  /// Back to the product as saved (call inside setState). A new product's form goes back to blank and stays open.
  void _dropEdits() {
    _editing = _isNew;
    _saveError = null;
    _conflict = false;
    final p = _page?.product;
    if (p != null) _fill(p);
  }

  // ---- build ------------------------------------------------------------------
  //
  // Phase 1 redesign (2026-11-16; pieces in widgets/catalog_kit.dart): a header with the product's name, status and
  // identifiers, then two balanced columns: what the product IS on the left (descriptions, vendors), what it COSTS and
  // what is ON HAND in a rail on the right (pricing with the margin, stock, pay). Editing keeps the same two columns, so
  // nothing moves when Edit is pressed. Empty fields are left out of the read view instead of showing dashes.

  static const _maxContent = 1440.0;

  /// How wide the left column's content is (set as the page lays out), so its fields can sit four to a row when they fit.
  double _mainWidth = 0;

  @override
  Widget build(BuildContext context) {
    final p = _page?.product;
    return Scaffold(
      backgroundColor: Colors.white,
      body: CallbackShortcuts(
        bindings: {
          // Ctrl+S (Cmd+S) saves while editing, as in any editor.
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): _shortcutSave,
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _shortcutSave,
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppRibbon(
              title: 'PRODUCT',
              // The name is the page's own heading below, so the ribbon only says where it sits (up to 154 characters
              // of name in capitals was hard to read there).
              kind: _isNew ? 'NEW' : ((p?.category ?? '').isEmpty ? null : p!.category.toUpperCase()),
              icon: accessIcon('catalog'),
              compactSide: 16,
              controls: _controls(),
            ),
            Expanded(child: PageSheet(child: _body0())),
          ],
        ),
      ),
    );
  }

  void _shortcutSave() {
    if (_editing && !_saving && (_isNew || _changed)) _save();
  }

  List<Widget> _controls() {
    const gap = SizedBox(width: 8);
    final back = RibbonGhostButton(icon: Icons.arrow_back_rounded, label: 'All products', onPressed: () => LeaveGuard.leave(_toList));
    if (_page == null) return [back];
    if (_editing) {
      return [
        RibbonGhostButton(icon: Icons.close_rounded, label: 'Cancel', onPressed: _saving ? null : _cancelEdit),
        gap,
        PageBanner.button(
          icon: Icons.check_rounded,
          label: _saving ? 'Saving...' : (_isNew ? 'Add product' : 'Save'),
          onPressed: _saving || (!_isNew && !_changed) ? null : _save,
        ),
      ];
    }
    return [
      back,
      if (_canEdit) ...[
        gap,
        PageBanner.button(icon: Icons.edit_rounded, label: 'Edit', onPressed: () => setState(() => _editing = true)),
        gap,
      ],
      // Delete is the rare, destructive one: under More, as on Job detail (Product Catalog > Delete).
      if (!_isNew && AuthSession.instance.can('catalog', AccessAction.delete)) ...[
        gap,
        PageBanner.more(
          items: [BannerMenuItem(icon: Icons.delete_outline_rounded, label: 'Delete', onPressed: _delete, danger: true)],
        ),
      ],
    ];
  }

  Widget _body0() {
    if (_loading) return const _DetailSkeleton();
    if (_error != null && _page == null) {
      final gone = _errorStatus == 404;
      return Center(
        child: FlatEmpty(
          icon: gone ? Icons.search_off_rounded : Icons.cloud_off_rounded,
          title: gone ? 'That product is not in the catalog' : 'Could not load the product',
          message: _error!,
          action: gone ? AppButton.ink('Back to the catalog', _toList) : AppButton.ink('Try again', _load),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        final width = c.maxWidth.clamp(0.0, _maxContent);
        final two = width >= 980;
        final rail = (width * 0.36).clamp(360.0, 480.0);
        final side = width < 600 ? 16.0 : 28.0;
        _mainWidth = (two ? width - rail : width) - side * 2;
        final main = _editing ? _editMain(side) : _readMain(side);
        final railBody = _editing ? _editRail(side) : _readRail(side);
        // Bands run the full width of the sheet (so their rules do too); what is in them is centred at most _maxContent wide.
        Widget band(Widget child) => Center(
          child: SizedBox(width: width, child: child),
        );
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_saveError != null || _errors.isNotEmpty) band(_notice(side)),
              DecoratedBox(
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: DashUi.line)),
                ),
                child: band(_editing ? _editHeader(side) : _readHeader(side)),
              ),
              band(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (two)
                      Stack(
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: main),
                              SizedBox(width: rail, child: railBody),
                            ],
                          ),
                          // The rail's edge runs the full height of the two columns, however long either one is.
                          Positioned(
                            top: 0,
                            bottom: 0,
                            right: rail,
                            child: const SizedBox(width: 1, child: ColoredBox(color: DashUi.line)),
                          ),
                        ],
                      )
                    else ...[
                      main,
                      Container(
                        decoration: const BoxDecoration(
                          border: Border(top: BorderSide(color: DashUi.line)),
                        ),
                        child: railBody,
                      ),
                    ],
                    const SizedBox(height: 28),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---- shared pieces ------------------------------------------------------------

  Widget _notice(double side) {
    final fields = _errors.length;
    final message = _saveError ?? (fields == 1 ? 'One field needs a fix before this can be saved.' : '$fields fields need a fix before this can be saved.');
    final warn = _conflict || _saveError == null;
    final fg = warn ? AppTheme.notesText : DashUi.redText;
    return Container(
      margin: EdgeInsets.fromLTRB(side, 16, side, 0),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: warn ? AppTheme.notesBg : DashUi.red.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: warn ? AppTheme.notesStroke : DashUi.red.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(_conflict ? Icons.sync_problem_rounded : Icons.error_outline_rounded, size: 20, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: fg, fontSize: 14, fontWeight: FontWeight.w600, height: 1.35),
            ),
          ),
          if (_conflict)
            TextButton(
              // Reloading puts the saved product back in every box, so typed changes ask first (they were dropped
              // without a word; audit round 2, 2026-11-20).
              onPressed: () async {
                if (_changed && !await _askDiscard(why: 'Reloading shows the product as it is saved now, and your changes are lost.')) return;
                if (!mounted) return;
                setState(() => _editing = false);
                _load();
              },
              style: TextButton.styleFrom(
                foregroundColor: DashUi.ink,
                textStyle: const TextStyle(fontFamily: AppTheme.fontFamily, fontFamilyFallback: AppTheme.fontFamilyFallback, fontWeight: FontWeight.w700),
              ),
              child: const Text('Reload product'),
            ),
        ],
      ),
    );
  }

  /// A block in either column: a small-caps label, then its content.
  Widget _section(String label, Widget child, {double side = 28, String? note, double top = 22}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(side, top, side, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CatalogLabel(label, note: note),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  /// A thin rule between the rail's blocks.
  Widget _rule(double side) => Padding(
    padding: EdgeInsets.fromLTRB(side, 22, side, 0),
    child: const Divider(height: 1, color: DashUi.line),
  );

  /// Children in [columns] equal columns, [gap] apart, wrapping into further rows.
  Widget _grid(List<Widget> children, {int columns = 2, double gap = 16, double runGap = 16}) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += columns) {
      final slice = children.sublist(i, (i + columns).clamp(0, children.length));
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var j = 0; j < columns; j++) ...[if (j > 0) SizedBox(width: gap), Expanded(child: j < slice.length ? slice[j] : const SizedBox())],
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++) ...[if (i > 0) SizedBox(height: runGap), rows[i]],
      ],
    );
  }

  /// A figure to read: its label, then the value ([big] for the price and the stock).
  Widget _value(String label, String value, {bool quiet = false, bool big = false, Color? tone, String? note, Key? key}) {
    final style = big
        ? TextStyle(
            fontSize: quiet ? 17 : 28,
            fontWeight: quiet ? FontWeight.w600 : FontWeight.w700,
            color: tone ?? (quiet ? DashUi.slate : DashUi.ink),
            letterSpacing: quiet ? 0 : -0.5,
            height: 1.2,
            fontFeatures: CatalogUi.figures,
          )
        : TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: tone ?? (quiet ? DashUi.slate : DashUi.ink),
            height: 1.3,
            fontFeatures: CatalogUi.figures,
          );
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.slate),
        ),
        const SizedBox(height: 4),
        Text(value, style: quiet && !big ? style.copyWith(fontWeight: FontWeight.w500) : style),
        if (note != null) ...[const SizedBox(height: 3), Text(note, style: CatalogUi.meta)],
      ],
    );
  }

  double? _numberIn(String key) => double.tryParse(_c[key]!.text.replaceAll(RegExp(r'[\$,\s]'), ''));

  /// A money field for reading: [empty] when there is none (blank, or 0 for the price list's "none"), else the exact amount.
  String _viewMoney(String key, String empty) {
    final n = _numberIn(key);
    return n == null || n == 0 ? empty : _preciseMoney(n);
  }

  // ---- reading ------------------------------------------------------------------

  Widget _readHeader(double side) {
    final p = _page!.product;
    final at = DateTime.tryParse(p.updatedAt ?? '')?.toLocal();
    final by = p.updatedBy ?? '';
    // Without a name it came in with the price list and has not been edited here.
    final changed = at == null
        ? null
        : (by.isEmpty
              ? 'From the price list, loaded ${DateFormat('MMM d, yyyy').format(at)}'
              : 'Last changed by $by on ${DateFormat('MMM d, yyyy').format(at)}');
    final ids = <(String?, String)>[
      if (p.category.isNotEmpty) (null, p.category),
      if (p.partNumber.isNotEmpty) ('Part #', p.partNumber),
      if (p.sku.isNotEmpty && p.sku != p.partNumber) ('SKU', p.sku),
      if (p.model.isNotEmpty) ('Model', p.model),
      if (p.productType.isNotEmpty) ('Type', p.productType),
    ];
    return Padding(
      padding: EdgeInsets.fromLTRB(side, 22, side, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text.rich(
            catalogNameSpan(p.name, const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: DashUi.ink, letterSpacing: -0.3, height: 1.25)),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _active
                  ? const CatalogTag('Active', tone: CatalogTone.good, icon: Icons.check_circle_rounded)
                  : const CatalogTag('Inactive', icon: Icons.pause_circle_outline_rounded),
              if (_invItem) const CatalogTag('Inventory item', tone: CatalogTone.info, icon: Icons.inventory_2_outlined),
              for (final (label, value) in ids)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (label != null) Text('$label ', style: const TextStyle(fontSize: 13.5, color: DashUi.slate)),
                    Text(
                      value,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: label == null ? FontWeight.w700 : FontWeight.w600,
                        color: DashUi.ink,
                        fontFeatures: CatalogUi.figures,
                      ),
                    ),
                  ],
                ),
              if (changed != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.history_rounded, size: 15, color: DashUi.subtle),
                    const SizedBox(width: 4),
                    Text(changed, style: CatalogUi.meta),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _readMain(double side) {
    final description = _c['description']!.text.trim();
    final ordering = _c['purchaseDescription']!.text.trim();
    final related = _c['relatedProducts']!.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(
          'DESCRIPTION',
          Text(description.isEmpty ? 'No description entered.' : description, style: description.isEmpty ? CatalogUi.cellQuiet : CatalogUi.body),
          side: side,
        ),
        if (ordering.isNotEmpty) _section('ORDERING NOTE', Text(ordering, style: CatalogUi.body), side: side),
        if (related.isNotEmpty) _section('RELATED PRODUCTS', Text(related, style: CatalogUi.body), side: side),
        if (_canSeeCost) _section('VENDORS', _vendorTable(), side: side),
      ],
    );
  }

  /// Where it is bought: a small table of vendor and purchase price, the primary one marked.
  Widget _vendorTable() {
    final named = [
      for (var i = 0; i < 3; i++)
        if (_c['v${i}Name']!.text.trim().isNotEmpty) i,
    ];
    if (named.isEmpty) return const Text('No vendors entered.', style: CatalogUi.cellQuiet);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: DashUi.line),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: DashUi.line)),
            ),
            child: const Row(
              children: [
                Expanded(child: Text('VENDOR', style: CatalogUi.head)),
                Text('PURCHASE PRICE', style: CatalogUi.head),
              ],
            ),
          ),
          for (var r = 0; r < named.length; r++)
            Container(
              constraints: const BoxConstraints(minHeight: 40),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              color: r.isOdd ? CatalogUi.stripe : Colors.white,
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(child: Text(_c['v${named[r]}Name']!.text.trim(), style: CatalogUi.cellStrong)),
                        if (named[r] == 0) ...[const SizedBox(width: 8), const CatalogTag('Primary')],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(_viewMoney('v${named[r]}Price', '—'), style: CatalogUi.cell),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _readRail(double side) {
    final price = _numberIn('unitPrice');
    final perJob = price == null || price == 0;
    final margin = _canSeeCost ? catalogMargin(_numberIn('unitPrice'), _numberIn('avgUnitCost')) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(
          'PRICING',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _value('Price', perJob ? 'No price' : _viewMoney('unitPrice', ''), big: true, quiet: perJob),
              const SizedBox(height: 16),
              _grid([
                _value('Member price', _viewMoney('memberPrice', 'Not set'), quiet: (_numberIn('memberPrice') ?? 0) == 0),
                if (_canSeeCost) _value('Unit cost', _viewMoney('avgUnitCost', 'Not entered'), quiet: (_numberIn('avgUnitCost') ?? 0) == 0),
              ]),
              if (margin != null) ...[const SizedBox(height: 18), _marginBlock(margin, price!, _numberIn('avgUnitCost')!)],
            ],
          ),
          side: side,
        ),
        _rule(side),
        _section('STOCK', _stock(), side: side),
        if (_canSeeCost) ...[_rule(side), _section('COMMISSION AND PAY', _payRead(), side: side)],
      ],
    );
  }

  /// The margin, from a real price AND a real cost (never made up), with a bar of cost against price.
  Widget _marginBlock(({double pct, bool above, bool even}) m, double price, double cost) {
    final tone = catalogMarginTone(m.pct);
    final per = price - cost;
    final note = m.above ? 'Cost is above the price' : (m.even ? 'Cost equals the price' : '${_preciseMoney(per)} per unit');
    final costShare = (cost / (m.above ? cost : price)).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Text(
              'Margin',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.slate),
            ),
            const Spacer(),
            Text(
              note,
              style: CatalogUi.meta.copyWith(color: m.pct <= 0 ? DashUi.redText : DashUi.slate, fontWeight: m.pct <= 0 ? FontWeight.w600 : FontWeight.w400),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${m.pct.toStringAsFixed(0)}%',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: tone, fontFeatures: CatalogUi.figures),
        ),
        const SizedBox(height: 8),
        // Cost (slate) against the price; what is left of the bar is the margin (emerald), or all red when the cost is above.
        Semantics(
          label: 'Cost is ${(cost / price * 100).toStringAsFixed(0)} percent of the price',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 8,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: costShare),
                duration: CatalogUi.motion(context, 520),
                curve: Curves.easeOutCubic,
                builder: (_, v, _) => Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: (v * 1000).round().clamp(1, 1000),
                      child: ColoredBox(color: m.pct <= 0 ? DashUi.red : DashUi.slate),
                    ),
                    if (v < 1)
                      Expanded(
                        flex: ((1 - v) * 1000).round().clamp(1, 1000),
                        child: const ColoredBox(color: DashUi.emerald),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// In stock, or why it can't be shown (the inventory row needs a person to sort it out).
  Widget _stock() {
    final conflict = _page?.inventoryConflict;
    if (conflict != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CatalogTag('Needs review', tone: CatalogTone.warn, icon: Icons.error_outline_rounded),
          const SizedBox(height: 8),
          Text(inventoryConflictText(conflict), style: CatalogUi.meta.copyWith(fontSize: 13.5)),
        ],
      );
    }
    final stock = _page?.stock;
    if (stock == null) return _value('In stock', 'Not in inventory', quiet: true, big: true);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _value('In stock', _count.format(stock), big: true, tone: stock > 0 ? null : DashUi.slate),
        const SizedBox(width: 10),
        Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: Text(stock == 1 ? 'unit on hand' : 'units on hand', style: CatalogUi.meta),
        ),
      ],
    );
  }

  Widget _payRead() {
    final lines = <(String, String)>[];
    String pct(String key) => '${_c[key]!.text.trim()}%';
    if (_paysCommission) {
      final parts = [
        if ((_numberIn('fixedCommission') ?? 0) > 0) _viewMoney('fixedCommission', ''),
        if ((_numberIn('percentCommission') ?? 0) > 0) pct('percentCommission'),
      ];
      lines.add(('Commission', parts.isEmpty ? 'Yes' : parts.join(' + ')));
    }
    if (_paysBonus) {
      final parts = [if ((_numberIn('fixedBonus') ?? 0) > 0) _viewMoney('fixedBonus', ''), if ((_numberIn('percentBonus') ?? 0) > 0) pct('percentBonus')];
      lines.add(('Bonus', parts.isEmpty ? 'Yes' : parts.join(' + ')));
    }
    if ((_numberIn('paysHours') ?? 0) > 0) lines.add(('Labor hours', _c['paysHours']!.text.trim()));
    if (lines.isEmpty) return const Text('None set.', style: CatalogUi.cellQuiet);
    return Column(
      children: [
        for (final (label, value) in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(label, style: const TextStyle(fontSize: 14, color: DashUi.slate)),
                ),
                Text(value, style: CatalogUi.cellStrong),
              ],
            ),
          ),
      ],
    );
  }

  // ---- editing --------------------------------------------------------------------

  Widget _editHeader(double side) {
    return Padding(
      padding: EdgeInsets.fromLTRB(side, 18, side, 16),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: CatalogUi.picked, borderRadius: BorderRadius.circular(10)),
            child: Icon(_isNew ? Icons.add_rounded : Icons.edit_rounded, size: 18, color: DashUi.ink),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isNew ? 'New product' : 'Editing ${_page?.product.name ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: DashUi.ink),
                ),
                const SizedBox(height: 2),
                const Text('Saved to our own price list only. Service Fusion is never changed.', style: CatalogUi.meta),
              ],
            ),
          ),
          if (!_isNew)
            AnimatedOpacity(
              opacity: _changed ? 1 : 0,
              duration: CatalogUi.motion(context),
              child: const CatalogTag('Unsaved changes', tone: CatalogTone.warn),
            ),
        ],
      ),
    );
  }

  Widget _editMain(double side) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(
          'PRODUCT',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _field('name', 'Product name', required: true),
              const SizedBox(height: 16),
              _categoryField(),
              const SizedBox(height: 16),
              _grid([
                _field('partNumber', 'Part number'),
                _field('sku', 'SKU'),
                _field('model', 'Model'),
                _field('productType', 'Type'),
              ], columns: _mainWidth >= 720 ? 4 : 2),
            ],
          ),
          side: side,
        ),
        _section(
          'DESCRIPTIONS',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _field('description', 'Description', lines: 3),
              const SizedBox(height: 16),
              _field('purchaseDescription', 'Ordering note', lines: 2, help: 'What the person ordering this needs to know.'),
              const SizedBox(height: 16),
              _field('relatedProducts', 'Related products', lines: 2),
            ],
          ),
          side: side,
        ),
        if (_canSeeCost) _section('VENDORS', _vendorFields(), side: side, note: 'The first is the primary vendor.'),
      ],
    );
  }

  Widget _editRail(double side) {
    final margin = _canSeeCost ? catalogMargin(_numberIn('unitPrice'), _numberIn('avgUnitCost')) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(
          'PRICING',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Empty (0 in the price list) reads as the list says it: per job / not set / not entered, never $0.00.
              _field('unitPrice', 'Price', money: true, empty: 'No price'),
              const SizedBox(height: 16),
              _grid([
                _field('memberPrice', 'Member price', money: true, empty: 'Not set'),
                if (_canSeeCost) _field('avgUnitCost', 'Unit cost', money: true, empty: 'Not entered'),
              ]),
              // The margin follows what is typed, so a price under the cost is seen before it is saved.
              AnimatedSize(
                duration: CatalogUi.motion(context, 200),
                alignment: Alignment.topCenter,
                child: margin == null
                    ? const SizedBox(width: double.infinity)
                    : Padding(padding: const EdgeInsets.only(top: 18), child: _marginBlock(margin, _numberIn('unitPrice')!, _numberIn('avgUnitCost')!)),
              ),
            ],
          ),
          side: side,
        ),
        _rule(side),
        _section(
          'STATUS',
          Column(
            children: [
              _switchRow(
                'Active',
                'Inactive products stay on the price list but are never offered when adding lines to an estimate or job.',
                _active,
                (v) => setState(() => _active = v),
              ),
              const SizedBox(height: 6),
              _switchRow('Inventory item', 'Kept in the warehouse inventory.', _invItem, (v) => setState(() => _invItem = v)),
            ],
          ),
          side: side,
        ),
        if (_canSeeCost) ...[_rule(side), _section('COMMISSION AND PAY', _payFields(), side: side)],
      ],
    );
  }

  /// A labelled text box. Its key is `field:<name>`, so tests and tools find it by what it is, not by its place.
  Widget _field(String key, String label, {int lines = 1, bool money = false, bool percent = false, bool required = false, String? empty, String? help}) {
    final ctl = _c[key]!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppFieldLabel(required ? '$label *' : label, help: help),
        TextField(
          key: ValueKey('field:$key'),
          controller: ctl,
          minLines: lines,
          maxLines: lines,
          enabled: !_saving,
          style: TextStyle(fontSize: 14.5, color: DashUi.ink, fontFeatures: money || percent ? CatalogUi.figures : null),
          keyboardType: money || percent ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
          inputFormatters: money || percent ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,$]'))] : null,
          decoration:
              appFieldDecoration(
                error: _errors[key],
                prefixText: money ? '\$ ' : null,
                // An empty price box says what empty means (priced per job, not set, not entered).
                hint: percent ? 'Percent' : (money ? empty : null),
              ).copyWith(
                suffixText: percent ? '%' : null,
                suffixStyle: const TextStyle(fontSize: 14, color: DashUi.slate),
              ),
        ),
      ],
    );
  }

  final _categoryFocus = FocusNode(debugLabel: 'product-category');

  /// The categories to pick from: the server's list with product counts, or (from a server older than Phase 3) the
  /// names the Product Catalog list last loaded.
  Future<Map<String, int?>> _loadCategories() async {
    if (widget.categoriesLoader != null) return widget.categoriesLoader!();
    try {
      final r = await LineItemsApi.listCategories();
      return {for (final c in r.categories) c.name: c.products};
    } on LineItemsException catch (e) {
      if (e.status == 404 && e.code == null && productCategories.value.isNotEmpty) return {for (final n in productCategories.value) n: null};
      rethrow;
    }
  }

  Future<void> _pickCategory() async {
    final pick = await showCategoryPickerDialog(
      context,
      current: _c['category']!.text.trim(),
      load: _loadCategories,
      pendingNew: _newCategory,
      canCreate: AuthSession.instance.can('catalog', AccessAction.create),
    );
    if (pick == null || !mounted) return;
    _newCategory = pick.isNew ? pick.name : null;
    _c['category']!.text = pick.name; // its listener rebuilds the page (and the Save and leave checks see the change)
    setState(() => _errors = {..._errors}..remove('category'));
    _categoryFocus.requestFocus();
  }

  /// Category: picked from the catalog's categories (searchable). A new category is only made when the person chooses
  /// "Create ..." in the picker, so a typo never quietly starts one (2026-11-18; it used to be free text).
  Widget _categoryField() {
    final value = _c['category']!.text.trim();
    final isNew = _newCategory != null && value == _newCategory;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppFieldLabel('Category'),
        Semantics(
          button: true,
          label: 'Category: ${value.isEmpty ? 'none' : value}${isNew ? ', a new category' : ''}. Pick a category',
          excludeSemantics: true,
          child: InkWell(
            mouseCursor: WidgetStateMouseCursor.clickable,
            key: const ValueKey('field:category'),
            focusNode: _categoryFocus,
            onTap: _saving ? null : _pickCategory,
            borderRadius: BorderRadius.circular(10),
            child: InputDecorator(
              isEmpty: value.isEmpty,
              isFocused: _categoryFocus.hasFocus,
              decoration: appFieldDecoration(
                error: _errors['category'],
                hint: 'No category',
              ).copyWith(suffixIcon: const Icon(Icons.expand_more_rounded, size: 20, color: DashUi.slate), enabled: !_saving),
              child: Row(
                children: [
                  Flexible(
                    child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5, color: DashUi.ink)),
                  ),
                  if (isNew) ...[const SizedBox(width: 8), const CatalogTag('New category', tone: CatalogTone.info, icon: Icons.add_rounded)],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// A switch with its name and what it means; the whole row toggles it.
  Widget _switchRow(String label, String help, bool value, ValueChanged<bool> onChanged) {
    return Semantics(
      toggled: value,
      label: label,
      child: InkWell(
        mouseCursor: WidgetStateMouseCursor.clickable,
        borderRadius: BorderRadius.circular(10),
        onTap: _saving ? null : () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: DashUi.ink),
                    ),
                    const SizedBox(height: 2),
                    Text(help, style: const TextStyle(fontSize: 13, height: 1.35, color: DashUi.slate)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ExcludeSemantics(
                child: CatalogSwitch(value: value, onChanged: _saving ? null : onChanged),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _vendorFields() {
    const ranks = ['Primary', 'Second', 'Third'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 82, bottom: 6),
          child: Row(
            children: [
              Expanded(child: Text('VENDOR', style: CatalogUi.head)),
              SizedBox(width: 12),
              SizedBox(width: 160, child: Text('PURCHASE PRICE', style: CatalogUi.head)),
            ],
          ),
        ),
        for (var i = 0; i < 3; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 82,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 13),
                    child: Text(
                      ranks[i],
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.slate),
                    ),
                  ),
                ),
                Expanded(child: _bareField('v${i}Name', semantic: '${ranks[i]} vendor')),
                const SizedBox(width: 12),
                SizedBox(width: 160, child: _bareField('v${i}Price', money: true, semantic: '${ranks[i]} vendor purchase price')),
              ],
            ),
          ),
      ],
    );
  }

  /// A text box without a label above it (the vendor table's cells), named for screen readers.
  Widget _bareField(String key, {bool money = false, required String semantic}) {
    return Semantics(
      label: semantic,
      child: TextField(
        key: ValueKey('field:$key'),
        controller: _c[key],
        enabled: !_saving,
        style: TextStyle(fontSize: 14.5, color: DashUi.ink, fontFeatures: money ? CatalogUi.figures : null),
        keyboardType: money ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
        inputFormatters: money ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,$]'))] : null,
        decoration: appFieldDecoration(error: _errors[key], prefixText: money ? '\$ ' : null),
      ),
    );
  }

  Widget _payFields() {
    final showCommission = _paysCommission || _c['fixedCommission']!.text.trim().isNotEmpty || _c['percentCommission']!.text.trim().isNotEmpty;
    final showBonus = _paysBonus || _c['fixedBonus']!.text.trim().isNotEmpty || _c['percentBonus']!.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _switchRow('Pays commission', 'Selling it earns the salesperson a commission.', _paysCommission, (v) => setState(() => _paysCommission = v)),
        AnimatedSize(
          duration: CatalogUi.motion(context, 200),
          alignment: Alignment.topCenter,
          child: showCommission
              ? Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 6),
                  child: _grid([_field('fixedCommission', 'Fixed commission', money: true), _field('percentCommission', 'Commission percent', percent: true)]),
                )
              : const SizedBox(width: double.infinity),
        ),
        const SizedBox(height: 6),
        _switchRow('Pays bonus', 'Selling or installing it earns a bonus.', _paysBonus, (v) => setState(() => _paysBonus = v)),
        AnimatedSize(
          duration: CatalogUi.motion(context, 200),
          alignment: Alignment.topCenter,
          child: showBonus
              ? Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 6),
                  child: _grid([_field('fixedBonus', 'Fixed bonus', money: true), _field('percentBonus', 'Bonus percent', percent: true)]),
                )
              : const SizedBox(width: double.infinity),
        ),
        const SizedBox(height: 14),
        _field('paysHours', 'Pays hours', help: 'Hours of labor credited.'),
      ],
    );
  }
}

/// The product page while it loads: its header and two columns, pulsing (still with reduced motion).
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
      label: 'Loading the product',
      liveRegion: true,
      child: SkeletonPulse(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 26, 28, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              bar(420, 20),
              const SizedBox(height: 14),
              Wrap(spacing: 10, runSpacing: 8, children: [bar(64, 18), bar(110, 18), bar(140)]),
              const SizedBox(height: 34),
              // The rail only where the page has two columns.
              LayoutBuilder(
                builder: (context, c) => Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [bar(90), const SizedBox(height: 14), bar(520), const SizedBox(height: 10), bar(460), const SizedBox(height: 10), bar(380)],
                      ),
                    ),
                    if (c.maxWidth >= 900) ...[
                      const SizedBox(width: 40),
                      SizedBox(
                        width: 360,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            bar(70),
                            const SizedBox(height: 14),
                            bar(150, 26),
                            const SizedBox(height: 18),
                            bar(260),
                            const SizedBox(height: 10),
                            bar(220),
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
