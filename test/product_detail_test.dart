// A product's own page: reading it, editing and saving it, adding a new one, and deleting it.

import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/product_detail_screen.dart';
import 'package:iohd_desktop/services/line_items_api.dart';
import 'package:iohd_desktop/theme/app_theme.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

final _theme = ThemeData(
  useMaterial3: true,
  fontFamily: 'Segoe UI',
  colorScheme: ColorScheme.fromSeed(seedColor: AppTheme.brandRed, primary: AppTheme.brandRed),
);

const _bearing = ProductRecord(
  id: 1,
  name: 'Bearing RC | Steel | 1"',
  category: 'Bearing - RC',
  partNumber: '0140950',
  model: 'B-1',
  unitPrice: 2.66,
  memberPrice: 2.4,
  avgUnitCost: 0.87,
  isInventoryItem: true,
  purchaseDescription: 'Door Thickness 1.75" and 2"',
  description: 'Steel bearing for torsion tubes',
  vendors: [(name: 'iStore', price: 0.95)],
  paysCommission: true,
  percentCommission: 5,
  updatedAt: '2026-11-16T15:00:00.000Z',
  updatedBy: 'Heather',
);

ProductPage _page({bool canSeeCost = true, bool canEdit = true, int? stock = 65, ProductRecord product = _bearing, String? conflict}) =>
    (product: product, stock: stock, canSeeCost: canSeeCost, canEdit: canEdit, inventoryConflict: conflict);

Future<void> _pump(WidgetTester t, ProductDetailScreen screen, {Size size = const Size(1366, 900)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(RepaintBoundary(key: const ValueKey('shot'), child: MaterialApp(debugShowCheckedModeBanner: false, theme: _theme, home: screen)));
  await t.pumpAndSettle();
}

/// The Nth text field, in page order.
/// A form box by what it is (the page keys every box `field:<name>`), so the two-column layout can order them freely.
Finder _field(String name) => find.byKey(ValueKey('field:$name'));

/// The catalog's categories as the picker gets them (name -> products).
const _cats = <String, int?>{'Bearing - RC': 4, 'Keypad': 14, 'Overhead Door': 9, 'Mine': 1, 'Something else': 2};
Future<Map<String, int?>> _catLoader() async => _cats;

/// Picks the existing category [name] in the category picker.
Future<void> _pickCategory(WidgetTester t, String name) async {
  await t.tap(_field('category'));
  await t.pumpAndSettle();
  await t.enterText(find.widgetWithText(TextField, 'Find a category, or type a new one'), name);
  await t.pumpAndSettle();
  await t.tap(find.byKey(ValueKey('pick-category:$name')));
  await t.pumpAndSettle();
  await t.tap(find.text('Use this category'));
  await t.pumpAndSettle();
}

/// The text field under the label [label].

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf']);
    await _loadFont('MaterialIcons', ['C:/src/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  });

  testWidgets('reads like a page: details, costs, stock, who changed it; no fields until Edit', (t) async {
    await _pump(t, ProductDetailScreen(productId: 1, loader: (_) async => _page()));
    expect(find.text('Bearing RC | Steel | 1"'), findsWidgets);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('\$2.66'), findsOneWidget);
    expect(find.text('\$0.87'), findsOneWidget);
    expect(find.text('Margin'), findsOneWidget);
    expect(find.text('65'), findsOneWidget);
    expect(find.text('iStore'), findsOneWidget); // the vendor table: the vendor, then its purchase price
    expect(find.text('\$0.95'), findsOneWidget);
    expect(find.textContaining('Last changed by Heather'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('without the costs switch: no cost, vendors or pay anywhere on the page', (t) async {
    final noCost = ProductRecord(id: 1, name: 'Bearing', unitPrice: 2.66, updatedAt: _bearing.updatedAt);
    await _pump(t, ProductDetailScreen(productId: 1, loader: (_) async => _page(canSeeCost: false, product: noCost)));
    for (final hidden in ['Unit cost', 'Margin', 'VENDORS', 'COMMISSION AND PAY', 'PURCHASE PRICE']) {
      expect(find.text(hidden), findsNothing, reason: hidden);
    }
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    expect(find.text('Unit cost'), findsNothing);
  });

  testWidgets('someone who cannot edit gets no Edit or Delete', (t) async {
    await _pump(t, ProductDetailScreen(productId: 1, loader: (_) async => _page(canEdit: false)));
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Delete'), findsNothing);
    expect(find.text('All products'), findsOneWidget);
  });

  testWidgets('Edit, change the price and name, Save: sends just those two fields and shows the saved product', (t) async {
    Map<String, dynamic>? sent;
    String? sentAt;
    final before = productCatalogChanged.value;
    await _pump(
      t,
      ProductDetailScreen(
        productId: 1,
        loader: (_) async => _page(),
        saver: (id, fields, at, {confirmDuplicate = false}) async {
          sent = fields;
          sentAt = at;
          return ProductRecord(id: id, name: fields['name'] as String, unitPrice: fields['unitPrice'] as double?, updatedAt: '2026-11-17T09:00:00.000Z', updatedBy: 'Me');
        },
      ),
    );
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    expect(find.text('Save'), findsOneWidget);
    // Save is off until something changed.
    expect(t.widget<FilledButton>(find.ancestor(of: find.text('Save'), matching: find.byType(FilledButton))).onPressed, isNull);

    await t.enterText(_field('name'), 'Bearing RC | Steel | 1" (new)');
    await t.enterText(_field('unitPrice'), '3.10');
    await t.pumpAndSettle();
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();

    // Only what changed goes to the server: untouched fields (cost, vendors, flags...) are never rewritten.
    expect(sent, {'name': 'Bearing RC | Steel | 1" (new)', 'unitPrice': 3.1});
    expect(sentAt, '2026-11-16T15:00:00.000Z'); // what the page loaded with, so a clash is noticed
    expect(find.byType(TextField), findsNothing); // back to reading
    expect(find.text('\$3.10'), findsOneWidget);
    expect(find.text('Saved'), findsOneWidget);
    expect(productCatalogChanged.value, before + 1);
  });

  testWidgets('a bad number stops the save and says which field', (t) async {
    var calls = 0;
    await _pump(t, ProductDetailScreen(productId: 1, loader: (_) async => _page(), saver: (id, f, at, {confirmDuplicate = false}) async {
      calls++;
      return _bearing;
    }));
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    await t.enterText(_field('unitPrice'), '1.2.3');
    await t.pumpAndSettle();
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(calls, 0);
    expect(find.textContaining('The price must be a number'), findsOneWidget);
  });

  testWidgets('Cancel with changes asks; Discard puts the saved values back', (t) async {
    await _pump(t, ProductDetailScreen(productId: 1, loader: (_) async => _page(), categoriesLoader: _catLoader));
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    await _pickCategory(t, 'Something else');
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(find.text('Discard your changes?'), findsOneWidget);
    await t.tap(find.text('Keep editing'));
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsWidgets);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    await t.tap(find.text('Discard changes'));
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Bearing - RC'), findsOneWidget);
    expect(find.text('Something else'), findsNothing);
  });

  testWidgets('a clash with someone else\'s save says so and offers a reload', (t) async {
    await _pump(
      t,
      ProductDetailScreen(
        productId: 1,
        loader: (_) async => _page(),
        saver: (id, f, at, {confirmDuplicate = false}) async => throw const LineItemsException('Someone else changed this product while you were editing.', status: 409),
        categoriesLoader: _catLoader,
      ),
    );
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    await _pickCategory(t, 'Mine');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(find.textContaining('Someone else changed this product'), findsOneWidget);
    expect(find.text('Reload product'), findsOneWidget);
    expect(find.byType(TextField), findsWidgets); // their typing is still there to copy
  });

  testWidgets('a new product opens in edit, needs a name, and is created with the fields', (t) async {
    int? createdId = -1;
    Map<String, dynamic>? sent;
    await _pump(
      t,
      ProductDetailScreen(
        saver: (id, fields, at, {confirmDuplicate = false}) async {
          createdId = id;
          sent = fields;
          return ProductRecord(id: 99, name: fields['name'] as String, updatedAt: '2026-11-17T09:00:00.000Z', updatedBy: 'Me');
        },
      ),
    );
    expect(find.text('Add product'), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);
    await t.tap(find.text('Add product'));
    await t.pumpAndSettle();
    expect(find.text('Give the product a name.'), findsOneWidget);
    expect(sent, isNull);

    await t.enterText(_field('name'), 'Torsion Spring 2.25');
    await t.pumpAndSettle();
    await t.tap(find.text('Add product'));
    await t.pumpAndSettle();
    expect(createdId, isNull); // a null id is a create
    expect(sent!['name'], 'Torsion Spring 2.25');
    expect(sent!['isActive'], true);
    expect(find.text('Product added'), findsOneWidget);
  });

  testWidgets('a product that is gone says so; a failed load can be retried', (t) async {
    await _pump(t, ProductDetailScreen(productId: 5, loader: (_) async => throw const LineItemsException('That product is not in the catalog.', status: 404)));
    expect(find.text('That product is not in the catalog'), findsOneWidget);
    expect(find.text('Back to the catalog'), findsOneWidget);

    var calls = 0;
    await _pump(
      t,
      ProductDetailScreen(
        key: UniqueKey(), // a new page, not the one above
        productId: 1,
        loader: (_) async {
          if (++calls == 1) throw const LineItemsException('Could not reach the server.');
          return _page();
        },
      ),
    );
    expect(find.text('Could not load the product'), findsOneWidget);
    await t.tap(find.text('Try again'));
    await t.pumpAndSettle();
    expect(find.text('\$2.66'), findsOneWidget);
  });

  testWidgets('Delete asks first, then deletes; Cancel keeps the product', (t) async {
    final deleted = <int>[];
    await _pump(t, ProductDetailScreen(productId: 1, loader: (_) async => _page(), deleter: (id) async => deleted.add(id)));
    // Delete is under More (the rare, destructive action), as on Job detail.
    await t.tap(find.text('More'));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete'));
    await t.pumpAndSettle();
    expect(find.text('Delete this product?'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(deleted, isEmpty);
    await t.tap(find.text('More'));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete'));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete product')); // the dialog's red button
    await t.pumpAndSettle();
    expect(deleted, [1]);
  });

  testWidgets('opens straight into editing when asked (the list\'s Edit button)', (t) async {
    await _pump(t, ProductDetailScreen(productId: 1, startEditing: true, loader: (_) async => _page()));
    expect(find.byType(TextField), findsWidgets);
    expect(find.text('Save'), findsOneWidget);
  });

  testWidgets('fits a narrow window', (t) async {
    await _pump(t, ProductDetailScreen(productId: 1, startEditing: true, loader: (_) async => _page()), size: const Size(420, 800));
    expect(t.takeException(), isNull);
  });

  // ---- Phase 0: data safety ------------------------------------------------------------------------------------------

  // Keypad 878MAX as production has it: a 5-decimal average cost, no member price (0), two vendors.
  const keypad = ProductRecord(
    id: 154,
    name: 'Keypad | 878MAX | LiftMaster',
    category: 'Keypad',
    unitPrice: 51.79,
    memberPrice: 0,
    avgUnitCost: 23.32465,
    isInventoryItem: true,
    vendors: [(name: 'Chamberlain Liftmaster', price: 23.32465), (name: 'Clopay', price: 0)],
    updatedAt: '2026-11-16T15:52:00.045Z',
  );

  testWidgets('a 5-decimal cost shows every decimal, on the page and in the form', (t) async {
    await _pump(t, ProductDetailScreen(productId: 154, loader: (_) async => _page(product: keypad, stock: 24)));
    expect(find.text('\$23.32465'), findsNWidgets(2)); // Unit cost and the primary vendor's price, not $23.32
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    expect(find.widgetWithText(TextField, '23.32465'), findsNWidgets(2)); // the cost and the first vendor's price
  });

  testWidgets('editing only the description sends only the description: the 5-decimal cost is never rounded or resent', (t) async {
    Map<String, dynamic>? sent;
    await _pump(
      t,
      ProductDetailScreen(
        productId: 154,
        loader: (_) async => _page(product: keypad),
        saver: (id, fields, at, {confirmDuplicate = false}) async {
          sent = fields;
          return keypad;
        },
      ),
    );
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    final description = _field('description');
    await t.enterText(description, 'Wireless keyless entry');
    await t.pumpAndSettle();
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(sent, {'description': 'Wireless keyless entry'});
  });

  testWidgets('a typed cost goes to the server exactly as typed; more than 6 decimals is refused on the field', (t) async {
    final sent = <Map<String, dynamic>>[];
    await _pump(
      t,
      ProductDetailScreen(
        productId: 154,
        loader: (_) async => _page(product: keypad),
        saver: (id, fields, at, {confirmDuplicate = false}) async {
          sent.add(fields);
          return keypad;
        },
      ),
    );
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    final cost = _field('avgUnitCost'); // the vendor's price shows the same figure, so the box is picked by what it is
    expect(find.descendant(of: cost, matching: find.text('23.32465')), findsOneWidget);
    await t.enterText(cost, '41.1234567');
    await t.pumpAndSettle();
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(sent, isEmpty);
    expect(find.textContaining('6 decimal places'), findsOneWidget);
    await t.enterText(find.widgetWithText(TextField, '41.1234567'), '41.123456');
    await t.pumpAndSettle();
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(sent.single, {'avgUnitCost': 41.123456});
  });

  testWidgets('a per-job price, no member price and no cost read as such, never as \$0.00, and no margin is made up', (t) async {
    const door = ProductRecord(id: 263, name: 'Clopay Architectural Series | Aluminum Full-View | 904 | Complete Door', unitPrice: 0, memberPrice: 0, avgUnitCost: 6841.79);
    await _pump(t, ProductDetailScreen(productId: 263, loader: (_) async => _page(product: door, stock: 0)));
    expect(find.text('Priced per job'), findsOneWidget);
    expect(find.text('Not set'), findsOneWidget); // member price
    expect(find.text('\$0.00'), findsNothing);
    expect(find.text('Margin'), findsNothing);
    const noCost = ProductRecord(id: 5, name: 'Tek Screws', unitPrice: 0.21, avgUnitCost: 0);
    await _pump(t, ProductDetailScreen(key: UniqueKey(), productId: 5, loader: (_) async => _page(product: noCost)));
    expect(find.text('Not entered'), findsOneWidget); // unit cost
    expect(find.text('Margin'), findsNothing); // not "100%"
  });

  testWidgets('editing a per-job product without touching the price leaves it per job (the price is not sent)', (t) async {
    const door = ProductRecord(id: 263, name: 'Complete Door 904', unitPrice: 0, memberPrice: 0, avgUnitCost: 6841.79, updatedAt: '2026-11-16T15:52:00.045Z');
    Map<String, dynamic>? sent;
    await _pump(t, ProductDetailScreen(productId: 263, startEditing: true, loader: (_) async => _page(product: door), categoriesLoader: _catLoader, saver: (id, f, at, {confirmDuplicate = false}) async {
      sent = f;
      return door;
    }));
    expect(find.widgetWithText(TextField, '0.00'), findsNothing); // the price box is empty, with "Priced per job" as its hint
    expect(find.text('Priced per job'), findsOneWidget);
    await _pickCategory(t, 'Overhead Door');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(sent, {'category': 'Overhead Door'});
  });

  testWidgets('a cost above the price shows the negative margin and says so', (t) async {
    const rail = ProductRecord(id: 9, name: "Operator Rail | 8' Operator Belt & Rail | LiftMaster", unitPrice: 60.6, avgUnitCost: 240.11222);
    await _pump(t, ProductDetailScreen(productId: 9, loader: (_) async => _page(product: rail)));
    expect(find.text('-296%'), findsOneWidget);
    expect(find.text('Cost is above the price'), findsOneWidget);
  });

  testWidgets('stock that needs review says why instead of showing a number', (t) async {
    const bracket = ProductRecord(id: 16, name: 'Bottom Bracket | Commercial | LH | Sure-Stop', unitPrice: 471.55);
    await _pump(t, ProductDetailScreen(productId: 16, loader: (_) async => _page(product: bracket, stock: null, conflict: 'duplicate_name')));
    expect(find.text('Needs review'), findsOneWidget);
    expect(find.textContaining('another product has the same name'), findsOneWidget);
    expect(find.text('Not in inventory'), findsNothing);
  });

  testWidgets('saving a name another product already has asks first; Save anyway sends it again, confirmed', (t) async {
    final calls = <({Map<String, dynamic> fields, bool confirmed})>[];
    await _pump(
      t,
      ProductDetailScreen(
        productId: 1,
        loader: (_) async => _page(),
        saver: (id, fields, at, {confirmDuplicate = false}) async {
          calls.add((fields: fields, confirmed: confirmDuplicate));
          if (!confirmDuplicate) {
            throw const LineItemsException(
              'Another product already has this name: Bearing RC | Retainer | 1".',
              status: 409,
              code: 'DUPLICATE',
              duplicates: [(id: 1, name: 'Bearing RC | Retainer | 1"', partNumber: '0140844')],
            );
          }
          return _bearing;
        },
      ),
    );
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    await t.enterText(_field('name'), 'Bearing RC | Retainer | 1"');
    await t.pumpAndSettle();
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(find.text('Another product has this name'), findsOneWidget);
    expect(find.textContaining('0140844'), findsOneWidget);
    await t.tap(find.text('Save anyway'));
    await t.pumpAndSettle();
    expect(calls.map((c) => c.confirmed), [false, true]);
    expect(calls.last.fields, {'name': 'Bearing RC | Retainer | 1"'});
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('a duplicate warning can be turned down: nothing is saved and the edits stay', (t) async {
    var confirmedCalls = 0;
    await _pump(
      t,
      ProductDetailScreen(
        productId: 1,
        loader: (_) async => _page(),
        saver: (id, fields, at, {confirmDuplicate = false}) async {
          if (confirmDuplicate) confirmedCalls++;
          throw const LineItemsException('Another product already has this part number: X.', status: 409, code: 'DUPLICATE', duplicates: [(id: 2, name: 'X', partNumber: '7')]);
        },
      ),
    );
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    await t.enterText(_field('partNumber'), '7');
    await t.pumpAndSettle();
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(find.text('Another product has this part number'), findsOneWidget);
    await t.tap(find.text('Go back'));
    await t.pumpAndSettle();
    expect(confirmedCalls, 0);
    expect(find.widgetWithText(TextField, '7'), findsOneWidget);
  });

  // Not a check: writes the page's pictures (set PRODUCT_SHOTS to a folder) so they can be looked at.
  // ---- the category picker (2026-11-18): existing categories only, unless "Create" is chosen on purpose ------------

  ProductDetailScreen picking({required void Function(Map<String, dynamic> f) onSave, Future<Map<String, int?>> Function()? cats, Object? error}) => ProductDetailScreen(
    productId: 1,
    startEditing: true,
    loader: (_) async => _page(),
    categoriesLoader: cats ?? _catLoader,
    saver: (id, f, at, {confirmDuplicate = false}) async {
      onSave(f);
      if (error != null) throw error;
      return ProductRecord(id: 1, name: _bearing.name, category: f['category'] as String? ?? _bearing.category, updatedAt: '2026-11-18T10:00:00.000Z');
    },
  );

  testWidgets('the category is picked from the catalog; a typo of one asks "did you mean" before anything new is made', (t) async {
    Map<String, dynamic>? sent;
    await _pump(t, picking(onSave: (f) => sent = f));
    await t.tap(_field('category'));
    await t.pumpAndSettle();
    expect(find.text('Pick a category'), findsOneWidget);
    expect(find.byKey(const ValueKey('pick-category:Keypad')), findsOneWidget);
    expect(find.text('14'), findsOneWidget, reason: 'each category with its product count');
    await t.enterText(find.widgetWithText(TextField, 'Find a category, or type a new one'), 'Keypads');
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('pick-new-category')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('category-lookalike')), findsOneWidget);
    expect(find.textContaining('"Keypads" looks like a category the catalog already has'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('use-category:Keypad')));
    await t.pumpAndSettle();
    await t.tap(find.text('Use this category'));
    await t.pumpAndSettle();
    expect(find.descendant(of: _field('category'), matching: find.text('Keypad')), findsOneWidget);
    expect(find.text('New category'), findsNothing);
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(sent, {'category': 'Keypad'}, reason: 'an existing category, so nothing is created');
  });

  testWidgets('a new category is only made on purpose: "Create", a tag on the field, and createCategory with the save', (t) async {
    Map<String, dynamic>? sent;
    await _pump(t, picking(onSave: (f) => sent = f));
    await t.tap(_field('category'));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, 'Find a category, or type a new one'), 'Gate  Hardware');
    await t.pumpAndSettle();
    expect(find.text('Create "Gate Hardware" as a new category'), findsOneWidget);
    expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Use this category')).onPressed, isNull, reason: 'typing alone picks nothing');
    await t.tap(find.byKey(const ValueKey('pick-new-category')));
    await t.pumpAndSettle();
    expect(find.text('"Gate Hardware" becomes a new category when you save the product.'), findsOneWidget);
    await t.tap(find.text('Create and use it'));
    await t.pumpAndSettle();
    expect(find.descendant(of: _field('category'), matching: find.text('Gate Hardware')), findsOneWidget);
    expect(find.text('New category'), findsOneWidget);
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(sent, {'category': 'Gate Hardware', 'createCategory': true});
  });

  testWidgets('"No category" can be picked; a category the server does not know shows on the field', (t) async {
    final sent = <Map<String, dynamic>>[];
    await _pump(t, picking(onSave: sent.add, error: const LineItemsException('There is no category called "Mine". Pick one from the list.', status: 400, code: 'CATEGORY_UNKNOWN')));
    await t.tap(_field('category'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('pick-no-category')));
    await t.pumpAndSettle();
    await t.tap(find.text('Use this category'));
    await t.pumpAndSettle();
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(sent.single, {'category': ''});
    expect(find.text('There is no category called "Mine". Pick one from the list.'), findsWidgets, reason: 'on the field and in the save notice');
    expect(find.byType(TextField), findsWidgets, reason: 'still editing');
  });

  testWidgets('the picker says when the categories could not be loaded, and Try again loads them', (t) async {
    var calls = 0;
    await _pump(
      t,
      picking(
        onSave: (_) {},
        cats: () async {
          calls++;
          if (calls == 1) throw const LineItemsException('Could not reach the server.');
          return _cats;
        },
      ),
    );
    await t.tap(_field('category'));
    await t.pumpAndSettle();
    expect(find.textContaining('The categories could not be loaded'), findsOneWidget);
    expect(find.text('Create and use it'), findsNothing);
    await t.tap(find.text('Try again'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('pick-category:Keypad')), findsOneWidget);
  });

  testWidgets('pictures', (t) async {
    final dir = Platform.environment['PRODUCT_SHOTS'];
    if (dir == null) return;
    Future<void> shot(String name) async {
      await t.runAsync(() async {
        final b = t.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
        final img = await b.toImage();
        File('$dir/$name.png').writeAsBytesSync((await img.toByteData(format: ImageByteFormat.png))!.buffer.asUint8List());
      });
    }

    await _pump(t, ProductDetailScreen(productId: 1, loader: (_) async => _page()));
    await shot('product_view');
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    await shot('product_edit');
  });
}
