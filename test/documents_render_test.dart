// Renders the Documents screen with fake API data and saves screenshots to test/shots/.
// Run:  flutter test test/documents_render_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/documents_screen.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

http.Response _json(Map<String, dynamic> b, [int code = 200]) => http.Response(jsonEncode(b), code);

http.Response Function(http.Request) _handler({required bool connected, bool configured = true, bool empty = false}) {
  return (r) {
    if (r.url.path.endsWith('/drive/status')) {
      return _json({
        'success': true,
        'configured': configured,
        'connected': connected,
        'email': 'john@integritydoornwa.com',
        if (configured && !connected) 'message': 'Your app account has no email address. Ask an admin to add your Google Workspace email on the Team page.',
      });
    }
    if (r.url.path.endsWith('/drive/files')) {
      if (empty) return _json({'success': true, 'items': [], 'nextPageToken': null});
      final folder = r.url.queryParameters['folderId'];
      if (folder == null && r.url.queryParameters['q'] == null) {
        return _json({
          'success': true,
          'items': [
            {'id': 'root', 'name': 'My Drive', 'isFolder': true, 'isDrive': true, 'mimeType': 'folder'},
            {'id': 'd1', 'name': 'Integrity Overhead Door', 'isFolder': true, 'isDrive': true, 'mimeType': 'folder'},
          ],
        });
      }
      return _json({
        'success': true,
        'nextPageToken': 'x',
        'items': [
          {'id': 'f1', 'name': 'Contracts', 'isFolder': true, 'mimeType': 'folder', 'modifiedTime': '2026-09-30T12:00:00Z'},
          {'id': 'f2', 'name': 'Lennar master agreement 2026.pdf', 'isFolder': false, 'mimeType': 'application/pdf', 'modifiedTime': '2026-09-12T12:00:00Z', 'owner': 'Heather Vera', 'webViewLink': 'https://x'},
          {'id': 'f3', 'name': 'Door pricing', 'isFolder': false, 'mimeType': 'application/vnd.google-apps.spreadsheet', 'modifiedTime': '2026-10-01T12:00:00Z', 'owner': 'Zac Clemens', 'webViewLink': 'https://x'},
          {'id': 'f4', 'name': 'Install checklist', 'isFolder': false, 'mimeType': 'application/vnd.google-apps.document', 'modifiedTime': '2026-08-02T12:00:00Z', 'webViewLink': 'https://x'},
        ],
      });
    }
    return http.Response('{}', 404);
  };
}

Future<void> _shot(WidgetTester tester, String name, http.Response Function(http.Request) h, {String? tapText}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 720);
  addTearDown(tester.view.reset);
  await http.runWithClient(() async {
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
      home: const DocumentsScreen(),
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
  setUpAll(() async {
    await _loadFont('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf', r'C:\Windows\Fonts\seguisb.ttf']);
    final root = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  testWidgets('blocked', (t) => _shot(t, 'documents_blocked', _handler(connected: false)));
  testWidgets('not configured', (t) => _shot(t, 'documents_not_configured', _handler(connected: false, configured: false)));
  testWidgets('top level', (t) => _shot(t, 'documents_root', _handler(connected: true)));
  testWidgets('inside a drive', (t) => _shot(t, 'documents_folder', _handler(connected: true), tapText: 'Integrity Overhead Door'));
  testWidgets('empty folder', (t) => _shot(t, 'documents_empty', _handler(connected: true, empty: true)));
}
