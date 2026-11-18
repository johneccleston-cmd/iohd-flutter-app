// Product Catalog Phase 3 (2026-11-16): the management views and the changes to several products at once, against a
// fake server (FakeManager). Real-Chrome pictures are in build/catalog_phase3.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/catalog_manage.dart';
import 'package:iohd_desktop/config/auth_session.dart';
import 'package:iohd_desktop/product_catalog_screen.dart';
import 'package:iohd_desktop/services/line_items_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _at = '2026-11-16T15:52:00.045Z';

CatalogEntry _p(int id, String name, {String sku = '', String category = 'Misc', double? rate = 10, double? cost = 4, bool active = true, int uses = 3, int? stock = 1, String? conflict}) =>
    CatalogEntry(
      key: 'cat:$id',
      name: name,
      sku: sku,
      category: category,
      rate: rate,
      cost: cost,
      active: active,
      uses: uses,
      lastUsed: uses > 0 ? '2026-10-01' : null,
      stock: stock,
      inventoryItem: true,
      inventoryConflict: conflict,
      inventoryLink: conflict == null ? 'name' : null,
      updatedAt: _at,
    );

final _base = <CatalogEntry>[
  _p(1, 'Hinge RC | 14GA | #2', sku: 'H2', category: 'Hinge - RC', rate: 13.3, cost: 1.03),
  _p(2, 'Hinge RC | 14GA | #3', sku: 'H3', category: 'Hinge - RC'),
  _p(3, 'Spring Anchor | Residential W/O Bearing', sku: 'SA1', category: 'Spring Anchor - Res'),
  _p(4, 'Top Bracket | Residential Adjustable', category: 'Top Bracket - Res'),
  _p(16, 'Bottom Bracket | Commercial | LH | Sure-Stop', sku: '120420', category: 'Bottom Bracket - Com', conflict: 'duplicate_name'),
  _p(17, 'Bottom Bracket | Commercial | LH | Sure-Stop', sku: '120436', category: 'Bottom Bracket - Com', conflict: 'duplicate_name'),
  _p(30, "Weather Seal | Stop Mold | 7' Almond", sku: 'SMAL', category: 'Weather Seal'),
  _p(31, "Weather Seal | Stop Mold | 9' Almond", sku: 'SMAL', category: 'Weather Seal'),
  _p(40, 'Operator | Commercial Jackshaft', sku: 'OP1', category: 'Commercial Operator Head', rate: 900, cost: 600),
];

/// The server, in memory: categories from the products plus one empty saved category, and every call written down.
class FakeManager extends CatalogManager {
  FakeManager(this.entries, {this.live = true});
  List<CatalogEntry> entries;
  final bool live;
  final List<String> calls = [];
  Map<int, String>? lastExpected;
  String? lastCategory;
  bool? lastActive;
  LineItemsException? bulkError;
  final List<CatalogReview> reviews = [];
  final Set<String> savedEmpty = {'Old Stuff'};

  static const _gone = LineItemsException('Not found', status: 404);

  List<CatalogCategory> get _cats {
    final by = <String, List<CatalogEntry>>{};
    for (final e in entries) {
      if (e.category.isNotEmpty) (by[e.category] ??= []).add(e);
    }
    return [
      for (final c in by.entries)
        CatalogCategory(name: c.key, products: c.value.length, active: c.value.where((e) => e.active).length, productIds: [for (final e in c.value) e.productId!]..sort()),
      for (final n in savedEmpty)
        if (!by.containsKey(n)) CatalogCategory(name: n, saved: true),
    ];
  }

  @override
  Future<({List<CatalogCategory> categories, int uncategorized, bool canEdit})> listCategories() async {
    calls.add('listCategories');
    if (!live) throw _gone;
    return (categories: _cats, uncategorized: 0, canEdit: true);
  }

  @override
  Future<CatalogCategory> createCategory(String name, {String? description}) async {
    calls.add('create:$name');
    savedEmpty.add(name);
    return CatalogCategory(name: name, saved: true);
  }

  @override
  Future<({CatalogCategory category, int moved})> renameCategory(String name, String newName, {required List<int> expectedProductIds}) async {
    calls.add('rename:$name>$newName:${expectedProductIds.join(',')}');
    entries = [for (final e in entries) e.category == name ? e.withChange(category: newName) : e];
    return (category: CatalogCategory(name: newName), moved: expectedProductIds.length);
  }

  @override
  Future<({CatalogCategory category, int moved})> mergeCategories(List<String> sources, String target, {required List<int> expectedProductIds}) async {
    calls.add('merge:${sources.join('+')}>$target:${expectedProductIds.join(',')}');
    entries = [for (final e in entries) sources.contains(e.category) ? e.withChange(category: target) : e];
    return (category: CatalogCategory(name: target), moved: expectedProductIds.length);
  }

  @override
  Future<void> deleteCategory(String name) async {
    calls.add('delete:$name');
    savedEmpty.remove(name);
  }

  @override
  Future<CatalogBulkResult> bulkUpdate(Map<int, String> expected, {String? category, bool? active}) async {
    calls.add('bulk');
    lastExpected = expected;
    lastCategory = category;
    lastActive = active;
    if (bulkError != null) throw bulkError!;
    var changed = 0;
    entries = [
      for (final e in entries)
        if (expected.containsKey(e.productId) && ((category != null && e.category != category) || (active != null && e.active != active)))
          (() {
            changed++;
            return e.withChange(category: category, active: active, updatedAt: '2026-11-16T20:00:00.000Z');
          })()
        else
          e,
    ];
    return (changed: changed, skipped: expected.length - changed, products: const <({int id, String category, bool active, String? updatedAt})>[]);
  }

  @override
  Future<({List<CatalogReview> reviews, bool canEdit})> listReviews() async {
    if (!live) throw _gone;
    return (reviews: List<CatalogReview>.of(reviews), canEdit: true);
  }

  @override
  Future<void> markReviewed(String issueKey, String signature, {String? note, String? label}) async {
    calls.add('review:$issueKey=$signature');
    reviews.add(CatalogReview(issueKey: issueKey, signature: signature, note: note ?? '', reviewedBy: 'Sam Example', reviewedAt: DateTime(2026, 11, 16)));
  }

  @override
  Future<void> clearReview(String issueKey) async {
    calls.add('unreview:$issueKey');
    reviews.removeWhere((r) => r.issueKey == issueKey);
  }

  @override
  Future<({List<CatalogAuditEntry> entries, bool more})> listAudit({int limit = 100, int? before}) async {
    if (!live) throw _gone;
    return (
      entries: [
        CatalogAuditEntry(
          id: 2,
          at: DateTime(2026, 11, 16, 14, 5),
          by: 'Sam Example',
          action: 'product.update',
          summary: 'Edited Hinge RC | 14GA | #2: avgUnitCost, partNumber',
          productIds: const [1],
          details: const {
            'changes': {
              'avgUnitCost': null,
              'partNumber': ['H1', 'H2'],
            },
          },
        ),
        CatalogAuditEntry(
          id: 1,
          at: DateTime(2026, 11, 16, 13, 0),
          by: 'Sam Example',
          action: 'category.rename',
          summary: 'Renamed the category "Hinge" to "Hinge - RC" (2 products)',
          productIds: const [1, 2],
        ),
      ],
      more: false,
    );
  }
}

Future<void> _signIn({bool canUpdate = true, bool canSeeCost = true}) async {
  AuthSession.instance.logout();
  final payload = base64Url.encode(utf8.encode(json.encode({'exp': DateTime(2100).millisecondsSinceEpoch})));
  SharedPreferences.setMockInitialValues({
    'iohd_auth_session': json.encode({
      'token': '$payload.sig',
      'name': 'Sam Example',
      'role': 'Office Manager',
      'is_admin': false,
      'denied': [if (!canUpdate) 'line_items.update', if (!canSeeCost) 'line_items.view'],
    }),
  });
  await AuthSession.instance.restore();
}

Future<FakeManager> _pump(
  WidgetTester t, {
  List<CatalogEntry>? entries,
  bool canSeeCost = true,
  bool live = true,
  Size size = const Size(1366, 768),
  CatalogView view = CatalogView.products,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final fake = FakeManager(entries ?? _base, live: live);
  await t.pumpWidget(
    MaterialApp(
      home: ProductCatalogScreen(
        manager: fake,
        initialView: view,
        loader: () async => (entries: fake.entries, canSeeCost: canSeeCost, historyDays: 540),
        exporter: (_, _) async => true,
      ),
    ),
  );
  await t.pumpAndSettle();
  return fake;
}

Finder _pick(int id) => find.byKey(ValueKey('pick:cat:$id'));

void main() {
  setUp(() => _signIn());
  tearDown(() => AuthSession.instance.logout());

  testWidgets('the ribbon has four views; Cleanup counts the checks and a check opens the product list filtered to it', (t) async {
    await _pump(t);
    for (final tab in ['Products', 'Categories', 'Cleanup', 'History']) {
      expect(find.bySemanticsLabel(RegExp('^$tab')), findsWidgets, reason: tab);
    }
    await t.tap(find.text('Cleanup'));
    await t.pumpAndSettle();
    expect(find.text('Catalog health'), findsOneWidget);
    // Same name (the Sure-Stop pair) is open beside the checks; Same part # (SMAL) is listed with its count.
    expect(find.byKey(const ValueKey('group:dupe_name:bottom bracket | commercial | lh | sure-stop')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('check:no_part')));
    await t.pumpAndSettle();
    expect(find.bySemanticsLabel('Remove filter Attention No part #'), findsOneWidget);
    expect(find.text('1 matching'), findsOneWidget, reason: 'the top bracket has no part number');
    expect(find.byKey(const ValueKey('row:cat:4')), findsOneWidget);
  });

  testWidgets('picking products: a box per row, Shift+click for a range, the page box, and pick all matching', (t) async {
    await _pump(t);
    expect(find.byKey(const ValueKey('selection-bar')), findsNothing);
    await t.tap(_pick(1));
    await t.pumpAndSettle();
    expect(find.text('1 picked'), findsOneWidget);
    // The list is A to Z: Bottom x2, Hinge #2, Hinge #3, Operator, Spring, Top, Weather x2. Shift+click Spring picks Hinge #2 to Spring.
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.tap(_pick(3));
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.pumpAndSettle();
    expect(find.text('4 picked'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('pick-all-matching')));
    await t.pumpAndSettle();
    expect(find.text('9 picked'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('pick-page')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('selection-bar')), findsNothing, reason: 'the page box unpicks the page');
  });

  testWidgets('moving several products: pick a category, see every product and what changes, confirm with the count', (t) async {
    final fake = await _pump(t);
    for (final id in [1, 3, 4]) {
      await t.tap(_pick(id));
    }
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('bulk-category')));
    await t.pumpAndSettle();
    expect(find.text('Move 3 products to…'), findsOneWidget);
    await t.enterText(find.widgetWithText(TextField, 'Find a category, or type a new one'), 'res');
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('bulk-category:Spring Anchor - Res')));
    await t.pumpAndSettle();
    await t.tap(find.text('Review the move'));
    await t.pumpAndSettle();
    expect(find.textContaining('Only the category changes'), findsOneWidget);
    expect(find.text('Already in Spring Anchor - Res'), findsOneWidget, reason: 'the spring anchor is there already');
    expect(fake.calls.where((c) => c == 'bulk'), isEmpty, reason: 'nothing is sent before the confirm');
    await t.tap(find.text('Move 2 products'));
    await t.pumpAndSettle();
    expect(fake.lastCategory, 'Spring Anchor - Res');
    expect(fake.lastExpected, {1: _at, 3: _at, 4: _at}, reason: 'each product goes with the time the list showed for it');
    expect(find.text('Moved 2 products to Spring Anchor - Res (1 was already so)'), findsOneWidget);
    expect(find.byKey(const ValueKey('selection-bar')), findsNothing, reason: 'the picks are cleared after the change');
  });

  testWidgets('a big change needs the tick; a change refused because someone else changed a product offers a reload', (t) async {
    final many = [..._base, for (var i = 0; i < 55; i++) _p(100 + i, 'Seal $i', sku: 'S$i', category: 'Weather Seal')];
    final fake = await _pump(t, entries: many);
    await t.tap(find.byKey(const ValueKey('pick-page')));
    await t.pumpAndSettle();
    expect(find.text('50 picked'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('bulk-status')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('bulk-inactive')));
    await t.pumpAndSettle();
    final apply = find.widgetWithText(FilledButton, 'Make 50 products inactive');
    expect(t.widget<FilledButton>(apply).onPressed, isNull, reason: 'not before the tick');
    await t.tap(find.byKey(const ValueKey('bulk-tick')));
    await t.pumpAndSettle();
    fake.bulkError = const LineItemsException('Someone else changed these products after you looked.', status: 409, code: 'CHANGED');
    await t.tap(apply);
    await t.pumpAndSettle();
    expect(find.textContaining('Someone else changed'), findsOneWidget);
    expect(fake.lastActive, isFalse);
    expect(fake.entries.where((e) => !e.active), isEmpty, reason: 'nothing changed');
    await t.tap(find.text('Reload the list'));
    await t.pumpAndSettle();
    expect(find.text('50 picked'), findsOneWidget, reason: 'the picks stay for another try');
  });

  testWidgets('without the Update switch the changes are off (and say why) but Export still works', (t) async {
    await _signIn(canUpdate: false);
    await _pump(t);
    await t.tap(_pick(1));
    await t.pumpAndSettle();
    final move = t.widget<TextButton>(find.byKey(const ValueKey('bulk-category')));
    expect(move.onPressed, isNull);
    expect(find.byTooltip('Changing products needs the Line Items & Costs > Update switch'), findsWidgets);
    await t.tap(find.byKey(const ValueKey('bulk-export')));
    await t.pumpAndSettle();
    expect(find.text('Exported 1 product'), findsOneWidget);
    // The Categories view lets them look, not change.
    await t.tap(find.text('Categories'));
    await t.pumpAndSettle();
    expect(find.text('New category'), findsNothing);
    expect(find.textContaining('Changing them needs the Line Items & Costs > Update switch'), findsOneWidget);
  });

  testWidgets('categories: rename refuses a name another category has, then renames with the product ids it showed', (t) async {
    final fake = await _pump(t, view: CatalogView.categories);
    await t.tap(find.byKey(const ValueKey('category:Hinge - RC')));
    await t.pumpAndSettle();
    expect(find.text('2 products  ·  2 active'), findsOneWidget);
    await t.tap(find.widgetWithText(OutlinedButton, 'Rename'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('catalog-form-field')), 'weather  seal');
    await t.pumpAndSettle();
    expect(find.textContaining('There is already a category called "Weather Seal"'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('catalog-form-field')), 'Hinge - Residential');
    await t.pumpAndSettle();
    expect(find.textContaining('2 products move with it'), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, 'Rename'));
    await t.pumpAndSettle();
    expect(fake.calls, contains('rename:Hinge - RC>Hinge - Residential:1,2'));
    expect(find.text('Renamed Hinge - RC to Hinge - Residential'), findsOneWidget);
  });

  testWidgets('categories: a word written two ways is flagged; merge previews the move and sends the folded-in products', (t) async {
    final fake = await _pump(t, view: CatalogView.categories);
    expect(find.textContaining('Commercial is written "Com" in 1 category and "Commercial" in 1'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('category:Top Bracket - Res')));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(OutlinedButton, 'Merge into…'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('merge-into:Spring Anchor - Res')));
    await t.pumpAndSettle();
    await t.tap(find.text('Review the merge'));
    await t.pumpAndSettle();
    expect(find.text('1 product, then removed'), findsOneWidget);
    await t.tap(find.text('Merge 1 product'));
    await t.pumpAndSettle();
    expect(fake.calls, contains('merge:Top Bracket - Res>Spring Anchor - Res:4'));
  });

  testWidgets('categories: only an empty category can be deleted, after a confirm', (t) async {
    final fake = await _pump(t, view: CatalogView.categories);
    await t.tap(find.byKey(const ValueKey('category:Hinge - RC')));
    await t.pumpAndSettle();
    expect(t.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Delete')).onPressed, isNull);
    await t.tap(find.byKey(const ValueKey('category:Old Stuff')));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(OutlinedButton, 'Delete'));
    await t.pumpAndSettle();
    expect(find.text('Delete this category?'), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, 'Delete category'));
    await t.pumpAndSettle();
    expect(fake.calls, contains('delete:Old Stuff'));
  });

  testWidgets('cleanup: duplicates by group; mark reviewed sends the group\'s ids; make inactive goes through the preview', (t) async {
    final fake = await _pump(t, view: CatalogView.cleanup);
    await t.tap(find.byKey(const ValueKey('check:dupe_part')));
    await t.pumpAndSettle();
    expect(find.text('Part # smal'), findsNothing);
    expect(find.text('Part # SMAL'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('review:dupe_part:smal')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('catalog-form-field')), 'Lengths share one part number');
    await t.tap(find.widgetWithText(FilledButton, 'Mark reviewed'));
    await t.pumpAndSettle();
    expect(fake.calls, contains('review:dupe_part:smal=30,31'));
    expect(find.text('Show 1 reviewed'), findsOneWidget, reason: 'the group is set aside');
    // The Sure-Stop pair: make one inactive.
    await t.tap(find.byKey(const ValueKey('check:dupe_name')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('deactivate:cat:17')));
    await t.pumpAndSettle();
    expect(find.text('Make 1 product inactive?'), findsOneWidget);
    expect(find.textContaining('stop being offered on new estimates and jobs'), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, 'Make 1 product inactive'));
    await t.pumpAndSettle();
    expect(fake.lastActive, isFalse);
    expect(fake.lastExpected, {17: _at});
    expect(find.text('Nothing to look at'), findsOneWidget, reason: 'one active product left: no longer a duplicate');
  });

  testWidgets('without costs the cost checks are not in Cleanup at all', (t) async {
    await _signIn(canSeeCost: false);
    await _pump(t, canSeeCost: false, view: CatalogView.cleanup);
    expect(find.byKey(const ValueKey('check:no_cost')), findsNothing);
    expect(find.byKey(const ValueKey('check:cost_above')), findsNothing);
    expect(find.byKey(const ValueKey('check:high_markup')), findsNothing);
    expect(find.text('MISSING DETAILS AND PRICING'), findsNothing);
    expect(find.text('MISSING DETAILS'), findsOneWidget);
  });

  testWidgets('an older server: categories come from the products, nothing can be changed, and bulk changes say why', (t) async {
    await _pump(t, live: false, view: CatalogView.categories);
    expect(find.textContaining('needs the server update'), findsOneWidget);
    expect(find.text('New category'), findsNothing);
    expect(find.byKey(const ValueKey('category:Hinge - RC')), findsOneWidget);
    await t.tap(find.text('Products'));
    await t.pumpAndSettle();
    await t.tap(_pick(1));
    await t.pumpAndSettle();
    expect(find.byTooltip('Needs the server update that adds changes to several products'), findsWidgets);
  });

  testWidgets('history lists the change log; a cost it was not sent reads as hidden', (t) async {
    await _pump(t, view: CatalogView.history);
    expect(find.text('Product edited'), findsOneWidget);
    expect(find.text('Category renamed'), findsOneWidget);
    await t.tap(find.text('Product edited'));
    await t.pumpAndSettle();
    expect(find.text('Changed (hidden: needs the cost switch)'), findsOneWidget);
    expect(find.text('H1  →  H2'), findsOneWidget);
  });

  for (final size in const [Size(1280, 600), Size(1366, 768), Size(1920, 940)]) {
    testWidgets('every view lays out at ${size.width.toInt()}x${size.height.toInt()} with nothing spilling over', (t) async {
      await _pump(t, size: size);
      for (final tab in ['Categories', 'Cleanup', 'History', 'Products']) {
        await t.tap(find.text(tab));
        await t.pumpAndSettle();
      }
      await t.tap(_pick(1));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('selection-bar')), findsOneWidget);
      await t.tap(find.text('Categories'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('category:Hinge - RC')));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  }
}
