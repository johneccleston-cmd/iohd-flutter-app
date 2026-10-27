// Behaviour of the Commission corrections screen against a fake backend (see corrections_fixture.dart): what is sent,
// what is shown, and the failure cases. Run: flutter test test/corrections_behavior_test.dart

import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'corrections_fixture.dart';

FilledButton _saveButton(WidgetTester t) => t.widget<FilledButton>(
  find.ancestor(of: find.text('Save correction'), matching: find.bySubtype<FilledButton>()).first,
);

Finder get _weightField => find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == 'New weight');
Finder get _noteField => find.byWidgetPredicate((w) => w is TextField && w.maxLength == 900);

/// Opens the fix dialog for Farmington visit [index]: 0 Daniel (nothing fixed), 1 Christopher (verified and weight
/// fixed by the office), 2 Ryan (callback fixed).
Future<void> _openFix(WidgetTester t, int index) async {
  await openJob(t, 'Farmington Fire Department');
  await t.tap(find.text('Fix').at(index));
  await pumpN(t);
}

void main() {
  setUpAll(loadCorrFonts);

  group('reasons', () {
    testWidgets('a reason is required, Other also needs a note, and both reach the server', (t) async {
      final api = FakeCorrApi();
      await withCorrections(t, api, () async {
        await _openFix(t, 0);
        await t.tap(find.text('Not verified').last); // a real change, so only the reason is missing
        await pumpN(t, 3);
        expect(_saveButton(t).onPressed, isNull, reason: 'no reason picked yet');
        for (final r in ['Tech did not mark complete', 'Tech marked complete by mistake', 'Office error', 'Other (note required)']) {
          expect(find.text(r), findsOneWidget);
        }

        await t.tap(find.text('Office error'));
        await pumpN(t, 3);
        expect(_saveButton(t).onPressed, isNotNull, reason: 'a listed reason needs no note');

        await t.tap(find.text('Other (note required)'));
        await pumpN(t, 3);
        expect(_saveButton(t).onPressed, isNull, reason: 'Other without a note');
        await t.enterText(_noteField, 'abc');
        await pumpN(t, 3);
        expect(_saveButton(t).onPressed, isNull, reason: 'a note under 5 characters is not a note');
        await t.enterText(_noteField, 'Gate was locked');
        await pumpN(t, 3);
        expect(_saveButton(t).onPressed, isNotNull);

        await t.tap(find.text('Save correction'));
        await pumpN(t);
      }, size: const Size(1440, 1100));

      expect(api.posts, hasLength(1));
      expect(api.posts.single['reason'], 'Other: Gate was locked');
      expect(api.posts.single['verified'], false);
      expect(api.posts.single['dayId'], 27879767);
      expect(api.posts.single.containsKey('weight'), isFalse, reason: 'only the field that changed is sent');
    });

    testWidgets('a listed reason with no note is sent as just the reason', (t) async {
      final api = FakeCorrApi();
      await withCorrections(t, api, () async {
        await _openFix(t, 0);
        await t.tap(find.text('Not verified').last);
        await t.tap(find.text('Tech did not mark complete'));
        await pumpN(t, 3);
        await t.tap(find.text('Save correction'));
        await pumpN(t);
      }, size: const Size(1440, 1100));
      expect(api.posts.single['reason'], 'Tech did not mark complete');
    });
  });

  group('the value is replaced, never added to', () {
    testWidgets('setting a weight sends the new weight itself and the summary shows now -> after', (t) async {
      final api = FakeCorrApi();
      await withCorrections(t, api, () async {
        await _openFix(t, 1); // Christopher: weight 1.5, fixed
        expect(find.text('Nothing will change yet. Pick a new value above.'), findsOneWidget);
        await t.tap(find.text('Set a value'));
        await pumpN(t, 3);
        await t.enterText(_weightField, '0.5');
        await pumpN(t, 3);
        expect(find.text('When you save'), findsOneWidget);
        // "1.5 -> 0.5" in the summary: the old weight is shown beside the new one, not a difference of -1.
        expect(find.descendant(of: find.byType(Wrap), matching: find.text('0.5')), findsWidgets);
        expect(find.textContaining('-1'), findsNothing);
        await t.tap(find.text('Office error'));
        await pumpN(t, 3);
        await t.tap(find.text('Save correction'));
        await pumpN(t);
      }, size: const Size(1440, 1100));
      expect(api.posts.single['weight'], 0.5);
      expect(api.posts.single.containsKey('verified'), isFalse);
    });

    testWidgets('a comma decimal is accepted and the 0 to 3 limit is enforced before saving', (t) async {
      final api = FakeCorrApi();
      await withCorrections(t, api, () async {
        await _openFix(t, 0);
        await t.tap(find.text('Set a value'));
        await pumpN(t, 3);
        await t.tap(find.text('Office error'));
        await t.enterText(_weightField, '3.5');
        await pumpN(t, 3);
        expect(find.text('Use 0 to 3'), findsOneWidget);
        expect(_saveButton(t).onPressed, isNull);
        await t.enterText(_weightField, '0,5');
        await pumpN(t, 3);
        expect(_saveButton(t).onPressed, isNotNull);
        await t.tap(find.text('Save correction'));
        await pumpN(t);
      }, size: const Size(1440, 1100));
      expect(api.posts.single['weight'], 0.5);
    });

    testWidgets('"Remove fix" is only offered for a field the office fixed, and sends null', (t) async {
      final api = FakeCorrApi();
      await withCorrections(t, api, () async {
        await _openFix(t, 0); // Daniel: nothing fixed
        expect(find.text('Remove fix'), findsNothing);
        await t.tap(find.text('Cancel'));
        await pumpN(t);

        await t.tap(find.text('Fix').at(1)); // Christopher: verified and weight fixed, callback not
        await pumpN(t);
        expect(find.text('Remove fix'), findsNWidgets(2));
        await t.tap(find.text('Remove fix').first); // verified
        await pumpN(t, 3);
        expect(find.textContaining('the sync decides from now on'), findsOneWidget);
        expect(find.textContaining("Removing a fix doesn't recalculate a closed job"), findsOneWidget);
        await t.tap(find.text('Office error'));
        await pumpN(t, 3);
        await t.tap(find.text('Save correction'));
        await pumpN(t);
      }, size: const Size(1440, 1100));
      expect(api.posts.single.containsKey('verified'), isTrue);
      expect(api.posts.single['verified'], isNull);
    });

    testWidgets('un-flagging a callback suggests a weight, because the old one was not kept', (t) async {
      final api = FakeCorrApi();
      await withCorrections(t, api, () async {
        await _openFix(t, 2); // Ryan: callback
        await t.tap(find.text('Not a callback').last);
        await pumpN(t, 3);
        expect(find.textContaining('the old value was not kept'), findsOneWidget);
        expect(t.widget<TextField>(_weightField).controller!.text, '1');
        await t.tap(find.text('Office error'));
        await pumpN(t, 3);
        await t.tap(find.text('Save correction'));
        await pumpN(t);
      }, size: const Size(1440, 1100));
      expect(api.posts.single['callback'], false);
      expect(api.posts.single['weight'], 1);
    });
  });

  group('saving safely', () {
    testWidgets('Cancel sends nothing', (t) async {
      final api = FakeCorrApi();
      await withCorrections(t, api, () async {
        await _openFix(t, 0);
        await t.tap(find.text('Not verified').last);
        await t.tap(find.text('Office error'));
        await pumpN(t, 3);
        await t.tap(find.text('Cancel'));
        await pumpN(t);
        expect(find.text('Fix this visit'), findsNothing);
      });
      expect(api.posts, isEmpty);
    });

    testWidgets('Save pressed twice and Ctrl+Enter during a save send one correction', (t) async {
      final api = FakeCorrApi()..postGate = Completer<void>();
      await withCorrections(t, api, () async {
        await _openFix(t, 0);
        await t.tap(find.text('Not verified').last);
        await t.tap(find.text('Office error'));
        await pumpN(t, 3);
        await t.tap(find.text('Save correction'));
        await t.pump(const Duration(milliseconds: 50));
        expect(find.text('Saving…'), findsOneWidget);
        await t.tap(find.text('Saving…'), warnIfMissed: false);
        await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await t.pump(const Duration(milliseconds: 50));
        api.postGate!.complete();
        await pumpN(t);
      }, size: const Size(1440, 1100));
      expect(api.posts, hasLength(1));
    });

    // Before: clicking outside the dialog mid-save closed it, and a failed save was then reported nowhere.
    testWidgets('the dialog cannot be dismissed mid-save, and a failed save is shown in it', (t) async {
      final api = FakeCorrApi()
        ..postGate = Completer<void>()
        ..postStatus = 500;
      await withCorrections(t, api, () async {
        await _openFix(t, 0);
        await t.tap(find.text('Not verified').last);
        await t.tap(find.text('Office error'));
        await pumpN(t, 3);
        await t.tap(find.text('Save correction'));
        await t.pump(const Duration(milliseconds: 50));
        await t.tapAt(const Offset(8, 8)); // the barrier
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await pumpN(t, 3);
        expect(find.text('Fix this visit'), findsOneWidget, reason: 'still open while saving');
        api.postGate!.complete();
        await pumpN(t);
        expect(find.text('Failed to save the correction.'), findsOneWidget);
        expect(find.text('Office error'), findsOneWidget, reason: 'what was picked is still there to retry');
        expect(_saveButton(t).onPressed, isNotNull, reason: 'can retry');
      }, size: const Size(1440, 1100));
    });

    testWidgets('a reload still in flight when a save lands does not put the old values back', (t) async {
      final api = FakeCorrApi();
      await withCorrections(t, api, () async {
        await openJob(t, 'Farmington Fire Department');
        api.detailGate = Completer<void>();
        await t.tap(find.byTooltip('Reload this job'));
        await t.pump(const Duration(milliseconds: 50));
        await t.tap(find.text('Fix').first); // Daniel, while the reload is still loading
        await pumpN(t);
        await t.tap(find.text('Set a value'));
        await pumpN(t, 3);
        await t.enterText(_weightField, '1');
        await t.tap(find.text('Office error'));
        await pumpN(t, 3);
        await t.tap(find.text('Save correction'));
        await pumpN(t);
        expect(find.text('earns nothing'), findsNothing, reason: 'saved weight 1 is showing');
        api.detailGate!.complete(); // the reload that started before the save returns the old weight 0
        await pumpN(t);
        expect(find.text('earns nothing'), findsNothing, reason: 'the stale reload was dropped');
        expect(find.text('Correction saved.'), findsOneWidget);
      }, size: const Size(1440, 1100));
      expect(api.posts.single['weight'], 1);
    });

    testWidgets('the saved visit shows its new values, pinned', (t) async {
      final handle = t.ensureSemantics();
      await withCorrections(t, FakeCorrApi(), () async {
        await _openFix(t, 0);
        await t.tap(find.text('Not verified').last);
        await t.tap(find.text('Office error'));
        await pumpN(t, 3);
        await t.tap(find.text('Save correction'));
        await pumpN(t, 25);
        expect(find.text('Fix this visit'), findsNothing);
        expect(find.bySemanticsLabel('Not verified, fixed by the office'), findsNWidgets(2),
            reason: 'Daniel now, as well as Christopher');
        expect(find.bySemanticsLabel('Weight 1.5, fixed by the office'), findsOneWidget);
      }, size: const Size(1440, 1100));
      handle.dispose();
    });
  });

  group('original and corrected values', () {
    testWidgets('a fixed value shows what it was before the office fix', (t) async {
      await withCorrections(t, FakeCorrApi(), () async {
        await openJob(t, 'Farmington Fire Department');
        expect(find.text('was 0'), findsOneWidget);
        expect(find.text('was Verified'), findsOneWidget);
        // Ryan's callback is fixed but the history has no entry for it: nothing is guessed.
        expect(find.text('was Not a callback'), findsNothing);
        expect(find.text('Fixed by the office: the sync keeps it'), findsOneWidget);
      });
    });

    testWidgets('when the history may be cut off, no "was" value is shown', (t) async {
      final capped = [
        for (var i = 0; i < 30; i++)
          {
            'action': 'set_weight',
            'target': 'Christopher Montgomery-Alvarez · 2026-10-15',
            'old_value': '${i + 1}',
            'new_value': '1.5',
            'reason': 'Repeated fix $i',
            'changed_by_name': 'John Eccleston',
            'changed_at': '2026-10-16T13:40:00Z',
          },
      ];
      await withCorrections(t, FakeCorrApi()..farmHistoryOverride = capped, () async {
        await openJob(t, 'Farmington Fire Department');
        expect(find.textContaining(RegExp(r'^was ')), findsNothing);
        expect(find.text('Latest 30 changes'), findsOneWidget);
      });
    });

    testWidgets('a removed fix resets where "was" is read from', (t) async {
      final history = [
        {'action': 'set_weight', 'target': 'Christopher Montgomery-Alvarez · 2026-10-15', 'old_value': '1', 'new_value': '1.5', 'reason': 'Second fix', 'changed_by_name': 'A', 'changed_at': '2026-10-17T10:00:00Z'},
        {'action': 'clear_weight', 'target': 'Christopher Montgomery-Alvarez · 2026-10-15', 'old_value': '0.5', 'new_value': 'back to sync', 'reason': 'Undo', 'changed_by_name': 'A', 'changed_at': '2026-10-16T10:00:00Z'},
        {'action': 'set_weight', 'target': 'Christopher Montgomery-Alvarez · 2026-10-15', 'old_value': '0', 'new_value': '0.5', 'reason': 'First fix', 'changed_by_name': 'A', 'changed_at': '2026-10-15T10:00:00Z'},
      ];
      await withCorrections(t, FakeCorrApi()..farmHistoryOverride = history, () async {
        await openJob(t, 'Farmington Fire Department');
        expect(find.text('was 1'), findsOneWidget, reason: 'the fix in effect started after the removal, from 1');
        expect(find.text('Sync decides'), findsOneWidget, reason: 'the removal reads in words in the history');
      });
    });
  });

  group('pay weeks', () {
    testWidgets('a job worked in a paid week says so, and so does its fix dialog', (t) async {
      await withCorrections(t, FakeCorrApi(), () async {
        await openJob(t, 'Trulove Construction', q: 'tru');
        expect(find.text('1 of 2 paid'), findsOneWidget);
        expect(find.text('Oct 5 – 11 paid · Oct 12 – 18 not run'), findsOneWidget, reason: 'a voided run pays nothing');
        await t.tap(find.text('Fix').first);
        await pumpN(t);
        expect(find.textContaining('Payroll has already been run for the week of Oct 5 – 11, 2026.'), findsOneWidget);
        expect(find.textContaining('adjustment run'), findsOneWidget);
      });
    });

    testWidgets('a job with nothing paid yet has no warning', (t) async {
      await withCorrections(t, FakeCorrApi(), () async {
        await openJob(t, 'Farmington Fire Department');
        expect(find.text('Not run yet'), findsOneWidget);
        await t.tap(find.text('Fix').first);
        await pumpN(t);
        expect(find.textContaining('Payroll has already been run'), findsNothing);
      });
    });

    testWidgets('if the run list fails, the week the server marks paid still warns and the rest is "unknown"', (t) async {
      await withCorrections(t, FakeCorrApi()..runsStatus = 500, () async {
        await openJob(t, 'Farmington Fire Department');
        expect(find.text('Unknown'), findsOneWidget);
        expect(find.text("Couldn't check payroll runs"), findsOneWidget);
        await openJob(t, 'Smith, Robert', q: 'smi');
        expect(find.text('Paid'), findsOneWidget, reason: "the job's own week_paid flag");
        await t.tap(find.text('Unlock'));
        await pumpN(t);
        expect(find.textContaining('Payroll has already been run for the week of Oct 5 – 11, 2026.'), findsOneWidget);
      });
    });

    testWidgets('a job that started before go-live has no pay weeks and cannot be fixed', (t) async {
      await withCorrections(t, FakeCorrApi(), () async {
        await openJob(t, 'Lennar Homes of Missouri - Wentzville Meadows Phase 2 Lot 114', q: 'len');
        expect(find.text('Started before go-live: nothing is paid'), findsOneWidget);
        expect(find.text('Fix'), findsNothing);
        expect(find.byIcon(Icons.lock_outline_rounded), findsNWidgets(2));
      });
    });
  });

  group('states', () {
    testWidgets('a job that fails to load can be retried', (t) async {
      final api = FakeCorrApi()..detailStatus = 500;
      await withCorrections(t, api, () async {
        await openJob(t, 'Farmington Fire Department');
        expect(find.text("Couldn't load this job"), findsOneWidget);
        api.detailStatus = 200;
        await t.tap(find.text('Try again'));
        await pumpN(t);
        expect(find.text('Site visits'), findsOneWidget);
      });
    });

    testWidgets('search results stay on screen while the next search runs', (t) async {
      final api = FakeCorrApi();
      await withCorrections(t, api, () async {
        await t.enterText(find.byType(TextField).first, 'farm');
        await pumpN(t);
        expect(find.text('Farmington Fire Department'), findsOneWidget);
        await t.enterText(find.byType(TextField).first, 'farmi');
        await t.pump(const Duration(milliseconds: 360)); // the debounce has fired, the request has not landed
        expect(find.text('Farmington Fire Department'), findsOneWidget);
        await pumpN(t);
      });
    });
  });

  group('keyboard and screen readers', () {
    testWidgets('a pill selector option can be focused and picked with the keyboard', (t) async {
      await withCorrections(t, FakeCorrApi(), () async {
        await _openFix(t, 0);
        Focus.of(t.element(find.text('Not verified').last)).requestFocus();
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.space);
        await pumpN(t, 3);
        expect(find.text('When you save'), findsOneWidget);
      }, size: const Size(1440, 1100));
    });

    testWidgets('pill selector options say which one is selected', (t) async {
      final handle = t.ensureSemantics();
      await withCorrections(t, FakeCorrApi(), () async {
        await _openFix(t, 0);
        final data = t.getSemantics(find.text('No change').first).getSemanticsData();
        expect(data.flagsCollection.isSelected, Tristate.isTrue);
        expect(data.flagsCollection.isButton, isTrue);
      }, size: const Size(1440, 1100));
      handle.dispose();
    });

    testWidgets('the Fix button names the visit it fixes', (t) async {
      final handle = t.ensureSemantics();
      await withCorrections(t, FakeCorrApi(), () async {
        await openJob(t, 'Farmington Fire Department');
        expect(find.bySemanticsLabel("Fix Daniel Baty's visit on Oct 14, 2026"), findsOneWidget);
      });
      handle.dispose();
    });

    testWidgets('with reduced motion the saved-visit highlight does not animate', (t) async {
      await withCorrections(t, FakeCorrApi(), () async {
        await _openFix(t, 0);
        await t.tap(find.text('Not verified').last);
        await t.tap(find.text('Office error'));
        await pumpN(t, 3);
        await t.tap(find.text('Save correction'));
        await pumpN(t, 3);
        final flash = t.widget<TweenAnimationBuilder<double>>(find.byType(TweenAnimationBuilder<double>));
        expect(flash.duration, Duration.zero);
        expect(flash.tween.begin, 0, reason: 'no tint at all');
      }, size: const Size(1440, 1100), reduceMotion: true);
    });

    testWidgets('without reduced motion the saved visit is tinted and fades', (t) async {
      await withCorrections(t, FakeCorrApi(), () async {
        await _openFix(t, 0);
        await t.tap(find.text('Not verified').last);
        await t.tap(find.text('Office error'));
        await pumpN(t, 3);
        await t.tap(find.text('Save correction'));
        await pumpN(t, 3);
        final flash = t.widget<TweenAnimationBuilder<double>>(find.byType(TweenAnimationBuilder<double>));
        expect(flash.duration, const Duration(milliseconds: 1800));
      }, size: const Size(1440, 1100));
    });
  });
}
