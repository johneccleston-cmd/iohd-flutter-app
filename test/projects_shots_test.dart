// Renders the Project Tracker at the desktop sizes the office uses, with a production-sized board (61 projects), a small
// one, the 13 live rows saved from the old sheet, an empty board, a failed load, the first load, and the main
// interactions (details with notes and files, grouping by owner, the editor, the row menu, a view-only user, a narrow
// window), and fails on any overflow. Pictures go to build/dash_shots/projects_*.png for review; nothing here is a golden.
//   flutter test test/projects_shots_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/projects_screen.dart';

import 'dashboard_harness.dart';
import 'projects_fixture.dart';

const _sizes = <String, Size>{'1280x600': Size(1280, 600), '1366x768': Size(1366, 768), '1500x800': Size(1500, 800), '1920x940': Size(1920, 940)};

/// Pumps the screen against [server] at [size], runs [then], saves the picture and fails on any overflow.
Future<void> _shoot(
  WidgetTester t,
  String name,
  FakeProjectsServer server, {
  Size size = const Size(1366, 768),
  Future<void> Function()? then,
  double textScale = 1,
}) async {
  final errors = await pumpDashboard(
    t,
    const ProjectsScreen(),
    api: DashFakeApi()..extra.add(server.handle),
    size: size,
    textScale: textScale,
    body: () async {
      if (then != null) await then();
      await saveDashShot(t, 'projects_$name');
    },
  );
  expect(errors.messages, isEmpty, reason: errors.messages.join('\n'));
}

Future<void> _frames(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

FakeProjectsServer _sample() {
  final body = jsonDecode(File('test/projects_sample.json').readAsStringSync()) as Map<String, dynamic>;
  return FakeProjectsServer(List<Map<String, dynamic>>.from(body['projects'] as List));
}

void main() {
  setUpAll(() async {
    await loadDashFonts();
  });
  setUp(() => projectsSignIn(admin: true));

  for (final e in _sizes.entries) {
    testWidgets('many projects ${e.key}', (t) => _shoot(t, 'many_${e.key}', FakeProjectsServer(manyProjects()), size: e.value));
  }
  testWidgets('130% text 1366', (t) => _shoot(t, 'many_1366x768_text130', FakeProjectsServer(manyProjects()), textScale: 1.3));
  testWidgets('few projects', (t) => _shoot(t, 'few_1366x768', FakeProjectsServer(fewProjects())));
  testWidgets('live sample (13 rows from the old sheet)', (t) => _shoot(t, 'sample_1366x768', _sample(), size: const Size(1366, 768)));
  testWidgets('empty', (t) => _shoot(t, 'empty_1366x768', FakeProjectsServer(const [])));
  testWidgets('load failed', (t) => _shoot(t, 'error_1366x768', FakeProjectsServer(manyProjects())..failWith = 502));

  testWidgets('details with notes and files', (t) async {
    await _shoot(
      t,
      'detail_1500x800',
      FakeProjectsServer(manyProjects()),
      size: const Size(1500, 800),
      then: () async {
        await t.tap(find.text('Sales Process Changes'));
        await _frames(t);
      },
    );
  });

  testWidgets('long name selected at 1280', (t) async {
    await _shoot(
      t,
      'long_name_1280x600',
      FakeProjectsServer(manyProjects()),
      size: const Size(1280, 600),
      then: () async {
        final row = find.textContaining('Need to collect on accounts receivable');
        await t.dragUntilVisible(row, find.byType(ListView), const Offset(0, -150));
        await _frames(t, 3);
        await t.tap(row.first);
        await _frames(t);
      },
    );
  });

  testWidgets('grouped by owner, all statuses', (t) async {
    await _shoot(
      t,
      'by_owner_1500x800',
      FakeProjectsServer(manyProjects()),
      size: const Size(1500, 800),
      then: () async {
        await t.tap(find.text('Owner').first);
        await t.tap(find.text('ALL'));
        await _frames(t);
      },
    );
  });

  testWidgets('overdue filter', (t) async {
    await _shoot(
      t,
      'overdue_1366x768',
      FakeProjectsServer(manyProjects()),
      then: () async {
        await t.tap(find.text('OVERDUE'));
        await _frames(t);
      },
    );
  });

  testWidgets('search with no match', (t) async {
    await _shoot(
      t,
      'no_match_1366x768',
      FakeProjectsServer(manyProjects()),
      then: () async {
        await t.enterText(find.byType(TextField).first, 'forklift');
        await _frames(t);
      },
    );
  });

  testWidgets('row menu', (t) async {
    await _shoot(
      t,
      'row_menu_1366x768',
      FakeProjectsServer(manyProjects()),
      then: () async {
        await t.tap(find.text('Warehouse Reorganization'), buttons: 2);
        await _frames(t);
      },
    );
  });

  testWidgets('editor', (t) async {
    await _shoot(
      t,
      'editor_1366x768',
      FakeProjectsServer(manyProjects()),
      then: () async {
        await t.tap(find.text('Warehouse Reorganization'));
        await _frames(t, 6); // let the pane finish its cross-fade
        await t.tap(find.widgetWithText(OutlinedButton, 'Edit').last);
        await _frames(t);
      },
    );
  });

  testWidgets('new project at 1280x600', (t) async {
    await _shoot(
      t,
      'new_1280x600',
      FakeProjectsServer(manyProjects()),
      size: const Size(1280, 600),
      then: () async {
        await t.tap(find.text('New project'));
        await _frames(t);
      },
    );
  });

  testWidgets('view-only user', (t) async {
    await projectsSignIn(denied: kProjectsViewOnly);
    await _shoot(
      t,
      'view_only_1366x768',
      FakeProjectsServer(manyProjects()),
      then: () async {
        await t.tap(find.text('Warehouse Reorganization'));
        await _frames(t);
      },
    );
  });

  testWidgets('narrow window opens details in a dialog', (t) async {
    await _shoot(
      t,
      'narrow_1024x700',
      FakeProjectsServer(manyProjects()),
      size: const Size(1024, 700),
      then: () async {
        await t.tap(find.text('Warehouse Reorganization'));
        await _frames(t);
      },
    );
  });

  testWidgets('first load', (t) async {
    final server = FakeProjectsServer(manyProjects());
    final api = DashFakeApi()..delay['/api/projects'] = const Duration(seconds: 20);
    api.extra.add((r) async {
      await Future<void>.delayed(const Duration(seconds: 20));
      return server.handle(r);
    });
    final errors = await pumpDashboard(
      t,
      const ProjectsScreen(),
      api: api,
      size: const Size(1366, 768),
      body: () async {
        await saveDashShot(t, 'projects_loading_1366x768');
        await t.pump(const Duration(seconds: 25));
      },
    );
    expect(errors.messages, isEmpty, reason: errors.messages.join('\n'));
  });
}
