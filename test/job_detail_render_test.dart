// Renders the real job detail screen with fake API data and saves screenshots to test/shots/.
// Run:  flutter test test/job_detail_render_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/job_detail_screen.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

Map<String, dynamic> _full() => {
      'job': {
        'job_id': '1096183137',
        'customer_name': 'Schuber Mitchell Homes',
        'contact_name': 'Dana Whitfield',
        'status': 'Final Invoice Sent',
        'sub_status': 'Site Check',
        'is_estimate': false,
        'category': 'Residential Install',
        'location': '1204 W Poplar St, Rogers, AR 72756',
        'description': 'Replace two garage doors, torsion springs, new weather seal.',
        'notes': 'Gate code 4471. Dog in backyard.',
        'po_number': 'PO-88231',
        'techs_assigned': 'Brett Hall, Marcus Lee',
        'opportunity_owner': 'Heather Vera',
        'start_date': '2026-10-06',
        'end_date': '2026-10-07',
        'closed_at': '2026-10-09',
        'total_revenue': '2450.00',
        'due_total': '950.00',
        'sf_details': {
          'priority': 'Normal',
          'duration': 3600,
          'time_frame_promised_start': '08:00:00',
          'time_frame_promised_end': '10:00:00',
          'techs': [
            {'name': 'Office Admin', 'status': 'Scheduled - Full Day'},
          ],
          'tasks': [
            {'description': 'How close will any surrounding equipment be to these doors?', 'is_completed': true},
            {'description': 'Send rolling door drawing to Chris to confirm there will not be an issue with the support arms', 'is_completed': true},
            {'description': 'Order the 5K forklift rental for day two', 'is_completed': false},
          ],
          'notes': [
            {'text': 'Doors are unloaded on site.', 'created_at': '2026-09-02T19:44:00Z'},
            {'text': 'D said will need to rent fork lift, but not for day 1. Will touch base tomorrow if they will be ready for it on Thursday. Need to ask Chris about telehandler', 'created_at': '2026-10-06T15:23:00Z'},
          ],
          'pictures': [
            {'name': 'front-of-house.jpg', 'url': 'https://example.invalid/a.jpg', 'type': 'Picture', 'comment': 'Before', 'is_private': false},
            {'name': 'garage-left.jpg', 'url': 'https://example.invalid/b.jpg', 'type': 'Picture', 'comment': '', 'is_private': false},
          ],
          'documents': [
            {'name': 'Signed work order.pdf', 'url': 'https://example.invalid/wo.pdf', 'type': 'Work Order', 'comment': 'Customer signed on site', 'is_private': false, 'created_at': '2026-10-07T15:00:00Z'},
            {'name': 'Permit.pdf', 'url': 'https://example.invalid/p.pdf', 'type': 'Permit', 'comment': '', 'is_private': true, 'created_at': '2026-10-02T15:00:00Z'},
          ],
          'visits': [
            {
              'start_date': '2026-09-02',
              'time_frame_promised_start': null,
              'time_frame_promised_end': null,
              'duration': 5400,
              'notes_for_techs': 'Bring the 5K forklift.',
              'techs': [
                {'name': 'Daniel Baty', 'status': 'Scheduled - Full Day'},
                {'name': 'Marcus Lee', 'status': 'Scheduled - Half Day'},
              ],
            },
            {
              'start_date': '2026-10-07',
              'time_frame_promised_start': '13:00:00',
              'time_frame_promised_end': '15:30:00',
              'duration': 3600,
              'notes_for_techs': '',
              'techs': [],
            },
          ],
        },
        'raw_items': [
          {'name': 'SMH | Gallery Steel | GD5S | Complete Door | White', 'total': 507.16, 'multiplier': 1, 'item_index': 3},
          {'name': 'Weather Seal | Stop Mold | 7\' White', 'total': 10.54, 'multiplier': 2, 'item_index': 6},
          {'name': 'SMH Installation | Gallery Steel | 16x7 | White', 'total': 300, 'multiplier': 1, 'item_index': 2},
        ],
      },
      'customer': {'primary_contact': 'Dana Whitfield', 'phone': '(479) 736-2125', 'email': 'dana@schubermitchell.com'},
      'fromEstimate': '1089344759',
      'visits': [
        {'tech_name': 'Brett Hall', 'work_date': '2026-10-06', 'is_verified': true, 'is_callback': false},
        {'tech_name': 'Marcus Lee', 'work_date': '2026-10-07', 'is_verified': false, 'is_callback': true},
      ],
      'payments': [
        {'amount': '1500.00', 'received_on': '2026-10-09T15:00:00Z', 'payment_type': 'Check', 'transaction_type': 'Payment'},
      ],
      'stripePayments': [
        {'id': 'stripe-pi_1', 'amount': '1225.00', 'received_on': '2026-10-17T15:00:00Z', 'kind': 'payment'},
      ],
      'history': [
        {'old_status': 'Created', 'new_status': 'Scheduled', 'changed_at': '2026-10-01T14:00:00Z'},
        {'old_status': 'Scheduled', 'new_status': 'Final Invoice Sent', 'changed_at': '2026-10-09T14:00:00Z'},
      ],
    };


final List<String> _requests = [];
final List<Map<String, dynamic>> _notesDb = [];
final List<Map<String, dynamic>> _tasksDb = [];

/// Fake server: the job, plus the uploaded-files route (two files of ours) and a delete that succeeds.
http.Client _mock({int filesStatus = 200}) => MockClient((req) async {
      _requests.add('${req.method} ${req.url.path}');
      if (req.url.path.endsWith('/files') && req.method == 'GET') {
        return http.Response(
          jsonEncode({
            'enabled': filesStatus == 200,
            'files': [
              {'id': '7', 'kind': 'pic', 'name': 'garage-after.jpg', 'url': 'https://example.invalid/after.jpg', 'uploadedBy': 'Dana Whitfield', 'size': 2411724},
              {'id': '8', 'kind': 'doc', 'name': 'Customer sign-off.pdf', 'url': 'https://example.invalid/so.pdf', 'uploadedBy': 'Dana Whitfield', 'size': 182400, 'createdAt': '2026-10-12T15:00:00Z'},
              {'id': '9', 'kind': 'doc', 'name': 'site-notes.txt', 'url': 'https://example.invalid/n.txt', 'uploadedBy': 'Dana Whitfield', 'size': 40},
              {'id': '10', 'kind': 'doc', 'name': 'Quote v2.docx', 'url': 'https://example.invalid/q.docx', 'uploadedBy': 'Dana Whitfield', 'size': 90000},
            ],
          }),
          200,
        );
      }
      if (req.url.path.endsWith('/files/9/content')) return http.Response('Gate code 4471. Call before arriving.', 200, headers: {'content-type': 'text/plain'});
      // Notes and tasks added in the app: a tiny in-memory stand-in for the backend tables.
      final path = req.url.path;
      if (path.endsWith('/notes-tasks')) return http.Response(jsonEncode({'notes': _notesDb, 'tasks': _tasksDb}), 200);
      if (req.method == 'POST' && path.endsWith('/notes')) {
        final note = {'id': '${_notesDb.length + 1}', 'body': jsonDecode(req.body)['body'], 'author': 'Dana Whitfield', 'createdAt': '2026-10-12T16:30:00Z'};
        _notesDb.insert(0, note);
        return http.Response(jsonEncode({'note': note}), 201);
      }
      if (req.method == 'POST' && path.endsWith('/tasks')) {
        final task = {
          'id': '${_tasksDb.length + 1}',
          'description': jsonDecode(req.body)['description'],
          'isCompleted': false,
          'createdBy': 'Dana Whitfield',
          'createdAt': '2026-10-12T16:31:00Z',
          'completedBy': '',
          'completedAt': null,
        };
        _tasksDb.insert(0, task);
        return http.Response(jsonEncode({'task': task}), 201);
      }
      if (req.method == 'PATCH' && path.contains('/tasks/')) {
        final task = _tasksDb.firstWhere((t) => path.endsWith('/tasks/${t['id']}'));
        task['isCompleted'] = jsonDecode(req.body)['is_completed'];
        task['completedBy'] = task['isCompleted'] == true ? 'Marcus Lee' : '';
        task['completedAt'] = task['isCompleted'] == true ? '2026-10-12T17:00:00Z' : null;
        return http.Response(jsonEncode({'task': task}), 200);
      }
      if (req.method == 'DELETE' && path.contains('/notes/')) {
        _notesDb.removeWhere((n) => path.endsWith('/notes/${n['id']}'));
        return http.Response(jsonEncode({'success': true}), 200);
      }
      if (req.method == 'DELETE') return http.Response(jsonEncode({'success': true}), 200);
      if (req.method == 'POST' && path.endsWith('/payment-link')) {
        final body = jsonDecode(req.body);
        if ((body['amount'] as num) > 100000) return http.Response(jsonEncode({'error': 'Amount must be between \$1 and \$250000.'}), 400);
        return http.Response(jsonEncode({'url': 'https://integrity-backend-cr02.onrender.com/pay/eyJqIjoiMTA5NjE4MzEzNyJ9.abc123', 'amount': body['amount'], 'type': body['type']}), 200);
      }
      return http.Response(jsonEncode(_full()), 200);
    });

Future<void> _shot(WidgetTester t, Size size, String name, http.Client client, {Map<String, dynamic>? initial}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  await http.runWithClient(() async {
    await t.pumpWidget(RepaintBoundary(
      key: const ValueKey('shot'),
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'),
        home: JobDetailScreen(jobId: '1096183137', initial: initial),
      ),
    ));
    await t.pump(const Duration(milliseconds: 50));
    await t.pump(const Duration(milliseconds: 300));
  }, () => client);
  expect(t.takeException(), isNull);
  await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/$name.png'));
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf']);
  });

  testWidgets('wide, full data', (t) async {
    await _shot(t, const Size(1500, 900), 'job_detail_wide', _mock());
  });

  testWidgets('status dropdown opens and a pick says it is not saved', (t) async {
    t.view.physicalSize = const Size(1500, 900);
    t.view.devicePixelRatio = 1;
    await http.runWithClient(() async {
      await t.pumpWidget(RepaintBoundary(
        key: const ValueKey('shot'),
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'),
          home: const JobDetailScreen(jobId: '1096183137'),
        ),
      ));
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.text('Final Invoice Sent').first);
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(find.text('Need To Schedule'), findsOneWidget); // the list is there
      expect(t.takeException(), isNull);
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/job_detail_status_menu.png'));
      await t.tap(find.text('Close Job'));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('is not saved yet'), findsOneWidget);
      expect(find.text('Final Invoice Sent'), findsWidgets); // value on screen is unchanged
    }, () => _mock());
  });

  testWidgets('request payment makes a pay link', (t) async {
    t.view.physicalSize = const Size(1500, 900);
    t.view.devicePixelRatio = 1;
    await http.runWithClient(() async {
      await t.pumpWidget(RepaintBoundary(
        key: const ValueKey('shot'),
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'),
          home: const JobDetailScreen(jobId: '1096183137'),
        ),
      ));
      await t.pumpAndSettle();
      await t.tap(find.text('Payment'));
      await t.pumpAndSettle();
      await t.tap(find.text('Request payment'));
      await t.pumpAndSettle();
      // Starts on the balance due (950.00).
      expect(find.widgetWithText(TextField, '950.00'), findsOneWidget);
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/job_detail_request_payment.png'));
      await t.enterText(find.byType(TextField), '999999');
      await t.tap(find.text('Create link'));
      await t.pumpAndSettle();
      expect(find.textContaining('Amount must be between'), findsOneWidget);
      await t.enterText(find.byType(TextField), '1225');
      await t.tap(find.text('Create link'));
      await t.pumpAndSettle();
      expect(find.textContaining('/pay/eyJ'), findsOneWidget);
      expect(find.text('Copy link'), findsOneWidget);
      expect(t.takeException(), isNull);
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/job_detail_payment_link.png'));
    }, () => _mock());
  });

  testWidgets('every tab opens', (t) async {
    t.view.physicalSize = const Size(1500, 900);
    t.view.devicePixelRatio = 1;
    await http.runWithClient(() async {
      await t.pumpWidget(RepaintBoundary(
        key: const ValueKey('shot'),
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'),
          home: const JobDetailScreen(jobId: '1096183137'),
        ),
      ));
      await t.pumpAndSettle();
      // Default tabs: Summary (Details) and Scheduling (Job Info).
      expect(find.text('Primary Contact'), findsOneWidget);
      expect(find.text('Arrival Time Window'), findsOneWidget);

      await t.tap(find.text('Payment'));
      await t.pumpAndSettle();
      expect(find.text('Balance Due'), findsOneWidget);
      expect(find.text('Arrival Time Window'), findsNothing);
      await t.tap(find.textContaining('Pics'));
      await t.pumpAndSettle();
      expect(find.text('front-of-house.jpg'), findsOneWidget);
      expect(find.text('Primary Contact'), findsNothing);
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/job_detail_tab_payment_pics.png'));

      await t.tap(find.text('Communications'));
      await t.pumpAndSettle();
      expect(find.text('No communications recorded'), findsOneWidget);
      await t.tap(find.text('Activity'));
      await t.pumpAndSettle();
      expect(find.textContaining('Created  →  Scheduled', findRichText: true), findsOneWidget);
      await t.tap(find.textContaining('Docs'));
      await t.pumpAndSettle();
      expect(find.text('Signed work order.pdf'), findsOneWidget);
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/job_detail_tab_docs.png'));
      await t.tap(find.text('Takeoffs'));
      await t.pumpAndSettle();
      expect(find.text('No takeoffs yet'), findsOneWidget);
      await t.tap(find.text('Summary'));
      await t.tap(find.text('Scheduling'));
      await t.pumpAndSettle();
      expect(find.text('Primary Contact'), findsOneWidget);
      expect(find.text('Arrival Time Window'), findsOneWidget);
      expect(t.takeException(), isNull);
    }, () => _mock());
  });

  testWidgets('tall: task list and notes', (t) async {
    await _shot(t, const Size(1500, 1700), 'job_detail_tall', _mock());
  });

  testWidgets('our uploads show with an Upload button and can be removed', (t) async {
    t.view.physicalSize = const Size(1500, 1000);
    t.view.devicePixelRatio = 1;
    _requests.clear();
    await http.runWithClient(() async {
      await t.pumpWidget(RepaintBoundary(
        key: const ValueKey('shot'),
        child: MaterialApp(theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'), home: const JobDetailScreen(jobId: '1096183137')),
      ));
      await t.pumpAndSettle();
      expect(_requests, contains('GET /api/jobs/1096183137/files'));

      await t.tap(find.textContaining('Pics'));
      await t.pumpAndSettle();
      expect(find.text('Upload pictures'), findsOneWidget);
      expect(find.text('garage-after.jpg'), findsOneWidget); // ours
      expect(find.text('front-of-house.jpg'), findsOneWidget); // Service Fusion's
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/job_detail_uploads_pics.png'));

      await t.tap(find.textContaining('Docs'));
      await t.pumpAndSettle();
      expect(find.text('Upload documents'), findsOneWidget);
      expect(find.text('Customer sign-off.pdf'), findsOneWidget);
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/job_detail_uploads_docs.png'));

      await t.tap(find.byTooltip('Remove').first);
      await t.pumpAndSettle();
      expect(find.text('Remove this file?'), findsOneWidget);
      await t.tap(find.text('Remove'));
      await t.pumpAndSettle();
      expect(_requests, contains('DELETE /api/jobs/1096183137/files/8'));
      expect(t.takeException(), isNull);
    }, () => _mock());
  });

  testWidgets('clicking a file opens a viewer in the same window with Download', (t) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    _requests.clear();
    await http.runWithClient(() async {
      await t.pumpWidget(RepaintBoundary(
        key: const ValueKey('shot'),
        child: MaterialApp(theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'), home: const JobDetailScreen(jobId: '1096183137')),
      ));
      await t.pumpAndSettle();

      // A picture: opens over the page, shows its place in the set, and Next moves along.
      await t.tap(find.textContaining('Pics'));
      await t.pumpAndSettle();
      await t.tap(find.text('garage-after.jpg'));
      await t.pumpAndSettle();
      expect(find.text('Download'), findsOneWidget);
      expect(find.textContaining('1 of 3'), findsOneWidget);
      expect(find.byTooltip('Previous'), findsNothing); // first one
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/file_viewer_picture.png'));
      await t.tap(find.byTooltip('Next'));
      await t.pumpAndSettle();
      expect(find.textContaining('2 of 3'), findsOneWidget);
      await t.tap(find.byTooltip('Close'));
      await t.pumpAndSettle();
      expect(find.text('Download'), findsNothing);

      // A text file: its content is fetched through the backend and shown.
      await t.tap(find.textContaining('Docs'));
      await t.pumpAndSettle();
      await t.tap(find.text('site-notes.txt'));
      await t.pumpAndSettle();
      expect(find.text('Gate code 4471. Call before arriving.'), findsOneWidget);
      expect(_requests, contains('GET /api/jobs/1096183137/files/9/content'));
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/file_viewer_text.png'));
      await t.tap(find.byTooltip('Close'));
      await t.pumpAndSettle();

      // A type with no preview says so and still offers Download.
      await t.tap(find.text('Quote v2.docx'));
      await t.pumpAndSettle();
      expect(find.text('No preview for .docx files'), findsOneWidget);
      expect(find.text('Download'), findsOneWidget);
      expect(t.takeException(), isNull);
    }, () => _mock());
  });

  testWidgets('add a note and a task: saved through the backend, shown with who did it, and in Activity', (t) async {
    t.view.physicalSize = const Size(1500, 1700);
    t.view.devicePixelRatio = 1;
    _notesDb.clear();
    _tasksDb.clear();
    _requests.clear();
    await http.runWithClient(() async {
      await t.pumpWidget(RepaintBoundary(
        key: const ValueKey('shot'),
        child: MaterialApp(theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'), home: const JobDetailScreen(jobId: '1096183137')),
      ));
      await t.pumpAndSettle();
      expect(_requests, contains('GET /api/jobs/1096183137/notes-tasks'));

      // Add Notes: an empty save is refused inside the dialog; a real one is saved and shown with the author.
      await t.tap(find.text('Add Notes'));
      await t.pumpAndSettle();
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(find.text('Type something first.'), findsOneWidget);
      await t.enterText(find.byType(TextField), 'Customer wants the grays to match.');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(_requests, contains('POST /api/jobs/1096183137/notes'));
      expect(find.text('Customer wants the grays to match.'), findsOneWidget);
      expect(find.textContaining('by Dana Whitfield'), findsWidgets);
      expect(find.textContaining('Service Fusion'), findsWidgets); // the synced notes are labelled as such

      // Add Task, then tick it off: who added and who finished it is shown.
      await t.tap(find.text('Add Task'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'Order the forklift for day two');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(find.text('Order the forklift for day two'), findsOneWidget);
      expect(find.textContaining('Added by Dana Whitfield'), findsOneWidget);
      await t.tap(find.byTooltip('Mark done'));
      await t.pumpAndSettle();
      expect(find.textContaining('done by Marcus Lee'), findsOneWidget);
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/job_detail_notes_tasks_added.png'));

      // Activity names the person for everything done in the app.
      await t.tap(find.text('Activity'));
      await t.pumpAndSettle();
      expect(find.textContaining('Dana Whitfield  Added a note', findRichText: true), findsOneWidget);
      expect(find.textContaining('Dana Whitfield  Added task "Order the forklift for day two"', findRichText: true), findsOneWidget);
      expect(find.textContaining('Marcus Lee  Completed task', findRichText: true), findsOneWidget);
      expect(find.textContaining('Service Fusion  Status', findRichText: true), findsWidgets);
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/job_detail_activity_users.png'));

      // Remove our note (asks first).
      await t.tap(find.byTooltip('Remove note'));
      await t.pumpAndSettle();
      expect(find.text('Remove this note?'), findsOneWidget);
      await t.tap(find.text('Remove'));
      await t.pumpAndSettle();
      expect(find.text('Customer wants the grays to match.'), findsNothing);
      expect(t.takeException(), isNull);
    }, () => _mock());
  });

  testWidgets('the Notes section is collapsed by default when there are more than two notes', (t) async {
    t.view.physicalSize = const Size(1500, 1300);
    t.view.devicePixelRatio = 1;

    // Two notes (the normal fixture): nothing to collapse, no control.
    await http.runWithClient(() async {
      await t.pumpWidget(RepaintBoundary(
        key: const ValueKey('shot'),
        child: MaterialApp(theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'), home: const JobDetailScreen(jobId: '1096183137')),
      ));
      await t.pumpAndSettle();
      expect(find.textContaining('Show all'), findsNothing);
      expect(find.text('Doors are unloaded on site.'), findsOneWidget);
    }, () => _mock());

    // Five notes: only the newest two show, with a control to open the rest.
    final job = _full();
    (job['job']['sf_details'] as Map)['notes'] = <Map<String, dynamic>>[
      for (var i = 1; i <= 5; i++) {'text': 'Note number $i about the job.', 'created_at': '2026-10-0${i}T15:00:00Z'},
    ];
    http.Client five() => MockClient((req) async {
          final p = req.url.path;
          if (p.endsWith('/notes-tasks')) return http.Response(jsonEncode({'notes': [], 'tasks': []}), 200);
          if (p.endsWith('/files')) return http.Response(jsonEncode({'enabled': true, 'files': []}), 200);
          return http.Response(jsonEncode(job), 200);
        });
    await http.runWithClient(() async {
      await t.pumpWidget(RepaintBoundary(
        key: const ValueKey('shot2'),
        child: MaterialApp(theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'), home: const JobDetailScreen(jobId: '1096183137', key: ValueKey('five-notes'))),
      ));
      await t.pumpAndSettle();
      expect(find.text('Note number 5 about the job.'), findsOneWidget); // newest first
      expect(find.text('Note number 4 about the job.'), findsOneWidget);
      expect(find.text('Note number 3 about the job.'), findsNothing); // hidden while collapsed
      expect(find.text('Show all 5 notes (3 older)'), findsOneWidget);
      await expectLater(find.byKey(const ValueKey('shot2')), matchesGoldenFile('shots/job_detail_notes_collapsed.png'));

      await t.tap(find.text('Show all 5 notes (3 older)'));
      await t.pumpAndSettle();
      for (var i = 1; i <= 5; i++) {
        expect(find.text('Note number $i about the job.'), findsOneWidget);
      }
      expect(find.text('Show fewer notes'), findsOneWidget);

      await t.ensureVisible(find.text('Show fewer notes'));
      await t.pumpAndSettle();
      await t.tap(find.text('Show fewer notes'));
      await t.pumpAndSettle();
      expect(find.text('Note number 1 about the job.'), findsNothing);
      expect(find.text('Show all 5 notes (3 older)'), findsOneWidget);
      expect(t.takeException(), isNull);
    }, () => five());
  });

  testWidgets('Site Visits collapses to the latest three when there are more than three', (t) async {
    t.view.physicalSize = const Size(1500, 1500);
    t.view.devicePixelRatio = 1;

    Map<String, dynamic> jobWithVisits(int n, {bool serviceFusion = true}) {
      final job = _full();
      final sf = job['job']['sf_details'] as Map;
      if (serviceFusion) {
        sf['visits'] = <Map<String, dynamic>>[
          for (var i = 1; i <= n; i++) {'start_date': '2026-09-${i.toString().padLeft(2, '0')}', 'duration': 3600, 'notes_for_techs': 'Notes for visit $i', 'techs': []},
        ];
      } else {
        sf.remove('visits');
      }
      job['visits'] = serviceFusion
          ? []
          : <Map<String, dynamic>>[
              for (var i = 1; i <= n; i++) {'tech_name': 'Tech $i', 'work_date': '2026-09-${i.toString().padLeft(2, '0')}', 'is_verified': true, 'is_callback': false},
            ];
      return job;
    }

    Future<void> open(Map<String, dynamic> job, String key) async {
      await http.runWithClient(() async {
        await t.pumpWidget(RepaintBoundary(
          key: ValueKey(key),
          child: MaterialApp(theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'), home: JobDetailScreen(jobId: '1096183137', key: ValueKey('screen-$key'))),
        ));
        await t.pumpAndSettle();
      }, () => MockClient((req) async {
            final p = req.url.path;
            if (p.endsWith('/notes-tasks')) return http.Response(jsonEncode({'notes': [], 'tasks': []}), 200);
            if (p.endsWith('/files')) return http.Response(jsonEncode({'enabled': true, 'files': []}), 200);
            return http.Response(jsonEncode(job), 200);
          }));
    }

    // Exactly three: nothing to collapse.
    await open(jobWithVisits(3), 'three');
    expect(find.text('Site Visits (3)'), findsOneWidget);
    expect(find.textContaining('Show all'), findsNothing);
    for (var i = 1; i <= 3; i++) {
      expect(find.text('Visit $i'), findsOneWidget);
    }

    // Eight: only the latest three (Visit 6..8, real numbers kept), with a control for the five earlier ones.
    await open(jobWithVisits(8), 'eight');
    expect(find.text('Site Visits (8)'), findsOneWidget);
    expect(find.text('Show all 8 visits (5 earlier)'), findsOneWidget);
    expect(find.text('Visit 5'), findsNothing);
    expect(find.text('Visit 6'), findsOneWidget);
    expect(find.text('Visit 8'), findsOneWidget);
    await expectLater(find.byKey(const ValueKey('eight')), matchesGoldenFile('shots/job_detail_visits_collapsed.png'));
    await t.tap(find.text('Show all 8 visits (5 earlier)'));
    await t.pumpAndSettle();
    for (var i = 1; i <= 8; i++) {
      expect(find.text('Visit $i'), findsOneWidget);
    }
    await t.ensureVisible(find.text('Show fewer visits'));
    await t.pumpAndSettle();
    await t.tap(find.text('Show fewer visits'));
    await t.pumpAndSettle();
    expect(find.text('Visit 1'), findsNothing);
    expect(find.text('Show all 8 visits (5 earlier)'), findsOneWidget);

    // Service Fusion sent no visits: the section says so, however many work days our commission ledger holds (7 here)
    // and whatever the job's own start date is. It must show exactly what Service Fusion shows.
    await open(jobWithVisits(7, serviceFusion: false), 'workdays');
    expect(find.text('Site Visits (0)'), findsOneWidget);
    expect(find.text('No visits scheduled.'), findsOneWidget);
    expect(find.text('Visit 1'), findsNothing);
    expect(find.textContaining('Show'), findsNothing);
    expect(find.text('Tech 1'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('Communications is a tab on the Details card, not Job Info', (t) async {
    t.view.physicalSize = const Size(1500, 900);
    t.view.devicePixelRatio = 1;
    await http.runWithClient(() async {
      await t.pumpWidget(RepaintBoundary(
        key: const ValueKey('shot'),
        child: MaterialApp(theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'), home: const JobDetailScreen(jobId: '1096183137')),
      ));
      await t.pumpAndSettle();
      expect(find.text('Communications'), findsOneWidget);
      // It sits in the same card as Summary / Pics / Docs / Takeoffs.
      final tab = t.getTopLeft(find.text('Communications')).dx;
      expect(tab, lessThan(t.getTopLeft(find.text('Job Info')).dx), reason: 'left column = Details card');
      await t.tap(find.text('Communications'));
      await t.pumpAndSettle();
      expect(find.text('No communications recorded'), findsOneWidget);
      expect(find.text('Primary Contact'), findsNothing); // the Details card swapped to that tab
      expect(find.text('Arrival Time Window'), findsOneWidget); // Job Info is untouched
    }, () => _mock());
  });

  testWidgets('uploads not set up: button is disabled and says why', (t) async {
    t.view.physicalSize = const Size(1500, 900);
    t.view.devicePixelRatio = 1;
    await http.runWithClient(() async {
      await t.pumpWidget(RepaintBoundary(
        key: const ValueKey('shot'),
        child: MaterialApp(theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'), home: const JobDetailScreen(jobId: '1096183137')),
      ));
      await t.pumpAndSettle();
      await t.tap(find.textContaining('Pics'));
      await t.pumpAndSettle();
      expect(find.textContaining('Uploads are not set up yet'), findsOneWidget);
      expect(t.widget<FilledButton>(find.byType(FilledButton).first).onPressed, isNull);
    }, () => _mock(filesStatus: 503));
  });

  testWidgets('full HD window: the page fills the width with little side padding', (t) async {
    await _shot(t, const Size(1920, 1000), 'job_detail_ultrawide', _mock());
  });

  testWidgets('a visit with two techs puts each tech on its own line', (t) async {
    t.view.physicalSize = const Size(1500, 1000);
    t.view.devicePixelRatio = 1;
    await http.runWithClient(() async {
      await t.pumpWidget(RepaintBoundary(
        key: const ValueKey('shot'),
        child: MaterialApp(theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'), home: const JobDetailScreen(jobId: '1096183137')),
      ));
      await t.pumpAndSettle();
      final first = t.getTopLeft(find.text('Daniel Baty'));
      final second = t.getTopLeft(find.text('Marcus Lee'));
      expect(second.dy - first.dy, greaterThan(20), reason: 'the second tech is on the next line, not beside the first');
      expect(second.dx, first.dx, reason: 'and lines up under it');
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/job_detail_visit_techs.png'));
    }, () => _mock());
  });

  testWidgets('narrow window', (t) async {
    await _shot(t, const Size(700, 900), 'job_detail_narrow', _mock());
  });

  testWidgets('sparse job from the calendar (only the row we had)', (t) async {
    final sparse = {
      'job': {'job_id': '1096183137', 'customer_name': 'Moser Construction LLC', 'status': 'Scheduled', 'is_estimate': true},
      'visits': [],
      'payments': [],
      'history': [],
    };
    await _shot(t, const Size(1300, 800), 'job_detail_sparse', MockClient((_) async => http.Response(jsonEncode(sparse), 200)));
  });

  testWidgets('server error with no row to show', (t) async {
    await _shot(t, const Size(1100, 700), 'job_detail_error', MockClient((_) async => http.Response('boom', 500)));
  });
}
