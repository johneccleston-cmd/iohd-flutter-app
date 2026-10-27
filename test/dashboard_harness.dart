// Shared harness for the eight dashboards: saved responses (test/fixtures/dashboards), a fake API that records what
// was asked for, a pinned clock, a signed-in session, and helpers to pump a dashboard, catch overflows and save a
// screenshot for review.
//
// Screenshots go to build/dash_shots/ (git-ignored). They are for looking at, not golden comparisons, so nothing
// here can "pass" by rewriting a reference image.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/config/auth_session.dart';
import 'package:iohd_desktop/widgets/dashboard_data.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Now" for every dashboard test: Oct 22 2026, 2:33 PM in Chicago. The fixtures were computed at 2:30 PM
/// (generatedAt 19:30 UTC), so the header should say "Updated 3 min ago".
final DateTime kDashNow = DateTime.parse('2026-10-22T19:33:00Z').toLocal();

void pinDashClock([DateTime? at]) {
  final now = at ?? kDashNow;
  DashClock.debugOverride = () => now;
}

void unpinDashClock() => DashClock.debugOverride = null;

/// A saved response from test/fixtures/dashboards (decoded fresh each time, so a test can change it).
Map<String, dynamic> dashFixture(String name) =>
    json.decode(File('test/fixtures/dashboards/$name.json').readAsStringSync()) as Map<String, dynamic>;

/// Which fixture answers which path. The paths are the ones the app requests.
const dashEndpoints = <String, String>{
  '/api/financial_dashboard': 'financial',
  '/api/commissions_stats': 'commissions',
  '/api/tech_stats': 'technicians',
  '/api/dashboards/inventory': 'inventory',
  '/api/dashboards/sales': 'sales',
  '/api/dashboards/collections': 'collections',
  '/api/dashboards/jobs': 'jobs',
  '/api/dashboards/estimates': 'estimates',
};

/// A fake backend for the dashboards. Every request is recorded. Per path you can force a status code, a different
/// fixture, a different fixture for one year, or a delay (to test what happens when answers arrive out of order).
class DashFakeApi {
  final requests = <http.Request>[];
  final status = <String, int>{};
  final fixture = <String, String>{};

  /// `path?year=Y` -> fixture name, for year-switch tests.
  final yearFixture = <String, String>{};
  final delay = <String, Duration>{};

  /// Extra handlers checked first (drill-down lists, payroll runs, a held-back answer ...). Return null to fall
  /// through to the fixtures.
  final extra = <Future<http.Response?> Function(http.Request)>[];

  Iterable<http.Request> to(String path) => requests.where((r) => r.url.path == path);

  http.Client client() => MockClient((req) async {
        requests.add(req);
        final path = req.url.path;
        for (final h in extra) {
          final r = await h(req);
          if (r != null) return r;
        }
        final wait = delay[path];
        if (wait != null) await Future<void>.delayed(wait);
        final code = status[path];
        if (code != null && code != 200) {
          return http.Response(json.encode({'error': 'simulated $code'}), code);
        }
        final year = req.url.queryParameters['year'];
        final name = yearFixture['$path?year=$year'] ?? fixture[path] ?? dashEndpoints[path];
        if (name == null) return http.Response(json.encode({'error': 'no fixture for $path'}), 404);
        return http.Response(json.encode(dashFixture(name)), 200);
      });
}

/// Signs in through the saved-session path (what reopening the app does). Admin by default.
Future<void> dashSignIn({bool admin = true}) async {
  AuthSession.instance.logout();
  final payload = base64Url.encode(utf8.encode(json.encode({'exp': DateTime(2100).millisecondsSinceEpoch})));
  SharedPreferences.setMockInitialValues({
    'iohd_auth_session': json.encode(
      {'token': '$payload.sig', 'name': 'Test Admin', 'role': admin ? 'Admin' : 'Office', 'is_admin': admin, 'denied': <String>[]},
    ),
  });
  await AuthSession.instance.restore();
}

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final f = File(p);
    if (!f.existsSync()) continue;
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(f.readAsBytesSync()).buffer)));
  }
  await loader.load();
}

/// The Windows app's fonts, so text measures like the real thing (call from setUpAll).
Future<void> loadDashFonts() async {
  await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf', 'C:/Windows/Fonts/seguisb.ttf']);
  final root = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
  await _loadFont('Roboto', [
    '$root/bin/cache/artifacts/material_fonts/roboto-regular.ttf',
    '$root/bin/cache/artifacts/material_fonts/roboto-medium.ttf',
    '$root/bin/cache/artifacts/material_fonts/roboto-bold.ttf',
  ]);
  await _loadFont('MaterialIcons', ['$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
}

final _shotKey = GlobalKey();

/// Layout problems (overflows) reported while a dashboard was on screen.
class DashLayoutErrors {
  final messages = <String>[];
  bool get overflowed => messages.any((m) => m.contains('overflowed'));
}

/// Pumps [screen] the way the app shows it (Segoe UI, light theme) at [size], with [api] answering requests, and
/// lets the entrance and count-up animations finish. Runs [body] afterwards inside the same fake-API zone, so taps
/// that fetch more data are answered too. Layout errors are collected instead of failing the test immediately.
Future<DashLayoutErrors> pumpDashboard(
  WidgetTester tester,
  Widget screen, {
  required DashFakeApi api,
  Size size = const Size(1280, 600),
  double textScale = 1.0,
  bool reduceMotion = false,
  Future<void> Function()? body,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  final errors = DashLayoutErrors();
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    final text = details.exceptionAsString();
    if (text.contains('overflowed')) {
      // The first line says by how much; the "error-causing widget" line says where.
      final full = details.toString().split('\n');
      final at = full.indexWhere((l) => l.contains('The relevant error-causing widget was'));
      final where = at >= 0 && at + 1 < full.length ? ' at ${full[at + 1].trim()}' : '';
      errors.messages.add('${text.split('\n').first}$where');
    } else {
      previous?.call(details);
    }
  };

  // flutter_test insists the handler is put back before the test body ends (a tear-down is too late), so the whole
  // interaction runs here and the handler is restored even if an expectation fails.
  try {
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale), disableAnimations: reduceMotion),
          child: RepaintBoundary(
            key: _shotKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
              home: Scaffold(body: screen),
            ),
          ),
        ),
      );
      await settleDashboard(tester);
      if (body != null) await body();
    }, api.client);
  } finally {
    FlutterError.onError = previous;
  }
  return errors;
}

/// Lets requests answer and the entrance/count-up animations finish. (Not pumpAndSettle: some dashboards have
/// animations that never stop, like the Commissions countdown.)
Future<void> settleDashboard(WidgetTester tester, {int frames = 30}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Saves what is on screen to build/dash_shots/[name].png for review (not a golden).
Future<void> saveDashShot(WidgetTester tester, String name) async {
  final boundary = _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/dash_shots')..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

/// Every network image URL on screen (to prove no third-party avatar service is asked for anyone's name).
Iterable<String> dashNetworkImageUrls(WidgetTester tester) => tester
    .widgetList<Image>(find.byType(Image))
    .map((i) => i.image)
    .whereType<NetworkImage>()
    .map((n) => n.url);
