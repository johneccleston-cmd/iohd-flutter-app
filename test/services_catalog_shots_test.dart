// Review pictures of the Services Catalog list and a service's page at the four desktop sizes the office uses, plus 130%
// text. A 60 px bar stands in for the app's nav bar, so the page gets the room it has in the real window. Any layout
// error (overflow) is printed with the picture's name and fails the test.
//   flutter test test/services_catalog_shots_test.dart --dart-define=SHOTS=after
// Pictures go to build/services_shots/<SHOTS>/. Nothing here is a golden.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/main.dart' show officeTheme;
import 'package:iohd_desktop/service_detail_screen.dart';
import 'package:iohd_desktop/services/line_items_api.dart';
import 'package:iohd_desktop/services_catalog_screen.dart';

import 'dashboard_harness.dart';
import 'services_catalog_fixture.dart';

const _set = String.fromEnvironment('SHOTS', defaultValue: 'after');

/// Every picture is drawn as the office sees it (UX audit 2026-11-19): the app's own theme (officeTheme), on Windows.
/// Before, these used a stand-in ThemeData on the test's default platform (Android), which hid the red text cursor and
/// drew every box 8 px taller than the app does (desktop density takes 8 px off Material boxes). The real web build
/// also uses Roboto, not Segoe UI: tool/ux_harness/ checks that in a real browser.
void shotTest(String name, Future<void> Function(WidgetTester) body) =>
    testWidgets(name, body, variant: TargetPlatformVariant.only(TargetPlatform.windows));
const _navBar = 60.0;
final _pageKey = GlobalKey();

Future<void> _pump(WidgetTester t, Widget page, {required Size size, double text = 1}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    RepaintBoundary(
      key: _pageKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: officeTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(text)),
          child: child!,
        ),
        home: Column(
          children: [
            Container(height: _navBar, color: const Color(0xFF14213D)),
            Expanded(child: page),
          ],
        ),
      ),
    ),
  );
  await t.pump(const Duration(milliseconds: 50));
  await t.pumpAndSettle();
}

Future<void> _shot(WidgetTester t, String name) async {
  final err = t.takeException();
  final boundary = _pageKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await t.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/services_shots/$_set')..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
  if (err != null) fail('$name: $err');
}

const _sizes = [Size(1280, 600), Size(1366, 768), Size(1500, 800), Size(1920, 940)];
String _tag(Size s) => '${s.width.toInt()}x${s.height.toInt()}';

void main() {
  setUpAll(() async {
    await loadDashFonts();
    // Text with no font family of its own (button labels, the dropdown's value) gets the platform font in the app,
    // but the block-drawing test font here: give it Segoe UI so the pictures read like the app.
    // The ribbon's buttons ask for Material's own font (Roboto), so it gets Segoe UI too.
    for (final family in const ['FlutterTest', 'Roboto']) {
      final fallback = FontLoader(family);
      for (final f in const ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf', 'C:/Windows/Fonts/seguisb.ttf']) {
        if (File(f).existsSync()) fallback.addFont(Future.value(ByteData.view(File(f).readAsBytesSync().buffer)));
      }
      await fallback.load();
    }
    await dashSignIn();
  });

  for (final size in _sizes) {
    for (final text in const [1.0, 1.3]) {
      final name = 'list_${_tag(size)}${text == 1 ? '' : '_t130'}';
      shotTest(name, (t) async {
        await _pump(
          t,
          ServicesCatalogScreen(key: UniqueKey(), load: () async => prodLikeCatalog()),
          size: size,
          text: text,
        );
        await _shot(t, name);
      });
    }
  }

  shotTest('list_search_1366x768', (t) async {
    await _pump(
      t,
      ServicesCatalogScreen(key: UniqueKey(), load: () async => prodLikeCatalog()),
      size: const Size(1366, 768),
    );
    await t.enterText(find.byType(TextField).first, 'operator');
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    await _shot(t, 'list_search_1366x768');
  });

  shotTest('list_narrow_900x700', (t) async {
    await _pump(
      t,
      ServicesCatalogScreen(key: UniqueKey(), load: () async => prodLikeCatalog()),
      size: const Size(900, 700),
    );
    await _shot(t, 'list_narrow_900x700');
  });

  // A service's page, read and being edited, at every size and 130% text; then the same for a service with no rates.
  Widget detail(CatalogEntry s) => ServiceDetailScreen(
    key: UniqueKey(),
    serviceKey: s.key,
    initial: s,
    loader: () async => (entries: [s, ...kProdLikeServices.where((e) => e.key != s.key)], canSeeCost: true, historyDays: 540),
  );
  for (final size in _sizes) {
    for (final text in const [1.0, 1.3]) {
      for (final edit in const [false, true]) {
        final name = 'detail_${edit ? 'edit' : 'view'}_${_tag(size)}${text == 1 ? '' : '_t130'}';
        shotTest(name, (t) async {
          await _pump(t, detail(kServiceWithRates), size: size, text: text);
          if (edit) {
            await t.tap(find.text('Edit'));
            await t.pumpAndSettle();
          }
          await _shot(t, name);
        });
      }
    }
  }
  // A service package (the user, 2026-11-20): eight separate lines, only the dispatch line at 1.
  for (final size in _sizes) {
    for (final edit in const [false, true]) {
      final name = 'package_${edit ? 'edit' : 'view'}_${_tag(size)}';
      shotTest(name, (t) async {
        await _pump(t, detail(kResidentialServicePackage), size: Size(size.width, size.height + 300));
        if (edit) {
          await t.tap(find.text('Edit'));
          await t.pumpAndSettle();
        }
        await _shot(t, name);
      });
    }
  }
  // Too narrow for the rates table: each rate stacks.
  shotTest('detail_edit_narrow_900x900', (t) async {
    await _pump(t, detail(kServiceWithRates), size: const Size(900, 900));
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    await _shot(t, 'detail_edit_narrow_900x900');
  });
  for (final edit in const [false, true]) {
    final name = 'detail_norates_${edit ? 'edit' : 'view'}_1366x768';
    shotTest(name, (t) async {
      await _pump(t, detail(kProdLikeServices.first), size: const Size(1366, 768));
      if (edit) {
        await t.tap(find.text('Edit'));
        await t.pumpAndSettle();
      }
      await _shot(t, name);
    });
  }
  // The changes to several services: the bar, the Move dialog and the Make inactive question (bulk actions are only
  // in the "after" set).
  if (_set != 'before') {
    Future<void> pick(WidgetTester t) async {
      for (final k in const [
        "sf:operator installation | liftmaster | 10' 85870",
        "sf:operator installation | liftmaster | 12' 4690l",
        'sf:commercial service | call | after hours',
      ]) {
        await t.tap(find.byKey(ValueKey('pick:$k')));
      }
      await t.pumpAndSettle();
    }

    shotTest('bulk_bar_1366x768', (t) async {
      await _pump(
        t,
        ServicesCatalogScreen(key: UniqueKey(), load: () async => prodLikeCatalog(), canEdit: true),
        size: const Size(1366, 768),
      );
      await t.enterText(find.byType(TextField).first, 'operator');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey("pick:sf:operator installation | liftmaster | 10' 85870")));
      await t.tap(find.byKey(const ValueKey("pick:sf:operator installation | liftmaster | 12' 4690l")));
      await t.pumpAndSettle();
      await _shot(t, 'bulk_bar_1366x768');
    });

    shotTest('bulk_move_dialog_1366x768', (t) async {
      await _pump(
        t,
        ServicesCatalogScreen(key: UniqueKey(), load: () async => prodLikeCatalog(), canEdit: true),
        size: const Size(1366, 1400),
      );
      await pick(t);
      await t.tap(find.byKey(const ValueKey('bulk-category')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('move-to:Operator Installations')));
      await t.pumpAndSettle();
      t.view.physicalSize = const Size(1366, 768);
      await t.pumpAndSettle();
      await _shot(t, 'bulk_move_dialog_1366x768');
    });

    shotTest('bulk_inactive_confirm_1366x768', (t) async {
      await _pump(
        t,
        ServicesCatalogScreen(key: UniqueKey(), load: () async => prodLikeCatalog(), canEdit: true),
        size: const Size(1366, 1400),
      );
      await pick(t);
      await t.tap(find.byKey(const ValueKey('bulk-status')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('bulk-inactive')));
      await t.pumpAndSettle();
      t.view.physicalSize = const Size(1366, 768);
      await t.pumpAndSettle();
      await _shot(t, 'bulk_inactive_confirm_1366x768');
    });

    shotTest('list_loading_1366x768', (t) async {
      final never = Completer<CatalogResult>();
      await t.binding.setSurfaceSize(null);
      t.view.physicalSize = const Size(1366, 768);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        RepaintBoundary(
          key: _pageKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: officeTheme(),
            home: Column(
              children: [
                Container(height: _navBar, color: const Color(0xFF14213D)),
                Expanded(
                  child: ServicesCatalogScreen(key: UniqueKey(), load: () => never.future, canEdit: true),
                ),
              ],
            ),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 300));
      await _shot(t, 'list_loading_1366x768');
      never.complete(prodLikeCatalog());
      await t.pumpAndSettle();
    });
  }
}
