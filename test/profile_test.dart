// My Profile: opened from the account menu in the top bar, shows the signed-in person, lists the pages they may open
// and changes their PIN. Renders to test/shots/profile/ as well, so a RenderFlex overflow fails the test.
// Run:  flutter test test/profile_test.dart --update-goldens

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/config/auth_session.dart';
import 'package:iohd_desktop/profile_screen.dart';
import 'package:iohd_desktop/widgets/app_dialog.dart';

import 'nav_fixture.dart';

Future<void> _shot(String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/profile/$name.png'));

const _users = [
  {
    'id': 'hvera',
    'name': 'Heather Vera',
    'jobTitle': 'Sales',
    'displayTitle': 'Sales Account Manager',
    'avatarUrl': 'https://ui-avatars.com/api/?name=Heather+Vera',
    'yearsWorked': 3.4,
    'integrityScore': 92.4,
  },
];

/// Runs [body] with a fake API. [users] is the /users answer (status, body); PIN calls are recorded in [pinCalls].
Future<void> _withApi(
  WidgetTester t,
  Future<void> Function(List<http.Request> pinCalls) body, {
  int usersStatus = 200,
  Object usersBody = _users,
  int pinStatus = 200,
}) async {
  final pinCalls = <http.Request>[];
  await http.runWithClient(() => body(pinCalls), () => MockClient((req) async {
        if (req.url.path == '/users') return http.Response(json.encode(usersBody), usersStatus);
        if (req.url.path == '/update_pin') {
          pinCalls.add(req);
          return http.Response(json.encode(pinStatus == 200 ? {'status': 'success'} : {'error': 'nope'}), pinStatus);
        }
        return http.Response('{}', 200);
      }));
}

/// [still] turns animations off (the slats loop forever, which pumpAndSettle can't wait out).
Future<void> _open(WidgetTester t, Size size, {bool still = true}) async {
  Future<void> settle() => still ? t.pumpAndSettle() : t.pump(const Duration(milliseconds: 600));
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  navStubPage = (path) => path == '/profile' ? const ProfileScreen() : const SizedBox();
  addTearDown(() => navStubPage = null);
  await t.pumpWidget(MaterialApp.router(
    debugShowCheckedModeBanner: false,
    routerConfig: navTestRouter(initial: '/calendar'),
    theme: navTestTheme(),
    builder: (context, child) =>
        MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: still), child: child!),
  ));
  await settle();
  await t.tap(find.byTooltip('Heather Vera'));
  await settle();
  await t.tap(find.text('My Profile'));
  await settle();
}

/// The dialog's own fields (the bar has a search field too).
Finder _pinField(int i) => find.descendant(of: find.byType(AppDialog), matching: find.byType(TextField)).at(i);

Future<void> _openPinDialog(WidgetTester t) async {
  await t.ensureVisible(find.text('Change PIN'));
  await t.tap(find.text('Change PIN'));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(loadNavFonts);
  setUp(() => navSignIn(badges: ['five_star', 'top_producer']));

  testWidgets('account menu opens My Profile, which shows who is signed in', (t) async {
    await _withApi(t, (_) async {
      await _open(t, const Size(1280, 900));
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(find.text('Heather Vera'), findsWidgets);
      expect(find.textContaining('Sales Account Manager'), findsWidgets);
      expect(find.textContaining('3 years with IOHD'), findsOneWidget);
      expect(find.text('hvera'), findsOneWidget);
      expect(find.text('Administrator'), findsOneWidget);
      expect(find.text('Pages you can open'), findsNothing);
      // No top-bar module claims the page.
      expect(GoRouter.of(t.element(find.byType(ProfileScreen))).state.uri.path, '/profile');
    });
  });

  testWidgets('the hero slats keep moving, and hold still when animations are off', (t) async {
    await _withApi(t, (_) async {
      await _open(t, const Size(1280, 900), still: false);
      await t.pump(const Duration(seconds: 1));
      expect(t.binding.hasScheduledFrame, isTrue); // an animation is still running
      await t.pump(const Duration(seconds: 1));
      expect(t.binding.hasScheduledFrame, isTrue);
    });
    await _withApi(t, (_) async {
      await _open(t, const Size(1280, 900));
      await t.pumpAndSettle();
      expect(t.binding.hasScheduledFrame, isFalse);
    });
  });

  testWidgets('integrity score sits in the banner, beside the chips', (t) async {
    await _withApi(t, (_) async {
      await _open(t, const Size(1280, 900));
      expect(find.text('Integrity score'), findsOneWidget);
      expect(find.text('92%'), findsOneWidget);
      expect(find.byTooltip('Excellent'), findsOneWidget);
      final score = t.getRect(find.text('92%'));
      final chip = t.getRect(find.text('Sales Account Manager').first);
      expect((score.center.dy - chip.center.dy).abs(), lessThan(30)); // the same row
      expect(score.left, greaterThan(chip.right)); // off to the side of them
      expect(score.top, lessThan(260)); // inside the banner
      await _shot('score_1280');
    });
  });

  testWidgets('integrity score counts up from 0 when animations are on', (t) async {
    await _withApi(t, (_) async {
      await _open(t, const Size(1280, 900), still: false);
      expect(find.text('92%'), findsNothing); // still on the way up, or the score hasn't arrived
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 400));
      }
      expect(find.text('92%'), findsOneWidget);
      expect(find.byTooltip('Excellent'), findsOneWidget);
    });
  });

  for (final (score, word) in [(80, 'Solid'), (65, 'Needs attention'), (30, 'Needs attention')]) {
    testWidgets('integrity score $score is "$word"', (t) async {
      await _withApi(t, (_) async {
        await _open(t, const Size(1280, 900));
        expect(find.byTooltip(word), findsOneWidget);
        expect(find.text('$score%'), findsOneWidget);
      }, usersBody: [
        {..._users.first, 'integrityScore': score}
      ]);
    });
  }

  testWidgets('no integrity score yet says so', (t) async {
    await _withApi(t, (_) async {
      await _open(t, const Size(1280, 900));
      expect(find.byTooltip('Not scored yet'), findsOneWidget);
      expect(find.text('—'), findsWidgets);
      await _shot('score_none_1280');
    }, usersBody: [
      {..._users.first, 'integrityScore': null}
    ]);
  });

  testWidgets('narrow window', (t) async {
    await _withApi(t, (_) async {
      await _open(t, const Size(390, 800));
      expect(find.byType(ProfileScreen), findsOneWidget);
      await _shot('narrow_390');
    });
  });

  testWidgets('My badges: earned ones are counted, the rest are locked, with the years medallion', (t) async {
    await _withApi(t, (_) async {
      await _open(t, const Size(1280, 900));
      expect(find.text('My badges'), findsOneWidget);
      expect(find.text('2 of 5 earned'), findsOneWidget);
      expect(find.text('3 Years'), findsOneWidget);
      expect(find.text('Not earned yet'), findsNWidgets(3));
      expect(find.byIcon(Icons.lock_outline_rounded), findsNWidgets(3));
      expect(find.byIcon(Icons.star_rounded), findsOneWidget);
      await _shot('admin_1280');
    });
  });

  testWidgets('a standard account and no badges yet', (t) async {
    await navSignIn(admin: false, badges: []);
    await _withApi(t, (_) async {
      await _open(t, const Size(1280, 900));
      expect(find.textContaining('Standard'), findsOneWidget);
      expect(find.text('Administrator'), findsNothing);
      expect(find.text('0 of 5 earned'), findsOneWidget);
      expect(find.textContaining('No badges yet'), findsOneWidget);
      await _shot('no_badges_1280');
    });
  });

  testWidgets('a sign-in saved before badges existed asks for one fresh sign-in', (t) async {
    await navSignIn(badges: null);
    await _withApi(t, (_) async {
      await _open(t, const Size(1280, 900));
      expect(find.textContaining('Sign out and back in once'), findsOneWidget);
      expect(find.textContaining('earned'), findsNothing);
    });
  });

  testWidgets('users list failing shows the error with Try again, not a blank page', (t) async {
    await _withApi(t, (_) async {
      await _open(t, const Size(1280, 900));
      expect(find.text('Try again'), findsOneWidget);
      // The page still shows what the sign-in already knew.
      expect(find.text('Heather Vera'), findsWidgets);
      await _shot('error_1280');
    }, usersStatus: 500, usersBody: {'error': 'boom'});
  });

  testWidgets('change PIN: needs 4 matching digits, then posts the old and new PIN', (t) async {
    await _withApi(t, (pinCalls) async {
      await _open(t, const Size(1280, 900));
      await _openPinDialog(t);
      await _shot('pin_dialog_1280');

      final save = find.widgetWithText(FilledButton, 'Save PIN');
      expect(t.widget<FilledButton>(save).onPressed, isNull);

      await t.enterText(_pinField(0), '1111');
      await t.enterText(_pinField(1), '2222');
      await t.enterText(_pinField(2), '3333');
      await t.pumpAndSettle();
      expect(find.text("The PINs don't match yet."), findsOneWidget);
      expect(t.widget<FilledButton>(save).onPressed, isNull);

      await t.enterText(_pinField(2), '2222');
      await t.pumpAndSettle();
      expect(t.widget<FilledButton>(save).onPressed, isNotNull);

      await t.tap(save);
      await t.pumpAndSettle();
      expect(pinCalls, hasLength(1));
      expect(pinCalls.single.headers['x-username'], 'hvera');
      expect(pinCalls.single.headers['x-pin'], '1111');
      expect(json.decode(pinCalls.single.body), {'newPin': '2222'});
      expect(find.text('Change PIN'), findsOneWidget); // the dialog closed, only the button is left
      expect(find.textContaining('Your PIN was changed'), findsOneWidget);
      expect(AuthSession.instance.isLoggedIn, isTrue);
    });
  });

  testWidgets('change PIN: a wrong current PIN says so and keeps the dialog open', (t) async {
    await _withApi(t, (pinCalls) async {
      await _open(t, const Size(1280, 900));
      await _openPinDialog(t);
      await t.enterText(_pinField(0), '9999');
      await t.enterText(_pinField(1), '2222');
      await t.enterText(_pinField(2), '2222');
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(FilledButton, 'Save PIN'));
      await t.pumpAndSettle();
      expect(find.text("That isn't your current PIN."), findsOneWidget);
      expect(find.text('Save PIN'), findsOneWidget);
      await _shot('pin_wrong_1280');
    }, pinStatus: 401);
  });

  testWidgets('Sign out on the page signs out', (t) async {
    await _withApi(t, (_) async {
      await _open(t, const Size(1280, 900));
      await t.ensureVisible(find.text('Sign out'));
      await t.tap(find.text('Sign out'));
      await t.pumpAndSettle();
      expect(AuthSession.instance.isLoggedIn, isFalse);
    });
  });
}
