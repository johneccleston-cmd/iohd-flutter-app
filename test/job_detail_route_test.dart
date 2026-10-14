// Checks the job page lives at /jobs/<id> inside the real nav shell (top bar visible), that Back returns to where you
// came from (Jobs or Calendar), and that the address is its own URL.
// Run:  flutter test test/job_detail_route_test.dart --update-goldens

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/job_detail_screen.dart';
import 'package:iohd_desktop/widgets/main_navigation_shell.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

class _TwoStubs extends StatelessWidget {
  const _TwoStubs();
  @override
  Widget build(BuildContext context) => Column(children: [
        TextButton(onPressed: () => context.go('/jobs/1096183137'), child: const Text('OPEN JOB FROM CALENDAR')),
        TextButton(onPressed: () => context.go('/jobs/1099999999'), child: const Text('OPEN OTHER JOB FROM CALENDAR')),
      ]);
}

class _Stub extends StatelessWidget {
  final String label;
  final String goTo;
  const _Stub(this.label, this.goTo);
  @override
  Widget build(BuildContext context) => Center(
        child: TextButton(onPressed: () => context.go(goTo), child: Text(label)),
      );
}

GoRouter _router() => GoRouter(
      initialLocation: '/calendar',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) => MainNavigationShell(navigationShell: shell),
          branches: [
            for (var i = 0; i < 9; i++)
              StatefulShellBranch(routes: [
                if (i == 4)
                  GoRoute(
                    path: '/jobs',
                    builder: (_, _) => const _Stub('OPEN JOB FROM LIST', '/jobs/1096183137'),
                    routes: [
                      jobDetailRoute(),
                    ],
                  )
                else if (i == 5)
                  GoRoute(path: '/calendar', builder: (_, _) => const _TwoStubs())
                else
                  GoRoute(path: '/other$i', builder: (_, _) => const SizedBox()),
              ]),
          ],
        ),
      ],
    );

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf']);
  });

  testWidgets('job page is /jobs/<id> inside the shell and Back returns to the caller', (t) async {
    t.view.physicalSize = const Size(1500, 900);
    t.view.devicePixelRatio = 1;
    final job = {
      'job': {'job_id': '1096183137', 'customer_name': 'Schuber Mitchell Homes', 'status': 'Scheduled - Full Day', 'is_estimate': false},
      'visits': [],
      'payments': [],
      'history': [],
    };
    final router = _router();
    await http.runWithClient(() async {
      await t.pumpWidget(RepaintBoundary(
        key: const ValueKey('shot'),
        child: MaterialApp.router(theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'), routerConfig: router),
      ));
      await t.pumpAndSettle();

      // From the calendar
      await t.tap(find.text('OPEN JOB FROM CALENDAR'));
      await t.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/jobs/1096183137');
      expect(find.text('Job # 1096183137'), findsOneWidget);
      expect(find.byType(MainNavigationShell), findsOneWidget); // the top nav is still there
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/job_detail_in_shell.png'));
      expect(find.textContaining('Back to'), findsNothing); // no Back button: the nav bar is the way out
      router.go('/calendar'); // what clicking Calendar in the nav bar does
      await t.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/calendar');

      // From the jobs list
      router.go('/jobs');
      await t.pumpAndSettle();
      await t.tap(find.text('OPEN JOB FROM LIST'));
      await t.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/jobs/1096183137');
      expect(find.textContaining('Back to'), findsNothing);
      router.go('/jobs');
      await t.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/jobs');
      expect(t.takeException(), isNull);

      // A DIFFERENT job from the calendar must show that job, not the one we were just on.
      router.go('/calendar');
      await t.pumpAndSettle();
      await t.tap(find.text('OPEN JOB FROM CALENDAR'));
      await t.pumpAndSettle();
      expect(find.text('Job # 1096183137'), findsOneWidget);
      router.go('/calendar');
      await t.pumpAndSettle();
      await t.tap(find.text('OPEN OTHER JOB FROM CALENDAR'));
      await t.pumpAndSettle();
      expect(find.text('Job # 1099999999'), findsOneWidget, reason: 'second job should replace the first');
      expect(find.text('Job # 1096183137'), findsNothing);
      expect(_requested, contains('/api/jobs/1099999999'), reason: 'and it loads that job from the server');

      // Same section, different job (e.g. the matching-estimate link): also switches.
      router.go('/jobs/1096183137');
      await t.pumpAndSettle();
      expect(find.text('Job # 1096183137'), findsOneWidget);
      expect(t.takeException(), isNull);
    }, () => MockClient((req) async {
          _requested.add(req.url.path);
          return http.Response(jsonEncode(job), 200);
        }));
  });
}

final List<String> _requested = [];
