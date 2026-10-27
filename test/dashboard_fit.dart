// What every redesigned dashboard has to pass at the desktop window sizes: nothing overflows, nothing scrolls
// vertically (no scrolling page and no scrolling panel inside it), the key figures are on screen, and at normal text
// size no text is cut short with an ellipsis. Builds on dashboard_harness.dart; screenshots go to build/dash_shots/.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dashboard_harness.dart';

/// The window sizes the dashboards must fit without scrolling (the ones the Collections redesign was checked at),
/// and the two at 130% text.
const dashFitSizes = <(Size, double, String)>[
  (Size(1280, 600), 1.0, '1280x600'),
  (Size(1280, 720), 1.0, '1280x720'),
  (Size(1366, 768), 1.0, '1366x768'),
  (Size(1500, 800), 1.0, '1500x800'),
  (Size(1920, 940), 1.0, '1920x940'),
  (Size(1280, 600), 1.3, '1280x600_text130'),
  (Size(1500, 800), 1.3, '1500x800_text130'),
];

/// Vertical scroll areas on screen (a page or a panel that scrolls up and down).
List<String> dashVerticalScrollers(WidgetTester t) => [
  for (final s in t.widgetList<Scrollable>(find.byType(Scrollable)))
    if (axisDirectionToAxis(s.axisDirection) == Axis.vertical) '${s.runtimeType}(${s.axisDirection})',
];

/// Text on screen that is cut short (an ellipsis, or lines dropped).
List<String> dashTruncatedTexts(WidgetTester t) {
  final out = <String>[];
  for (final e in find.byType(RichText).evaluate()) {
    final ro = e.renderObject;
    if (ro is RenderParagraph && ro.hasSize && ro.didExceedMaxLines) {
      out.add(ro.text.toPlainText());
    }
  }
  return out;
}

/// The rectangle of the first widget showing [text] (exact match first, then a substring).
Rect dashTextRect(WidgetTester t, String text) {
  final exact = find.text(text);
  final f = exact.evaluate().isNotEmpty ? exact.first : find.textContaining(text).first;
  return t.getRect(f);
}

/// Pumps [screen] at each of [dashFitSizes] and checks the rules above. [mustShow] are texts whose whole box has to
/// be inside the window. [extra] runs more checks at each size.
void dashFitTests(
  String name,
  Widget Function() screen,
  DashFakeApi Function() api, {
  required List<String> mustShow,
  Future<void> Function(WidgetTester t, Size size, double scale)? extra,
  List<(Size, double, String)> sizes = dashFitSizes,
}) {
  for (final (size, scale, tag) in sizes) {
    testWidgets('$name $tag: everything on screen, nothing scrolls, no overflow', (t) async {
      late List<String> scrollers;
      late List<String> truncated;
      final errors = await pumpDashboard(t, screen(), api: api(), size: size, textScale: scale, body: () async {
        await saveDashShot(t, '${name}_$tag');
        scrollers = dashVerticalScrollers(t);
        truncated = dashTruncatedTexts(t);
        final window = Offset.zero & size;
        for (final text in mustShow) {
          final r = dashTextRect(t, text);
          expect(window.contains(r.topLeft) && window.contains(r.bottomRight - const Offset(0.01, 0.01)), isTrue,
              reason: '"$text" is on screen at $tag ($r)');
        }
        if (extra != null) await extra(t, size, scale);
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.toSet().join('\n'));
      expect(t.takeException(), isNull);
      expect(scrollers, isEmpty, reason: 'the dashboard never scrolls vertically at $tag');
      if (scale == 1.0) {
        expect(truncated, isEmpty, reason: 'no text is cut short at $tag');
      } else if (truncated.isNotEmpty) {
        // At 130% a long name may be shortened with an ellipsis (its full text is a hover away), as on Collections.
        // ignore: avoid_print
        print('$name $tag shortened: ${truncated.toSet().join(' | ')}');
      }
    });
  }
}
