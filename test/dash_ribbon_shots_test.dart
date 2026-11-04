// Renders the dashboards' navy title bar (the "ribbon") for review and saves the top of the screen to
// build/ribbon_shots/<SHOTS_TAG>/ (default "after"; git-ignored, not goldens): settled at several widths and at 130%
// text, without a year selector, refreshing and refresh-failed, with reduced motion, and frame strips of the opening
// animation and a year change. Fails on any layout overflow.
//
// Run: flutter test test/dash_ribbon_shots_test.dart

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iohd_desktop/collections_dashboard_screen.dart';
import 'package:iohd_desktop/inventory_dashboard_screen.dart';
import 'package:iohd_desktop/reports_screen.dart';

import 'dashboard_harness.dart';

final _shot = GlobalKey();
final _tag = Platform.environment['SHOTS_TAG'] ?? 'after';

/// Like [pumpDashboard], but leaves the first frame on screen so the opening animation can be photographed.
Future<void> _pump(WidgetTester t, Widget screen, {Size size = const Size(1500, 800), double textScale = 1, bool reduceMotion = false}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  addTearDown(t.view.reset);
  await t.pumpWidget(MediaQuery(
    data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale), disableAnimations: reduceMotion),
    child: RepaintBoundary(
      key: _shot,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: Scaffold(body: screen),
      ),
    ),
  ));
}

/// The top [height] px of the screen at 2x, so the ribbon's detail is visible.
Future<void> _save(WidgetTester t, String name, {double height = 120}) => t.runAsync(() async {
      final boundary = _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final full = await boundary.toImage(pixelRatio: 2);
      final src = Rect.fromLTWH(0, 0, full.width.toDouble(), height * 2);
      final rec = ui.PictureRecorder();
      Canvas(rec).drawImageRect(full, src, Offset.zero & src.size, Paint());
      final image = await rec.endRecording().toImage(src.width.toInt(), src.height.toInt());
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('build/ribbon_shots/$_tag/$name.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes!.buffer.asUint8List());
    });

const _collections = '/api/dashboards/collections';

void main() {
  setUpAll(loadDashFonts);
  setUp(() async {
    pinDashClock();
    await dashSignIn();
  });
  tearDown(unpinDashClock);

  for (final (name, screen, size, scale) in [
    ('collections_1500', const CollectionsDashboardScreen(), const Size(1500, 800), 1.0),
    ('collections_1280_text130', const CollectionsDashboardScreen(), const Size(1280, 720), 1.3),
    ('financial_1920', const ReportsScreen(), const Size(1920, 940), 1.0),
    ('financial_800', const ReportsScreen(), const Size(800, 700), 1.0),
    ('financial_420', const ReportsScreen(), const Size(420, 800), 1.0),
    ('inventory_1280', const InventoryDashboardScreen(), const Size(1280, 600), 1.0),
  ]) {
    testWidgets('$name settled', (t) async {
      await http.runWithClient(() async {
        await _pump(t, screen, size: size, textScale: scale);
        await settleDashboard(t);
        await _save(t, name);
      }, DashFakeApi().client);
    });
  }

  testWidgets('opening frames', (t) async {
    await http.runWithClient(() async {
      await _pump(t, const CollectionsDashboardScreen());
      var at = 0;
      for (final ms in const [0, 60, 140, 240, 360, 520, 760, 1100, 1600]) {
        await t.pump(Duration(milliseconds: ms - at));
        at = ms;
        await _save(t, 'open_${ms.toString().padLeft(4, '0')}');
      }
    }, DashFakeApi().client);
  });

  testWidgets('reduced motion: the first frame is the finished one', (t) async {
    await http.runWithClient(() async {
      await _pump(t, const CollectionsDashboardScreen(), reduceMotion: true);
      await t.pump();
      await _save(t, 'reduced_first_frame');
    }, DashFakeApi().client);
  });

  testWidgets('year change frames', (t) async {
    await http.runWithClient(() async {
      await _pump(t, const CollectionsDashboardScreen());
      await settleDashboard(t);
      await t.tap(dashYearArrow('Previous year'));
      var at = 0;
      for (final ms in const [16, 80, 160, 260, 400]) {
        await t.pump(Duration(milliseconds: ms - at));
        at = ms;
        await _save(t, 'year_${ms.toString().padLeft(3, '0')}');
      }
      await settleDashboard(t);
    }, DashFakeApi().client);
  });

  testWidgets('the year menu', (t) async {
    await http.runWithClient(() async {
      await _pump(t, const CollectionsDashboardScreen());
      await settleDashboard(t);
      await t.tap(find.byType(PopupMenuButton<int>));
      await settleDashboard(t, frames: 5);
      await _save(t, 'year_menu', height: 240);
      await t.tapAt(const Offset(20, 400));
      await settleDashboard(t, frames: 5);
    }, DashFakeApi().client);
  });

  testWidgets('refreshing, landed and failed', (t) async {
    final api = DashFakeApi();
    await http.runWithClient(() async {
      await _pump(t, const CollectionsDashboardScreen());
      await settleDashboard(t);
      await _save(t, 'state_updated');
      api.delay[_collections] = const Duration(seconds: 2);
      await t.tap(dashRefreshButton);
      for (final ms in const [150, 450, 900]) {
        await t.pump(const Duration(milliseconds: 150));
        if (ms == 150) await _save(t, 'state_refreshing_a');
        if (ms == 900) await _save(t, 'state_refreshing_b');
      }
      await t.pump(const Duration(milliseconds: 1500));
      for (final ms in const [100, 300, 600, 1000]) {
        await t.pump(Duration(milliseconds: ms == 100 ? 100 : ms ~/ 2));
        await _save(t, 'state_landed_$ms');
      }
      await settleDashboard(t);
      api.delay.clear();
      api.status[_collections] = 500;
      await t.tap(dashRefreshButton);
      await settleDashboard(t, frames: 10);
      await _save(t, 'state_refresh_failed');
    }, api.client);
  });
}
