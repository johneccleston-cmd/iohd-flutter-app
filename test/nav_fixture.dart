// Shared setup for the top navigation bar tests: a router with the real app's branch order and paths (stub pages),
// a signed-in session with chosen permissions, the machine's Segoe UI, and a fake API.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/config/auth_session.dart';
import 'package:iohd_desktop/widgets/flat_page.dart';
import 'package:iohd_desktop/widgets/main_navigation_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    if (File(p).existsSync()) {
      loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
    }
  }
  await loader.load();
}

Future<void> loadNavFonts() async {
  await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf', 'C:/Windows/Fonts/seguisb.ttf']);
  final root = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
  await _loadFont('MaterialIcons', ['$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
}

/// Signs in through the saved-session path (what a page refresh does). [denied] are `<key>.view` style keys.
Future<void> navSignIn({
  bool admin = true,
  List<String> denied = const [],
  String name = 'Heather Vera',
  String role = 'Sales Account Manager',
  List<String>? badges, // null: a saved sign-in from before badges were kept
}) async {
  AuthSession.instance.logout();
  final payload = base64Url.encode(utf8.encode(json.encode({'exp': DateTime(2100).millisecondsSinceEpoch})));
  SharedPreferences.setMockInitialValues({
    'iohd_auth_session': json.encode(
      {'token': '$payload.sig', 'name': name, 'role': role, 'is_admin': admin, 'denied': denied, 'badges': badges},
    ),
  });
  await AuthSession.instance.restore();
}

/// Denies the view permission of every key given.
List<String> denyViews(Iterable<String> keys) => [for (final k in keys) '$k.view'];

/// How many times the bar has asked for the users list (the account photo).
int navUsersRequests = 0;

http.Client navApi() => MockClient((req) async {
      if (req.url.path == '/users') {
        navUsersRequests++;
        return http.Response('[]', 200);
      }
      return http.Response('{}', 200);
    });

/// Replaces the stub pages, e.g. with one that keeps updating itself. Reset it in tearDown.
Widget Function(String path)? navStubPage;

class _StubPage extends StatelessWidget {
  final String path;
  const _StubPage(this.path);

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Colors.white,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageBanner(title: path),
            // Something on the page to Tab to, as every real screen has.
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: TextButton(onPressed: () {}, child: const Text('Page action')),
              ),
            ),
            const Expanded(child: SizedBox()),
          ],
        ),
      );
}

GoRoute _stub(String path, {List<RouteBase> routes = const []}) =>
    GoRoute(path: path, builder: (_, s) => navStubPage?.call(s.uri.path) ?? _StubPage(s.uri.path), routes: routes);

/// Same branch order and paths as the router in lib/main.dart, with stub pages.
GoRouter navTestRouter({String initial = '/calendar'}) => GoRouter(
      initialLocation: initial,
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) => MainNavigationShell(navigationShell: shell),
          branches: [
            StatefulShellBranch(routes: [
              for (final p in ['/office', '/statuses', '/payments', '/invoices', '/documents', '/site-checks', '/takeoffs'])
                _stub(p),
            ]),
            StatefulShellBranch(routes: [_stub('/customers')]),
            StatefulShellBranch(routes: [_stub('/projects')]),
            StatefulShellBranch(routes: [_stub('/estimates', routes: [_stub(':id')])]),
            StatefulShellBranch(routes: [_stub('/jobs', routes: [_stub(':id')])]),
            StatefulShellBranch(routes: [_stub('/calendar')]),
            StatefulShellBranch(routes: [
              _stub('/inventory', routes: [_stub('catalog'), _stub('purchase-orders'), _stub('vendors')]),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(
                path: '/hr',
                redirect: (_, s) => s.uri.path == '/hr' ? '/hr/payroll' : null,
                routes: [
                  _stub('payroll'),
                  _stub('kpis', routes: [_stub(':id')]),
                  _stub('team'),
                  _stub('corrections'),
                ],
              ),
            ]),
            StatefulShellBranch(routes: [
              _stub('/dashboards', routes: [
                for (final d in ['financial', 'commissions', 'technicians', 'inventory', 'jobs', 'estimates', 'sales', 'collections'])
                  _stub(d),
              ]),
            ]),
            StatefulShellBranch(routes: [_stub('/profile')]),
          ],
        ),
      ],
    );

/// The pop-up parts of the theme in lib/main.dart (menus, tooltips, pop-up menus), on Segoe UI.
ThemeData navTestTheme() => ThemeData(
      useMaterial3: true,
      fontFamily: 'Segoe UI',
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFCC0007), primary: const Color(0xFFCC0007)),
      popupMenuTheme: PopupMenuThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.14),
        menuPadding: const EdgeInsets.all(6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF0F172A)),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: const WidgetStatePropertyAll(Colors.white),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(8),
          shadowColor: WidgetStatePropertyAll(Colors.black.withValues(alpha: 0.14)),
          padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: Color(0xFFE2E8F0))),
          ),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 450),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: const Color(0xFF0F172A), borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white),
      ),
    );

/// Pumps the shell at [size] on [initial] and returns the router.
Future<GoRouter> pumpNav(WidgetTester t, Size size, {String initial = '/calendar', double textScale = 1}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final router = navTestRouter(initial: initial);
  await http.runWithClient(() async {
    await t.pumpWidget(MaterialApp.router(
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      theme: navTestTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
    ));
    await t.pumpAndSettle();
  }, navApi);
  return router;
}

Finder get navShell => find.byType(MainNavigationShell);
