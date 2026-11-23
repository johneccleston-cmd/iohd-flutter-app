// Making a service inactive only stops it being picked for new lines (2026-11-19, the user's rule). A line already on a
// job or an estimate is its own copy (name, description, quantity, price, cost, tax and the catalog key it came from),
// so it reads and saves exactly as it was whether or not its service is still active. The server side of the same
// rule, through the real routes and Postgres, is integrity-backend test/inactive_service_lines.test.js.
//   flutter test test/inactive_service_lines_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/services/line_items_api.dart';
import 'package:iohd_desktop/utils/line_item_math.dart';
import 'package:iohd_desktop/widgets/line_items_editor.dart';

import 'dashboard_harness.dart';

const _service = CatalogEntry(
  key: 'sf:residential service',
  name: 'Residential Service | Tune-Up',
  kind: 'service',
  category: 'Service',
  group: 'Service',
  description: 'Lubricate, balance and test the door and opener.',
  rate: 145,
  cost: 30,
  uses: 40,
  rateUses: 40,
  taxable: true,
  priceStatus: 'settled',
);

/// What the save sent for a line, as the server stores it.
Map<String, dynamic> _sent(LineDraft l) => l.toJson()..remove('id');

/// A line as it comes back from the server on reopening (the JSON round trip the page does).
List<LineDraft> _reopened(List<LineDraft> lines) => [
  for (var i = 0; i < lines.length; i++) LineDraft.fromJson({...lines[i].toJson(), 'id': '${i + 1}'}),
];

Future<void> _pump(WidgetTester t, {required List<LineDraft> lines, required List<CatalogEntry> catalog, required List<List<LineDraft>> saved}) async {
  t.view.physicalSize = const Size(1500, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
      home: Scaffold(
        body: SingleChildScrollView(
          child: LineItemsEditor(
            key: UniqueKey(),
            lines: lines,
            taxRate: 9.5,
            editable: true,
            showCost: true,
            onSave: (l, _) async {
              saved.add([...l]);
              return null;
            },
            // The catalog as the search sees it, inactive entries included, so the editor's own guard is what is tested.
            search: (q) async => [for (final e in catalog) if (e.name.toLowerCase().contains(q.toLowerCase())) e],
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Finder get _searchBox => find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Add a line'));

Future<void> _type(WidgetTester t, String q) async {
  await t.enterText(_searchBox, q);
  await t.pump(const Duration(milliseconds: 300));
  await t.pumpAndSettle();
}

Future<void> _save(WidgetTester t) async {
  await t.tap(find.text('Save').last);
  await t.pumpAndSettle();
}

void main() {
  setUpAll(loadDashFonts);

  for (final record in const ['job', 'estimate']) {
    testWidgets('$record: a line from a service made inactive stays as it was, through reopening and an unrelated save', (t) async {
      final saved = <List<LineDraft>>[];
      // 1. A new record: the active service is offered and added, with a custom line beside it, and saved.
      await _pump(t, lines: const [], catalog: [_service], saved: saved);
      await _type(t, 'tune');
      expect(find.text('Residential Service | Tune-Up'), findsWidgets, reason: 'the active service is offered');
      await t.tap(find.text('Residential Service | Tune-Up').last);
      await t.pumpAndSettle();
      await _type(t, 'Haul away');
      await t.tap(find.textContaining('Add a custom line', findRichText: true).last);
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('line-1-rate')), '35');
      await t.pumpAndSettle();
      await _save(t);
      expect(saved, hasLength(1));
      final first = saved.single;
      final serviceLine = _sent(first[0]);
      expect(serviceLine['name'], 'Residential Service | Tune-Up');
      expect(serviceLine['description'], 'Lubricate, balance and test the door and opener.');
      expect(serviceLine['rate'], 145);
      expect(serviceLine['cost'], 30);
      expect(serviceLine['taxable'], isTrue);
      expect(serviceLine['catalogKey'], 'sf:residential service');
      expect(serviceLine['catalogRate'], 145);

      // 2. The office makes the service inactive (and, for good measure, renames and re-prices it).
      const inactive = CatalogEntry(
        key: 'sf:residential service',
        name: 'Residential Tune-Up (old)',
        kind: 'service',
        category: 'Service',
        group: 'Service',
        description: 'Changed wording',
        rate: 199,
        cost: 55,
        uses: 40,
        rateUses: 40,
        priceStatus: 'settled',
        active: false,
      );

      // 3-4. The record is reopened: the line reads as it was saved, not as the catalog now says.
      final reopened = _reopened(first);
      saved.clear();
      await _pump(t, lines: reopened, catalog: const [inactive], saved: saved);
      expect(find.text('Residential Service | Tune-Up'), findsOneWidget);
      expect(find.text('Residential Tune-Up (old)'), findsNothing);
      expect(find.textContaining('145.00'), findsWidgets, reason: 'its own price, not the catalog\'s \$199');
      expect(find.textContaining('199.00'), findsNothing);

      // 5. Something unrelated is changed (the other line's quantity) and saved.
      await t.tap(find.text('Haul away'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('line-1-qty')), '2');
      await t.pumpAndSettle();
      await _save(t);

      // 6. The service line went back exactly as it came.
      expect(saved, hasLength(1));
      expect(_sent(saved.single[0]), {..._sent(reopened[0])});
      expect(saved.single[0].sameAs(reopened[0]), isTrue);
      expect(saved.single[1].quantity, 2);

      // 7-8. A new record can't pick it: the search no longer offers the inactive service.
      saved.clear();
      await _pump(t, lines: const [], catalog: const [inactive], saved: saved);
      await _type(t, 'tune');
      expect(find.text('Residential Tune-Up (old)'), findsNothing, reason: 'an inactive service is never offered');
      expect(find.textContaining('Nothing in the catalog matches'), findsOneWidget);
    });
  }
}
