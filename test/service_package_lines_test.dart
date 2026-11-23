// A service package on a job or estimate (USER RULE 2026-11-20). Picking a service that has rates (Residential Service)
// in the Products & Services search adds the package's name as a heading and each of its rates as its own line under
// it, indented, with an "S" in a circle: a service line. Each starts at its own quantity (the dispatch line 1, the rest
// 0, raised when the job needs them), price and cost. None is a "main" line; the heading carries no price of its own.
//   flutter test test/service_package_lines_test.dart
// Review pictures go to build/job_shots/package_*.png.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'job_page_fixture.dart';

/// The real Residential Service package's rate names; prices, costs and commissions are made up.
const _rates = [
  ('Service Call | Dispatch & Evaluation', 1.0, 89.0, 25.0),
  ('Service | Accessory Install & Program', 0.0, 65.0, 15.0),
  ('Service | Tune-Up', 0.0, 129.0, 30.0),
  ('Service | Standard Repair', 0.0, 185.0, 45.0),
  ('Service | Advanced Repair', 0.0, 325.0, 80.0),
  ('+ Additional Door Tune-Up & Service', 0.0, 79.0, 20.0),
  ('+ Priority Call', 0.0, 75.0, 0.0),
  ('+ Travel Charge', 0.0, 45.0, 0.0),
];

final Map<String, dynamic> _package = {
  'key': 'sf:residential service',
  'name': 'Residential Service',
  'sku': '',
  'category': 'Service Packages',
  'group': 'Service Packages',
  'kind': 'service',
  'rate': 89.0,
  'rateUses': 640,
  'rateMin': 89.0,
  'rateMax': 89.0,
  'cost': 25.0,
  'uses': 640,
  'taxable': false,
  'priceStatus': 'settled',
  'description': 'Diagnose and service a residential garage door and opener.',
  'rates': [
    for (final (name, qty, rate, cost) in _rates)
      {'name': name, 'description': '', 'qty': qty, 'rate': rate, 'cost': cost, 'paysCommission': true, 'commissionType': 'percent', 'commissionValue': 10},
  ],
};

FakeJobServer _server() => FakeJobServer()..extraCatalog = [_package];

Future<void> _toBlock(WidgetTester t) async {
  await t.ensureVisible(find.text('Products & Services'));
  await settle(t, frames: 6);
}

Future<void> _edit(WidgetTester t) async {
  await t.tap(find.text('Edit Job'));
  await settle(t, frames: 6);
}

Future<void> _pick(WidgetTester t, String query, String name) async {
  await t.ensureVisible(catalogSearch);
  await settle(t, frames: 3);
  await t.enterText(catalogSearch, query);
  await settle(t, frames: 8);
  await t.tap(find.text(name).last);
  await settle(t, frames: 10);
}

Future<void> _addPackage(WidgetTester t) async {
  await _edit(t);
  await _pick(t, 'residential service', 'Residential Service');
}

/// How many lines carry each mark (USER RULE 2026-11-20: "S" a service line, "I" an inventory item).
int _marks(String kind) => find.byKey(ValueKey('$kind-mark')).evaluate().length;

void main() {
  setUpAll(jobPageSetUp);

  testWidgets('picking a package adds its name as a heading and every rate as its own S line under it', (t) async {
    final s = _server();
    final errors = await pumpJobPage(t, s, size: const Size(1500, 2600), body: () async {
      await _toBlock(t);
      await _edit(t);
      final services = _marks('service'), items = _marks('item');
      await _pick(t, 'residential service', 'Residential Service');
      expect(find.text('Service package · 8 lines'), findsOneWidget, reason: 'one heading, the package name over its lines');
      expect(_marks('service') - services, 8, reason: 'an S on each of its lines');
      expect(_marks('item'), items, reason: 'none of them is an inventory item');
      for (final (name, _, _, _) in _rates) {
        expect(find.textContaining(name.split(' | ').last, findRichText: true), findsWidgets, reason: name);
      }
      // Each line is indented under the heading: its S sits in from where the heading's name starts.
      final heading = t.getRect(find.text('Residential Service').first);
      final mark = t.getRect(find.byKey(const ValueKey('service-mark')).last);
      expect(mark.left, greaterThan(heading.left), reason: 'the S sits in from the heading');
      expect(find.text('Main'), findsNothing, reason: 'no rate is the main one');
      // The heading has no price; the only charged package line is the dispatch line at 1.
      expect(find.text(r'$89.00'), findsWidgets);
      await saveJobShot(t, 'package_added_1500');
    });
    expect(errors.messages, isEmpty, reason: errors.messages.join('\n'));
  });

  testWidgets('every other line is marked: S for a service line, I for an inventory item', (t) async {
    final s = _server();
    await pumpJobPage(t, s, size: const Size(1500, 2600), body: () async {
      await _toBlock(t);
      // Service Fusion's own lines, read-only: each one marked, by what Service Fusion says it is.
      final readOnly = _marks('service') + _marks('item');
      expect(readOnly, greaterThan(0), reason: "Service Fusion's lines are marked too");
      await _edit(t);
      final services = _marks('service'), items = _marks('item');
      await _pick(t, 'liftmaster 87504', 'LiftMaster 87504 Smart Opener');
      expect(_marks('item') - items, 1, reason: 'a product is an inventory item: I');
      await _pick(t, 'spring replacement', 'Spring Replacement | Labor');
      expect(_marks('service') - services, 1, reason: 'a service without rates is one S line');
      expect(find.textContaining('Service package'), findsNothing, reason: 'and no package heading');
    });
  });

  testWidgets('the lines start at their own quantities: dispatch 1, the rest 0 (quieter)', (t) async {
    final s = _server();
    await pumpJobPage(t, s, size: const Size(1500, 2600), body: () async {
      await _toBlock(t);
      await _addPackage(t);
      // The quantities as the table writes them (two decimals).
      Finder qty(String text) => find.descendant(of: find.byKey(const ValueKey('col-qty')), matching: find.text(text));
      expect(qty('1.00'), findsWidgets, reason: 'the dispatch line');
      expect(qty('0.00'), findsNWidgets(7), reason: 'seven lines at 0, raised when the job needs them');
    });
  });

  testWidgets('Remove package takes all its lines at once, and Undo puts them all back', (t) async {
    final s = _server();
    await pumpJobPage(t, s, size: const Size(1500, 2600), body: () async {
      await _toBlock(t);
      await _edit(t);
      final before = _marks('service');
      await _pick(t, 'residential service', 'Residential Service');
      final actions = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.endsWith('-actions') && (w.key! as ValueKey<String>).value.startsWith('package-'));
      expect(actions, findsOneWidget);
      await t.ensureVisible(actions);
      await t.tap(actions);
      await settle(t, frames: 6);
      await t.tap(find.text('Remove package'));
      await settle(t, frames: 8);
      expect(_marks('service'), before);
      expect(find.text('Service package · 8 lines'), findsNothing);
      expect(find.textContaining('Removed "Residential Service" (8 lines)'), findsOneWidget);
      await t.tap(find.text('Undo'));
      await settle(t, frames: 8);
      expect(_marks('service'), before + 8);
      expect(find.text('Service package · 8 lines'), findsOneWidget);
    });
  });

  for (final size in const [Size(1280, 1800), Size(1920, 1800)]) {
    testWidgets('review picture at ${size.width.toInt()}', (t) async {
      final s = _server();
      await pumpJobPage(t, s, size: size, body: () async {
        await _toBlock(t);
        await _addPackage(t);
        await settle(t, frames: 16); // past the lines' light
        await saveJobShot(t, 'package_added_${size.width.toInt()}');
      });
    });
  }
}
