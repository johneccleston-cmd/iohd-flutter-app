// What the top bar costs: how much of it rebuilds when the page updates, on a route change, on hover, when a menu
// opens and when the window is resized, and how often it fetches the account photo. Prints the numbers (debug-mode
// test timings: compare runs with each other, not with the real app); asserts only what must hold.
// Run:  flutter test test/nav_perf_test.dart

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart' as widgets;
import 'package:flutter_test/flutter_test.dart';

import 'nav_fixture.dart';

/// Counts rebuilds of elements inside the bar (under the shell's PreferredSize, menus included) while [body] runs.
Future<int> _barRebuilds(Future<void> Function() body) async {
  var n = 0;
  final old = widgets.debugOnRebuildDirtyWidget;
  widgets.debugOnRebuildDirtyWidget = (e, _) {
    if (e.widget is PreferredSize || e.findAncestorWidgetOfExactType<PreferredSize>() != null) n++;
  };
  try {
    await body();
  } finally {
    widgets.debugOnRebuildDirtyWidget = old;
  }
  return n;
}

class _Ticker extends StatefulWidget {
  const _Ticker();
  @override
  State<_Ticker> createState() => _TickerState();
}

class _TickerState extends State<_Ticker> {
  int ticks = 0;
  @override
  Widget build(BuildContext context) => Center(child: Text('tick $ticks'));
}

final _log = <String>[];
void _note(String s) => _log.add(s);

void main() {
  setUpAll(loadNavFonts);
  setUp(() async {
    await navSignIn();
    navUsersRequests = 0;
  });
  tearDown(() => navStubPage = null);
  tearDownAll(() {
    // ignore: avoid_print
    print('\n=== nav perf ===\n${_log.join('\n')}\n================');
  });

  testWidgets('a page updating itself never rebuilds the bar', (t) async {
    navStubPage = (_) => const _Ticker();
    await pumpNav(t, const Size(1440, 700));
    final ticker = t.state<_TickerState>(find.byType(_Ticker));
    final n = await _barRebuilds(() async {
      for (var i = 0; i < 120; i++) {
        // ignore: invalid_use_of_protected_member
        ticker.setState(() => ticker.ticks++);
        await t.pump(const Duration(milliseconds: 16));
      }
    });
    _note('page setState x120: bar rebuilds = $n');
    expect(n, 0);
  });

  testWidgets('route changes', (t) async {
    final router = await pumpNav(t, const Size(1440, 700));
    final routes = ['/jobs', '/calendar', '/dashboards/sales', '/hr/kpis/12', '/inventory/catalog'];
    final sw = Stopwatch();
    final n = await _barRebuilds(() async {
      sw.start();
      for (var i = 0; i < 50; i++) {
        router.go(routes[i % routes.length]);
        await t.pump();
      }
      sw.stop();
    });
    _note('route change x50: ${(sw.elapsedMicroseconds / 50 / 1000).toStringAsFixed(2)} ms per change, '
        '${(n / 50).toStringAsFixed(1)} bar rebuilds per change');
    _note('account photo requests over 50 route changes: $navUsersRequests');
    expect(navUsersRequests, lessThanOrEqualTo(1));
  });

  testWidgets('opening and closing a menu', (t) async {
    await pumpNav(t, const Size(1440, 700));
    var frames = 0;
    final sw = Stopwatch()..start();
    for (var i = 0; i < 20; i++) {
      await t.tap(find.text('My Office'));
      frames += await t.pumpAndSettle();
      await t.tapAt(const Offset(1200, 600));
      frames += await t.pumpAndSettle();
    }
    sw.stop();
    _note('open + close My Office x20: ${(sw.elapsedMicroseconds / 20 / 1000).toStringAsFixed(2)} ms per cycle, '
        '${(frames / 20).toStringAsFixed(1)} frames per cycle');
  });

  // The first page of each menu, to tell which menus a sweep opened.
  const firstPages = {'Customers': 'My Office', 'Stock Levels': 'Inventory', 'Payroll': 'HR', 'Financial': 'Dashboards'};
  for (final (speed, step) in const [('~940 px/s', 15.0), ('~1900 px/s', 30.0)]) {
    testWidgets('sweeping the pointer across the bar at $speed', (t) async {
      await pumpNav(t, const Size(1440, 700));
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(10, 30));
      addTearDown(mouse.removePointer);
      var framesOpen = 0;
      var mostAtOnce = 0;
      final opened = <String>{};
      final n = await _barRebuilds(() async {
        for (var x = 10.0; x < 900; x += step) {
          await mouse.moveTo(Offset(x, 30));
          await t.pump(const Duration(milliseconds: 16));
          final showing = [for (final e in firstPages.entries) if (find.text(e.key).evaluate().isNotEmpty) e.value];
          if (showing.isNotEmpty) framesOpen++;
          mostAtOnce = showing.length > mostAtOnce ? showing.length : mostAtOnce;
          opened.addAll(showing);
        }
        await mouse.moveTo(const Offset(1200, 600));
        await t.pumpAndSettle();
      });
      _note('pointer sweep $speed: bar rebuilds = $n, frames with a menu open = $framesOpen, '
          'menus opened = ${opened.length} ${opened.toList()}, most open at once = $mostAtOnce');
    });
  }

  testWidgets('resizing the window', (t) async {
    await pumpNav(t, const Size(1440, 300));
    final sw = Stopwatch()..start();
    for (var i = 0; i < 60; i++) {
      t.view.physicalSize = Size(700 + (i * 37) % 1200, 300);
      await t.pump();
    }
    sw.stop();
    _note('resize x60 (700-1900 px): ${(sw.elapsedMicroseconds / 60 / 1000).toStringAsFixed(2)} ms per frame');
  });
}
