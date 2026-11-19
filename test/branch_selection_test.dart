// Highlighting text on one menu tab must not pick up text from the tabs the nav shell keeps alive behind it. The hidden
// tabs stay laid out at full size, so a job ribbon's number and the hidden Product Catalog ribbon's title sat in the
// same spot, and copying the job number gave "PRODUCT CATALOG 1101296053".
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/widgets/page_selection.dart';

Widget _tab(String text) => Align(
  alignment: Alignment.topLeft,
  child: Padding(padding: const EdgeInsets.all(20), child: Text(text, style: const TextStyle(fontSize: 20))),
);

Future<String> _dragCopy(WidgetTester t, Widget stack, Finder target) async {
  String? copied;
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
    return null;
  });
  await t.pumpWidget(MaterialApp(builder: appSelectionBuilder, home: Scaffold(body: stack)));
  await t.pumpAndSettle();
  final r = t.getRect(target);
  final g = await t.startGesture(r.centerLeft + const Offset(1, 0), kind: PointerDeviceKind.mouse);
  await t.pump(const Duration(milliseconds: 100));
  await g.moveTo(r.centerRight - const Offset(1, 0));
  await t.pump(const Duration(milliseconds: 100));
  await g.up();
  await t.pumpAndSettle();
  t.state<SelectableRegionState>(find.byType(SelectableRegion).first)
    // ignore: deprecated_member_use
    .copySelection(SelectionChangedCause.keyboard);
  await t.pump();
  return copied ?? '';
}

void main() {
  final job = find.text('1101296053');

  testWidgets('a hidden tab\'s text is not copied with the visible tab\'s', variant: TargetPlatformVariant.only(TargetPlatform.windows), (t) async {
    final out = await _dragCopy(t, BranchStack(currentIndex: 0, children: [_tab('1101296053'), _tab('PRODUCT CATALOG')]), job);
    expect(out, contains('1101296053'));
    expect(out, isNot(contains('PRODUCT')));
  });

  testWidgets('the tab that is showing can be copied after switching to it', variant: TargetPlatformVariant.only(TargetPlatform.windows), (t) async {
    final out = await _dragCopy(t, BranchStack(currentIndex: 1, children: [_tab('PRODUCT CATALOG'), _tab('1101296053')]), job);
    expect(out, contains('1101296053'));
    expect(out, isNot(contains('PRODUCT')));
  });

  testWidgets('control: go_router\'s plain stack picks up the hidden tab (the bug)', variant: TargetPlatformVariant.only(TargetPlatform.windows), (t) async {
    final plain = IndexedStack(
      index: 0,
      children: [
        _tab('1101296053'),
        Offstage(child: TickerMode(enabled: false, child: _tab('PRODUCT CATALOG'))),
      ],
    );
    final out = await _dragCopy(t, plain, job);
    expect(out, contains('PRODUCT'));
  });
}
