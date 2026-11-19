// The Services Catalog page: rows from the list endpoint, cost column only when the person may see costs, loading /
// error / empty / no-match states, search, and no overflow at the desktop sizes and a narrow window. The pictures go to
// build/job_shots/services_catalog_*.png for review; nothing here is a golden.
//   flutter test test/services_catalog_test.dart

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/services/line_items_api.dart';
import 'package:iohd_desktop/services_catalog_screen.dart';

import 'dashboard_harness.dart';

typedef _Result = ({List<CatalogEntry> entries, bool canSeeCost, int historyDays});

const _services = [
  CatalogEntry(key: 'sf:service call', name: 'Service Call', kind: 'service', category: 'Service', rate: 89, rateMin: 69, rateMax: 129, cost: 22.5, uses: 412, lastUsed: '2026-11-12', taxable: false, description: 'Diagnose and quote repair'),
  CatalogEntry(key: 'sf:spring replacement', name: 'Torsion Spring Replacement (pair)', kind: 'service', category: 'Service', rate: 285, rateMin: 249, rateMax: 325, cost: 96, uses: 233, lastUsed: '2026-11-10', taxable: true, description: 'Two torsion springs, balance and adjust the door, lubricate rollers and hinges, check the opener travel and safety reverse before leaving the site'),
  CatalogEntry(key: 'sf:install', name: 'Install – Residential Door', kind: 'service', category: 'Service', rate: null, rateMin: 450, rateMax: 900, uses: 40, lastUsed: '2026-10-02', taxable: true),
  CatalogEntry(key: 'sf:old', name: 'Warranty Visit', kind: 'service', category: 'Service', uses: 1),
];

_Result _ok({bool cost = true, List<CatalogEntry> entries = _services}) => (entries: entries, canSeeCost: cost, historyDays: 540);

final _pageKey = GlobalKey();

Future<void> _pump(WidgetTester t, Future<_Result> Function() load, {Size size = const Size(1366, 768)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
      home: RepaintBoundary(key: _pageKey, child: ServicesCatalogScreen(key: UniqueKey(), load: load)),
    ),
  );
}

Future<void> _shot(WidgetTester t, String name) async {
  final boundary = _pageKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await t.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/job_shots')..createSync(recursive: true);
    File('${dir.path}/services_catalog_$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(() async {
    await loadDashFonts();
    await dashSignIn();
  });

  testWidgets('lists services with prices and cost, no overflow at desktop sizes', (t) async {
    for (final size in const [Size(1280, 600), Size(1366, 768), Size(1920, 940), Size(420, 800)]) {
      await _pump(t, () async => _ok(), size: size);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: '$size');
      expect(find.text('Service Call'), findsOneWidget);
      expect(find.text('\$89.00'), findsOneWidget);
      expect(find.text('\$69.00 – \$129.00'), findsOneWidget);
      expect(find.text('Services'), findsWidgets);
      await _shot(t, '${size.width.toInt()}x${size.height.toInt()}');
    }
  });

  testWidgets('hides the cost column without Line Items & Costs > View', (t) async {
    await _pump(t, () async => _ok(cost: false));
    await t.pumpAndSettle();
    expect(find.text('Unit Cost'), findsNothing);
    await _pump(t, () async => _ok());
    await t.pumpAndSettle();
    expect(find.text('Unit Cost'), findsOneWidget);
  });

  testWidgets('shows the loading rows, then an error with a working retry', (t) async {
    var calls = 0;
    final first = Completer<_Result>();
    await _pump(t, () {
      calls++;
      return calls == 1 ? first.future : Future.value(_ok());
    });
    await t.pump();
    expect(find.bySemanticsLabel('Loading services'), findsOneWidget);
    first.completeError(const LineItemsException('Could not reach the server.'));
    await t.pumpAndSettle();
    expect(find.text('Could not reach the server.'), findsOneWidget);
    await _shot(t, 'error');
    await t.tap(find.text('Try again'));
    await t.pumpAndSettle();
    expect(find.text('Service Call'), findsOneWidget);
    expect(calls, 2);
  });

  // Services Catalog Phase 2: the list answers 403 without the page's switch (Team > Services Catalog), and the page says
  // so instead of showing a generic error; a refresh that is refused after access was taken away clears the list.
  testWidgets('a 403 says there is no access, not that loading failed', (t) async {
    const refused = LineItemsException('Not allowed.', status: 403);
    for (final size in const [Size(1366, 768), Size(420, 800)]) {
      await _pump(t, () async => throw refused, size: size);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: '$size');
      expect(find.text("You don't have access to the Services Catalog"), findsOneWidget);
      expect(find.text('Ask an admin to turn it on in Team.'), findsOneWidget);
      expect(find.text('Could not load the services'), findsNothing);
      expect(find.text('Try again'), findsNothing);
      await _shot(t, 'no_access_${size.width.toInt()}');
    }

    var calls = 0;
    await _pump(t, () async {
      calls++;
      if (calls > 1) throw refused;
      return _ok();
    });
    await t.pumpAndSettle();
    expect(find.text('Service Call'), findsOneWidget);
    await t.tap(find.byTooltip('Refresh'));
    await t.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Service Call'), findsNothing, reason: 'nothing of the list stays on show');
    expect(find.text("You don't have access to the Services Catalog"), findsOneWidget);

    // Any other failure is still the ordinary error with Try again.
    await _pump(t, () async => throw const LineItemsException('Server error (500).', status: 500));
    await t.pumpAndSettle();
    expect(find.text('Could not load the services'), findsOneWidget);
    expect(find.text("You don't have access to the Services Catalog"), findsNothing);
  });

  testWidgets('empty list and search with no match say so', (t) async {
    await _pump(t, () async => _ok(entries: const []));
    await t.pumpAndSettle();
    expect(find.text('No services yet'), findsOneWidget);

    await _pump(t, () async => _ok());
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'spring');
    await t.pump();
    expect(find.text('Torsion Spring Replacement (pair)'), findsOneWidget);
    expect(find.text('Service Call'), findsNothing);
    await t.enterText(find.byType(TextField), 'zzz');
    await t.pump();
    expect(find.text('No services match'), findsOneWidget);
    await _shot(t, 'no_match');
    await t.tap(find.text('Clear search'));
    await t.pump();
    expect(find.text('Service Call'), findsOneWidget);
  });
}
