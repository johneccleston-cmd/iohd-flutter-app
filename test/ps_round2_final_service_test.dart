// Products & Services round 2 finalization (2026-11-23), the service page: the shared row menu words (A2), commission
// limits checked before anything is sent (A5) and the 25-rate cap in the editor (B10). The server refuses the same
// (integrity-backend test/ps_round2_final.test.js).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/service_detail_screen.dart';
import 'package:iohd_desktop/services/line_items_api.dart';

import 'dashboard_harness.dart';

CatalogEntry _service(List<ServiceRate> rates) => CatalogEntry(
  key: 'sf:service call',
  name: 'Residential Service',
  kind: 'service',
  category: 'Service Packages',
  group: 'Service Packages',
  rate: 75,
  cost: 15,
  uses: 412,
  editedFields: const ['rates'],
  rates: rates,
);

const _two = [
  ServiceRate(name: 'Dispatch & Evaluation', qty: 1, rate: 89, cost: 20, paysCommission: true, commissionType: 'percent', commissionValue: 10),
  ServiceRate(name: 'After hours', qty: 0, rate: 120, cost: 30, paysCommission: true, commissionType: 'fixed', commissionValue: 10),
];

Future<List<List<ServiceRate>>> _open(WidgetTester t, CatalogEntry service) async {
  final sent = <List<ServiceRate>>[];
  t.view.physicalSize = const Size(1500, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
      home: ServiceDetailScreen(
        serviceKey: service.key,
        loader: () async => (entries: [service], canSeeCost: true, historyDays: 540),
        saver: (key, fields) async => service,
        ratesSaver: (key, rates) async {
          sent.add(rates);
          return service;
        },
      ),
    ),
  );
  await t.pumpAndSettle();
  await t.tap(find.text('Edit'));
  await t.pumpAndSettle();
  return sent;
}

Finder _field(String key) => find.byKey(ValueKey('field:$key'));

void main() {
  setUpAll(loadDashFonts);

  testWidgets('A2: a rate\'s menu has the line table\'s words: Copy / Delete (rates are dragged, not moved from the menu)', (t) async {
    await _open(t, _service(_two));
    await t.tap(find.byKey(const ValueKey('rate-menu:1')));
    await t.pumpAndSettle();
    for (final w in ['Copy', 'Delete']) {
      expect(find.text(w), findsOneWidget, reason: w);
    }
    // Moved by dragging their handle, or Alt+Up / Alt+Down (the user 2026-11-24).
    expect(find.text('Move up'), findsNothing);
    expect(find.text('Move down'), findsNothing);
    expect(find.text('Duplicate rate'), findsNothing);
    expect(find.text('Remove rate'), findsNothing);
  });

  testWidgets('A5: a \$ commission above its line\'s rate is refused on the page, with the rate in the words, and nothing is sent', (t) async {
    final sent = await _open(t, _service(_two));
    await t.enterText(_field('rate1.commission'), '500');
    await t.pump();
    expect(find.text('Over rate'), findsOneWidget, reason: 'the PAYS cell says so as it is typed');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(find.textContaining("A \$ commission can't be more than the line's rate (\$120.00)."), findsOneWidget);
    expect(sent, isEmpty);
    // Up to the rate itself is fine, and the amount typed is what is saved (never trimmed to fit).
    await t.enterText(_field('rate1.commission'), '120');
    await t.pump();
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(sent.single[1].commissionValue, 120);
  });

  testWidgets('A5: a % commission needs a priced line', (t) async {
    final sent = await _open(t, _service(_two));
    await t.enterText(_field('rate0.rate'), '');
    await t.pump();
    expect(find.text('No price'), findsOneWidget);
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(find.textContaining('A % commission needs a price on the line.'), findsOneWidget);
    expect(sent, isEmpty);
  });

  testWidgets('B10: at 25 rates Add rate and Copy are greyed out and the page says why; no 26th line is made', (t) async {
    final sent = await _open(t, _service([for (var i = 0; i < 25; i++) ServiceRate(name: 'Line ${i + 1}', qty: i == 0 ? 1 : 0, rate: 10)]));
    expect(find.text('25 rates at most'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('add-rate')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('field:rate25.name')), findsNothing, reason: 'no 26th line');
    await t.ensureVisible(find.byKey(const ValueKey('rate-menu:0')));
    await t.tap(find.byKey(const ValueKey('rate-menu:0')));
    await t.pumpAndSettle();
    await t.tap(find.text('Copy'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('field:rate25.name')), findsNothing, reason: 'Copy is greyed out too');
    expect(sent, isEmpty);
  });
}
