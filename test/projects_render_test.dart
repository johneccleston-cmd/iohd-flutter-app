// Renders the Project Tracker with project data saved from the live sheet and saves screenshots to test/shots/.
// Run:  PROJECTS_JSON=<path to saved /api/projects JSON> flutter test test/projects_render_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/projects_screen.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

http.Response _ok(String body, [int code = 200]) =>
    http.Response.bytes(utf8.encode(body), code, headers: {'content-type': 'application/json; charset=utf-8'});

Future<void> _shot(WidgetTester tester, String name, http.Response Function(http.Request) h, {String? tapText}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1366, 768);
  addTearDown(tester.view.reset);
  await http.runWithClient(() async {
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
      home: const ProjectsScreen(),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    if (tapText != null) {
      await tester.tap(find.text(tapText).first);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
  }, () => MockClient((r) async => h(r)));
}

void main() {
  final body = File(Platform.environment['PROJECTS_JSON'] ?? 'test/projects_sample.json').readAsStringSync();

  setUpAll(() async {
    await _loadFont('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf', r'C:\Windows\Fonts\seguisb.ttf']);
    final root = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  testWidgets('list', (t) => _shot(t, 'projects_list', (r) => _ok(body)));
  testWidgets('detail', (t) => _shot(t, 'projects_detail', (r) => _ok(body), tapText: "KPI's, Reporting & Dashboards"));
  testWidgets('empty', (t) => _shot(t, 'projects_empty', (r) => _ok(jsonEncode({'success': true, 'projects': []}))));
  testWidgets('error', (t) => _shot(t, 'projects_error', (r) => _ok(jsonEncode({'success': false, 'error': 'The project sheet could not be reached. Try again.'}), 502)));
}
