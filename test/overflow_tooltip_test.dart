import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/widgets/flat_page.dart';

// User rule 2026-11-23: no hover text that only repeats what is already on screen. A cut-short cell still shows its
// full wording on hover.
void main() {
  Future<void> pump(WidgetTester t, double width, Widget child) async {
    await t.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: width, child: child)))));
    await t.pump(); // the post-frame measurement
  }

  const name = 'Ridgeview Property Management Group of Northwest Arkansas';
  Widget cell() => const OverflowTooltip(message: name, child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis));

  // The test font draws every letter 14 px wide, so 'Acme Doors' needs 140 px.
  const short = OverflowTooltip(message: 'Acme Doors', child: Text('Acme Doors', maxLines: 1, overflow: TextOverflow.ellipsis));

  testWidgets('text that fits has no hover text', (t) async {
    await pump(t, 400, short);
    expect(find.byTooltip('Acme Doors'), findsNothing);
  });

  testWidgets('text cut short shows its full wording on hover', (t) async {
    await pump(t, 120, cell());
    expect(find.byTooltip(name), findsOneWidget);
  });

  testWidgets('widening the column takes the hover text away again', (t) async {
    await pump(t, 60, short);
    expect(find.byTooltip('Acme Doors'), findsOneWidget);
    await pump(t, 400, short);
    expect(find.byTooltip('Acme Doors'), findsNothing);
  });

  testWidgets('a link with nothing extra to say only explains itself when cut short', (t) async {
    await pump(t, 2000, FlatLink('1099563432', onTap: () {}));
    expect(find.byType(Tooltip).evaluate().where((e) => (e.widget as Tooltip).message!.isNotEmpty), isEmpty);
    await pump(t, 40, FlatLink('1099563432', onTap: () {}));
    expect(find.byTooltip('1099563432'), findsOneWidget);
  });

  testWidgets('a link tip that adds something is always there', (t) async {
    await pump(t, 2000, FlatLink('pi_123', tip: 'Open this payment in Stripe', onTap: () {}));
    expect(find.byTooltip('Open this payment in Stripe'), findsOneWidget);
  });
}
