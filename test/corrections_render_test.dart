// Renders the real Commission corrections screen with fake API data and saves screenshots to test/shots/.
// Run:  flutter test test/corrections_render_test.dart --update-goldens
// A RenderFlex overflow fails the test, so every shot (and the sweep at the end) doubles as an overflow check.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'corrections_fixture.dart';

Future<void> _shot(
  WidgetTester t,
  String name, {
  Size size = const Size(1440, 900),
  double textScale = 1,
  FakeCorrApi? api,
  Future<void> Function()? then,
}) async {
  await withCorrections(t, api ?? FakeCorrApi(), () async {
    if (then != null) await then();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
  }, size: size, textScale: textScale);
}

void main() {
  setUpAll(loadCorrFonts);

  testWidgets('empty + recent', (t) => _shot(t, 'corr_empty'));
  testWidgets('search results', (t) => _shot(t, 'corr_search', then: () async {
    await t.enterText(find.byType(TextField).first, 'farm');
    await pumpN(t);
  }));
  testWidgets('no matches', (t) => _shot(t, 'corr_nomatch', then: () async {
    await t.enterText(find.byType(TextField).first, 'zzz');
    await pumpN(t);
  }));

  testWidgets('locked job with office fixes', (t) =>
      _shot(t, 'corr_detail', then: () => openJob(t, 'Farmington Fire Department')));
  testWidgets('job worked across a paid week', (t) =>
      _shot(t, 'corr_detail_paidweek', then: () => openJob(t, 'Trulove Construction')));
  testWidgets('paid job before go-live', (t) => _shot(t, 'corr_paid',
      then: () => openJob(t, 'Lennar Homes of Missouri - Wentzville Meadows Phase 2 Lot 114')));
  testWidgets('detail 1280x600', (t) => _shot(t, 'corr_detail_1280',
      size: const Size(1280, 600), then: () => openJob(t, 'Farmington Fire Department')));
  testWidgets('detail 1024', (t) => _shot(t, 'corr_detail_1024',
      size: const Size(1024, 700), then: () => openJob(t, 'Farmington Fire Department')));
  testWidgets('detail 860 (visits stack)', (t) => _shot(t, 'corr_detail_860',
      size: const Size(860, 800), then: () => openJob(t, 'Farmington Fire Department')));
  testWidgets('narrow detail', (t) =>
      _shot(t, 'corr_narrow', size: const Size(700, 900), then: () => openJob(t, 'Farmington Fire Department')));
  testWidgets('phone detail', (t) =>
      _shot(t, 'corr_phone', size: const Size(390, 844), then: () => openJob(t, 'Farmington Fire Department')));
  testWidgets('narrow search', (t) => _shot(t, 'corr_narrow_search', size: const Size(700, 800), then: () async {
    await t.enterText(find.byType(TextField).first, 'farm');
    await pumpN(t);
  }));
  testWidgets('detail at 130% text', (t) => _shot(t, 'corr_text130',
      size: const Size(1280, 800), textScale: 1.3, then: () => openJob(t, 'Farmington Fire Department')));

  testWidgets('loading skeleton', (t) {
    final api = FakeCorrApi()..detailGate = Completer<void>();
    return _shot(t, 'corr_loading', api: api, then: () async {
      await t.enterText(find.byType(TextField).first, 'farm');
      await pumpN(t);
      await t.tap(find.text('Farmington Fire Department').first);
      await pumpN(t, 3);
      api.detailGate!.complete(); // let it finish after the shot is taken (in tearDown order)
    });
  });
  testWidgets('job failed to load', (t) => _shot(t, 'corr_error',
      api: FakeCorrApi()..detailStatus = 500, then: () => openJob(t, 'Farmington Fire Department')));

  testWidgets('fix dialog', (t) => _shot(t, 'corr_fix', then: () async {
    await openJob(t, 'Farmington Fire Department');
    await t.tap(find.text('Fix').first);
    await pumpN(t);
  }));
  testWidgets('fix dialog with changes picked', (t) => _shot(t, 'corr_fix_changes', size: const Size(1440, 1000),
      then: () async {
    await openJob(t, 'Farmington Fire Department');
    await t.tap(find.text('Fix').at(1)); // Christopher: weight and verified fixed by the office
    await pumpN(t);
    await t.tap(find.text('Verified').last);
    await t.tap(find.text('Set a value'));
    await pumpN(t, 3);
    await t.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == 'New weight'), '1');
    await t.tap(find.text('Office error'));
    await pumpN(t, 3);
  }));
  testWidgets('fix dialog: un-flag a callback', (t) => _shot(t, 'corr_fix_callback', then: () async {
    await openJob(t, 'Farmington Fire Department');
    await t.tap(find.text('Fix').last);
    await pumpN(t);
    await t.tap(find.text('Not a callback').last);
    await pumpN(t);
  }));
  testWidgets('fix dialog: week already paid', (t) => _shot(t, 'corr_fix_paidweek', then: () async {
    await openJob(t, 'Trulove Construction');
    await t.tap(find.text('Fix').first);
    await pumpN(t);
  }));
  testWidgets('fix dialog on a phone', (t) => _shot(t, 'corr_fix_phone', size: const Size(390, 844), then: () async {
    await openJob(t, 'Farmington Fire Department');
    await t.tap(find.text('Fix').first);
    await pumpN(t);
    await t.tap(find.text('Not verified').last);
    await pumpN(t);
  }));
  testWidgets('unlock dialog (job not closing, week paid)', (t) => _shot(t, 'corr_unlock', then: () async {
    await openJob(t, 'Smith, Robert');
    await t.tap(find.text('Unlock'));
    await pumpN(t);
  }));

  // Every job at every width from a phone to a wide monitor, at normal and 130% text: no overflow anywhere.
  for (final width in const [360.0, 390.0, 600.0, 820.0, 860.0, 1024.0, 1280.0, 1920.0]) {
    for (final scale in const [1.0, 1.3]) {
      testWidgets('no overflow at ${width.toInt()}px, text $scale', (t) async {
        await withCorrections(t, FakeCorrApi(), () async {
          for (final (customer, q) in const [
            ('Farmington Fire Department', 'farm'),
            ('Trulove Construction', 'tru'),
            ('Smith, Robert', 'smi'),
            ('Lennar Homes of Missouri - Wentzville Meadows Phase 2 Lot 114', 'len'),
          ]) {
            if (find.text('Back to search').evaluate().isNotEmpty) {
              await t.tap(find.text('Back to search'));
              await pumpN(t, 2);
            }
            await openJob(t, customer, q: q);
            expect(t.takeException(), isNull, reason: '$customer at ${width}px');
            // The technician column never collapses: either it has room or the visits switch to stacked blocks.
            final tech = find.text('Daniel Baty');
            if (tech.evaluate().isNotEmpty) {
              expect(t.getSize(tech.first).width, greaterThan(60), reason: 'tech name squeezed at ${width}px');
            }
          }
        }, size: Size(width, 900), textScale: scale);
      });
    }
  }
}
