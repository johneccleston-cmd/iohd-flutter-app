// Change close date: moving a late-closed job's commission into the week it should have closed.
// Renders the dialog (shots in test/shots/corr_close_date*.png) and checks what is posted and shown after saving.
// Run:  flutter test test/corrections_close_date_test.dart  (add --update-goldens to write the shots)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'corrections_fixture.dart';

const _reason = 'Finished Nov 12 but not closed in Service Fusion until Nov 19';

Future<void> _openDialog(WidgetTester t) async {
  await openJob(t, 'Lane Valente Industries', q: 'lane');
  await t.tap(find.text('Change close date'));
  await pumpN(t);
}

void main() {
  setUpAll(loadCorrFonts);

  testWidgets('the lock band offers Change close date', (t) async {
    await withCorrections(t, FakeCorrApi(), () async {
      await openJob(t, 'Lane Valente Industries', q: 'lane');
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/corr_close_date_band.png'));
    });
  });

  testWidgets('the dialog suggests the last day worked and shows the week it will pay in', (t) async {
    await withCorrections(t, FakeCorrApi(), () async {
      await _openDialog(t);
      expect(find.text('Thu, Nov 12, 2026'), findsOneWidget);
      expect(find.text('the week of Nov 16 – 22, 2026'), findsOneWidget);
      expect(find.text('the week of Nov 9 – 15, 2026'), findsOneWidget);
      await t.enterText(find.byType(TextField).last, _reason);
      await pumpN(t, 3);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/corr_close_date_dialog.png'));
    }, size: const Size(1440, 1000));
  });

  testWidgets('saving posts the day and reason, then shows the new close and the history line', (t) async {
    final api = FakeCorrApi();
    await withCorrections(t, api, () async {
      await _openDialog(t);
      await t.tap(find.text('Move close date'), warnIfMissed: false);
      await pumpN(t, 3);
      expect(api.posts, isEmpty, reason: 'no reason yet, so Save is off');

      await t.enterText(find.byType(TextField).last, _reason);
      await pumpN(t, 3);
      await t.tap(find.text('Move close date'));
      await pumpN(t, 30);

      expect(api.posts.single, {'date': '2026-11-12', 'reason': _reason});
      expect(api.paths.where((p) => p.startsWith('POST')).single, endsWith('/jobs/1101272271/close-date'));
      expect(find.text('Change close date').hitTestable(), findsOneWidget, reason: 'dialog closed, band still there');
      expect(find.textContaining('Close date moved'), findsWidgets);
      expect(find.text('Closed Nov 12, 2026'), findsOneWidget); // the history's new value
      expect(find.textContaining('Closed Nov 12, 2026 6:00 PM'), findsOneWidget); // the lock band
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/corr_close_date_saved.png'));
    }, size: const Size(1440, 1000));
  });

  testWidgets('a job whose close week was already paid cannot be moved', (t) async {
    await withCorrections(t, FakeCorrApi(), () async {
      await openJob(t, 'Smith, Robert', q: 'smi');
      final button = t.widget<OutlinedButton>(
        find.ancestor(of: find.text('Change close date'), matching: find.byWidgetPredicate((w) => w is OutlinedButton)),
      );
      expect(button.onPressed, isNull);
    });
  });

  for (final (size, scale) in const [(Size(390, 844), 1.0), (Size(1024, 700), 1.3)]) {
    testWidgets('the dialog fits ${size.width.toInt()}px at text $scale without overflow', (t) async {
      await withCorrections(t, FakeCorrApi(), () async {
        await _openDialog(t);
        expect(t.takeException(), isNull);
        expect(find.text('Move close date'), findsOneWidget);
      }, size: size, textScale: scale);
    });
  }
  testWidgets('dialog on a phone', (t) async {
    await withCorrections(t, FakeCorrApi(), () async {
      await _openDialog(t);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/corr_close_date_phone.png'));
    }, size: const Size(390, 844));
  });
}
