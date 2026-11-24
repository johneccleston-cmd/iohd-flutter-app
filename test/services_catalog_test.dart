// The Services Catalog page (redesign 2026-11-19): rows from the list endpoint with Service, Category, Cost and Price
// (cost only when the person may see costs; the Times used / Last used columns stay gone, USER RULE 11-19), status tabs
// with live counts, the fixed categories and usage filters with counts, the sorts, a quiet note on rarely used services,
// the picks and the changes to several services, loading / error / empty / no-match states and no overflow at the
// desktop sizes, at 130% text and in a narrow window. Pictures go to build/job_shots/services_catalog_*.png for review;
// nothing here is a golden.
//   flutter test test/services_catalog_test.dart

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/service_detail_screen.dart';
import 'package:iohd_desktop/services/line_items_api.dart';
import 'package:iohd_desktop/services_catalog_screen.dart';
import 'package:iohd_desktop/widgets/dashboard_data.dart';

import 'dashboard_harness.dart';
import 'services_catalog_fixture.dart';

typedef _Result = ({List<CatalogEntry> entries, bool canSeeCost, int historyDays});

const _services = [
  CatalogEntry(key: 'sf:service call', name: 'Service Call', kind: 'service', category: 'Service', rate: 89, rateMin: 69, rateMax: 129, cost: 22.5, uses: 412, lastUsed: '2026-11-12', taxable: false, description: 'Diagnose and quote repair'),
  CatalogEntry(key: 'sf:spring replacement', name: 'Torsion Spring Replacement (pair)', kind: 'service', category: 'Service', rate: 285, rateMin: 249, rateMax: 325, cost: 96, uses: 233, lastUsed: '2026-11-10', taxable: true, description: 'Two torsion springs, balance and adjust the door, lubricate rollers and hinges, check the opener travel and safety reverse before leaving the site'),
  CatalogEntry(key: 'sf:install', name: 'Install – Residential Door', kind: 'service', category: 'Service', rate: null, rateMin: 450, rateMax: 900, uses: 40, lastUsed: '2026-10-02', taxable: true),
  CatalogEntry(key: 'sf:old', name: 'Warranty Visit', kind: 'service', category: 'Service', uses: 1),
];

_Result _ok({bool cost = true, List<CatalogEntry> entries = _services}) => (entries: entries, canSeeCost: cost, historyDays: 540);

final _pageKey = GlobalKey();

Future<void> _pump(
  WidgetTester t,
  Future<_Result> Function() load, {
  Size size = const Size(1366, 768),
  double text = 1,
  Future<CatalogEntry> Function(String, Map<String, dynamic>)? saver,
  bool? canEdit,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(text)), child: child!),
      home: RepaintBoundary(
        key: _pageKey,
        child: ServicesCatalogScreen(key: UniqueKey(), load: load, saver: saver, canEdit: canEdit),
      ),
    ),
  );
}

Future<void> _shot(WidgetTester t, String name) async {
  final boundary = _pageKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await t.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/job_shots')..createSync(recursive: true);
    File('${dir.path}/services_catalog_$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Future<void> _search(WidgetTester t, String q) async {
  await t.enterText(find.byType(TextField).first, q);
  await t.pump(const Duration(milliseconds: 400));
  await t.pumpAndSettle();
}

Finder _row(String key) => find.byKey(ValueKey('row:$key'));
Finder _tab(String status) => find.byKey(ValueKey('status:$status'));

/// The keys of the rows on screen, top to bottom.
List<String> _rowKeys(WidgetTester t) {
  final rows = t.widgetList(find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('row:'))).toList();
  return [for (final w in rows) (w.key! as ValueKey<String>).value.substring(4)];
}

/// The service as the server sends it back after [fields] were saved (the group and status the fake applies).
CatalogEntry _applied(CatalogEntry e, Map<String, dynamic> fields) {
  final category = fields.containsKey('category') ? (fields['category'] as String? ?? (e.computed?['category'] as String? ?? 'Service')) : null;
  final active = fields.containsKey('active') ? (fields['active'] as bool? ?? (e.computed?['active'] as bool? ?? true)) : e.active;
  return CatalogEntry(
    key: e.key,
    name: e.name,
    kind: 'service',
    category: category ?? e.category,
    group: category ?? e.group,
    rate: e.rate,
    cost: e.cost,
    uses: e.uses,
    lastUsed: e.lastUsed,
    active: active,
    editedFields: const ['category'],
    computed: const {'category': 'Service', 'active': true},
  );
}

void main() {
  setUpAll(() async {
    await loadDashFonts();
    await dashSignIn();
  });
  setUp(() => DashClock.debugOverride = () => DateTime(2026, 11, 19, 12));
  tearDown(() => DashClock.debugOverride = null);

  testWidgets('lists services with category, cost and price; no overflow at the desktop sizes, 130% text and narrow', (t) async {
    for (final (size, text) in const [
      (Size(1280, 600), 1.0),
      (Size(1366, 768), 1.0),
      (Size(1500, 800), 1.0),
      (Size(1920, 940), 1.0),
      (Size(1280, 600), 1.3),
      (Size(1366, 768), 1.3),
      (Size(420, 800), 1.0),
    ]) {
      await _pump(t, () async => _ok(), size: size, text: text);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: '$size @ $text');
      expect(find.text('Service Call'), findsOneWidget);
      expect(find.text('\$89.00'), findsOneWidget);
      // The status sits in the filter sidebar (where the window is wide enough for it), not in the command row.
      expect(_tab('active'), size.width > 1100 && text == 1.0 ? findsOneWidget : findsAtLeastNWidgets(0));
      if (size.width > 900) {
        expect(find.text('SERVICE'), findsOneWidget);
        expect(find.text('PRICE'), findsOneWidget);
        expect(find.text('COST'), findsOneWidget);
      } else {
        expect(find.text('SERVICE'), findsNothing, reason: 'rows stack when narrow');
      }
      if (size.width >= 1366 && text == 1) {
        expect(find.text('CATEGORY'), findsOneWidget);
        expect(find.text('Filters'), findsOneWidget, reason: 'the sidebar');
      }
      // USER RULE 11-19: no scorecards, no price range / times used / last used / tax columns.
      for (final gone in const ['PRICE RANGE', 'TIMES USED', 'LAST USED', 'TAX', 'UNIT COST', 'USUAL PRICE']) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
      expect(find.textContaining('Built from'), findsNothing);
      // No price: "Varies" when its lines were billed at different prices, "No price" when there is nothing to go on.
      expect(find.text('Varies'), findsOneWidget);
      expect(find.text('No price'), findsOneWidget);
      expect(find.text('None'), findsNothing);
      await _shot(t, '${size.width.toInt()}x${size.height.toInt()}${text == 1 ? '' : '_t130'}');
    }
  });

  testWidgets('a superseded service is kept with its history, on the Inactive tab, and found by a search on Active', (t) async {
    const replacement = CatalogEntry(
      key: 'sfr:10792835~commercial-service-dispatch-evaluation',
      name: 'Commercial Service Dispatch & Evaluation',
      kind: 'service',
      category: 'Commercial Service',
      rate: 109,
      rateMin: 109,
      rateMax: 394,
      uses: 22,
      lastUsed: '2026-11-13',
      replaces: [(key: 'sfr:10792835', name: 'Scope of Work | Commercial Service Call')],
    );
    const superseded = CatalogEntry(
      key: 'sfr:10792835',
      name: 'Scope of Work | Commercial Service Call',
      kind: 'service',
      category: 'Commercial Service',
      rate: 199,
      rateMin: 39.8,
      rateMax: 14000,
      uses: 159,
      lastUsed: '2026-11-12',
      active: false,
      supersededBy: (key: 'sfr:10792835~commercial-service-dispatch-evaluation', name: 'Commercial Service Dispatch & Evaluation'),
    );
    final entries = [superseded, ..._services, replacement];
    for (final size in const [Size(1366, 768), Size(420, 800)]) {
      await _pump(t, () async => _ok(entries: entries), size: size);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: '$size');
      // The page starts on the active services.
      expect(find.text('Scope of Work | Commercial Service Call'), findsNothing);
      expect(find.textContaining('Replaces Scope of Work | Commercial Service Call', findRichText: true), findsOneWidget);
      expect(find.text('Commercial Service Dispatch & Evaluation'), findsOneWidget);
      if (size.width > 1000) {
        // The status counts are in the filter sidebar, which a phone-narrow window folds into the Filters dialog.
        expect(find.bySemanticsLabel('Active, 5'), findsOneWidget);
        expect(find.bySemanticsLabel('Inactive, 1'), findsOneWidget);
      }
    }
    // The Inactive tab: the superseded one, marked, with what replaced it.
    await _pump(t, () async => _ok(entries: entries));
    await t.pumpAndSettle();
    await t.tap(_tab('inactive'));
    await t.pumpAndSettle();
    expect(find.text('Scope of Work | Commercial Service Call'), findsOneWidget);
    expect(find.textContaining('Superseded by Commercial Service Dispatch & Evaluation', findRichText: true), findsOneWidget);
    expect(find.text('Service Call'), findsNothing);
    await _shot(t, 'superseded_1366');
    // Searching on Active by the old name finds the replacement, then the old one under its own label.
    await _pump(t, () async => _ok(entries: entries));
    await t.pumpAndSettle();
    await _search(t, 'scope of work');
    expect(_rowKeys(t), [replacement.key, superseded.key]);
    expect(find.byKey(const ValueKey('inactive-matches')), findsOneWidget);
    expect(find.textContaining('ALSO MATCHING: 1 INACTIVE', findRichText: true), findsOneWidget);
    expect(find.text('Service Call'), findsNothing);
    await _shot(t, 'search_inactive_matches');
  });

  testWidgets('hides the cost column without Line Items & Costs > View', (t) async {
    await _pump(t, () async => _ok(cost: false));
    await t.pumpAndSettle();
    expect(find.text('COST'), findsNothing);
    await t.tap(find.byKey(const ValueKey('sort-menu')));
    await t.pumpAndSettle();
    expect(find.text('Highest cost'), findsNothing, reason: 'no sort by a figure they cannot see');
    expect(find.text('Highest price'), findsOneWidget);
  });

  testWidgets('shows the loading rows, then an error with a working retry', (t) async {
    var calls = 0;
    final first = Completer<_Result>();
    await _pump(t, () {
      calls++;
      return calls == 1 ? first.future : Future.value(_ok());
    });
    await t.pump();
    expect(find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Loading the services'), findsOneWidget);
    first.completeError(const LineItemsException('Could not reach the server.'));
    await t.pumpAndSettle();
    expect(find.text('Could not reach the server.'), findsOneWidget);
    await _shot(t, 'error');
    await t.tap(find.text('Try again'));
    await t.pumpAndSettle();
    expect(find.text('Service Call'), findsOneWidget);
    expect(calls, 2);
  });

  // Services Catalog Phase 2: the list answers 403 without the page's switch (Team > Services Catalog), and the page says
  // so instead of showing a generic error; a refresh that is refused after access was taken away clears the list.
  testWidgets('a 403 says there is no access, not that loading failed', (t) async {
    const refused = LineItemsException('Not allowed.', status: 403);
    for (final size in const [Size(1366, 768), Size(420, 800)]) {
      await _pump(t, () async => throw refused, size: size);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: '$size');
      expect(find.text("You don't have access to the Services Catalog"), findsOneWidget);
      expect(find.text('Ask an admin to turn it on in Team.'), findsOneWidget);
      expect(find.text('Could not load the services'), findsNothing);
      expect(find.text('Try again'), findsNothing);
      await _shot(t, 'no_access_${size.width.toInt()}');
    }

    var calls = 0;
    await _pump(t, () async {
      calls++;
      if (calls > 1) throw refused;
      return _ok();
    });
    await t.pumpAndSettle();
    expect(find.text('Service Call'), findsOneWidget);
    await t.tap(find.byTooltip('Refresh'));
    await t.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Service Call'), findsNothing, reason: 'nothing of the list stays on show');
    expect(find.text("You don't have access to the Services Catalog"), findsOneWidget);

    // Any other failure is still the ordinary error with Try again.
    await _pump(t, () async => throw const LineItemsException('Server error (500).', status: 500));
    await t.pumpAndSettle();
    expect(find.text('Could not load the services'), findsOneWidget);
    expect(find.text("You don't have access to the Services Catalog"), findsNothing);
  });

  testWidgets('empty list and search with no match say so, and point at the other tab', (t) async {
    await _pump(t, () async => _ok(entries: const []));
    await t.pumpAndSettle();
    expect(find.text('No services yet'), findsOneWidget);

    await _pump(t, () async => _ok());
    await t.pumpAndSettle();
    await _search(t, 'spring');
    expect(find.text('Torsion Spring Replacement (pair)'), findsOneWidget);
    expect(find.text('Service Call'), findsNothing);
    expect(find.bySemanticsLabel('Active, 1'), findsOneWidget, reason: 'the tabs count the matches');
    await _search(t, 'zzz');
    expect(find.text('No active services match'), findsOneWidget);
    await _shot(t, 'no_match');
    await t.tap(find.text('Clear search and filters'));
    await t.pumpAndSettle();
    expect(find.text('Service Call'), findsOneWidget);

    // Nothing inactive matches, but on the Inactive tab the active matches are offered.
    await t.tap(_tab('inactive'));
    await t.pumpAndSettle();
    await _search(t, 'spring');
    expect(find.text('No inactive services match'), findsOneWidget);
    expect(find.text('1 active service does.'), findsOneWidget);
    await t.tap(find.text('Show active'));
    await t.pumpAndSettle();
    expect(find.text('Torsion Spring Replacement (pair)'), findsOneWidget);
  });

  testWidgets('search ignores case, punctuation and spacing', (t) async {
    await _pump(t, () async => prodLikeCatalog());
    await t.pumpAndSettle();
    await _search(t, 'lift master 6690');
    expect(_rowKeys(t).length, 2, reason: "7' and 8' 6690L");
    await _search(t, '2-10 WARRANTY');
    expect(find.textContaining('2-10 Warranty Company Service', findRichText: true), findsOneWidget);
    await _search(t, 'mechanical component'); // in the description
    expect(find.textContaining('2-10 Warranty Company Service', findRichText: true), findsOneWidget);
  });

  testWidgets('no Service Fusion wording, no "/" hint, no Last used text: rows, tooltips and dialogs (USER RULE 2026-11-19)', (t) async {
    Finder sfTooltip() => find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').contains('Service Fusion'));
    await _pump(t, () async => prodLikeCatalog(), size: const Size(1500, 2400), canEdit: true);
    await t.pumpAndSettle();
    await t.tap(_tab('all'));
    await t.pumpAndSettle();
    expect(find.textContaining('Service Fusion', findRichText: true), findsNothing);
    expect(sfTooltip(), findsNothing);
    expect(find.text('/'), findsNothing, reason: 'the search box has no key hint');
    for (final gone in const ['Last used', 'Used once', 'Never billed']) {
      expect(find.textContaining(gone, findRichText: true), findsNothing, reason: gone);
    }
    // The bulk dialogs say what happens to jobs and estimates, without naming Service Fusion.
    await t.tap(find.byKey(const ValueKey("pick:sf:operator installation | liftmaster | 10' 85870")));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('bulk-category')));
    await t.pumpAndSettle();
    expect(find.text('Lines already on jobs and estimates do not change.'), findsOneWidget);
    expect(find.textContaining('Service Fusion', findRichText: true), findsNothing);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('bulk-status')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('bulk-inactive')));
    await t.pumpAndSettle();
    expect(find.textContaining('Lines already on jobs and estimates do not change.'), findsOneWidget);
    expect(find.textContaining('Service Fusion', findRichText: true), findsNothing);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
  });

  testWidgets('no usage notes on the rows; the Most used sort; no usage filters, groups closed', (t) async {
    await _pump(t, () async => prodLikeCatalog(), size: const Size(1500, 900));
    await t.pumpAndSettle();
    // How much a service is used shows in the sorts only (USER RULE 2026-11-19: no "Last used" text on the rows).
    expect(find.textContaining('Last used', findRichText: true), findsNothing);
    expect(find.textContaining('Used 1,075', findRichText: true), findsNothing);
    await _search(t, 'emergency');
    expect(find.textContaining('Used once', findRichText: true), findsNothing);
    await _search(t, '');
    await t.tap(find.byKey(const ValueKey('sort-menu')));
    await t.pumpAndSettle();
    await t.tap(find.text('Most used').last);
    await t.pumpAndSettle();
    expect(_rowKeys(t).take(2).toList(), ['sf:residential installation | complete overhead door', 'sf:commercial service']);
    expect(find.text('Most used'), findsOneWidget, reason: 'the sort says what it is');
    // The sidebar has no Usage, Last used or Changes filters (USER RULE 2026-11-19), and its groups start closed.
    for (final gone in const ['Usage, last 18 months', 'Last used', 'Changes', 'Used once', 'Edited by the office', 'Edited']) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    expect(find.text('Category'), findsWidgets);
    expect(find.byKey(const ValueKey('cat:none')), findsNothing, reason: 'Category starts closed');
    expect(find.text('Has a price'), findsNothing, reason: 'there is no Price filter any more');
    expect(find.text('Status'), findsOneWidget, reason: 'Active / Inactive / All are a sidebar group');
    expect(find.text('Price'), findsNothing);
    // A price sort, highest first: the unpriced ones ("Varies") go last, whichever way it is sorted.
    await t.tap(find.text('PRICE'));
    await t.pumpAndSettle();
    expect(_rowKeys(t).first, 'sf:dock leveler installation');
    await t.tap(find.text('PRICE'));
    await t.pumpAndSettle();
    expect(_rowKeys(t).first, isNot(contains('labor only')), reason: 'lowest first still starts with a priced one');
  });

  testWidgets('the categories are the fixed list with counts; No category is marked and filters', (t) async {
    await _pump(t, () async => prodLikeCatalog(), size: const Size(1500, 900));
    await t.pumpAndSettle();
    await t.tap(find.text('Category').first); // the sidebar group starts closed
    await t.pumpAndSettle();
    for (final c in kServiceCategories) {
      expect(find.bySemanticsLabel(RegExp('^${RegExp.escape(c)}, [0-9]+\$')), findsOneWidget, reason: c);
    }
    expect(find.bySemanticsLabel('No category, 25'), findsOneWidget);
    expect(find.bySemanticsLabel('Operator Installations, 2'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('cat:none')));
    await t.pumpAndSettle();
    expect(find.text('Operator Installations'), findsWidgets, reason: 'only in the sidebar now');
    expect(find.bySemanticsLabel('Active, 25'), findsOneWidget);
    expect(_rowKeys(t).contains('sf:dock leveler installation'), isFalse);
  });

  testWidgets('Move to category: pick, choose, and only what changes is sent', (t) async {
    final sent = <String, Map<String, dynamic>>{};
    final byKey = {for (final e in kProdLikeServices) e.key: e};
    await _pump(
      t,
      () async => prodLikeCatalog(),
      size: const Size(1500, 2200),
      saver: (key, fields) async {
        sent[key] = fields;
        return _applied(byKey[key]!, fields);
      },
    );
    await t.pumpAndSettle();
    const plain = "sf:operator installation | liftmaster | 10' 85870"; // in no category
    const moved = "sf:operator installation | liftmaster | 8' 6690l"; // already in Operator Installations
    await t.tap(find.byKey(const ValueKey('pick:$plain')));
    await t.tap(find.byKey(const ValueKey('pick:$moved')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('selection-bar')), findsOneWidget);
    expect(find.text('2 selected'), findsOneWidget);
    await _shot(t, 'picked');
    await t.tap(find.byKey(const ValueKey('bulk-category')));
    await t.pumpAndSettle();
    expect(find.text('Move 2 services'), findsOneWidget);
    expect(find.text('1 here now'), findsNWidgets(2), reason: 'one is in no category, one in Operator Installations');
    await _shot(t, 'move_dialog');
    await t.tap(find.byKey(const ValueKey('move-to:Operator Installations')));
    await t.pump();
    await t.tap(find.text('Move'));
    await t.pumpAndSettle();
    expect(sent, {
      plain: {'category': 'Operator Installations'},
    }, reason: 'the one already there is left alone');
    expect(find.text('Moved 1 service to Operator Installations (1 was already so)'), findsOneWidget);
    expect(find.byKey(const ValueKey('selection-bar')), findsNothing, reason: 'the saved and the already-so ones are unpicked');

    // Back out of a category: the edit is dropped (null), never "no category" as a value.
    sent.clear();
    await t.tap(find.byKey(const ValueKey('pick:$moved')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('bulk-category')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('move-to:')));
    await t.pump();
    await t.tap(find.text('Move'));
    await t.pumpAndSettle();
    expect(sent, {
      moved: {'category': null},
    });
  });

  testWidgets('Make inactive / active: says what it does first; back to what the job lines say is sent as null', (t) async {
    final sent = <String, Map<String, dynamic>>{};
    final byKey = {for (final e in kProdLikeServices) e.key: e};
    await _pump(
      t,
      () async => prodLikeCatalog(),
      size: const Size(1500, 2200),
      saver: (key, fields) async {
        sent[key] = fields;
        return _applied(byKey[key]!, fields);
      },
    );
    await t.pumpAndSettle();
    const active = 'sf:commercial service | call | after hours';
    await t.tap(find.byKey(const ValueKey('pick:$active')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('bulk-status')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('bulk-inactive')));
    await t.pumpAndSettle();
    expect(find.text('Make 1 service inactive?'), findsOneWidget);
    expect(find.textContaining('Lines already on jobs and estimates do not change'), findsOneWidget);
    await _shot(t, 'inactive_confirm');
    await t.tap(find.text('Make inactive'));
    await t.pumpAndSettle();
    expect(sent, {
      active: {'active': false},
    });
    expect(find.text('Made 1 service inactive'), findsOneWidget);
    expect(_row(active), findsNothing, reason: 'it left the Active tab');

    // One the office switched off (computed active): making it active drops the edit.
    sent.clear();
    await t.tap(_tab('inactive'));
    await t.pumpAndSettle();
    const off = 'sf:commercial door removal';
    await t.tap(find.byKey(const ValueKey('pick:$off')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('bulk-status')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('bulk-active')));
    await t.pumpAndSettle();
    await t.tap(find.text('Make active'));
    await t.pumpAndSettle();
    expect(sent, {
      off: {'active': null},
    });
  });

  testWidgets('a change to several services that partly fails says which, and keeps those picked', (t) async {
    final byKey = {for (final e in kProdLikeServices) e.key: e};
    const ok = 'sf:dock leveler installation';
    const bad = 'sf:commercial service';
    await _pump(
      t,
      () async => prodLikeCatalog(),
      size: const Size(1500, 2200),
      saver: (key, fields) async {
        if (key == bad) throw const LineItemsException('Server error (500).', status: 500);
        return _applied(byKey[key]!, fields);
      },
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('pick:$ok')));
    await t.tap(find.byKey(const ValueKey('pick:$bad')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('bulk-category')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('move-to:Service Packages')));
    await t.pump();
    await t.tap(find.text('Move'));
    await t.pumpAndSettle();
    expect(find.text('1 of 2 saved'), findsOneWidget);
    expect(find.textContaining('Server error (500).', findRichText: true), findsOneWidget);
    await _shot(t, 'bulk_failed');
    await t.tap(find.text('OK'));
    await t.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget, reason: 'the failed one stays picked');
  });

  testWidgets('without Line Items & Costs > Update there are no pick boxes', (t) async {
    await _pump(t, () async => prodLikeCatalog(), canEdit: false);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('pick-page')), findsNothing);
    expect(find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('pick:')), findsNothing);
  });

  testWidgets('a list read that started before a save does not undo it on screen', (t) async {
    var calls = 0;
    final slow = Completer<_Result>();
    await _pump(t, () {
      calls++;
      return calls == 1 ? Future.value(_ok()) : slow.future;
    });
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Refresh'));
    await t.pump();
    // The service page saves while the refresh is on its way.
    serviceChanged.value = const CatalogEntry(key: 'sf:service call', name: 'Service Call (renamed)', kind: 'service', rate: 95, uses: 412, lastUsed: '2026-11-12');
    await t.pump();
    slow.complete(_ok()); // read before the save: still the old name
    await t.pumpAndSettle();
    expect(find.text('Service Call (renamed)'), findsOneWidget);
    expect(find.text('Service Call'), findsNothing);
    serviceChanged.value = null;
  });
}
