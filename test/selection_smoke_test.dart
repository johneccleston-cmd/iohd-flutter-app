// Checks that dragging the mouse across dashboard text and pressing Ctrl+C copies it. The main navigation shell
// wraps the whole app in one (appSelectionBuilder in main.dart); the same wrapper is used here. Time passes during the drag, like in a real browser, so
// widgets that animate or tick (the clock, the hurdle meters, the flame) get their chance to interfere.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/commission_dashboard_screen.dart';
import 'package:iohd_desktop/widgets/page_selection.dart';

Map<String, dynamic> _tech(String name, double week) => {
      'id': name,
      'name': name,
      'jobTitle': 'Technician',
      'imageUrl': '',
      'isSales': false,
      'ytdCommission': 0,
      'weekGross': week,
      'hurdleStreak': week >= 750 ? 1 : 0,
    };

Future<String> _drag(WidgetTester tester, Finder target) async {
  String? copied;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
    return null;
  });
  final body = jsonEncode({
    'summary': {'totalPayoutsYtd': 0, 'commercialRetainagePool': 0, 'avgCommissionPerTech': 0},
    'meta': {'weeklyThreshold': 750},
    'technicians': [_tech('Andrew Johnson', 0), _tech('Nick Smith', 781.74)],
    'monthlyData': [],
  });
  late String out;
  await http.runWithClient(() async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: 'Segoe UI'),
      builder: appSelectionBuilder, // the same wrapper main.dart uses for the whole app
      home: const Scaffold(body: CommissionDashboardContent(selectedYear: 2026)),
    ));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final r = tester.getRect(target);
    final g = await tester.startGesture(r.centerLeft + const Offset(2, 0), kind: PointerDeviceKind.mouse);
    for (var k = 1; k <= 10; k++) {
      await tester.pump(const Duration(milliseconds: 120));
      await g.moveTo(Offset.lerp(r.centerLeft, r.centerRight, k / 10)! - const Offset(2, 0));
    }
    await tester.pump(const Duration(milliseconds: 120));
    await g.up();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // Copy from the selection region nearest the text (a column's own SelectionGroup, or the page's area). The
    // test harness doesn't route Ctrl+C into the inner region, so call its copy directly.
    final region =
        tester.state<SelectableRegionState>(find.ancestor(of: target, matching: find.byType(SelectableRegion)).first);
    // ignore: deprecated_member_use
    region.copySelection(SelectionChangedCause.keyboard);
    await tester.pump();
    out = copied ?? '';
  }, () => MockClient((req) async => http.Response(req.url.path.contains('payroll') ? '{"runs":[]}' : body, 200)));
  return out;
}

void main() {
  setUpAll(() async {
    final loader = FontLoader('Segoe UI');
    for (final p in [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf']) {
      loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
    }
    await loader.load();
  });
  testWidgets('staff card name', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1500, 800);
    addTearDown(tester.view.reset);
    expect(await _drag(tester, find.text('Andrew Johnson').first), contains('Andrew Johnso'));
  });
  testWidgets('top card label', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1500, 800);
    addTearDown(tester.view.reset);
    expect(await _drag(tester, find.text('Total payouts YTD').first), contains('Total payouts'));
  });
  testWidgets('hurdle meter name', variant: TargetPlatformVariant.only(TargetPlatform.windows), (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1500, 800);
    addTearDown(tester.view.reset);
    expect(await _drag(tester, find.text('Nick Smith').last), contains('Nick Sm'));
  });
}
