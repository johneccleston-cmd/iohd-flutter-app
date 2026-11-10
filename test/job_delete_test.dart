// The Delete button on the job / estimate page (the Team screen's Jobs / Estimates Delete switch; admins always): confirm,
// DELETE /api/jobs/:id, back to the list, and the server's refusal shown when the job has payments or payroll history.
// Also the other job-page switches (Update: notes, tasks, uploads; Payments > Create: Request payment). Saves screenshots
// to test/shots/.
// Run:  flutter test test/job_delete_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/config/auth_session.dart';
import 'package:iohd_desktop/job_detail_screen.dart';
import 'package:iohd_desktop/widgets/record_list_view.dart' show recordDeleted;

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

Map<String, dynamic> _record({bool estimate = false}) => {
      'job': {
        'job_id': '1096183137',
        'customer_name': 'Schuber Mitchell Homes',
        'status': estimate ? 'Estimate Provided' : 'Unscheduled',
        'is_estimate': estimate,
        'total_revenue': '1000',
        'due_total': '1000',
        'raw_items': [],
        'other_charges': [],
      },
      'payments': [],
      'history': [],
    };

/// [deleteStatus]/[deleteBody] answer the DELETE; [admin] and [denied] are what /login says.
http.Client _client({required bool admin, List<String> denied = const [], bool estimate = false, int deleteStatus = 200, Map<String, dynamic>? deleteBody, List<http.Request>? sent}) =>
    MockClient((req) async {
      sent?.add(req);
      final p = req.url.path;
      if (p == '/login') {
        final exp = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch;
        final token = '${base64Url.encode(utf8.encode(json.encode({'exp': exp})))}.sig';
        return http.Response(json.encode({'token': token, 'name': 'Bella', 'role': admin ? 'Office Manager' : 'Office', 'is_admin': admin, 'access_denied': denied}), 200);
      }
      if (req.method == 'DELETE') return http.Response(jsonEncode(deleteBody ?? {'success': true}), deleteStatus);
      if (p.endsWith('/notes-tasks')) return http.Response(jsonEncode({'notes': [], 'tasks': []}), 200);
      if (p.endsWith('/files')) return http.Response(jsonEncode({'enabled': true, 'files': []}), 200);
      if (p.endsWith('/1096183137')) return http.Response(jsonEncode(_record(estimate: estimate)), 200);
      return http.Response('{}', 200);
    });

GoRouter _router() => GoRouter(
      initialLocation: '/jobs/1096183137',
      routes: [
        GoRoute(path: '/jobs', builder: (_, _) => const Scaffold(body: Text('JOBS LIST'))),
        GoRoute(path: '/estimates', builder: (_, _) => const Scaffold(body: Text('ESTIMATES LIST'))),
        GoRoute(path: '/jobs/:id', builder: (_, s) => JobDetailScreen(jobId: s.pathParameters['id']!)),
        GoRoute(path: '/estimates/:id', builder: (_, s) => JobDetailScreen(jobId: s.pathParameters['id']!)),
      ],
    );

Future<GoRouter> _open(WidgetTester t, http.Client client) async {
  t.view.physicalSize = const Size(1400, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final router = _router();
  AuthSession.instance.logout();
  await AuthSession.instance.login('bella', '1234');
  await t.pumpWidget(RepaintBoundary(
    key: const ValueKey('shot'),
    child: MaterialApp.router(theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'), routerConfig: router),
  ));
  await t.pumpAndSettle();
  return router;
}

final _deleteButton = find.widgetWithText(FilledButton, 'Delete');

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf']);
  });
  tearDown(() {
    AuthSession.instance.logout();
    recordDeleted.value = null;
  });

  testWidgets('office staff see Delete unless the Jobs Delete switch is off', (t) async {
    final on = _client(admin: false);
    await http.runWithClient(() async {
      await _open(t, on);
      expect(AuthSession.instance.isLoggedIn && !AuthSession.instance.isAdmin, isTrue);
      expect(_deleteButton, findsOneWidget);
    }, () => on);
    final off = _client(admin: false, denied: ['jobs.delete']);
    await http.runWithClient(() async {
      await _open(t, off);
      expect(find.text('Schuber Mitchell Homes'), findsWidgets, reason: 'the job loaded');
      expect(_deleteButton, findsNothing);
      expect(find.text('Add Task'), findsOneWidget, reason: 'Update is still on');
    }, () => off);
  });

  testWidgets('with Jobs Update and Payments Create off, the page is read-only', (t) async {
    final client = _client(admin: false, denied: ['jobs.update', 'jobs.delete', 'payments.create']);
    await http.runWithClient(() async {
      await _open(t, client);
      expect(find.text('Schuber Mitchell Homes'), findsWidgets);
      expect(_deleteButton, findsNothing);
      expect(find.text('Add Task'), findsNothing);
      expect(find.text('Add Notes'), findsNothing);
      expect(find.textContaining('Use Add Task'), findsNothing);
      expect(find.textContaining('Request'), findsNothing);
    }, () => client);
  });

  testWidgets('admin: Cancel keeps it, Delete sends DELETE, goes back to Jobs and tells the lists', (t) async {
    final sent = <http.Request>[];
    final client = _client(admin: true, sent: sent);
    await http.runWithClient(() async {
      final router = await _open(t, client);
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/job_delete_button.png'));

      await t.tap(_deleteButton);
      await t.pumpAndSettle();
      expect(find.text('Delete job #1096183137?'), findsOneWidget);
      expect(find.textContaining("Schuber Mitchell Homes's job comes out of the IOHD apps"), findsOneWidget);
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/job_delete_confirm.png'));

      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(sent.where((r) => r.method == 'DELETE'), isEmpty);

      await t.tap(_deleteButton);
      await t.pumpAndSettle();
      await t.tap(find.text('Delete job'));
      await t.pumpAndSettle();
      final del = sent.where((r) => r.method == 'DELETE').single;
      expect(del.url.path, '/api/jobs/1096183137');
      expect(del.headers.keys.map((k) => k.toLowerCase()), contains('authorization'));
      expect(router.routerDelegate.currentConfiguration.uri.path, '/jobs');
      expect(find.text('JOBS LIST'), findsOneWidget);
      expect(find.text('Job #1096183137 deleted.'), findsOneWidget);
      expect(recordDeleted.value, '1096183137');
    }, () => client);
  });

  testWidgets('an estimate goes back to Estimates', (t) async {
    final client = _client(admin: true, estimate: true);
    await http.runWithClient(() async {
      final router = await _open(t, client);
      await t.tap(_deleteButton);
      await t.pumpAndSettle();
      await t.tap(find.text('Delete estimate'));
      await t.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/estimates');
    }, () => client);
  });

  testWidgets("the server's refusal is shown and the page stays", (t) async {
    final client = _client(
      admin: true,
      deleteStatus: 409,
      deleteBody: {'success': false, 'error': "This job can't be deleted because it has payments recorded.", 'reasons': ['it has payments recorded']},
    );
    await http.runWithClient(() async {
      final router = await _open(t, client);
      await t.tap(_deleteButton);
      await t.pumpAndSettle();
      await t.tap(find.text('Delete job'));
      await t.pumpAndSettle();
      expect(find.text('Not deleted'), findsOneWidget);
      expect(find.text("This job can't be deleted because it has payments recorded."), findsOneWidget);
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/job_delete_refused.png'));
      await t.tap(find.text('OK'));
      await t.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/jobs/1096183137');
      expect(_deleteButton, findsOneWidget, reason: 'the button is usable again');
      expect(recordDeleted.value, isNull);
    }, () => client);
  });
}
