// Tax, discounts & fees redesign (2026-11-20): the Arkansas catalog, the math for taxes, percentage discounts and fees,
// and the panel in the Products & Services table.
//   flutter test test/tax_discounts_fees_test.dart
//
// USER RULE 2026-11-20: adding a tax taxes nothing; it becomes a choice in each line's Tax dropdown, and only lines set
// to it are taxed. Fees and discounts are never taxed.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/utils/charge_presets.dart';
import 'package:iohd_desktop/utils/line_item_math.dart';
import 'package:iohd_desktop/utils/sales_tax_catalog.dart';
import 'package:iohd_desktop/widgets/dashboard_data.dart';
import 'package:iohd_desktop/widgets/line_items_editor.dart';

const _today = '2026-11-20';

int _rate(String sfName, String day) => ArkansasTax.fromServiceFusionName(sfName, day)!.milli;

/// Every Service Fusion tax name and rate charged on production since 2024 (read-only query, 2026-11-20), with the first
/// and last job dates. The catalog gives each one's rate on both days, except where DFA changed a rate and Service Fusion
/// was not updated (listed in [_sfBehind]).
const _sfCharged = <(String, double, String, String)>[
  ('Sales Tax (State & County, Benton)', 7.5, '2024-07-29', '2026-10-14'),
  ('Sales Tax (State & County, Carroll)', 7, '2024-10-07', '2026-05-18'),
  ('Sales Tax (State, County, & Local Use Tax, Alma)', 9.75, '2025-08-05', '2025-08-05'),
  ('Sales Tax (State, County, & Local Use Tax, Avoca)', 8.5, '2025-03-28', '2025-03-28'),
  ('Sales Tax (State, County, & Local Use Tax, Bella Vista)', 9.5, '2024-08-12', '2026-11-28'),
  ('Sales Tax (State, County, & Local Use Tax, Benton)', 9.375, '2025-07-31', '2026-10-07'),
  ('Sales Tax (State, County, & Local Use Tax, Bentonville)', 9.5, '2024-06-04', '2027-01-03'),
  ('Sales Tax (State, County, & Local Use Tax, Berryville)', 9, '2025-11-10', '2026-11-05'),
  ('Sales Tax (State, County, & Local Use Tax, Cave Springs)', 9.75, '2024-07-09', '2026-11-09'),
  ('Sales Tax (State, County, & Local Use Tax, Centerton)', 9.5, '2024-07-18', '2027-01-03'),
  ('Sales Tax (State, County, & Local Use Tax, Decatur)', 9.5, '2025-01-20', '2026-11-18'),
  ('Sales Tax (State, County, & Local Use Tax, Elkins)', 10.5, '2025-04-28', '2026-09-16'),
  ('Sales Tax (State, County, & Local Use Tax, Elm Springs, Benton)', 8.5, '2025-10-01', '2026-06-30'),
  ('Sales Tax (State, County, & Local Use Tax, Elm Springs, Washington)', 8.75, '2024-12-02', '2026-11-29'),
  ('Sales Tax (State, County, & Local Use Tax, Eureka Springs)', 9.375, '2024-08-09', '2026-11-23'),
  ('Sales Tax (State, County, & Local Use Tax, Farmington)', 9.75, '2024-10-08', '2026-12-17'),
  ('Sales Tax (State, County, & Local Use Tax, Fayetteville)', 9.75, '2024-06-17', '2026-11-29'),
  ('Sales Tax (State, County, & Local Use Tax, Fort Smith)', 9.5, '2026-12-02', '2026-12-02'),
  ('Sales Tax (State, County, & Local Use Tax, Garfield)', 9, '2024-07-19', '2026-01-23'),
  ('Sales Tax (State, County, & Local Use Tax, Gentry)', 9.5, '2024-07-22', '2026-12-01'),
  ('Sales Tax (State, County, & Local Use Tax, Goshen)', 9.75, '2025-03-10', '2026-04-14'),
  ('Sales Tax (State, County, & Local Use Tax, Gravette)', 9.5, '2024-11-14', '2026-12-09'),
  ('Sales Tax (State, County, & Local Use Tax, Harrison)', 9.5, '2026-04-09', '2026-05-27'),
  ('Sales Tax (State, County, & Local Use Tax, Highfill)', 9.5, '2024-07-25', '2026-08-06'),
  ('Sales Tax (State, County, & Local Use Tax, Hot Springs)', 9.5, '2026-05-12', '2026-06-23'),
  ('Sales Tax (State, County, & Local Use Tax, Huntsville)', 10, '2024-12-10', '2026-10-22'),
  ('Sales Tax (State, County, & Local Use Tax, Johnson (city))', 10.75, '2026-08-28', '2026-08-28'),
  ('Sales Tax (State, County, & Local Use Tax, Lincoln)', 10.75, '2024-08-28', '2026-11-26'),
  ('Sales Tax (State, County, & Local Use Tax, Lowell)', 9.5, '2024-07-29', '2027-01-03'),
  ('Sales Tax (State, County, & Local Use Tax, Madison)', 10.5, '2025-07-31', '2025-07-31'),
  ('Sales Tax (State, County, & Local Use Tax, Mena)', 9.5, '2026-06-19', '2026-11-20'),
  ('Sales Tax (State, County, & Local Use Tax, North Little Rock)', 9.5, '2026-01-12', '2026-09-02'),
  ('Sales Tax (State, County, & Local Use Tax, Pea Ridge)', 9.5, '2024-09-18', '2026-10-21'),
  ('Sales Tax (State, County, & Local Use Tax, Prairie Grove)', 10.5, '2024-08-20', '2027-01-03'),
  ('Sales Tax (State, County, & Local Use Tax, Rogers)', 9.5, '2024-07-16', '2026-11-29'),
  ('Sales Tax (State, County, & Local Use Tax, Russellville)', 9, '2025-10-17', '2026-02-04'),
  ('Sales Tax (State, County, & Local Use Tax, Shirley)', 9, '2025-08-04', '2025-08-04'),
  ('Sales Tax (State, County, & Local Use Tax, Siloam Springs)', 9.5, '2024-07-26', '2027-01-03'),
  ('Sales Tax (State, County, & Local Use Tax, Springdale, Benton)', 9.5, '2024-07-17', '2026-12-09'),
  ('Sales Tax (State, County, & Local Use Tax, Springdale, Washington)', 9.75, '2024-07-30', '2027-01-03'),
  ('Sales Tax (State, County, & Local Use Tax, St. Paul)', 11, '2026-04-02', '2026-04-02'),
  ('Sales Tax (State, County, & Local Use Tax, Tontitown)', 10.5, '2024-08-12', '2027-01-03'),
  ('Sales Tax (State, County, & Local Use Tax, Van Buren (city))', 9.25, '2026-02-06', '2026-02-06'),
  ('Sales Tax (State, County, & Local Use Tax, Washington)', 9.5, '2025-01-17', '2026-09-10'),
  ('Sales Tax (State, County, & Local Use Tax, West Fork)', 10.75, '2025-12-31', '2025-12-31'),
  ('Sales Tax (State & County, Madison)', 9, '2025-04-25', '2026-06-16'),
  ('Sales Tax (State & County, Madison)', 10, '2026-08-05', '2026-12-06'),
  ('Sales Tax (State & County, Pulaski)', 7.5, '2026-06-23', '2026-06-23'),
  ('Sales Tax (State & County, Searcy)', 8, '2025-08-25', '2025-08-25'),
  ('Sales Tax (State & County, Washington)', 7.75, '2024-12-13', '2026-09-23'),
];

/// Where Service Fusion kept charging a rate after DFA changed it (its tax setting was never updated): Madison County
/// went from 2.5% to 3.5% on 2025-10-01; Saline County's 0.375% (Benton city) ended the same day.
const _sfBehind = {
  'Sales Tax (State, County, & Local Use Tax, Benton)',
  'Sales Tax (State, County, & Local Use Tax, Huntsville)',
  'Sales Tax (State, County, & Local Use Tax, St. Paul)',
};

Future<void> _pump(WidgetTester t, Widget editor, {Size size = const Size(1500, 1000), double textScale = 1}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  DashClock.debugOverride = () => DateTime(2026, 11, 20, 10);
  addTearDown(() => DashClock.debugOverride = null);
  await t.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: size, disableAnimations: true, textScaler: TextScaler.linear(textScale)),
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: Scaffold(body: SingleChildScrollView(child: editor)),
      ),
    ),
  );
  await t.pumpAndSettle();
}

LineItemsEditor _editor(List<LineDraft> lines, {double? taxRate, List<SalesTax> taxOptions = const [], List<LineSummaryRow>? summary}) =>
    LineItemsEditor(lines: lines, taxRate: taxRate, editable: true, showCost: true, onPreviewSave: () {}, taxOptions: taxOptions, summary: summary);

const _door = LineDraft(name: 'Garage Door 16x7', quantity: 1, rate: 1000, cost: 600);
const _opener = LineDraft(name: 'Opener', quantity: 1, rate: 500, cost: 300);

Future<void> _openPanel(WidgetTester t) async {
  await t.tap(find.text('Tax, discounts & fees'));
  await t.pumpAndSettle();
}

Future<void> _search(WidgetTester t, String q) async {
  await t.enterText(find.byKey(const ValueKey('charges-search')), q);
  await t.pumpAndSettle();
}

void main() {
  group('the Arkansas catalog (DFA quarterly tables)', () {
    test('the state, every county and every city, each with dated rates', () {
      expect(ArkansasTax.milliOn(ArkansasTax.state, _today), 6500);
      expect(ArkansasTax.rateOn(ArkansasTax.state, _today)!.from, '2013-07-01');
      final counties = ArkansasTax.all.where((j) => j.level == TaxLevel.county).toList();
      final cities = ArkansasTax.all.where((j) => j.level == TaxLevel.city).toList();
      expect(counties, hasLength(75), reason: 'all 75 Arkansas counties are in DFA\'s table');
      expect(cities.length, greaterThan(340));
      for (final j in ArkansasTax.all) {
        expect(j.periods, isNotEmpty, reason: j.name);
        for (var i = 1; i < j.periods.length; i++) {
          expect(j.periods[i - 1].to, isNotNull, reason: '${j.name}: a period before another ends');
          expect(j.periods[i - 1].to!.compareTo(j.periods[i].from), lessThan(0), reason: '${j.name}: periods don\'t overlap');
        }
        for (final c in j.counties) {
          expect(ArkansasTax.county(c), isNotNull, reason: '${j.name} is in county $c');
        }
      }
      // Counties at 0% are not offered (no local tax there that day).
      expect(ArkansasTax.counties(_today).map((c) => c.name), isNot(contains('Saline County')));
      expect(ArkansasTax.counties(_today).map((c) => c.name), isNot(contains('Monroe County')));
    });

    test('a place is the state + its county + its city, each once, at the day\'s rates', () {
      final rogers = TaxComposition(day: _today, county: ArkansasTax.countyNamed('Benton'), city: ArkansasTax.cityNamed('Rogers'));
      expect(rogers.parts.map((p) => (p.name, p.milli)), [('Arkansas state', 6500), ('Benton County', 1000), ('Rogers', 2000)]);
      expect(rogers.milli, 9500);
      expect(rogers.serviceFusionName, 'Sales Tax (State, County, & Local Use Tax, Rogers)');
      // A city in two counties is named with the county it is in, as Service Fusion names it.
      final springdale = ArkansasTax.cityNamed('Springdale')!;
      expect(springdale.counties, ['72', '04']);
      expect(TaxComposition(day: _today, county: ArkansasTax.county('72'), city: springdale).milli, 9750);
      expect(TaxComposition(day: _today, county: ArkansasTax.county('04'), city: springdale).milli, 9500);
      expect(TaxComposition(day: _today, county: ArkansasTax.county('04'), city: springdale).serviceFusionName, 'Sales Tax (State, County, & Local Use Tax, Springdale, Benton)');
      // Unincorporated: state + county.
      expect(TaxComposition(day: _today, county: ArkansasTax.countyNamed('Washington')).milli, 7750);
      // A city in a county with no county tax: state + city only.
      final benton = TaxComposition(day: _today, county: ArkansasTax.countyNamed('Saline'), city: ArkansasTax.cityNamed('Benton'));
      expect(benton.parts.map((p) => p.name), ['Arkansas state', 'Benton']);
      // Every place's name reads back as the same place.
      for (final c in ArkansasTax.cities(_today)) {
        for (final n in c.counties) {
          final comp = TaxComposition(day: _today, county: ArkansasTax.county(n), city: c);
          final back = ArkansasTax.fromServiceFusionName(comp.serviceFusionName, _today);
          expect(back?.city?.id, c.id, reason: comp.serviceFusionName);
          expect(back?.county?.id, comp.county!.id, reason: comp.serviceFusionName);
        }
      }
    });

    test('rates change on their day; history is kept', () {
      const madison = 'Sales Tax (State & County, Madison)';
      expect(_rate(madison, '2025-09-30'), 9000);
      expect(_rate(madison, '2025-10-01'), 10000, reason: 'Madison County went to 3.5% on Oct 1, 2025');
      const bentonCity = 'Sales Tax (State, County, & Local Use Tax, Benton)';
      expect(_rate(bentonCity, '2025-09-30'), 9375);
      expect(_rate(bentonCity, '2025-10-01'), 9000, reason: 'Saline County\'s 0.375% was rescinded on Oct 1, 2025');
      // Announced by DFA for Jan 1, 2027 (tool/tax/announced_changes.csv).
      final boone = ArkansasTax.countyNamed('Boone')!;
      expect(ArkansasTax.milliOn(boone, '2026-12-31'), 1250);
      expect(ArkansasTax.milliOn(boone, '2027-01-01'), 1000);
      expect(boone.periods.last.announced, isTrue);
    });

    test('every tax Service Fusion charged since 2024 is the catalog\'s rate on its days (except where SF fell behind DFA)', () {
      var checked = 0;
      for (final (name, rate, first, last) in _sfCharged) {
        final m = (rate * 1000).round();
        expect(ArkansasTax.fromServiceFusionName(name, first), isNotNull, reason: name);
        if (_sfBehind.contains(name) || (name.endsWith('Madison)') && rate == 9)) {
          // Service Fusion's rate is the catalog's from before DFA's change on 2025-10-01, and not the one since.
          expect(_rate(name, '2025-09-30'), m, reason: '$name before Oct 1, 2025');
          expect(_rate(name, last), isNot(m), reason: '$name: DFA changed it, Service Fusion did not');
        } else {
          expect(_rate(name, first), m, reason: '$name on $first');
          expect(_rate(name, last), m, reason: '$name on $last');
        }
        checked++;
      }
      expect(checked, 50);
    });

    test('a rate change typed in on the settings screen holds from its day', () {
      final rogers = ArkansasTax.cityNamed('Rogers')!;
      addTearDown(() => ArkansasTax.changes = const []);
      ArkansasTax.changes = [TaxRateChange(jurisdictionId: rogers.id, milli: 2250, from: '2027-04-01', note: 'test')];
      expect(ArkansasTax.milliOn(rogers, '2027-03-31'), 2000);
      expect(ArkansasTax.milliOn(rogers, '2027-04-01'), 2250);
      expect(ArkansasTax.nextAfter(rogers, _today), (2250, '2027-04-01', true));
    });
  });

  group('the math', () {
    test('two taxes on their own lines, each rounded once; a tax on no line charges nothing', () {
      final lines = [
        _door.copyWith(taxable: true, taxName: 'A'),
        _opener.copyWith(taxable: true, taxName: 'B'),
        const LineDraft(name: 'Labor', quantity: 1, rate: 333.33, cost: 0),
      ];
      final t = computeLineTotals(lines, null, taxRates: {'A': 9.75, 'B': 9.5, 'C': 10});
      expect(t.taxes.map((f) => (f.name, f.baseCents, f.taxCents)), [('A', 100000, 9750), ('B', 50000, 4750), ('C', 0, 0)], reason: 'C is on no line: \$0.00');
      expect(t.taxCents, 14500);
      expect(t.totalCents, 183333 + 14500);
    });

    test('percentage discount off the items, percentage fee on items less discounts; fees never taxed, never a missing cost', () {
      final lines = [
        _door.copyWith(taxable: true, taxName: 'A'),
        const LineDraft(kind: LineKind.discount, name: 'Clopay', percent: 20),
        const LineDraft(kind: LineKind.fee, name: 'Card fee', percent: 3, taxable: true, taxName: 'A'),
        const LineDraft(kind: LineKind.fee, name: 'Trip', rate: 45),
      ];
      final t = computeLineTotals(lines, null, taxRates: {'A': 10});
      expect(t.discountCents, 20000);
      expect(t.lines[2].amountCents, 2400, reason: '3% of \$800 (items less the discount)');
      expect(t.feeCents, 2400 + 4500);
      expect(t.taxCents, 10000, reason: '10% of the door only: a discount does not lower it unless set to, a fee is never taxed');
      expect(t.missingCostLines, 0, reason: 'a fee has no cost to enter');
      // Decision 8 (2026-11-23): the card fee goes to the processor, so it is not profit; the trip charge still is.
      expect(t.processingFeeCents, 2400);
      expect(t.profitCents, 100000 - 20000 + 6900 - 2400 - 60000);
      expect(t.totalCents, 100000 - 20000 + 6900 + 10000);
    });

    test('a discount never lowers any tax, even one marked taxable (USER RULE 2026-11-20: tax is per line, discounts are off the total)', () {
      final lines = [
        _door.copyWith(taxable: true, taxName: 'A'), // $1,000 at 10%
        _opener.copyWith(taxable: true, taxName: 'B'), // $500 at 5%
        const LineDraft(kind: LineKind.discount, name: 'Builder', rate: 300, taxable: true),
        const LineDraft(kind: LineKind.discount, name: 'Clopay', percent: 20),
      ];
      final t = computeLineTotals(lines, null, taxRates: {'A': 10, 'B': 5});
      expect(t.taxes.map((f) => (f.name, f.baseCents)), [('A', 100000), ('B', 50000)], reason: 'each tax on its lines\' own amounts');
      expect(t.taxCents, 10000 + 2500);
      expect(t.discountCents, 30000 + 30000);
      expect(t.totalCents, 150000 - 60000 + 12500);
    });

    test('the one-rate formula the backend shares is unchanged with no fees or percentages', () {
      final t = computeLineTotals([_door.copyWith(taxable: true), const LineDraft(kind: LineKind.discount, name: 'd', rate: 100, taxable: true)], 9.75);
      expect(t.taxCents, 9750, reason: '9.75% of the door: the discount never lowers it');
      expect(t.taxes.single.name, isNull);
    });

    test('a fee and a percentage survive the JSON round trip; parsePercent', () {
      const fee = LineDraft(kind: LineKind.fee, name: 'Card', percent: 3);
      final back = LineDraft.fromJson(fee.toJson());
      expect(back.isFee, isTrue);
      expect(back.percent, 3);
      expect(back.sameAs(fee), isTrue);
      expect(parsePercent('2.5 %'), 2.5);
      expect(parsePercent('9.375%'), 9.375);
      expect(parsePercent('x'), isNull);
    });

    test('a record\'s own tax still takes its "Sales Tax" lines when another tax is added beside it', () {
      const own = SalesTax('Sales Tax (State, County, & Local Use Tax, Bentonville)', 9.5, onRecord: true);
      const added = SalesTax('Sales Tax (State, County, & Local Use Tax, Rogers)', 9.5, kind: SalesTaxKind.arkansas);
      expect(SalesTax.resolve('Sales Tax', [own]), own);
      expect(SalesTax.resolve('Sales Tax', [own, added]), own);
      expect(SalesTax.resolve(added.name, [own, added]), added);
    });
  });

  group('the panel', () {
    testWidgets('adding Rogers taxes nothing; it becomes a choice in a line\'s Tax, and only that line is taxed', (t) async {
      await _pump(t, _editor([_door, _opener]));
      expect(find.text(r'$1,500.00'), findsWidgets);
      await _openPanel(t);
      await _search(t, 'rogers');
      expect(find.byKey(const ValueKey('charge-choice-AR-04-02')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('charge-choice-AR-04-02')));
      await t.pumpAndSettle();
      // The parts and the total, with the days the rates took effect.
      expect(find.text('Arkansas state'), findsOneWidget);
      expect(find.text('Benton County'), findsOneWidget);
      expect(find.text('9.5%'), findsWidgets);
      await t.tap(find.byKey(const ValueKey('add-tax')));
      await t.pumpAndSettle();
      expect(find.textContaining('Choose it in a line\'s Tax column'), findsOneWidget);
      expect(find.text('Sales tax Rogers'), findsOneWidget, reason: 'the tax line is on the record');
      expect(find.text(r'$1,500.00'), findsWidgets, reason: 'the total is unchanged: nothing is taxed yet');
      // Line 1's Tax: No tax -> Rogers.
      await t.tap(find.text('No tax').first);
      await t.pumpAndSettle();
      await t.tap(find.text('Rogers').last);
      await t.pumpAndSettle();
      expect(find.text(r'$95.00'), findsNWidgets(2), reason: '9.5% of the door only (its line, and Taxes, fees & discounts)');
      expect(find.text(r'$1,595.00'), findsWidgets);
    });

    testWidgets('a set\'s own-rate lines keep saying so after another tax is added (found in real Chrome)', (t) async {
      await _pump(t, _editor([_door.copyWith(taxable: true), _opener.copyWith(taxable: true)], taxRate: 10));
      expect(find.text('Taxable'), findsNWidgets(2));
      await _openPanel(t);
      await _search(t, 'rogers');
      await t.tap(find.byKey(const ValueKey('charge-choice-AR-04-02')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('add-tax')));
      await t.pumpAndSettle();
      expect(find.text('Taxable'), findsNWidgets(2), reason: 'they were labelled "Rogers 9.5%"');
      expect(find.text('Rogers'), findsNothing);
      expect(find.text(r'$150.00'), findsNWidgets(2), reason: 'still 10% of \$1,500 (its line, and Taxes, fees & discounts)');
      // Their menu ticks the set's rate and offers Rogers beside it.
      await t.tap(find.text('Taxable').first);
      await t.pumpAndSettle();
      expect(find.text('Rogers'), findsWidgets);
      expect(find.byIcon(Icons.check_rounded), findsWidgets);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
    });

    testWidgets('a city in two counties asks which; a place already on the record is never added twice', (t) async {
      await _pump(
        t,
        _editor([_door], taxOptions: const [SalesTax('Sales Tax (State, County, & Local Use Tax, Springdale, Benton)', 9.5, onRecord: true)]),
      );
      await _openPanel(t);
      await _search(t, 'springdale');
      await t.tap(find.byKey(const ValueKey('charge-choice-AR-72-10')));
      await t.pumpAndSettle();
      expect(find.text('Which county is the job in?'), findsOneWidget);
      expect(find.text('9.75%'), findsWidgets, reason: 'Washington County first (the city\'s own county): 6.5 + 1.25 + 2');
      await t.tap(find.byKey(const ValueKey('county-AR-04')));
      await t.pumpAndSettle();
      expect(find.text('Already on this record'), findsOneWidget);
      expect(t.widget<FilledButton>(find.byKey(const ValueKey('add-tax'))).onPressed, isNull);
      await t.tap(find.byKey(const ValueKey('county-AR-72')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('add-tax')));
      await t.pumpAndSettle();
      // Both are now choices in the line's Tax.
      await t.tap(find.text('No tax').first);
      await t.pumpAndSettle();
      expect(find.text('Springdale, Benton'), findsWidgets);
      expect(find.text('Springdale, Washington'), findsWidgets);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
    });

    testWidgets('removing a tax sets its lines to No tax, and Undo puts both back', (t) async {
      await _pump(
        t,
        _editor(
          [_door.copyWith(taxable: true, taxName: 'Sales Tax (State, County, & Local Use Tax, Rogers)'), _opener],
          taxOptions: const [SalesTax('Sales Tax (State, County, & Local Use Tax, Rogers)', 9.5, onRecord: true)],
        ),
      );
      expect(find.text(r'$95.00'), findsNWidgets(2), reason: 'its line, and Taxes, fees & discounts');
      await _openPanel(t);
      await t.tap(find.byKey(const ValueKey('charge-choice-rt:Sales Tax (State, County, & Local Use Tax, Rogers)')));
      await t.pumpAndSettle();
      expect(find.textContaining('1 line is set to this tax'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('remove-tax')));
      await t.pumpAndSettle();
      expect(find.text(r'$95.00'), findsNothing);
      expect(find.textContaining('1 line now No tax'), findsOneWidget);
      await t.tap(find.text('Undo'));
      await t.pumpAndSettle();
      expect(find.text(r'$95.00'), findsNWidgets(2), reason: 'the tax and its line are back');
    });

    testWidgets('a percentage discount and a card fee: added, changed, removed; the box never moves when % and \$ swap', (t) async {
      await _pump(t, _editor([_door, _opener]));
      await _openPanel(t);
      await _search(t, 'clopay');
      await t.tap(find.byKey(const ValueKey('charge-choice-p:d-clopay')));
      await t.pumpAndSettle();
      final box = t.getRect(find.byKey(const ValueKey('charge-value')));
      await t.tap(find.byKey(const ValueKey('mode-Dollar amount')));
      await t.pumpAndSettle();
      expect(t.getRect(find.byKey(const ValueKey('charge-value'))), box, reason: 'the amount box stays put');
      await t.tap(find.byKey(const ValueKey('mode-Percentage')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('charge-value')), '20');
      await t.pumpAndSettle();
      expect(find.textContaining(r'Takes $300.00 off'), findsOneWidget, reason: '20% of \$1,500');
      await t.tap(find.byKey(const ValueKey('save-charge')));
      await t.pumpAndSettle();
      expect(find.text(r'-$300.00'), findsWidgets);
      // The line shows its percentage where an item's rate is, in its box while editing ("20" with its "%").
      expect(find.text('20'), findsOneWidget);
      // The card fee: 3% of the items less the discount.
      await _openPanel(t);
      await _search(t, 'credit card');
      await t.tap(find.byKey(const ValueKey('charge-choice-p:f-card')));
      await t.pumpAndSettle();
      expect(find.textContaining(r'Adds $36.00'), findsOneWidget, reason: '3% of \$1,200');
      await t.tap(find.byKey(const ValueKey('save-charge')));
      await t.pumpAndSettle();
      expect(find.text(r'$36.00'), findsWidgets);
      expect(find.text('Not taxed'), findsNothing, reason: 'a fee\'s Tax column is empty (USER RULE 2026-11-24)');
      expect(find.text(r'$1,236.00'), findsWidgets);
      // Change it to 4% from the panel, then remove it.
      await _openPanel(t);
      await t.tap(find.byKey(ValueKey('charge-choice-rf:${_uidOf(t, 'rf')}')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('charge-value')), '4');
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('save-charge')));
      await t.pumpAndSettle();
      expect(find.text(r'$48.00'), findsWidgets);
      await _openPanel(t);
      await t.tap(find.byKey(ValueKey('charge-choice-rf:${_uidOf(t, 'rf')}')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('remove-charge')));
      await t.pumpAndSettle();
      expect(find.text(r'$48.00'), findsNothing);
      expect(find.text(r'$1,200.00'), findsWidgets);
    });

    testWidgets('out-of-state tax: its own rate, typed in (0 to 30%), never an Arkansas one', (t) async {
      await _pump(t, _editor([_door]));
      await _openPanel(t);
      await _search(t, 'out-of-state');
      await t.tap(find.byKey(const ValueKey('charge-choice-oos')));
      await t.pumpAndSettle();
      expect(t.widget<FilledButton>(find.byKey(const ValueKey('save-oos'))).onPressed, isNull, reason: 'no rate yet');
      await t.enterText(find.byKey(const ValueKey('oos-name')), 'Out-of-state sales tax (Missouri)');
      await t.enterText(find.byKey(const ValueKey('oos-rate')), '45');
      await t.pumpAndSettle();
      expect(find.text(kTaxRateRuleText), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('oos-rate')), '8.225');
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('save-oos')));
      await t.pumpAndSettle();
      await t.tap(find.text('No tax').first);
      await t.pumpAndSettle();
      await t.tap(find.text('Out-of-state sales tax (Missouri)').last);
      await t.pumpAndSettle();
      expect(find.text(r'$82.25'), findsNWidgets(2), reason: '8.225% of \$1,000 (its line, and Taxes, fees & discounts)');
    });

    testWidgets('keyboard: arrows move through the choices, Enter opens one, Esc goes back, then closes', (t) async {
      await _pump(t, _editor([_door]));
      await _openPanel(t);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('charge-value')), findsOneWidget, reason: 'the first choice is the first discount (discounts and fees lead the taxes)');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('charges-search')), findsOneWidget, reason: 'back to the list');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('charges-search')), findsNothing, reason: 'closed');
    });

    testWidgets('fits a 1280 x 600 window and large text without overflowing', (t) async {
      await _pump(t, _editor([_door, _opener]), size: const Size(1280, 600), textScale: 1.3);
      await _openPanel(t);
      expect(t.takeException(), isNull);
      await _search(t, 'springdale');
      await t.tap(find.byKey(const ValueKey('charge-choice-AR-72-10')));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });

    testWidgets('a Service Fusion record\'s own discounts show for reference, not as changeable', (t) async {
      await _pump(
        t,
        _editor(
          [_door],
          summary: const [
            LineSummaryRow('Items', 100000, kind: SummaryKind.items),
            LineSummaryRow('Builder Relationship Discount', -14000, kind: SummaryKind.discount),
            LineSummaryRow('Total', 86000, kind: SummaryKind.total),
          ],
        ),
      );
      await _openPanel(t);
      expect(find.text('Builder Relationship Discount'), findsWidgets);
      expect(find.textContaining('not changed here'), findsOneWidget);
    });
  });
}

/// The rule's text, as the panel shows it.
const kTaxRateRuleText = 'Tax rate must be between 0% and 30%.';

/// The uid in the panel's key for the first discount ('rd') or fee ('rf') it lists on the record.
String _uidOf(WidgetTester t, String prefix) {
  final keys = t
      .widgetList(find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('charge-choice-$prefix:')))
      .map((w) => (w.key! as ValueKey<String>).value)
      .toList();
  return keys.first.split(':').last;
}
