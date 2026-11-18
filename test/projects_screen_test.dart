// Behaviour of the Project Tracker (lib/projects_screen.dart + parts): the band's counts and filters, search, sorting,
// moving a project along the workflow (with Undo, failure and a collision with someone else's save), the editor (saving,
// collisions, unsaved changes, links without https), deleting, permissions, keyboard, narrow windows and plain-word
// errors. Runs against the fake /api/projects in projects_fixture.dart.
//   flutter test test/projects_screen_test.dart

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iohd_desktop/config/auth_session.dart';
import 'package:iohd_desktop/projects_screen.dart';

import 'dashboard_harness.dart' show loadDashFonts;
import 'projects_fixture.dart';

const _wide = Size(1500, 900);

Future<void> _settle(WidgetTester t, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Shows the screen against [server] at [size] and runs [body] inside the same fake-API zone.
Future<void> _run(WidgetTester t, FakeProjectsServer server, Future<void> Function() body, {Size size = _wide}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  addTearDown(t.view.reset);
  await http.runWithClient(() async {
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: const ProjectsScreen(),
      ),
    );
    await _settle(t);
    await body();
  }, server.client);
}

/// The title in the detail pane (or detail dialog).
String? _paneTitle(WidgetTester t) {
  final f = find.byWidgetPredicate((w) => w is Text && w.style?.fontSize == 19);
  // The pane cross-fades: while it does, the outgoing title comes first and the incoming one last.
  return f.evaluate().isEmpty ? null : (f.evaluate().last.widget as Text).data;
}

Map<String, dynamic> _bodyOf(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;

Iterable<http.Request> _puts(FakeProjectsServer s) => s.requests.where((r) => r.method == 'PUT');

Map<String, dynamic> _onServer(FakeProjectsServer s, String name) => s.projects.firstWhere((p) => p['name'] == name);

/// A band segment's label (status group headers use the same capitals further down).
Finder _band(String label) => find.text(label.toUpperCase()).first;

void main() {
  setUpAll(loadDashFonts);
  setUp(() => projectsSignIn(admin: true));
  tearDown(() => AuthSession.instance.logout());

  testWidgets('every band count is what clicking it shows', (t) async {
    final server = FakeProjectsServer(manyProjects());
    await _run(t, server, () async {
      final semantics = t.ensureSemantics();
      const expected = {
        'Open': 26,
        'Planning': 17,
        'In progress': 7,
        'In review': 2,
        'On hold': 0,
        'Complete': 35,
        'All': 61,
        'Overdue': 3,
        'Due soon': 1,
        'No owner': 1,
      };
      for (final e in expected.entries) {
        expect(find.bySemanticsLabel(RegExp('^${e.key}, ${e.value}(,|\$)')), findsOneWidget, reason: e.key);
        await t.tap(_band(e.key));
        await _settle(t, 4);
        expect(find.text('${e.value} of 61 projects'), findsOneWidget, reason: 'list under ${e.key}');
      }
      semantics.dispose();
    });
  });

  testWidgets('search covers notes and file names, needs every word, and the band counts follow it', (t) async {
    final server = FakeProjectsServer(manyProjects());
    await _run(t, server, () async {
      final semantics = t.ensureSemantics();
      final search = find.byType(TextField).first;

      await t.enterText(search, 'springs'); // only in Warehouse Reorganization's notes
      await _settle(t, 5);
      expect(find.text('1 of 61 projects'), findsOneWidget);
      expect(find.text('Warehouse Reorganization'), findsWidgets);
      expect(find.bySemanticsLabel(RegExp(r'^Open, 1(,|$)')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^All, 1(,|$)')), findsOneWidget);

      await t.enterText(search, 'template draft'); // a file name on Sales Process Changes
      await _settle(t, 5);
      expect(find.text('1 of 61 projects'), findsOneWidget);
      expect(_paneTitle(t), 'Sales Process Changes', reason: 'the pane follows the list');

      await t.enterText(search, 'zac warehouse'); // support person + name: both words must match
      await _settle(t, 5);
      expect(find.text('1 of 61 projects'), findsOneWidget);

      await t.enterText(search, 'forklift');
      await _settle(t, 5);
      expect(find.text('No projects match'), findsOneWidget);
      expect(find.text('No project selected'), findsOneWidget);
      await t.tap(find.text('Clear search and filters'));
      await _settle(t, 5);
      expect(find.text('26 of 61 projects'), findsOneWidget);
      semantics.dispose();
    });
  });

  testWidgets('equal projects keep one order whatever order the server sends them in', (t) async {
    List<Map<String, dynamic>> board() => [
      for (final n in ['Delta', 'Alpha', 'Echo', 'Charlie', 'Bravo']) fakeProject(n.codeUnitAt(0), n, owner: 'Zac Clemens', priority: 'Medium'),
    ];
    Future<List<String>> order(List<Map<String, dynamic>> seed) async {
      late List<String> names;
      await _run(t, FakeProjectsServer(seed), () async {
        final ys = {
          for (final n in ['Alpha', 'Bravo', 'Charlie', 'Delta', 'Echo']) n: t.getTopLeft(find.text(n).first).dy,
        };
        names = ys.keys.toList()..sort((a, b) => ys[a]!.compareTo(ys[b]!));
      });
      return names;
    }

    final first = await order(board());
    final second = await order(board().reversed.toList());
    expect(first, ['Alpha', 'Bravo', 'Charlie', 'Delta', 'Echo']);
    expect(second, first);
  });

  testWidgets('moving a project on the workflow track saves the whole project, guarded, and Undo moves it back', (t) async {
    final server = FakeProjectsServer(manyProjects());
    final before = Map<String, dynamic>.of(_onServer(server, 'Warehouse Reorganization'));
    await _run(t, server, () async {
      await t.tap(find.text('Warehouse Reorganization'));
      await _settle(t, 5);
      expect(_paneTitle(t), 'Warehouse Reorganization');

      await t.tap(find.byTooltip('Move to In Review'));
      await _settle(t, 4);
      final put = _puts(server).single;
      expect(put.url.path, '/api/projects/${before['id']}');
      final body = _bodyOf(put);
      expect(body['status'], 'In Review');
      expect(body['ifUnchangedSince'], before['updatedAt']);
      for (final k in ['name', 'owner', 'support', 'requestedBy', 'priority', 'deadline', 'notes', 'files']) {
        expect(body[k], before[k], reason: '$k is sent unchanged');
      }
      expect(_onServer(server, 'Warehouse Reorganization')['status'], 'In Review');
      expect(find.textContaining('moved to In Review'), findsOneWidget);

      await t.tap(find.text('Undo'));
      await _settle(t, 4);
      expect(_puts(server).length, 2);
      expect(_bodyOf(_puts(server).last)['status'], 'In Progress');
      expect(_onServer(server, 'Warehouse Reorganization')['status'], 'In Progress');
      expect(find.text('Moved back to In Progress.'), findsOneWidget);
    });
  });

  testWidgets('a failed status change puts the old status back and says why', (t) async {
    final server = FakeProjectsServer(manyProjects());
    await _run(t, server, () async {
      await t.tap(find.text('Warehouse Reorganization'));
      await _settle(t, 5);
      server.failWith = 500;
      await t.tap(find.byTooltip('Move to Complete'));
      await _settle(t, 4);
      expect(find.text("Couldn't change the status: Could not complete that. Try again."), findsOneWidget);
      expect(find.byTooltip('Move to Complete'), findsOneWidget, reason: 'Complete is still a step to move to, so not current');
      expect(_onServer(server, 'Warehouse Reorganization')['status'], 'In Progress');
    });
  });

  testWidgets("a status change made from an old copy doesn't overwrite someone else's save", (t) async {
    final server = FakeProjectsServer(manyProjects());
    await _run(t, server, () async {
      await t.tap(find.text('Warehouse Reorganization'));
      await _settle(t, 5);
      final id = _onServer(server, 'Warehouse Reorganization')['id'] as int;
      editElsewhere(server, id, {'notes': 'Bella added this a minute ago.'});

      final gets = server.requests.where((r) => r.method == 'GET').length;
      await t.tap(find.byTooltip('Move to In Review'));
      await _settle(t, 6);
      expect(find.textContaining('Someone else changed this project just now'), findsOneWidget);
      expect(_onServer(server, 'Warehouse Reorganization')['notes'], 'Bella added this a minute ago.', reason: 'their notes survive');
      expect(_onServer(server, 'Warehouse Reorganization')['status'], 'In Progress');
      expect(server.requests.where((r) => r.method == 'GET').length, greaterThan(gets), reason: 'their version is fetched');
      expect(find.text('Bella added this a minute ago.'), findsOneWidget, reason: 'and shown in the pane');
    });
  });

  testWidgets('the editor shows the saved project at once, and a collision offers Save anyway', (t) async {
    final server = FakeProjectsServer(manyProjects());
    await _run(t, server, () async {
      await t.tap(find.text('Fleet GPS and Fuel Card Rollout'));
      await _settle(t, 5);
      await t.tap(find.widgetWithText(OutlinedButton, 'Edit'));
      await _settle(t, 4);
      expect(find.text('Edit project'), findsOneWidget);

      await t.enterText(find.widgetWithText(TextField, 'Fleet GPS and Fuel Card Rollout'), 'Fleet GPS Rollout');
      await t.tap(find.text('Save changes'));
      await _settle(t, 4);
      expect(find.text('Edit project'), findsNothing);
      expect(find.text('Project saved.'), findsOneWidget);
      expect(find.text('Fleet GPS Rollout'), findsWidgets, reason: 'shown without waiting for a reload');
      expect(_bodyOf(_puts(server).last)['ifUnchangedSince'], isNotNull);

      // Now someone else saves it while it is open here.
      await t.tap(find.widgetWithText(OutlinedButton, 'Edit'));
      await _settle(t, 4);
      editElsewhere(server, _onServer(server, 'Fleet GPS Rollout')['id'] as int, {'priority': 'Urgent'});
      await t.enterText(find.widgetWithText(TextField, 'Fleet GPS Rollout'), 'Fleet GPS Rollout, phase 2');
      await t.tap(find.text('Save changes'));
      await _settle(t, 4);
      expect(find.textContaining('Someone else saved this project after you opened it'), findsOneWidget);
      expect(find.text('Save anyway'), findsOneWidget);
      expect(_onServer(server, 'Fleet GPS Rollout')['priority'], 'Urgent', reason: 'nothing overwritten yet');

      await t.tap(find.text('Save anyway'));
      await _settle(t, 4);
      expect(_bodyOf(_puts(server).last).containsKey('ifUnchangedSince'), isFalse);
      expect(server.projects.any((p) => p['name'] == 'Fleet GPS Rollout, phase 2'), isTrue);
      expect(find.text('Edit project'), findsNothing);
    });
  });

  testWidgets('closing the editor with unsaved changes asks first, and saves nothing', (t) async {
    final server = FakeProjectsServer(manyProjects());
    await _run(t, server, () async {
      await t.tap(find.text('New project'));
      await _settle(t, 4);
      // Nothing typed yet: Cancel just closes.
      await t.tap(find.text('Cancel'));
      await _settle(t, 4);
      expect(find.text('New project'), findsOneWidget, reason: 'only the ribbon button is left');

      await t.tap(find.text('New project'));
      await _settle(t, 4);
      await t.enterText(find.byType(TextField).last, 'Half-typed thought');
      await t.tap(find.text('Cancel'));
      await _settle(t, 4);
      expect(find.text('Discard your changes?'), findsOneWidget);
      await t.tap(find.text('Keep editing'));
      await _settle(t, 4);
      expect(find.text('Add project'), findsOneWidget, reason: 'still editing');

      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(t, 4);
      expect(find.text('Discard your changes?'), findsOneWidget, reason: 'Escape asks too');
      await t.tap(find.text('Discard'));
      await _settle(t, 4);
      expect(find.text('Add project'), findsNothing);
      expect(server.writes, isEmpty);
    });
  });

  testWidgets('a new project needs a name, then appears selected', (t) async {
    final server = FakeProjectsServer(manyProjects());
    await _run(t, server, () async {
      await t.tap(find.text('New project'));
      await _settle(t, 4);
      await t.tap(find.text('Add project'));
      await _settle(t, 2);
      expect(find.text('A project needs a name.'), findsOneWidget);
      expect(server.writes, isEmpty);

      await t.enterText(find.widgetWithText(TextField, 'What is the project?'), 'Paint the showroom');
      await t.tap(find.text('Add project'));
      await _settle(t, 6);
      expect(find.text('Project added.'), findsOneWidget);
      final post = server.requests.where((r) => r.method == 'POST').single;
      expect(_bodyOf(post)['status'], 'Planning');
      expect(_paneTitle(t), 'Paint the showroom');
    });
  });

  testWidgets('a pasted link without https gets it on save', (t) async {
    final server = FakeProjectsServer(manyProjects());
    await _run(t, server, () async {
      await t.tap(find.text('Fleet GPS and Fuel Card Rollout'));
      await _settle(t, 5);
      await t.tap(find.widgetWithText(OutlinedButton, 'Edit'));
      await _settle(t, 4);
      await t.tap(find.text('Add file'));
      await t.pump();
      await t.enterText(find.widgetWithText(TextField, 'File name').last, 'Map');
      await t.enterText(find.widgetWithText(TextField, 'Paste a Drive or web link').last, ' drive.google.com/file/d/abc ');
      await t.tap(find.text('Save changes'));
      await _settle(t, 4);
      expect((_bodyOf(_puts(server).last)['files'] as List).last, {'name': 'Map', 'url': 'https://drive.google.com/file/d/abc'});
    });
  });

  testWidgets('deleting asks first, removes the project and moves the pane to the next one', (t) async {
    final server = FakeProjectsServer(manyProjects());
    await _run(t, server, () async {
      await t.tap(find.text('Warehouse Reorganization'));
      await _settle(t, 5);
      await t.tap(find.byTooltip('More actions'));
      await _settle(t, 5);
      await t.tap(find.text('Delete project'));
      await _settle(t, 5);
      expect(find.text('Delete this project?'), findsOneWidget);
      await t.tap(find.widgetWithText(FilledButton, 'Delete project'));
      await _settle(t, 4);
      expect(server.requests.where((r) => r.method == 'DELETE').single.url.path, endsWith('/${manyProjects().first['id']}'));
      expect(find.text('Project deleted.'), findsOneWidget);
      expect(find.text('Warehouse Reorganization'), findsNothing);
      expect(_paneTitle(t), isNot('Warehouse Reorganization'));
      expect(_paneTitle(t), isNotNull);
      expect(find.text('25 of 60 projects'), findsOneWidget);
    });
  });

  testWidgets('view-only people can read everything but change nothing', (t) async {
    await projectsSignIn(denied: kProjectsViewOnly);
    final server = FakeProjectsServer(manyProjects());
    await _run(t, server, () async {
      expect(find.text('New project'), findsNothing);
      await t.tap(find.text('Warehouse Reorganization'));
      await _settle(t, 5);
      expect(_paneTitle(t), 'Warehouse Reorganization');
      expect(find.text('Racking on the north wall is in. Still to do:'), findsOneWidget, reason: 'notes are readable');
      expect(find.widgetWithText(OutlinedButton, 'Edit'), findsNothing);
      expect(find.byTooltip('More actions'), findsNothing);
      expect(find.byTooltip('Move to In Review'), findsNothing, reason: 'the track is not a button');
      expect(find.text('Put on hold'), findsNothing);
      expect(find.text('Add notes'), findsNothing);

      await t.tap(find.text('Warehouse Reorganization').first, buttons: kSecondaryButton); // the row, not the pane
      await _settle(t, 5);
      expect(find.text('You can view projects but not change them.'), findsOneWidget);
      expect(find.text('Edit project'), findsNothing);
      expect(find.text('Delete project'), findsNothing);
      await t.tapAt(const Offset(5, 5));
      await _settle(t, 5);

      // Enter and Delete do nothing for them either.
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.sendKeyEvent(LogicalKeyboardKey.delete);
      await _settle(t, 5);
      expect(find.text('Edit project'), findsNothing);
      expect(find.text('Delete this project?'), findsNothing);
      expect(server.writes, isEmpty);
    });
  });

  testWidgets('without the Delete switch there is no delete anywhere', (t) async {
    await projectsSignIn(denied: const ['projects.delete']);
    final server = FakeProjectsServer(manyProjects());
    await _run(t, server, () async {
      await t.tap(find.text('Warehouse Reorganization'));
      await _settle(t, 5);
      expect(find.byTooltip('More actions'), findsNothing);
      await t.tap(find.widgetWithText(OutlinedButton, 'Edit'));
      await _settle(t, 4);
      expect(find.text('Edit project'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Delete'), findsNothing);
    });
  });

  testWidgets('arrow keys move through the list and Enter opens the editor', (t) async {
    final server = FakeProjectsServer(manyProjects());
    await _run(t, server, () async {
      // Grouped by status, In Progress first, most urgent first.
      expect(_paneTitle(t), 'Commercial Service Agreements');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _settle(t, 5);
      expect(_paneTitle(t), isNot('Commercial Service Agreements'));
      final second = _paneTitle(t);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await _settle(t, 5);
      expect(_paneTitle(t), 'Commercial Service Agreements');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _settle(t, 5);
      expect(_paneTitle(t), second);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(t, 4);
      expect(find.text('Edit project'), findsOneWidget);
    });
  });

  testWidgets('grouped by owner: the busiest person first, unowned projects last, finished work below open work', (t) async {
    final server = FakeProjectsServer(manyProjects());
    await _run(t, server, () async {
      await t.tap(find.text('Owner').first);
      await t.tap(_band('All'));
      await _settle(t, 4);
      final john = t.getTopLeft(find.text('John Eccleston').first).dy;
      final ryan = t.getTopLeft(find.text('Ryan Schwartz').first).dy;
      expect(john, lessThan(ryan), reason: 'John has the most open projects in the fixture');
      // John's first row is open work, not one of his finished projects.
      final firstOpen = t.getTopLeft(find.text("KPI's, Reporting & Dashboards")).dy;
      final finished = find.textContaining('Finished project');
      if (finished.evaluate().isNotEmpty) expect(firstOpen, lessThan(t.getTopLeft(finished.first).dy));
    }, size: const Size(1500, 2400));
  });

  testWidgets('a narrow window shows details in a dialog that follows changes', (t) async {
    final server = FakeProjectsServer(manyProjects());
    await _run(t, server, () async {
      await t.tap(find.text('Warehouse Reorganization'));
      await _settle(t, 4);
      expect(find.byType(Dialog), findsOneWidget);
      expect(_paneTitle(t), 'Warehouse Reorganization');
      await t.tap(find.byTooltip('Move to In Review'));
      await _settle(t, 4);
      expect(find.descendant(of: find.byType(Dialog), matching: find.text('In Review')), findsWidgets);
      expect(find.descendant(of: find.byType(Dialog), matching: find.byTooltip('Move to In Progress')), findsOneWidget);
    }, size: const Size(1024, 760));
  });

  testWidgets('a failed refresh keeps the list and says it may be out of date', (t) async {
    final server = FakeProjectsServer(manyProjects());
    await _run(t, server, () async {
      server.failGetWith = 502;
      server.failMessage = 'The project sheet could not be reached.';
      await t.tap(find.byTooltip('Refresh'));
      await _settle(t, 4);
      expect(find.text("Couldn't refresh projects: The project sheet could not be reached."), findsOneWidget);
      expect(find.text('Warehouse Reorganization'), findsWidgets);

      server.failGetWith = null;
      await t.tap(find.text('Try again'));
      await _settle(t, 4);
      expect(find.textContaining("Couldn't refresh projects"), findsNothing);
    });
  });

  testWidgets('network trouble reads as plain words, never exception text', (t) async {
    final server = FakeProjectsServer(manyProjects())..throwError = http.ClientException('Connection refused');
    await _run(t, server, () async {
      expect(find.text("Couldn't load projects"), findsOneWidget);
      expect(find.textContaining("Couldn't reach the server"), findsOneWidget);
      expect(find.textContaining('ClientException'), findsNothing);
    });
  });

  testWidgets('a server that never answers times out with plain words', (t) async {
    final slow = FakeProjectsServer(manyProjects())..hang = true;
    await _run(t, slow, () async {
      await t.pump(const Duration(seconds: 31)); // past the app's 30 s timeout
      await _settle(t, 3);
      expect(find.textContaining('The server took too long to answer'), findsOneWidget);
      expect(find.textContaining('TimeoutException'), findsNothing);
    });
  });

  testWidgets('projects with missing details still read cleanly', (t) async {
    final server = FakeProjectsServer([
      fakeProject(1, '', owner: '', priority: '', status: 'Planning'),
      {
        'id': 2,
        'name': 'Fixed date',
        'owner': 'Zac Clemens',
        'status': 'Planning',
        'priority': 'Low',
        'deadline': '2030-01-01',
        'files': [
          {'name': 'Draft', 'url': ''},
        ],
      },
    ]);
    await _run(t, server, () async {
      expect(find.text('Untitled project'), findsWidgets);
      expect(find.text('No owner'), findsWidgets);
      await t.tap(find.text('Fixed date').first);
      await _settle(t, 5);
      expect(find.text('Jan 1, 2030'), findsWidgets, reason: 'a date-only deadline is not shifted by the time zone');
      expect(find.text('No link yet'), findsOneWidget);
      expect(find.textContaining('Updated'), findsNothing, reason: 'no updatedAt from an older server: nothing made up');
    });
  });
}
