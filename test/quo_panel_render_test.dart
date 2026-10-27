// Renders the Calls & Texts panel (collapsed threads + popup) with fake data. Shots: build/dash_shots/quo_*.png
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iohd_desktop/widgets/dashboard_kit.dart' show DashUi, SkeletonPulse;
import 'package:iohd_desktop/widgets/quo_activity_panel.dart';

import 'dashboard_harness.dart';

Map<String, dynamic> _m(
  String id,
  String dir,
  String body,
  String at,
  String sender, {
  String line = 'L1',
  String lineName = 'Main Office',
  String phone = '4793411151',
}) => {
  'quo_id': id, 'kind': 'message', 'direction': dir, 'body': body, 'occurred_at': at, 'sender': sender,
  'quo_line_id': line, 'line_name': lineName, 'phone_key': phone,
};

/// A fake API that answers the activity request with [body] (plus [extra] handlers first).
DashFakeApi _api(Map<String, dynamic> body, [Future<http.Response?> Function(http.Request)? extra]) {
  final api = DashFakeApi();
  if (extra != null) api.extra.add(extra);
  api.extra.add((req) async => req.url.path.endsWith('/activity') ? http.Response(json.encode(body), 200) : null);
  return api;
}

const _panel = Scaffold(backgroundColor: Colors.white, body: SingleChildScrollView(child: QuoActivityPanel(customerId: '63366142')));

void main() {
  setUpAll(loadDashFonts);
  setUp(QuoActivityPanel.clearCache); // every test reuses the same customer, so no answer may leak into the next one

  testWidgets('a prefetched answer is on screen the moment the tab opens, then refreshed', (tester) async {
    var loads = 0;
    var activity = [_m('m1', 'incoming', 'Hello?', '2026-10-24T13:00:00Z', 'Manny Vera')];
    final api = DashFakeApi()
      ..extra.add((req) async {
        if (req.url.path != '/api/quo/jobs/7/activity') return null;
        loads++;
        return http.Response(json.encode({'phone': '(479) 341-1151', 'hasPhone': true, 'activity': activity}), 200);
      });
    final open = ValueNotifier(false); // the Communications tab
    await pumpDashboard(
      tester,
      ValueListenableBuilder<bool>(
        valueListenable: open,
        builder: (_, on, _) => on ? const SingleChildScrollView(child: QuoActivityPanel(jobId: '7')) : const SizedBox(),
      ),
      api: api,
      size: const Size(1100, 600),
      body: () async {
        await QuoActivityPanel.prefetch(jobId: '7'); // the job page does this as it loads
        expect(loads, 1);
        activity = [_m('m2', 'incoming', 'Are you coming today?', '2026-10-24T13:05:00Z', 'Manny Vera'), ...activity];
        open.value = true;
        await tester.pump(); // one frame: no waiting on the server
        expect(find.textContaining('Hello?'), findsOneWidget);
        expect(find.byType(SkeletonPulse), findsNothing);
        await settleDashboard(tester, frames: 3);
        expect(loads, 2, reason: 'the copy is refreshed in the background');
        expect(find.textContaining('Are you coming today?'), findsOneWidget);
      },
    );
  });

  testWidgets('a tab opened while its prefetch is still loading waits for that answer instead of asking again', (tester) async {
    var loads = 0;
    final answer = Completer<http.Response>();
    final api = DashFakeApi()
      ..extra.add((req) async {
        if (req.url.path != '/api/quo/jobs/7/activity') return null;
        loads++;
        return answer.future;
      });
    final open = ValueNotifier(false);
    await pumpDashboard(
      tester,
      ValueListenableBuilder<bool>(
        valueListenable: open,
        builder: (_, on, _) => on ? const SingleChildScrollView(child: QuoActivityPanel(jobId: '7')) : const SizedBox(),
      ),
      api: api,
      size: const Size(1100, 600),
      body: () async {
        unawaited(QuoActivityPanel.prefetch(jobId: '7'));
        await tester.pump();
        open.value = true;
        await tester.pump();
        expect(find.byType(SkeletonPulse), findsOneWidget);
        answer.complete(http.Response(
          json.encode({'phone': '(479) 341-1151', 'hasPhone': true, 'activity': [_m('m1', 'incoming', 'Hello?', '2026-10-24T13:00:00Z', 'Manny Vera')]}),
          200,
        ));
        await settleDashboard(tester, frames: 3);
        expect(find.textContaining('Hello?'), findsOneWidget);
        expect(loads, 1);
      },
    );
  });

  testWidgets('threads start collapsed and open in a popup with senders', (tester) async {
    final activity = [
      {..._m('c1', 'incoming', '', '2026-10-23T15:23:00Z', 'Manny Vera'), 'kind': 'call', 'duration_sec': 0},
      _m('m3', 'outgoing', 'We can be there Thursday morning.', '2026-10-22T14:00:00Z', 'Heather Vera'),
      _m('m2', 'incoming', 'Can someone come look at the spring?', '2026-10-22T13:40:00Z', 'Manny Vera'),
      _m('m1', 'outgoing', 'Thanks for calling Integrity Overhead Doors.', '2026-10-22T13:30:00Z', 'Bella'),
      _m('s1', 'incoming', 'Is the quote ready?', '2026-08-01T13:30:00Z', 'Manny Vera', line: 'L2', lineName: 'Sales Line'),
    ];
    final errors = await pumpDashboard(
      tester,
      _panel,
      api: _api({'phone': '(479) 341-1151', 'hasPhone': true, 'activity': activity}),
      size: const Size(1100, 600),
      body: () async {
        expect(find.textContaining('Main Office'), findsOneWidget);
        expect(find.textContaining('Sales Line'), findsOneWidget);
        expect(find.textContaining('(479) 341-1151'), findsNothing); // one number only: rows don't repeat it
        expect(find.text('Thanks for calling Integrity Overhead Doors.'), findsNothing); // collapsed
        await saveDashShot(tester, 'quo_threads');
        await tester.tap(find.textContaining('Main Office'));
        await settleDashboard(tester, frames: 5);
        expect(find.text('Thanks for calling Integrity Overhead Doors.'), findsOneWidget);
        expect(find.text('Heather Vera'), findsOneWidget);
        expect(find.text('(479) 341-1151'), findsOneWidget); // the popup names the number it is with
        await saveDashShot(tester, 'quo_popup');
      },
    );
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('job mode labels each message with its job and lets you move it', (tester) async {
    final activity = [
      {..._m('m2', 'incoming', 'Can someone come look at the spring?', '2026-10-22T13:40:00Z', 'Manny Vera'), 'job_id': '1097733351', 'job_is_manual': true},
      {..._m('m1', 'outgoing', 'We can be there Thursday.', '2026-10-22T14:00:00Z', 'Heather Vera'), 'job_id': '1097733351', 'job_is_manual': true},
    ];
    Map<String, dynamic>? moved;
    final api = DashFakeApi()
      ..extra.add((req) async {
        if (req.url.path == '/api/quo/jobs/1097733351/activity') {
          return http.Response(
            json.encode({
              'phone': '(479) 341-1151', 'hasPhone': true, 'customerId': 63366142,
              'jobs': [
                {'job_id': '1097733351', 'status': 'Active', 'is_estimate': false, 'start_date': '2026-10-20', 'location': '12 Main St'},
                {'job_id': '1090000001', 'status': 'Won', 'is_estimate': true, 'start_date': '2026-09-01', 'location': '9 Oak Ave'},
              ],
              'activity': activity,
            }),
            200,
          );
        }
        if (req.url.path == '/api/quo/links' && req.method == 'PUT') {
          moved = json.decode(req.body) as Map<String, dynamic>;
          return http.Response('{"ok":true}', 200);
        }
        return null;
      });
    final errors = await pumpDashboard(
      tester,
      const Scaffold(backgroundColor: Colors.white, body: SingleChildScrollView(child: QuoActivityPanel(jobId: '1097733351'))),
      api: api,
      size: const Size(1100, 700),
      body: () async {
        await tester.tap(find.textContaining('Main Office'));
        await settleDashboard(tester, frames: 5);
        // Every link is one someone chose, so there is no "(auto)" tag and no way "back to automatic".
        expect(find.text('Job 1097733351'), findsNWidgets(2));
        expect(find.textContaining('(auto)'), findsNothing);
        await saveDashShot(tester, 'quo_job_popup');
        await tester.tap(find.text('Job 1097733351').first);
        await settleDashboard(tester, frames: 5);
        expect(find.text('Which job is this about?'), findsOneWidget);
        expect(find.textContaining('Estimate 1090000001'), findsOneWidget);
        expect(find.text('Back to automatic'), findsNothing);
        await saveDashShot(tester, 'quo_job_picker');
        await tester.tap(find.textContaining('Estimate 1090000001'));
        await settleDashboard(tester, frames: 5);
        expect(moved, {'quoIds': ['m1'], 'jobId': '1090000001'});
        // "No job" removes the link.
        await tester.tap(find.text('Job 1097733351').first);
        await settleDashboard(tester, frames: 5);
        await tester.tap(find.text('No job'));
        await settleDashboard(tester, frames: 5);
        expect(moved, {'quoIds': ['m1'], 'jobId': 'auto'});
      },
    );
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('job mode still shows linked calls when the customer has no phone on file', (tester) async {
    final api = DashFakeApi()
      ..extra.add((req) async {
        if (req.url.path == '/api/quo/jobs/1097733351/activity') {
          return http.Response(
            json.encode({
              'phone': null, 'hasPhone': false, 'customerId': 63366142, 'jobs': const [],
              'activity': [
                {..._m('m1', 'incoming', 'Gate code is 4410.', '2026-10-22T13:40:00Z', 'Manny Vera'), 'job_id': '1097733351', 'job_is_manual': true},
              ],
            }),
            200,
          );
        }
        return null;
      });
    final errors = await pumpDashboard(
      tester,
      const Scaffold(backgroundColor: Colors.white, body: SingleChildScrollView(child: QuoActivityPanel(jobId: '1097733351'))),
      api: api,
      size: const Size(1100, 700),
      body: () async {
        expect(find.textContaining('no phone number on file'), findsNothing);
        expect(find.textContaining('Main Office'), findsOneWidget);
      },
    );
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('a call shows its summary and next steps; the transcript loads only when opened', (tester) async {
    final activity = [
      {..._m('AC1', 'incoming', '', '2026-10-23T15:23:00Z', 'Manny Vera'), 'kind': 'call', 'duration_sec': 125, 'has_transcript': true,
        'ai_summary': {'summary': ['Customer asked about a broken spring.'], 'nextSteps': ['Send an estimate']}},
      {..._m('AC2', 'outgoing', '', '2026-10-22T15:00:00Z', 'Heather Vera'), 'kind': 'call', 'duration_sec': 40}, // nothing yet
    ];
    final asked = <String>[];
    var transcriptRequests = 0;
    final errors = await pumpDashboard(
      tester,
      _panel,
      api: _api({'phone': '(479) 341-1151', 'hasPhone': true, 'activity': activity}, (req) async {
        if (req.method == 'POST' && req.url.path.endsWith('/details')) {
          asked.add(req.url.path);
          return http.Response('{"ok":true,"changed":false}', 200);
        }
        if (req.url.path == '/api/quo/calls/AC1/transcript') {
          transcriptRequests++;
          return http.Response(json.encode({'lines': [
            {'speaker': 'Manny Vera', 'content': 'My spring snapped last night.'},
            {'speaker': 'Heather Vera', 'content': 'We can come Thursday.'},
          ]}), 200);
        }
        return null;
      }),
      size: const Size(1100, 760),
      body: () async {
        await tester.tap(find.textContaining('Main Office'));
        await settleDashboard(tester, frames: 8);
        expect(asked, ['/api/quo/calls/AC2/details']); // only the call that has neither summary nor transcript
        expect(find.text('Customer asked about a broken spring.'), findsOneWidget);
        expect(find.textContaining('Send an estimate'), findsOneWidget);
        expect(transcriptRequests, 0, reason: 'transcripts are not loaded until someone opens one');
        await tester.tap(find.text('Show transcript'));
        await settleDashboard(tester, frames: 3);
        expect(transcriptRequests, 1);
        expect(find.textContaining('My spring snapped last night.', findRichText: true), findsOneWidget);
        expect(find.text('Summary'), findsOneWidget);
        expect(find.text('Transcript'), findsOneWidget);
        await saveDashShot(tester, 'quo_call_details');
        await tester.tap(find.text('Hide transcript'));
        await settleDashboard(tester, frames: 2);
        await tester.tap(find.text('Show transcript'));
        await settleDashboard(tester, frames: 2);
        expect(transcriptRequests, 1, reason: 'opened again: already loaded');
      },
    );
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('two numbers are two conversations, and a reply goes to the number it answers', (tester) async {
    final activity = [
      {..._m('a2', 'incoming', 'This is my cell, text me here', '2026-10-24T13:00:00Z', 'Manny Vera', phone: '4795550123'), 'job_id': '7'},
      {..._m('a1', 'incoming', 'Office line here', '2026-10-20T13:00:00Z', 'Manny Vera'), 'job_id': '7'},
    ];
    Map<String, dynamic>? sent;
    final errors = await pumpDashboard(
      tester,
      const Scaffold(backgroundColor: Colors.white, body: SingleChildScrollView(child: QuoActivityPanel(jobId: '7'))),
      api: _api({'phone': '(479) 341-1151', 'hasPhone': true, 'customerId': 1, 'jobs': [], 'activity': activity}, (req) async {
        if (req.url.path == '/api/quo/send') {
          sent = json.decode(req.body) as Map<String, dynamic>;
          return http.Response('{"ok":true,"id":"ACnew"}', 200);
        }
        return null;
      }),
      size: const Size(1100, 700),
      body: () async {
        expect(find.textContaining('(479) 555-0123'), findsOneWidget);
        expect(find.textContaining('(479) 341-1151'), findsOneWidget);
        await saveDashShot(tester, 'quo_two_numbers');
        await tester.tap(find.textContaining('(479) 555-0123'));
        await settleDashboard(tester, frames: 5);
        expect(find.text('Office line here'), findsNothing, reason: 'the other number is a different conversation');
        await tester.enterText(find.byType(TextField), 'On our way');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await settleDashboard(tester, frames: 5);
        expect(sent, {'to': '4795550123', 'text': 'On our way', 'from': 'L1', 'jobId': '7'});
      },
    );
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('pictures, empty texts and unanswered calls read sensibly; long history says it is cut off', (tester) async {
    final activity = [
      {..._m('p1', 'incoming', '', '2026-10-24T13:00:00Z', 'Manny Vera'), 'media': [{'url': 'https://example.com/door.jpg', 'type': 'image/jpeg'}]},
      _m('e1', 'incoming', '', '2026-10-23T13:00:00Z', 'Manny Vera'),
      {..._m('c1', 'outgoing', '', '2026-10-22T13:00:00Z', 'Heather Vera'), 'kind': 'call', 'duration_sec': 0},
      // Rang out to voicemail: Quo gives it a duration and "completed", but nobody answered.
      {..._m('c2', 'incoming', '', '2026-10-21T13:00:00Z', 'Manny Vera'), 'kind': 'call', 'duration_sec': 31, 'status': 'completed', 'answered': false},
      {..._m('c3', 'incoming', '', '2026-10-20T13:00:00Z', 'Manny Vera'), 'kind': 'call', 'duration_sec': 95, 'status': 'completed', 'answered': true},
    ];
    final errors = await pumpDashboard(
      tester,
      _panel,
      api: _api({'phone': '(479) 341-1151', 'hasPhone': true, 'truncated': true, 'activity': activity}),
      size: const Size(1100, 700),
      body: () async {
        expect(find.textContaining('Manny Vera: Picture'), findsOneWidget); // the row preview
        expect(find.textContaining('Showing the latest 5 calls and texts'), findsOneWidget);
        await tester.tap(find.textContaining('Main Office'));
        await settleDashboard(tester, frames: 5);
        expect(find.text('Open picture'), findsOneWidget);
        expect(find.text('(no text)'), findsOneWidget);
        expect(find.text('Outgoing call · no answer'), findsOneWidget);
        expect(find.text('Missed call'), findsOneWidget);
        expect(find.text('Incoming call · 1m 35s'), findsOneWidget);
        expect(find.byIcon(Icons.phone_missed_rounded), findsNWidgets(2));
        await saveDashShot(tester, 'quo_media');
      },
    );
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('a missed call nobody has answered shows as a red icon on the row, before the conversation is opened', (tester) async {
    Map<String, dynamic> call(String id, String dir, String at, {required bool answered, String phone = '4793411151', String lineName = 'Main Office'}) => {
      ..._m(id, dir, '', at, 'Manny Vera', phone: phone, lineName: lineName),
      'kind': 'call',
      'duration_sec': answered ? 60 : 0,
      'answered': answered,
    };
    final activity = [
      // Newest first, like the server. The Main Office number has a missed call and no reply since.
      call('a1', 'incoming', '2026-10-25T13:00:00Z', answered: false),
      _m('a0', 'incoming', 'Hello?', '2026-10-24T13:00:00Z', 'Manny Vera'),
      // The Shop number missed a call too, but we called back.
      call('b2', 'outgoing', '2026-10-23T13:00:00Z', answered: true, phone: '4795550123', lineName: 'Shop'),
      call('b1', 'incoming', '2026-10-23T12:00:00Z', answered: false, phone: '4795550123', lineName: 'Shop'),
    ];
    final errors = await pumpDashboard(
      tester,
      _panel,
      api: _api({'phone': '(479) 341-1151', 'hasPhone': true, 'activity': activity}),
      size: const Size(1100, 700),
      body: () async {
        expect(find.byIcon(Icons.phone_missed_rounded), findsOneWidget, reason: 'only the thread nobody called back');
        expect(find.textContaining('1 missed'), findsOneWidget);
        final dot = tester.widget<Container>(find.ancestor(of: find.byIcon(Icons.phone_missed_rounded), matching: find.byType(Container)).first);
        expect((dot.decoration as BoxDecoration).color, DashUi.red);
        await saveDashShot(tester, 'quo_missed_row');
      },
    );
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('an open conversation refreshes itself, and stops when it is closed', (tester) async {
    var loads = 0;
    var activity = [_m('m1', 'incoming', 'Hello?', '2026-10-24T13:00:00Z', 'Manny Vera')];
    final api = DashFakeApi()
      ..extra.add((req) async {
        if (!req.url.path.endsWith('/activity')) return null;
        loads++;
        return http.Response(json.encode({'phone': '(479) 341-1151', 'hasPhone': true, 'activity': activity}), 200);
      });
    await pumpDashboard(tester, _panel, api: api, size: const Size(1100, 700), body: () async {
      await tester.tap(find.textContaining('Main Office'));
      await settleDashboard(tester, frames: 5);
      final before = loads;
      activity = [_m('m2', 'incoming', 'Are you coming today?', '2026-10-24T13:05:00Z', 'Manny Vera'), ...activity];
      await tester.pump(const Duration(seconds: 16));
      await settleDashboard(tester, frames: 3);
      expect(loads, before + 1);
      expect(find.text('Are you coming today?'), findsOneWidget, reason: 'the new text shows without reopening');
      await tester.tap(find.byTooltip('Close'));
      await settleDashboard(tester, frames: 5);
      final closed = loads;
      await tester.pump(const Duration(seconds: 40));
      expect(loads, closed, reason: 'no polling once the conversation is closed');
    });
  });
}
