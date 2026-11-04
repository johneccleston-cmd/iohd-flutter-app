// Opens the account menu and the About box from the nav bar, and saves screenshots to test/shots/.
// Run:  flutter test test/about_render_test.dart --update-goldens

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iohd_desktop/config/app_info.dart';

import 'nav_fixture.dart';

void main() {
  setUpAll(loadNavFonts);

  testWidgets('account menu offers About, which shows version, company, support and copyright', (t) async {
    await navSignIn();
    await pumpNav(t, const Size(1440, 860));

    await http.runWithClient(() async {
      await t.tap(find.bySemanticsLabel('Account'));
      await t.pumpAndSettle();
      expect(find.text('About $kAppName'), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/about_menu.png'));

      await t.tap(find.text('About $kAppName'));
      await t.pumpAndSettle();
    }, navApi);

    expect(find.text(kAppVersion), findsOneWidget);
    expect(find.text(kCompanyName), findsOneWidget);
    expect(find.text(kSupportPhone), findsOneWidget);
    expect(find.text(kSupportEmail), findsOneWidget);
    expect(find.textContaining('All rights reserved'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/about_dialog.png'));
  });
}
