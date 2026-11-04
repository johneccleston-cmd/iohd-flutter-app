// Renders a plain tooltip next to the scorecard hover card so their looks can be compared.
// Run: flutter test test/tip_look_shots_test.dart  (writes build/tip_look/tips.png)
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/widgets/dash_hover_card.dart';

import 'dashboard_harness.dart';

final _shot = GlobalKey();

void main() {
  setUpAll(loadDashFonts);
  testWidgets('plain tooltip matches the scorecard card', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(900, 360);
    addTearDown(t.view.reset);
    await t.pumpWidget(RepaintBoundary(
      key: _shot,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          fontFamily: 'Segoe UI',
          tooltipTheme: TooltipThemeData(
            waitDuration: const Duration(milliseconds: 350),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            margin: const EdgeInsets.all(8),
            constraints: const BoxConstraints(maxWidth: 320),
            decoration: dashTipDecoration,
            textStyle: dashTipBodyStyle,
          ),
        ),
        home: Scaffold(
          backgroundColor: const Color(0xFFF1F5F9),
          body: Padding(
            padding: const EdgeInsets.all(40),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              DashHoverCard(
                title: 'Win rate',
                value: '42%',
                body: 'Share of sent estimates that were won this year.',
                color: const Color(0xFF2563EB),
                child: Container(key: const Key('card'), width: 200, height: 80, color: Colors.white, child: const Center(child: Text('Scorecard'))),
              ),
              const SizedBox(width: 120),
              Tooltip(
                message: 'Whole years with the company',
                child: Container(key: const Key('plain'), width: 200, height: 80, color: Colors.white, child: const Center(child: Text('Plain tooltip'))),
              ),
            ]),
          ),
        ),
      ),
    ));
    final g = await t.createGesture(kind: ui.PointerDeviceKind.mouse);
    await g.addPointer(location: Offset.zero);
    addTearDown(g.removePointer);
    for (final k in ['card', 'plain']) {
      await g.moveTo(t.getCenter(find.byKey(Key(k))));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      await t.runAsync(() async {
        final b = _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final img = await b.toImage(pixelRatio: 2);
        final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
        File('build/tip_look/$k.png')
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes!.buffer.asUint8List());
      });
      await g.moveTo(Offset.zero);
      await t.pump(const Duration(milliseconds: 400));
    }
  });
}
