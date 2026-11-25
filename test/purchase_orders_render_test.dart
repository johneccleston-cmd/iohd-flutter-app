// Draws the purchase order screens with the app's own font and icons to build/po_shots/*.png (git-ignored), to look
// at: the list wide, mid and phone width; the PO page late, partly in, received, a draft, editing, new with what is
// missing, and the Receive dialog. Not goldens: nothing is compared.
//   flutter test test/purchase_orders_render_test.dart

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iohd_desktop/main.dart' show officeTheme;
import 'package:iohd_desktop/purchase_order_detail_screen.dart';
import 'package:iohd_desktop/purchase_orders_screen.dart';

import 'nav_fixture.dart';
import 'purchase_orders_fixture.dart';

const _shot = ValueKey('po-shot');
final _out = Directory('build/po_shots');

Future<void> _font(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    if (File(p).existsSync()) loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

Future<void> _save(WidgetTester t, String name) async {
  final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(_shot));
  final bytes = await t.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  });
  File('${_out.path}/$name.png').writeAsBytesSync(bytes!);
}

Future<void> _scene(WidgetTester t, String name, Size size, Widget screen, {Future<void> Function()? then, FakePoServer? server}) async {
  poView(t, size);
  final s = server ?? FakePoServer();
  await http.runWithClient(() async {
    await t.pumpWidget(
      RepaintBoundary(
        key: _shot,
        child: MaterialApp(debugShowCheckedModeBanner: false, theme: officeTheme(), home: screen),
      ),
    );
    await t.pumpAndSettle();
    if (then != null) await then();
    await t.pumpAndSettle();
  }, () => s.client);
  expect(t.takeException(), isNull, reason: name);
  await _save(t, name);
}

void main() {
  setUpAll(() async {
    _out.createSync(recursive: true);
    await _font('IBM Plex Sans', [
      for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) 'assets/fonts/IBMPlexSans-$w.ttf',
    ]);
    await _font('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\segoeuib.ttf']);
    final root = Platform.environment['FLUTTER_ROOT'] ?? r'C:\flutter';
    await _font('MaterialIcons', ['$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });
  setUp(() => navSignIn());

  testWidgets('list wide', (t) => _scene(t, 'list_1440', const Size(1440, 860), const PurchaseOrdersScreen()));
  testWidgets('list mid', (t) => _scene(t, 'list_900', const Size(900, 900), const PurchaseOrdersScreen()));
  testWidgets('list phone', (t) => _scene(t, 'list_420', const Size(420, 900), const PurchaseOrdersScreen()));
  testWidgets('list past due filter', (t) => _scene(t, 'list_filter', const Size(1440, 640), const PurchaseOrdersScreen(), then: () async {
        await t.tap(find.widgetWithText(ChoiceChip, 'Past due'));
      }));
  testWidgets('list empty', (t) => _scene(t, 'list_empty', const Size(1440, 640), const PurchaseOrdersScreen(), server: FakePoServer(seed: false)));

  testWidgets('PO late', (t) => _scene(t, 'po_late_1440', const Size(1440, 900), const PurchaseOrderDetailScreen(orderId: 1)));
  testWidgets('PO partly in', (t) => _scene(t, 'po_partial_1440', const Size(1440, 900), const PurchaseOrderDetailScreen(orderId: 2)));
  testWidgets('PO received', (t) => _scene(t, 'po_received_1440', const Size(1440, 800), const PurchaseOrderDetailScreen(orderId: 3)));
  testWidgets('PO draft', (t) => _scene(t, 'po_draft_1440', const Size(1440, 800), const PurchaseOrderDetailScreen(orderId: 4)));
  testWidgets('PO mid', (t) => _scene(t, 'po_partial_900', const Size(900, 1200), const PurchaseOrderDetailScreen(orderId: 2)));
  testWidgets('PO phone', (t) => _scene(t, 'po_partial_420', const Size(420, 1500), const PurchaseOrderDetailScreen(orderId: 2)));
  testWidgets('PO editing', (t) => _scene(t, 'po_edit_1440', const Size(1440, 1000), const PurchaseOrderDetailScreen(orderId: 2), then: () async {
        await t.tap(find.text('Edit'));
      }));
  testWidgets('PO new, what is missing', (t) => _scene(t, 'po_new_missing_1440', const Size(1440, 900), const PurchaseOrderDetailScreen(), then: () async {
        await t.tap(find.text('Create PO'));
      }));
  testWidgets('PO receive dialog', (t) => _scene(t, 'po_receive_1440', const Size(1440, 900), const PurchaseOrderDetailScreen(orderId: 2), then: () async {
        await t.tap(find.text('Receive'));
      }));
  testWidgets('PO more menu', (t) => _scene(t, 'po_more_1440', const Size(1440, 700), const PurchaseOrderDetailScreen(orderId: 2), then: () async {
        await t.tap(find.text('More'));
      }));
}
