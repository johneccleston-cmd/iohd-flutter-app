// Renders the Products & Services block on the job and estimate pages at the desktop sizes the office uses, with
// realistic data (several options, many lines, long descriptions, discounts, hidden lines, lines with no cost, a line
// that loses money), and fails on any overflow. The pictures go to build/job_shots/ps_*.png for review; nothing here
// is a golden.
//   flutter test test/products_services_shots_test.dart

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart' show SkeletonPulse;
import 'package:iohd_desktop/widgets/line_items_editor.dart';

import 'job_page_fixture.dart';

const _sizes = <String, Size>{
  '1280x600': Size(1280, 600),
  '1366x768': Size(1366, 768),
  '1500x800': Size(1500, 800),
  '1920x940': Size(1920, 940),
};

const _specs = 'SIZE : 16\' 0" X 7\' 0"\nMODEL : 4300 | R-Value 12.9 | 25 Ga Steel\nASSEMBLY TYPE : COMPLETE DOOR\n'
    'PANEL INSULATION : POLYURETHANE\nWINDOWS : 4 Stockton, insulated\nHARDWARE : Spade handles, black';

Map<String, dynamic> _l(String name, {double qty = 1, double? rate, double? cost, bool taxable = true, String description = '', String sku = '', bool discount = false}) => {
  'kind': discount ? 'discount' : 'item',
  'name': name,
  'description': description,
  'sku': sku,
  'quantity': qty,
  'rate': rate,
  'cost': cost,
  'taxable': taxable,
  'source': 'catalog',
};

/// Four options the way the office builds them, from a cheap builder-grade door to a premium carriage house.
void _seedEstimate(FakeJobServer s, {bool accepted = false}) {
  s.addOption(kEstimateId, 'Builder grade', [
    _l('SMH | Gallery Steel | GD5S | Complete Door | Sandtone (Clay)', rate: 527.72, cost: 507.16, description: '16x7 GD5S complete door, non-insulated'),
    _l("Weather Seal | Stop Mold | 7' Sandtone", qty: 2, rate: 4.46, cost: 4.46),
    _l('SMH Installation | Gallery Steel | 16x7 | Sandtone', rate: 300, cost: 0, taxable: false),
  ], taxRate: 10.5);
  s.addOption(
    kEstimateId,
    'Insulated',
    [
      _l('Clopay | Classic Steel | 4300 | Complete Door | Almond', rate: 1489, cost: 912.4, description: _specs, sku: 'CL-4300-1607'),
      _l('LiftMaster 87504 Smart Opener', rate: 689, cost: 401.37, description: 'Wi-Fi belt drive opener with battery backup and two remotes', sku: 'LM-87504'),
      _l('Torsion Spring | 0.250 x 2" x 32"', qty: 2, rate: 89, cost: 19.5, sku: 'TS-25032'),
      _l("Weather Seal | Stop Mold | 16' Almond", rate: 10.2, cost: 10.2),
      _l('Installation | Door and Opener | Residential', rate: 450, cost: 120, taxable: false),
    ],
    taxRate: 10.5,
    recommended: true,
    accepted: accepted,
  );
  s.addOption(kEstimateId, 'Premium carriage house', [
    _l('Clopay | Canyon Ridge | Carriage House | 5-Layer | Ultra-Grain Cypress, Medium finish with Cypress overlays', rate: 6420, cost: 4410, description: _specs, sku: 'CL-CR-5L'),
    _l('LiftMaster 98022 Jackshaft Opener', rate: 1149, cost: 702.18, description: 'Wall mount, battery backup, myQ, camera kit', sku: 'LM-98022'),
    _l('Decorative Hardware Kit | Black | Spade', rate: 189, cost: 64),
    _l('Keyless Entry Pad', rate: 79, cost: null),
    _l('Haul away and disposal of the old door', rate: 125, cost: 40, taxable: false),
    _l('Paint touch-up on the jambs (warranty courtesy)', rate: 60, cost: 95, taxable: false),
    _l('Installation | Carriage House | Two techs, full day', rate: 950, cost: 380, taxable: false),
    _l('Loyal customer discount', rate: 250, taxable: false, discount: true),
  ], taxRate: 10.5);
  s.addOption(kEstimateId, 'Repair only', [
    _l('Spring Replacement | Labor', rate: 150, cost: null, taxable: false),
    _l('Torsion Spring | 0.250 x 2" x 32"', qty: 2, rate: 89, cost: 19.5, sku: 'TS-25032'),
  ], taxRate: 10.5);
}

/// [text] inside the line items (the page has a "Description" of its own, in Details).
Finder _inTable(String text) => find.descendant(of: find.byType(LineItemsEditor), matching: find.text(text));

/// The pointer resting on [target], for the hover states.
Future<void> _hover(WidgetTester t, Finder target) async {
  final g = await t.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: Offset.zero);
  addTearDown(g.removePointer);
  await g.moveTo(t.getCenter(target));
  await settle(t, frames: 6);
}

/// The block's title at the top of the window, as someone who scrolled down to it sees it.
Future<void> _toBlock(WidgetTester t) async {
  await t.ensureVisible(find.text('Products & Services'));
  await settle(t, frames: 6);
}

Future<void> _shoot(
  WidgetTester t,
  FakeJobServer s,
  String name, {
  String id = kEstimateId,
  Size size = const Size(1500, 800),
  double textScale = 1,
  Future<void> Function()? then,
}) async {
  final errors = await pumpJobPage(t, s, id: id, size: size, textScale: textScale, body: () async {
    // Real shadows, as the app draws them (the test framework otherwise draws every shadow as a hard black outline,
    // which made the menus look boxed in). Put back before the test ends: the framework checks it.
    debugDisableShadows = false;
    try {
      await _toBlock(t);
      if (then != null) await then();
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

  group('a phone-narrow window with large text (420px, text x1.3)', () {
    // The rest of the page has overflows of its own at this size (the status pills, the Task List strip); only this
    // block's files are checked here.
    bool ours(String m) => m.contains('line_items_editor.dart') || m.contains('job_detail_items.dart') || m.contains('catalog_search_field.dart');
    for (final (name, id, edit) in [('estimate', kEstimateId, false), ('estimate_editing', kEstimateId, true), ('job', kJobId, false), ('job_editing', kJobId, true)]) {
      testWidgets(name, (t) async {
        final s = FakeJobServer();
        _seedEstimate(s);
        final errors = await pumpJobPage(t, s, id: id, size: const Size(420, 2600), textScale: 1.3, body: () async {
          await _toBlock(t);
          if (edit) {
            await t.tap(find.byIcon(Icons.edit_outlined).first);
            await settle(t, frames: 6);
          }
          await saveJobShot(t, 'ps_stress_${name}_420');
        });
        expect(errors.messages.where(ours), isEmpty, reason: '${errors.messages}');
        t.takeException(); // the rest of the page's own overflows (see above)
      });
    }
  });

  group('estimate with four options (admin)', () {
    for (final e in _sizes.entries) {
      testWidgets('viewport ${e.key}', (t) async {
        final s = FakeJobServer();
        _seedEstimate(s);
        await _shoot(t, s, 'ps_estimate_${e.key}', size: e.value);
      });
    }
    for (final w in [1280.0, 1366.0, 1500.0, 1920.0]) {
      testWidgets('whole block ${w.toInt()} wide', (t) async {
        final s = FakeJobServer();
        _seedEstimate(s);
        await _shoot(t, s, 'ps_estimate_full_${w.toInt()}', size: Size(w, 1500));
      });
    }
    testWidgets('the premium option, its lines and the notes', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      s.optionsOf(kEstimateId)[2].notes = 'Includes removal of the old door and opener.\nLead time 4 to 6 weeks from order.\n'
          'Lifetime limited warranty on sections; 5 years on hardware.';
      await _shoot(t, s, 'ps_estimate_premium_1500', size: const Size(1500, 1500), then: () async {
        await t.tap(find.text('Premium carriage house').first);
        await settle(t, frames: 6);
        await t.tap(_inTable('Description').first);
        await settle(t, frames: 4);
      });
    });
    testWidgets('while the lines load: a skeleton shaped like the table', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      final hold = s.holdOptions = Completer<void>();
      await _shoot(t, s, 'ps_estimate_loaded_1366', size: const Size(1366, 1000), then: () async {
        expect(find.byType(SkeletonPulse), findsOneWidget);
        await saveJobShot(t, 'ps_estimate_loading_1366');
        hold.complete();
        await settle(t, frames: 6);
        expect(find.byType(SkeletonPulse), findsNothing);
      });
    });
    testWidgets('the option menu', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      await _shoot(t, s, 'ps_estimate_menu_1366', size: const Size(1366, 1100), then: () async {
        await t.tap(find.byKey(const ValueKey('option-actions')));
        await settle(t, frames: 4);
      });
    });
    testWidgets('editing preview, a changed line and a removed one', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      await _shoot(t, s, 'ps_estimate_editing_1500', size: const Size(1500, 1300), then: () async {
        await t.tap(find.text('Edit Estimate'));
        await settle(t, frames: 6);
        await t.tap(find.text('Torsion Spring | 0.250 x 2" x 32"').first);
        await settle(t, frames: 3);
        await t.enterText(find.byKey(const ValueKey('line-2-qty')), '3');
        await settle(t, frames: 3);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(t, frames: 3);
        await t.tap(find.text('LiftMaster 87504 Smart Opener').first);
        await settle(t, frames: 3);
      });
    });
    testWidgets('editing: the pointer on a line shows what can be changed, its steps and its actions', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      await _shoot(t, s, 'ps_estimate_editing_hover_1500', size: const Size(1500, 1300), then: () async {
        await t.tap(find.text('Edit Estimate'));
        await settle(t, frames: 6);
        await _hover(t, find.text('Torsion Spring | 0.250 x 2" x 32"').first);
      });
    });
    testWidgets('editing, nothing open yet', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      await _shoot(t, s, 'ps_estimate_editing_rest_1366', size: const Size(1366, 1300), then: () async {
        await t.tap(find.text('Edit Estimate'));
        await settle(t, frames: 6);
      });
    });
    testWidgets('accepted and sent to the job', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s, accepted: true);
      s.optionsOf(kEstimateId)[1].convertedJobId = kJobId;
      await _shoot(t, s, 'ps_estimate_accepted_1366', size: const Size(1366, 1200));
    });
    testWidgets('someone who can\'t see costs', (t) async {
      final s = FakeJobServer(canSeeCost: false, canEdit: false);
      _seedEstimate(s);
      await _shoot(t, s, 'ps_estimate_nocost_1280', size: const Size(1280, 1200));
    });
    testWidgets('a narrow window', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      await _shoot(t, s, 'ps_estimate_narrow_900', size: const Size(900, 1600));
    });
    testWidgets('a narrow window, editing', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      await _shoot(t, s, 'ps_estimate_narrow_editing_760', size: const Size(760, 1800), then: () async {
        await t.tap(find.byIcon(Icons.edit_outlined).first);
        await settle(t, frames: 6);
      });
    });
  });

  // The four office sizes in both views (user 2026-11-13 QA list), editing included.
  group('estimate, editing at each office size', () {
    for (final e in _sizes.entries) {
      testWidgets('editing ${e.key}', (t) async {
        final s = FakeJobServer();
        _seedEstimate(s);
        await _shoot(t, s, 'ps_estimate_editing_${e.key}', size: e.value, then: () async {
          await t.tap(find.text('Edit Estimate'));
          await settle(t, frames: 6);
          await _toBlock(t);
          await t.scrollUntilVisible(find.byKey(const ValueKey('line-0-more')), 200, scrollable: find.byType(Scrollable).first);
          await settle(t, frames: 4);
        });
      });
    }
  });

  // Every awkward line at once, from what prod really has (checked 2026-11-13): a quantity of 0 (17% of Service Fusion's
  // lines), a fraction (68.57 ft of stop mold), 2,400 screws, a very long name and description, no SKU, no cost, no price,
  // a $0 line, a discount.
  group('edge cases', () {
    void seedEdges(FakeJobServer s) => s.addOption(kEstimateId, 'Edge cases', [
      _l('Clopay | Canyon Ridge | Carriage House | 5-Layer | Ultra-Grain Cypress, Medium finish with Cypress overlays, arched windows and wrought iron hardware, two-car', rate: 6420, cost: 4410, description: '$_specs\nNOTE : Customer wants the windows on the top section only, and the hardware painted to match the trim.', sku: 'CL-CR-5L-ARCH-16070'),
      _l('Stop Mold | Install New Standard Color', qty: 68.57, rate: 0.61, cost: 0.2),
      _l("7'16\" Head #3 Tek Screws | Retail Accessories", qty: 2400, rate: 0.21, cost: 0.04, sku: 'TEK-3'),
      _l('Spring Replacement | Labor', qty: 1.5, rate: 150, taxable: false),
      _l('Site visit (no charge)', qty: 0, rate: 95, cost: 0, taxable: false),
      _l('Courtesy adjustment', rate: 0, cost: 0, taxable: false),
      _l('Keyless Entry Pad (price to be confirmed)', rate: null, cost: 31.5),
      _l('Builder discount', rate: 125, taxable: false, discount: true),
    ], taxRate: 10.5);
    for (final (w, h) in [(1280.0, 1500.0), (1920.0, 1400.0)]) {
      testWidgets('read-only ${w.toInt()}', (t) async {
        final s = FakeJobServer();
        seedEdges(s);
        await _shoot(t, s, 'ps_edges_${w.toInt()}', size: Size(w, h), then: () async {
          await t.tap(_inTable('Description').first);
          await settle(t, frames: 4);
        });
      });
      testWidgets('editing ${w.toInt()}', (t) async {
        final s = FakeJobServer();
        seedEdges(s);
        await _shoot(t, s, 'ps_edges_editing_${w.toInt()}', size: Size(w, h), then: () async {
          await t.tap(find.text('Edit Estimate'));
          await settle(t, frames: 6);
          await t.tap(_inTable('68.57'));
          await settle(t, frames: 3);
        });
      });
    }
    testWidgets('Service Fusion\'s own odd lines on a job: a discount kept as an item at -\$0.10 x 35,125.30', (t) async {
      final rec = jobRecord();
      final job = rec['job'] as Map<String, dynamic>;
      job['raw_items'] = [
        {'item_index': 1, 'name': 'Install New Standard Color Stop Mold | Weather Seal | Taxable', 'multiplier': 4481, 'rate': 0.61, 'total': 2733.41, 'cost': 896.2, 'tax': 'Sales Tax', 'is_show_rate_items': true},
        {'item_index': 2, 'name': 'Stop Mold | Install New Standard Color', 'multiplier': 68.57, 'rate': 0.61, 'total': 41.83, 'cost': 13.71, 'tax': 'Sales Tax', 'is_show_rate_items': true},
        {'item_index': 3, 'name': 'Door section, ordered (to be installed on the return visit)', 'multiplier': 0, 'rate': 389, 'total': 0, 'cost': 0, 'tax': null, 'is_show_rate_items': false},
        {'item_index': 4, 'name': '10% Discount (Doors & Openers)', 'multiplier': 35125.3, 'rate': -0.1, 'total': -3512.53, 'cost': null, 'tax': null, 'is_show_rate_items': true},
      ];
      job.remove('total_revenue');
      final s = FakeJobServer(records: {kJobId: rec, kEstimateId: estimateRecord()});
      await _shoot(t, s, 'ps_job_sf_odd_1366', id: kJobId, size: const Size(1366, 1000));
    });
  });

  group('estimate with many lines', () {
    // A big commercial estimate: 24 lines, a few with long descriptions, some hidden, some with no cost, a discount.
    void seedMany(FakeJobServer s) => s.addOption(kEstimateId, 'Warehouse, 12 doors', [
      for (var i = 1; i <= 24; i++)
        _l(
          i % 7 == 0 ? 'Installation | Commercial sectional | Dock door $i, two techs' : (i % 5 == 0 ? 'Clopay | 3200 Commercial | 12x14 | Insulated, ribbed, with vision lites and a chain hoist' : 'Door part $i | Hinge #$i | 14 ga'),
          qty: ((i % 4) + 1).toDouble(),
          rate: 12.5 * i + (i % 5 == 0 ? 2400 : 0),
          cost: i % 6 == 0 ? null : (6.0 * i + (i % 5 == 0 ? 1500 : 0)),
          taxable: i % 7 != 0,
          description: i % 5 == 0 ? _specs : '',
          sku: i % 3 == 0 ? 'CP-$i' : '',
        ),
      _l('Volume discount', rate: 400, taxable: false, discount: true),
    ], taxRate: 10.5);
    testWidgets('read-only', (t) async {
      final s = FakeJobServer();
      seedMany(s);
      await _shoot(t, s, 'ps_estimate_many_1920', size: const Size(1920, 2000));
    });
    testWidgets('editing', (t) async {
      final s = FakeJobServer();
      seedMany(s);
      await _shoot(t, s, 'ps_estimate_many_editing_1366', size: const Size(1366, 2200), then: () async {
        await t.tap(find.text('Edit Estimate'));
        await settle(t, frames: 6);
        await t.tap(find.text('Door part 4 | Hinge #4 | 14 ga').first);
        await settle(t, frames: 3);
      });
    });
    testWidgets('at 1280, read-only', (t) async {
      final s = FakeJobServer();
      seedMany(s);
      await _shoot(t, s, 'ps_estimate_many_1280', size: const Size(1280, 2000));
    });
  });

  // Every menu in the block, open; one near the window's bottom edge; and the tax menu frame by frame while it opens
  // and closes (round 2, 2026-11-13: the menus' motion).
  group('menus and popovers', () {
    Future<void> edit(WidgetTester t) async {
      await t.tap(find.text('Edit Estimate'));
      await settle(t, frames: 6);
    }

    testWidgets('the tax select', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      await _shoot(t, s, 'ps_menu_tax_1366', size: const Size(1366, 900), then: () async {
        await edit(t);
        await t.tap(_inTable('Taxable 10.5%').first);
        await settle(t, frames: 4);
      });
    });
    testWidgets('the tax select, frame by frame', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      await _shoot(t, s, 'ps_motion_tax_rest', size: const Size(1366, 900), then: () async {
        await edit(t);
        await t.tap(_inTable('Taxable 10.5%').first);
        var at = 0;
        for (final ms in [16, 48, 80, 120, 180]) {
          await t.pump(Duration(milliseconds: ms - at));
          at = ms;
          await saveJobShot(t, 'ps_motion_tax_open_${ms}ms');
        }
        await settle(t, frames: 3);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        at = 0;
        for (final ms in [16, 48, 80, 120]) {
          await t.pump(Duration(milliseconds: ms - at));
          at = ms;
          await saveJobShot(t, 'ps_motion_tax_close_${ms}ms');
        }
        await settle(t, frames: 3);
      });
    });
    testWidgets('the tax select on a line at the window\'s bottom edge', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      await _shoot(t, s, 'ps_menu_tax_edge_1280x600', size: const Size(1280, 600), then: () async {
        await edit(t);
        final last = _inTable('No tax').last;
        await Scrollable.ensureVisible(t.element(last), alignment: 1);
        await settle(t, frames: 4);
        await t.tap(last);
        await settle(t, frames: 4);
      });
    });
    testWidgets('a line\'s actions', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      await _shoot(t, s, 'ps_menu_row_1366', size: const Size(1366, 900), then: () async {
        await edit(t);
        await t.tap(find.byKey(const ValueKey('line-1-actions')));
        await settle(t, frames: 4);
      });
    });
    testWidgets('Tax, discounts & fees', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      await _shoot(t, s, 'ps_menu_charges_1366', size: const Size(1366, 900), then: () async {
        await edit(t);
        await t.ensureVisible(find.text('Tax, discounts & fees'));
        await settle(t, frames: 3);
        await t.tap(find.text('Tax, discounts & fees'));
        await settle(t, frames: 4);
      });
    });
    testWidgets('New option', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      await _shoot(t, s, 'ps_menu_new_option_1366', size: const Size(1366, 900), then: () async {
        await t.tap(find.text('New option'));
        await settle(t, frames: 4);
      });
    });
    testWidgets('a line deleted, frame by frame', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      await _shoot(t, s, 'ps_motion_delete_after', size: const Size(1366, 900), then: () async {
        await edit(t);
        await t.tap(find.byKey(const ValueKey('line-1-actions')));
        await settle(t, frames: 3);
        await t.tap(find.text('Delete').last);
        var at = 0;
        for (final ms in [0, 40, 90, 140, 200]) {
          await t.pump(Duration(milliseconds: ms - at));
          at = ms;
          await saveJobShot(t, 'ps_motion_delete_${ms}ms');
        }
        await settle(t, frames: 4);
      });
    });
    testWidgets('a description opening, frame by frame', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      await _shoot(t, s, 'ps_motion_desc_after', size: const Size(1366, 900), then: () async {
        await t.tap(_inTable('Description').first);
        var at = 0;
        for (final ms in [0, 50, 100, 200]) {
          await t.pump(Duration(milliseconds: ms - at));
          at = ms;
          await saveJobShot(t, 'ps_motion_desc_${ms}ms');
        }
        await settle(t, frames: 3);
      });
    });
    testWidgets('the catalog search\'s results', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      await _shoot(t, s, 'ps_menu_catalog_1366', size: const Size(1366, 900), then: () async {
        await edit(t);
        await t.ensureVisible(catalogSearch);
        await settle(t, frames: 3);
        await t.enterText(catalogSearch, 'spring');
        await settle(t, frames: 6);
      });
    });
  });

  group('estimate with no options', () {
    testWidgets('Service Fusion\'s items, its tax worked out from its total', (t) async {
      final s = FakeJobServer();
      await _shoot(t, s, 'ps_estimate_sf_1366', size: const Size(1366, 1000));
    });
  });

  group('job', () {
    testWidgets('Service Fusion\'s items, charges and a discount (admin)', (t) async {
      final s = FakeJobServer();
      await _shoot(t, s, 'ps_job_sf_1366', id: kJobId, size: const Size(1366, 1000));
    });
    testWidgets('Service Fusion\'s items, editing', (t) async {
      final s = FakeJobServer();
      await _shoot(t, s, 'ps_job_sf_editing_1920', id: kJobId, size: const Size(1920, 1100), then: () async {
        await t.tap(find.text('Edit Job'));
        await settle(t, frames: 6);
      });
    });
    testWidgets('the job\'s own items, from an estimate', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      final from = s.optionsOf(kEstimateId)[1];
      final id = s.addOption(kJobId, 'Job items', [for (final i in from.items) Map<String, dynamic>.from(i)], taxRate: 10.5, source: 'estimate');
      s.optionsOf(kJobId).firstWhere((o) => o.id == id)
        ..sourceEstimateId = kEstimateId
        ..sourceOptionId = from.id;
      await _shoot(t, s, 'ps_job_set_1500', id: kJobId, size: const Size(1500, 1100));
    });
    testWidgets('many lines', (t) async {
      final rec = jobRecord();
      final job = rec['job'] as Map<String, dynamic>;
      job['raw_items'] = [
        for (var i = 1; i <= 18; i++)
          {
            'item_index': i,
            'name': i % 5 == 0 ? 'Custom carriage house door with arched glass, wrought iron hardware and a matching side entry door, painted on site' : 'Door part $i | Hinge #$i | 14 ga',
            'multiplier': (i % 4) + 1,
            'rate': 12.5 * i,
            'total': 12.5 * i * ((i % 4) + 1),
            'cost': i % 7 == 0 ? null : 6.0 * i * ((i % 4) + 1),
            'tax': i % 3 == 0 ? null : 'Sales Tax',
            'is_show_rate_items': i % 6 != 0,
            'description': i % 6 == 0 ? _specs : '',
          },
      ];
      job.remove('total_revenue');
      final s = FakeJobServer(records: {kJobId: rec, kEstimateId: estimateRecord()});
      await _shoot(t, s, 'ps_job_many_1920', id: kJobId, size: const Size(1920, 1700));
    });
  });

  // Round 3 (2026-11-13): the defects and the estimate's own option, for review next to the round 2 pictures.
  group('round 3', () {
    Future<TestGesture> mouse(WidgetTester t) async {
      final g = await t.createGesture(kind: PointerDeviceKind.mouse);
      await g.addPointer(location: Offset.zero);
      addTearDown(g.removePointer);
      return g;
    }

    Future<void> editIt(WidgetTester t) async {
      await t.tap(find.text('Edit Estimate'));
      await settle(t, frames: 8);
      await _toBlock(t);
    }

    testWidgets('the estimate\'s own option on show, read-only and editing', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      await _shoot(t, s, 'ps_r3_estimate_option_view_1366', size: const Size(1366, 1000), then: () async {
        await t.tap(find.byKey(const ValueKey('option-tab-sf')));
        await settle(t, frames: 4);
      });
      await _shoot(t, s, 'ps_r3_estimate_option_edit_1366', size: const Size(1366, 1000), then: () async {
        await t.tap(find.byKey(const ValueKey('option-tab-sf')));
        await settle(t, frames: 4);
        await editIt(t);
      });
    });
    testWidgets('an alternative on show, editing', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      await _shoot(t, s, 'ps_r3_alternative_edit_1366', size: const Size(1366, 1000), then: () => editIt(t));
    });
    testWidgets('a qty arrow clicked on a closed line, the pointer moved away', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      await _shoot(t, s, 'ps_r3_arrow_closed_after_1366', size: const Size(1366, 1000), then: () async {
        await editIt(t);
        final m = await mouse(t);
        final up = find.bySemanticsLabel('One more').at(2);
        await m.moveTo(t.getCenter(up));
        await settle(t, frames: 2);
        await t.tap(up);
        await settle(t, frames: 3);
        await m.moveTo(Offset.zero);
        await settle(t, frames: 4);
      });
    });
    testWidgets('a qty arrow under the pointer (its hover look)', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      await _shoot(t, s, 'ps_r3_arrow_hover_1366', size: const Size(1366, 1000), then: () async {
        await editIt(t);
        final m = await mouse(t);
        await m.moveTo(t.getCenter(find.bySemanticsLabel('One more').at(2)));
        await settle(t, frames: 4);
      });
    });
    testWidgets('a qty arrow clicked in an open line, a return stepped toward 0', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      await _shoot(t, s, 'ps_r3_arrow_open_line_1366', size: const Size(1366, 1000), then: () async {
        await editIt(t);
        await t.tap(_inTable('2.00').first);
        await settle(t, frames: 3);
        await t.enterText(find.byKey(const ValueKey('line-2-qty')), '-3');
        await settle(t, frames: 2);
        await t.tap(find.descendant(of: find.byKey(const ValueKey('col-qty')).at(3), matching: find.bySemanticsLabel('One more')));
        await settle(t, frames: 4);
      });
    });
    testWidgets('Description on a line with none, editing: the line opens in place', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      await _shoot(t, s, 'ps_r3_desc_opens_line_1366', size: const Size(1366, 1000), then: () async {
        await editIt(t);
        await t.tap(find.byKey(const ValueKey('line-2-more')));
        await settle(t, frames: 5);
      });
    });
    testWidgets('the pointer over a read-only line (nothing lights up)', (t) async {
      final s = FakeJobServer();
      _seedEstimate(s);
      await _shoot(t, s, 'ps_r3_hover_readonly_1366', size: const Size(1366, 1000), then: () async {
        final m = await mouse(t);
        await m.moveTo(t.getCenter(_inTable('LiftMaster 87504 Smart Opener')));
        await settle(t, frames: 4);
      });
    });
    testWidgets('no cost column, editing', (t) async {
      final s = FakeJobServer(canSeeCost: false);
      _seedEstimate(s);
      await _shoot(t, s, 'ps_r3_nocost_edit_1280', size: const Size(1280, 1000), then: () => editIt(t));
    });
  });

  // Round 4 (2026-11-13): the option tabs on the table, the tax column with real long names, negative and fractional
  // quantities, and the four office window sizes, read-only and editing, job and estimate.
  group('round 4', () {
    // The commonest tax on prod (2,867 lines): "Sales Tax (State, County, & Local Use Tax, Springdale, Washington)".
    const longTax = 'Sales Tax (State, County, & Local Use Tax, Springdale, Washington)';

    /// The estimate as Service Fusion has it, with the long tax name, a return (-1), a fractional quantity (1.5) and a
    /// catalog entry at 0; its total still adds up, so the tax is worked out from it.
    void sfEstimate(FakeJobServer s) {
      final job = s.records[kEstimateId]!['job'] as Map<String, dynamic>;
      final items = [for (final it in job['raw_items'] as List) Map<String, dynamic>.from(it as Map)];
      for (final it in items) {
        if (it['tax'] != null) it['tax'] = longTax;
      }
      items.addAll([
        {'item_index': 7, 'name': "Return | Stop Mold | 16' Sandtone", 'product': 'Return', 'multiplier': -1, 'rate': 10.2, 'total': -10.2, 'cost': -10.2, 'tax': longTax},
        {'item_index': 8, 'name': 'Lubricant | Garage door spray | per can', 'product': 'Lubricant', 'multiplier': 1.5, 'rate': 8, 'total': 12, 'cost': 4.5, 'tax': null},
        {'item_index': 9, 'name': 'Keypad | LiftMaster 877MAX (optional)', 'product': 'Keypad', 'multiplier': 0, 'rate': 59, 'total': 0, 'cost': 0, 'tax': longTax},
      ]);
      job['raw_items'] = items;
      job['total_revenue'] = '908.48';
      job['due_total'] = '908.48';
    }

    /// The job as Service Fusion has it: its tax charge named in full, a return, a fractional quantity and a 0 line.
    void sfJob(FakeJobServer s) {
      final job = s.records[kJobId]!['job'] as Map<String, dynamic>;
      final items = [for (final it in job['raw_items'] as List) Map<String, dynamic>.from(it as Map)];
      items.addAll([
        {'item_index': 7, 'name': "Return | Stop Mold | 7' Sandtone", 'product': 'Return', 'multiplier': -1, 'rate': 4.46, 'total': -4.46, 'cost': -4.46, 'tax': 'Sales Tax'},
        {'item_index': 8, 'name': 'Haul away | per cubic yard', 'service': 'Haul away', 'multiplier': 2.5, 'rate': 12, 'total': 30, 'cost': 10, 'tax': null},
        {'item_index': 9, 'name': 'Keypad | LiftMaster 877MAX (optional)', 'product': 'Keypad', 'multiplier': 0, 'rate': 59, 'total': 0, 'cost': 0, 'tax': 'Sales Tax'},
      ]);
      job['raw_items'] = items;
      job['other_charges'] = [
        {'name': longTax, 'is_discount': false, 'is_percentage': true, 'rate': 10.5, 'total': 112.2261},
        {'name': 'Builder Relationship Discount', 'is_discount': true, 'is_percentage': false, 'rate': 50, 'total': 50},
      ];
      job['total_revenue'] = '1761.05';
      job['due_total'] = '1761.05';
    }

    /// Four options of ours, one with a long name, the recommended one (it opens first) with a return, a fractional
    /// quantity and a catalog entry at 0.
    void seed(FakeJobServer s) {
      sfEstimate(s);
      sfJob(s);
      s.addOption(kEstimateId, 'Builder grade', [
        _l('SMH | Gallery Steel | GD5S | Complete Door | Sandtone (Clay)', rate: 527.72, cost: 507.16, description: '16x7 GD5S complete door, non-insulated'),
        _l("Weather Seal | Stop Mold | 7' Sandtone", qty: 2, rate: 4.46, cost: 4.46),
        _l('SMH Installation | Gallery Steel | 16x7 | Sandtone', rate: 300, cost: 0, taxable: false),
      ], taxRate: 10.5);
      s.addOption(
        kEstimateId,
        'Insulated',
        [
          _l('Clopay | Classic Steel | 4300 | Complete Door | Almond', rate: 1489, cost: 912.4, description: _specs, sku: 'CL-4300-1607'),
          _l('LiftMaster 87504 Smart Opener', rate: 689, cost: 401.37, description: 'Wi-Fi belt drive opener with battery backup and two remotes', sku: 'LM-87504'),
          _l('Torsion Spring | 0.250 x 2" x 32"', qty: 2, rate: 89, cost: 19.5, sku: 'TS-25032'),
          _l('Return | Torsion Spring | 0.207 x 1.75" x 30" (wrong size)', qty: -1, rate: 89, cost: 19.5, sku: 'TS-20730'),
          _l('Track lubrication | per door', qty: 1.5, rate: 18, cost: 3.25),
          _l('Keypad | LiftMaster 877MAX (optional)', qty: 0, rate: 59, cost: 31.2, sku: 'LM-877MAX'),
          _l('Installation | Door and Opener | Residential', rate: 450, cost: 120, taxable: false),
        ],
        taxRate: 10.5,
        recommended: true,
      );
      s.addOption(kEstimateId, 'Premium carriage house with full-view glass, smart opener and keypad package', [
        _l('Clopay | Canyon Ridge | Carriage House | 5-Layer | Ultra-Grain Cypress, Medium finish with Cypress overlays', rate: 6420, cost: 4410, description: _specs, sku: 'CL-CR-5L'),
        _l('LiftMaster 98022 Jackshaft Opener', rate: 1149, cost: 702.18, sku: 'LM-98022'),
        _l('Installation | Carriage House | Two techs, full day', rate: 950, cost: 380, taxable: false),
        _l('Loyal customer discount', rate: 250, taxable: false, discount: true),
      ], taxRate: 10.5);
      s.addOption(kEstimateId, 'Repair only', [
        _l('Spring Replacement | Labor', rate: 150, cost: null, taxable: false),
        _l('Torsion Spring | 0.250 x 2" x 32"', qty: 2, rate: 89, cost: 19.5, sku: 'TS-25032'),
      ], taxRate: 10.5);
    }

    Future<void> edit(WidgetTester t, {bool job = false}) async {
      await t.tap(find.text(job ? 'Edit Job' : 'Edit Estimate'));
      await settle(t, frames: 8);
      await _toBlock(t);
    }

    for (final e in _sizes.entries) {
      testWidgets('estimate ${e.key}', (t) async {
        final s = FakeJobServer();
        seed(s);
        await _shoot(t, s, 'ps_r4_estimate_${e.key}', size: e.value);
        await _shoot(t, s, 'ps_r4_estimate_editing_${e.key}', size: e.value, then: () => edit(t));
      });
      testWidgets('job ${e.key}', (t) async {
        final s = FakeJobServer();
        seed(s);
        await _shoot(t, s, 'ps_r4_job_${e.key}', id: kJobId, size: e.value);
        await _shoot(t, s, 'ps_r4_job_editing_${e.key}', id: kJobId, size: e.value, then: () => edit(t, job: true));
      });
    }
    testWidgets('the whole block, estimate and job, read-only and editing', (t) async {
      final s = FakeJobServer();
      seed(s);
      await _shoot(t, s, 'ps_r4_estimate_full_1366', size: const Size(1366, 1500));
      await _shoot(t, s, 'ps_r4_estimate_full_editing_1366', size: const Size(1366, 1700), then: () => edit(t));
      await _shoot(t, s, 'ps_r4_job_full_1500', id: kJobId, size: const Size(1500, 1300));
      await _shoot(t, s, 'ps_r4_job_full_editing_1500', id: kJobId, size: const Size(1500, 1400), then: () => edit(t, job: true));
    });
    testWidgets('the estimate\'s own option (long tax names), read-only and editing', (t) async {
      final s = FakeJobServer();
      seed(s);
      Future<void> sf() async {
        await t.tap(find.byKey(const ValueKey('option-tab-sf')));
        await settle(t, frames: 6);
      }

      await _shoot(t, s, 'ps_r4_sf_option_1366', size: const Size(1366, 1100), then: sf);
      await _shoot(t, s, 'ps_r4_sf_option_editing_1366', size: const Size(1366, 1100), then: () async {
        await sf();
        await edit(t);
      });
    });
    testWidgets('only the estimate\'s own option (no options made here)', (t) async {
      final s = FakeJobServer();
      sfEstimate(s);
      await _shoot(t, s, 'ps_r4_sf_only_1366', size: const Size(1366, 1000));
    });
    testWidgets('no cost column, read-only and editing', (t) async {
      final s = FakeJobServer(canSeeCost: false);
      seed(s);
      await _shoot(t, s, 'ps_r4_nocost_1366', size: const Size(1366, 1000));
      await _shoot(t, s, 'ps_r4_nocost_editing_1366', size: const Size(1366, 1000), then: () => edit(t));
    });
    testWidgets('large text (x1.3), read-only and editing', (t) async {
      final s = FakeJobServer();
      seed(s);
      await _shoot(t, s, 'ps_r4_text130_1366', size: const Size(1366, 1100), textScale: 1.3);
      await _shoot(t, s, 'ps_r4_text130_editing_1500', size: const Size(1500, 1200), textScale: 1.3, then: () => edit(t));
    });
    testWidgets('nine options with long names', (t) async {
      final s = FakeJobServer();
      seed(s);
      for (final n in ['Good', 'Better', 'Best (insulated steel, 3-layer)', 'Commercial rolling steel door']) {
        s.addOption(kEstimateId, n, [_l('Torsion Spring | 0.250 x 2" x 32"', qty: 2, rate: 89, cost: 19.5)], taxRate: 10.5);
      }
      await _shoot(t, s, 'ps_r4_many_options_1280', size: const Size(1280, 900));
      await _shoot(t, s, 'ps_r4_many_options_1920', size: const Size(1920, 900));
    });
    testWidgets('interaction states: tab hover and keyboard focus, menus, a switch mid-fade, a narrow block', (t) async {
      final s = FakeJobServer();
      seed(s);
      Finder tab(int i) => find.byKey(ValueKey('option-tab-${s.optionsOf(kEstimateId)[i].id}'));
      await _shoot(t, s, 'ps_r4_tab_hover_1366', size: const Size(1366, 900), then: () => _hover(t, tab(0)));
      await _shoot(t, s, 'ps_r4_tab_focus_1366', size: const Size(1366, 900), then: () async {
        // Keyboard: Tab from the block's New option onto the tabs.
        Focus.of(t.element(find.text('New option'))).requestFocus();
        await settle(t, frames: 2);
        for (var i = 0; i < 3; i++) {
          await t.sendKeyEvent(LogicalKeyboardKey.tab);
          await settle(t, frames: 2);
        }
      });
      await _shoot(t, s, 'ps_r4_switch_mid_1366', size: const Size(1366, 900), then: () async {
        await t.tap(tab(0));
        await t.pump();
        await t.pump(const Duration(milliseconds: 50));
      });
      await _shoot(t, s, 'ps_r4_option_menu_1366', size: const Size(1366, 900), then: () async {
        await t.tap(find.byKey(const ValueKey('option-actions')));
        await settle(t, frames: 4);
      });
      await _shoot(t, s, 'ps_r4_tax_menu_1366', size: const Size(1366, 900), then: () async {
        await t.tap(find.byKey(const ValueKey('option-tab-sf')));
        await settle(t, frames: 4);
        await edit(t);
        await t.tap(_inTable('Springdale 10.5%').first);
        await settle(t, frames: 4);
      });
      await _shoot(t, s, 'ps_r4_narrow_760', size: const Size(760, 1400));
    });
    testWidgets('nine options: the "+N more" menu', (t) async {
      final s = FakeJobServer();
      seed(s);
      for (final n in ['Good', 'Better', 'Best (insulated steel, 3-layer)', 'Commercial rolling steel door']) {
        s.addOption(kEstimateId, n, [_l('Torsion Spring | 0.250 x 2" x 32"', qty: 2, rate: 89, cost: 19.5)], taxRate: 10.5);
      }
      await _shoot(t, s, 'ps_r4_more_menu_1280', size: const Size(1280, 900), then: () async {
        await t.tap(find.byKey(const ValueKey('option-tab-more')));
        await settle(t, frames: 4);
      });
    });
    testWidgets('an accepted alternative', (t) async {
      final s = FakeJobServer();
      sfEstimate(s);
      s.addOption(kEstimateId, 'Builder grade', [_l("Weather Seal | Stop Mold | 7' Sandtone", qty: 2, rate: 4.46, cost: 4.46)], taxRate: 10.5);
      s.addOption(kEstimateId, 'Insulated', [_l('LiftMaster 87504 Smart Opener', rate: 689, cost: 401.37)], taxRate: 10.5, accepted: true);
      await _shoot(t, s, 'ps_r4_accepted_1366', size: const Size(1366, 1000));
    });
  });
}
