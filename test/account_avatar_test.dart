// The top-right account circle shows the signed-in person's photo, and keeps the initials when there is no photo.
// Run:  flutter test test/account_avatar_test.dart

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/config/auth_session.dart';
import 'package:iohd_desktop/widgets/main_navigation_shell.dart';

GoRouter _router() => GoRouter(
      initialLocation: '/calendar',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) => MainNavigationShell(navigationShell: shell),
          branches: [
            for (var i = 0; i < 9; i++)
              StatefulShellBranch(routes: [GoRoute(path: i == 5 ? '/calendar' : '/other$i', builder: (_, _) => const SizedBox())]),
          ],
        ),
      ],
    );

http.Client _client(String who, List<Map<String, dynamic>> users) => MockClient((req) async {
      if (req.url.path == '/login') {
        final exp = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch;
        final token = '${base64Url.encode(utf8.encode(json.encode({'exp': exp})))}.sig';
        return http.Response(json.encode({'token': token, 'name': who, 'role': 'Office Manager', 'is_admin': true}), 200);
      }
      if (req.url.path == '/users') return http.Response(json.encode(users), 200);
      return http.Response('{}', 200);
    });

Future<void> _signInAndShow(WidgetTester t, String who, List<Map<String, dynamic>> users) async {
  t.view.physicalSize = const Size(1500, 700);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await http.runWithClient(() async {
    AuthSession.instance.logout();
    await AuthSession.instance.login('user', '1234');
    await t.pumpWidget(MaterialApp.router(routerConfig: _router()));
    await t.pumpAndSettle();
  }, () => _client(who, users));
}

void main() {
  tearDown(() => AuthSession.instance.logout());

  testWidgets('a person with a photo gets the photo, not initials', (t) async {
    await _signInAndShow(t, 'Heather Vera', [
      {'name': 'Heather Vera', 'avatarUrl': 'https://example.test/images/heather_vera.jpg'},
    ]);
    final account = find.byTooltip('Heather Vera');
    expect(account, findsOneWidget);
    expect(find.descendant(of: account, matching: find.byType(Image)), findsOneWidget);
  });

  testWidgets('no photo (or only a generated initials image): the initials circle stays', (t) async {
    await _signInAndShow(t, 'Ryan Schwartz', [
      {'name': 'Heather Vera', 'avatarUrl': 'https://example.test/heather.jpg'},
      {'name': 'Ryan Schwartz', 'avatarUrl': 'https://ui-avatars.com/api/?name=Ryan+Schwartz&background=random'},
    ]);
    final account = find.byTooltip('Ryan Schwartz');
    expect(find.descendant(of: account, matching: find.byType(Image)), findsNothing);
    expect(find.descendant(of: account, matching: find.text('RS')), findsOneWidget);
  });
}
