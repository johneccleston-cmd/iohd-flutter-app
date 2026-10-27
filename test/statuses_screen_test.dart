// Renders the Estimate & Job Statuses screen against a fake server, saves screenshots to test/shots/ and checks
// add / delete. Run:  flutter test test/statuses_screen_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/statuses_screen.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

http.Response _json(Object body, [int code = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), code, headers: {'content-type': 'application/json; charset=utf-8'});

/// A tiny in-memory copy of the /api/statuses routes.
class _Fake {
  final rows = <Map<String, dynamic>>[];
  int _next = 1;
  final calls = <String>[];
  Map<String, dynamic>? lastBody;

  _Fake() {
    for (final s in builtInStatuses()) {
      rows.add({...s.toJson(), 'id': _next++});
    }
  }

  http.Response handle(http.Request r) {
    calls.add('${r.method} ${r.url.path}');
    final p = r.url.path;
    if (r.body.isNotEmpty) lastBody = jsonDecode(r.body) as Map<String, dynamic>;
    if (r.method == 'GET' && p == '/api/statuses') {
      return _json({
        'success': true,
        'statuses': rows,
        'commissionByName': {
          'paid & closed': {'kind': 'closing', 'pays': true, 'line': 'A job earns its commission, and is paid, in the pay week it first reaches this status.'},
          'callback': {'kind': 'callback', 'pays': true, 'line': 'Pays the tech a flat amount for each verified visit and counts as a strike.', 'amount': 50, 'unit': r'$', 'label': 'Flat payout per verified visit', 'live': false},
          'need deposit': {'kind': 'none', 'pays': false, 'line': 'Not a commission status. It does not trigger or change any pay.'},
        },
      });
    }
    if (r.method == 'POST' && p == '/api/statuses') {
      final b = jsonDecode(r.body) as Map<String, dynamic>;
      rows.add({...b, 'id': _next++});
      return _json({'success': true}, 201);
    }
    if (r.method == 'PUT' && p.startsWith('/api/statuses/')) return _json({'success': true});
    if (r.method == 'DELETE') {
      final id = int.parse(p.split('/').last);
      rows.removeWhere((e) => e['id'] == id);
      return _json({'success': true});
    }
    return _json({'success': false, 'error': 'nope'}, 404);
  }
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _open(WidgetTester t, http.Response Function(http.Request) h, Future<void> Function() body, {Size size = const Size(1366, 768)}) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = size;
  addTearDown(t.view.reset);
  await http.runWithClient(() async {
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
      home: const StatusesScreen(),
    ));
    await _settle(t);
    await body();
  }, () => MockClient((r) async => h(r)));
}

Future<void> _golden(String name) => expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf', r'C:\Windows\Fonts\seguisb.ttf']);
    final root = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  testWidgets('job list, then estimate tab', (t) async {
    final f = _Fake();
    await _open(t, f.handle, () async {
      expect(find.text('Need Deposit'), findsOneWidget);
      expect(find.text('Open Jobs'), findsWidgets);
      await _golden('statuses_jobs');
      await t.tap(find.text('Estimate Statuses'));
      await _settle(t);
      expect(find.text('Estimate Provided'), findsOneWidget);
      expect(find.text('Need Deposit'), findsNothing);
      await _golden('statuses_estimates');
    });
  });

  testWidgets('add opens the editor and saves', (t) async {
    final f = _Fake();
    await _open(t, f.handle, () async {
      await t.tap(find.text('Add job status'));
      await _settle(t);
      await _golden('statuses_editor');
      await t.tap(find.text('Add status')); // empty name is refused
      await _settle(t);
      expect(find.text('Give the status a name.'), findsOneWidget);
      await t.enterText(find.byType(TextField).first, 'Need Permit');
      await t.tap(find.text('Add status'));
      await _settle(t);
      expect(f.calls, contains('POST /api/statuses'));
      expect(f.rows.last['name'], 'Need Permit'); // lands at the bottom of the list
      expect(f.rows.last['kind'], 'job');
    });
  });

  testWidgets('editor shows the commission badge, one-liner and amount', (t) async {
    final f = _Fake();
    await _open(t, f.handle, () async {
      await t.tap(find.byTooltip('Edit Need Deposit'));
      await _settle(t);
      expect(find.text('Not a commission status'), findsOneWidget);
      expect(find.text('Commission paying status'), findsNothing);
      await t.tap(find.byTooltip('Close'));
      await _settle(t);
      await t.scrollUntilVisible(find.byTooltip('Edit Callback'), 200, scrollable: find.byType(Scrollable).first);
      await t.tap(find.byTooltip('Edit Callback'));
      await _settle(t);
      expect(find.text('Commission paying status'), findsOneWidget);
      expect(find.text('Flat payout per verified visit'), findsOneWidget);
      expect(find.textContaining('payroll still pays the old amount'), findsOneWidget);
      await t.enterText(find.byType(TextField).last, '75');
      await _settle(t);
      await _golden('statuses_editor_commission');
      await t.tap(find.text('Save'));
      await _settle(t);
      expect(f.calls.any((c) => c.startsWith('PUT /api/statuses/')), isTrue);
      expect(f.lastBody?['commissionAmount'], 75);
    });
  });

  testWidgets('delete asks first', (t) async {
    final f = _Fake();
    await _open(t, f.handle, () async {
      await t.tap(find.byTooltip('Delete Need Deposit'));
      await _settle(t);
      expect(find.textContaining('Service Fusion'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await _settle(t);
      expect(find.text('Need Deposit'), findsOneWidget);
      await t.tap(find.byTooltip('Delete Need Deposit'));
      await _settle(t);
      await t.tap(find.text('Delete'));
      await _settle(t);
      expect(find.text('Need Deposit'), findsNothing);
    });
  });

  testWidgets('server without the route shows the built-in list read-only', (t) async {
    await _open(t, (r) => _json({'success': false}, 404), () async {
      expect(find.text('Need Deposit'), findsOneWidget);
      expect(find.byTooltip('Delete Need Deposit'), findsNothing);
      await _golden('statuses_readonly');
    });
  });

  testWidgets('error shows retry', (t) async {
    await _open(t, (r) => _json({'success': false, 'error': 'Could not load the status. Try again.'}, 500), () async {
      expect(find.textContaining('Could not load'), findsWidgets);
      await _golden('statuses_error');
    });
  });

  testWidgets('narrow window has no overflow', (t) async {
    await _open(t, _Fake().handle, () async {
      expect(t.takeException(), isNull);
      await _golden('statuses_narrow');
    }, size: const Size(520, 800));
  });
}
