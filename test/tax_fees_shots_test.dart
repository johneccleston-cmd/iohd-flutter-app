// Review pictures of the Tax, discounts & fees redesign (2026-11-20): the panel on the estimate page at the office's
// window sizes, its forms, the table and totals after adding a tax, a discount and a fee, and the settings screen.
// They go to build/job_shots/tax_*.png; nothing here is a golden. Fails on any overflow or error on the page.
//   flutter test test/tax_fees_shots_test.dart

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/services/tax_settings_api.dart';
import 'package:iohd_desktop/tax_settings_screen.dart';
import 'package:iohd_desktop/widgets/dashboard_data.dart';

import 'job_page_fixture.dart';

Map<String, dynamic> _l(String name, {double qty = 1, double? rate, double? cost, bool taxable = false, String sku = ''}) => {
  'kind': 'item',
  'name': name,
  'sku': sku,
  'quantity': qty,
  'rate': rate,
  'cost': cost,
  'taxable': taxable,
  'source': 'catalog',
};

void _seed(FakeJobServer s) {
  s.addOption(kEstimateId, 'Insulated', [
    _l('Clopay | Classic Steel | 4300 | Complete Door | Almond', rate: 1489, cost: 912.4, sku: 'CL-4300-1607'),
    _l('LiftMaster 87504 Smart Opener', rate: 689, cost: 401.37, sku: 'LM-87504'),
    _l('Torsion Spring | 0.250 x 2" x 32"', qty: 2, rate: 89, cost: 19.5, sku: 'TS-25032'),
    _l('Installation | Door and Opener | Residential', rate: 450, cost: 120),
  ]);
}

Future<void> _open(WidgetTester t) async {
  await t.tap(find.text('Edit Estimate'));
  await settle(t, frames: 6);
  await t.ensureVisible(find.text('Tax, discounts & fees'));
  await settle(t, frames: 4);
  await t.tap(find.text('Tax, discounts & fees'));
  await settle(t, frames: 6);
}

Future<void> _shot(WidgetTester t, String name, {Size size = const Size(1500, 800), double textScale = 1, required Future<void> Function() then}) async {
  final s = FakeJobServer();
  _seed(s);
  DashClock.debugOverride = () => DateTime(2026, 11, 20, 10);
  addTearDown(() => DashClock.debugOverride = null);
  final errors = await pumpJobPage(t, s, id: kEstimateId, size: size, textScale: textScale, body: () async {
    debugDisableShadows = false;
    try {
      await then();
      await saveJobShot(t, name);
    } finally {
      debugDisableShadows = true;
    }
  });
  expect(errors.messages, isEmpty, reason: '$name: ${errors.messages}');
  expect(t.takeException(), isNull);
}

void main() {
  setUpAll(jobPageSetUp);
  setUp(() => TaxSettingsStore.instance.debugReset());

  for (final (label, size) in const [('1280x600', Size(1280, 600)), ('1366x768', Size(1366, 768)), ('1500x800', Size(1500, 800)), ('1920x940', Size(1920, 940))]) {
    testWidgets('the panel open, $label', (t) async {
      await _shot(t, 'tax_panel_$label', size: size, then: () => _open(t));
    });
  }

  testWidgets('the panel, large text (x1.3) at 1366x768', (t) async {
    await _shot(t, 'tax_panel_x13', size: const Size(1366, 768), textScale: 1.3, then: () => _open(t));
  });

  testWidgets('searching "spring": the sections that match, with their headings', (t) async {
    await _shot(t, 'tax_panel_search', then: () async {
      await _open(t);
      await t.enterText(find.byKey(const ValueKey('charges-search')), 'spring');
      await settle(t, frames: 4);
    });
  });

  testWidgets('Springdale: which county, the parts and the total', (t) async {
    await _shot(t, 'tax_place_springdale', then: () async {
      await _open(t);
      await t.enterText(find.byKey(const ValueKey('charges-search')), 'springdale');
      await settle(t, frames: 4);
      await t.tap(find.byKey(const ValueKey('charge-choice-AR-72-10')));
      await settle(t, frames: 6);
    });
  });

  testWidgets('a discount: % or \$, its amount and what it comes to', (t) async {
    await _shot(t, 'tax_discount_form', then: () async {
      await _open(t);
      await t.enterText(find.byKey(const ValueKey('charges-search')), 'clopay');
      await settle(t, frames: 4);
      await t.tap(find.byKey(const ValueKey('charge-choice-p:d-clopay')));
      await settle(t, frames: 6);
      await t.enterText(find.byKey(const ValueKey('charge-value')), '20');
      await settle(t, frames: 3);
    });
  });

  testWidgets('out of state', (t) async {
    await _shot(t, 'tax_out_of_state', then: () async {
      await _open(t);
      await t.enterText(find.byKey(const ValueKey('charges-search')), 'out-of-state');
      await settle(t, frames: 4);
      await t.tap(find.byKey(const ValueKey('charge-choice-oos')));
      await settle(t, frames: 6);
      await t.enterText(find.byKey(const ValueKey('oos-rate')), '8.225');
      await settle(t, frames: 3);
    });
  });

  testWidgets('after: Rogers on two lines, a 20% discount and the card fee, with the totals', (t) async {
    await _shot(t, 'tax_after', size: const Size(1500, 1300), then: () async {
      await _open(t);
      await t.enterText(find.byKey(const ValueKey('charges-search')), 'rogers');
      await settle(t, frames: 4);
      await t.tap(find.byKey(const ValueKey('charge-choice-AR-04-02')));
      await settle(t, frames: 6);
      await t.tap(find.byKey(const ValueKey('add-tax')));
      await settle(t, frames: 8);
      for (var i = 0; i < 2; i++) {
        await t.tap(find.text('No tax').first);
        await settle(t, frames: 4);
        await t.tap(find.text('Rogers').last);
        await settle(t, frames: 4);
      }
      for (final (q, key, v) in [('clopay', 'charge-choice-p:d-clopay', '20'), ('credit card', 'charge-choice-p:f-card', '')]) {
        await t.tap(find.text('Tax, discounts & fees'));
        await settle(t, frames: 6);
        await t.enterText(find.byKey(const ValueKey('charges-search')), q);
        await settle(t, frames: 4);
        await t.tap(find.byKey(ValueKey(key)));
        await settle(t, frames: 6);
        if (v.isNotEmpty) await t.enterText(find.byKey(const ValueKey('charge-value')), v);
        await settle(t, frames: 2);
        await t.tap(find.byKey(const ValueKey('save-charge')));
        await settle(t, frames: 8);
      }
      ScaffoldMessenger.of(t.element(find.text('Tax, discounts & fees'))).hideCurrentSnackBar();
      await settle(t, frames: 6);
      await t.ensureVisible(find.text('Estimate total').last);
      await settle(t, frames: 4);
    });
  });

  testWidgets('the settings screen (Inventory > Tax, Discounts & Fees)', (t) async {
    t.view.physicalSize = const Size(1500, 1500);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    DashClock.debugOverride = () => DateTime(2026, 11, 20, 10);
    addTearDown(() => DashClock.debugOverride = null);
    final key = GlobalKey();
    await http.runWithClient(() async {
      await t.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
            home: const Scaffold(body: TaxSettingsScreen()),
          ),
        ),
      );
      await settle(t, frames: 8);
      await t.enterText(find.descendant(of: find.byKey(const ValueKey('tax-lookup')), matching: find.byType(TextField)), 'spring');
      await settle(t, frames: 4);
      await saveShotOf(t, key, 'tax_settings_screen');
    }, () => MockClient((req) async => http.Response(json.encode({'settings': null, 'version': null}), 200)));
    expect(t.takeException(), isNull);
  });
}
