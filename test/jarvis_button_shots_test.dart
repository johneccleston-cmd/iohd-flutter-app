// Review screenshots of the Ask Jarvis button (the bar at the widths people use, close-ups at rest, hovered and focused)
// and of the panel growing out of it, frame by frame, opening and closing. Written to
// <JARVIS_SHOTS_DIR or build/jarvis_button_shots>/ (not goldens). A layout overflow fails the scene.
// Run:  flutter test test/jarvis_button_shots_test.dart

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'nav_fixture.dart';

final String _dir = Platform.environment['JARVIS_SHOTS_DIR'] ?? 'build/jarvis_button_shots';
final _shotKey = GlobalKey();

Finder get _button => find.byWidgetPredicate((w) => w.runtimeType.toString() == '_AskButton');

Future<void> _pumpBar(WidgetTester t, Size size, {bool still = false}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final router = navTestRouter(initial: '/jobs');
  await http.runWithClient(() async {
    await t.pumpWidget(RepaintBoundary(
      key: _shotKey,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        routerConfig: router,
        theme: navTestTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: still),
          child: child!,
        ),
      ),
    ));
    await t.pumpAndSettle();
  }, navApi);
}

/// Saves the whole window, or with [crop] that part of it at [scale] times the size.
Future<void> _save(WidgetTester t, String name, {Rect? crop, double scale = 1}) async {
  final boundary = _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await t.runAsync(() async {
    var image = await boundary.toImage(pixelRatio: scale);
    if (crop != null) {
      final src = Rect.fromLTRB(crop.left * scale, crop.top * scale, crop.right * scale, crop.bottom * scale);
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawImageRect(image, src, Offset.zero & src.size, Paint());
      image = await recorder.endRecording().toImage(src.width.round(), src.height.round());
    }
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory(_dir)..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Rect _around(WidgetTester t) => t.getRect(_button).inflate(14);

void main() {
  setUpAll(loadNavFonts);
  setUp(() => navSignIn());

  for (final w in const <double>[1920, 1440, 1366, 1280, 1100, 860, 520]) {
    testWidgets('bar ${w.toInt()}', (t) async {
      await _pumpBar(t, Size(w, 220));
      await _save(t, 'bar_${w.toInt()}');
    });
  }

  testWidgets('close-ups: rest and hover (mid-twinkle and settled)', (t) async {
    await _pumpBar(t, const Size(1440, 220));
    final crop = _around(t);
    await _save(t, 'zoom_rest', crop: crop, scale: 3);

    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: t.getCenter(_button));
    addTearDown(mouse.removePointer);
    await t.pump();
    await t.pump(const Duration(milliseconds: 70));
    await _save(t, 'zoom_hover_mid', crop: crop, scale: 3);
    await t.pumpAndSettle();
    await _save(t, 'zoom_hover', crop: crop, scale: 3);
  });

  testWidgets('close-up: keyboard focus', (t) async {
    await _pumpBar(t, const Size(1440, 220));
    final crop = _around(t);
    // Tab along the bar until the button has keyboard focus.
    var reached = false;
    for (var i = 0; i < 20 && !reached; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pumpAndSettle();
      reached = Focus.maybeOf(t.element(find.text('Ask Jarvis'))) == FocusManager.instance.primaryFocus;
    }
    expect(reached, isTrue, reason: 'Tab reaches Ask Jarvis');
    await _save(t, 'zoom_focus', crop: crop, scale: 3);
  });

  testWidgets('narrow bar: the mark alone', (t) async {
    await _pumpBar(t, const Size(520, 220));
    expect(find.text('Ask Jarvis'), findsNothing);
    await _save(t, 'zoom_icon_only', crop: _around(t), scale: 3);
  });

  testWidgets('opening and closing, frame by frame', (t) async {
    await _pumpBar(t, const Size(1440, 860));
    await t.tap(_button);
    var at = 0;
    for (final ms in const [0, 40, 80, 120, 170, 230, 300, 380, 470, 560]) {
      await t.pump(Duration(milliseconds: ms - at));
      at = ms;
      await _save(t, 'open_${ms.toString().padLeft(3, '0')}');
    }
    await t.pumpAndSettle();
    await _save(t, 'open_settled');

    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    at = 0;
    for (final ms in const [0, 50, 100, 150, 200, 240]) {
      await t.pump(Duration(milliseconds: ms - at));
      at = ms;
      await _save(t, 'close_${ms.toString().padLeft(3, '0')}');
    }
    await t.pumpAndSettle();
    expect(find.textContaining('Explore what Jarvis'), findsNothing);
  });

  testWidgets('Ctrl+J grows the panel from the button too', (t) async {
    await _pumpBar(t, const Size(1280, 800));
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    await t.pump(const Duration(milliseconds: 120));
    await _save(t, 'ctrlj_120');
    await t.pumpAndSettle();
    expect(find.textContaining('Explore what Jarvis'), findsOneWidget);
  });

  testWidgets('reduce motion: open at once', (t) async {
    await _pumpBar(t, const Size(1280, 800), still: true);
    await t.tap(_button);
    await t.pump();
    await t.pump();
    await _save(t, 'still_open');
    expect(find.textContaining('Explore what Jarvis'), findsOneWidget);
  });
}
