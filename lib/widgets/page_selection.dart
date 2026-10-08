import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show Selectable;

/// Makes all text in the app highlightable and copyable with the mouse, like on a normal website: every page, dialog,
/// pop-up and the sign-in screen. Wire it up once, in `MaterialApp.router(builder: appSelectionBuilder)`.
Widget appSelectionBuilder(BuildContext context, Widget? child) => AppSelection(child: child ?? const SizedBox.shrink());

/// Sits above the app's navigator, so everything the navigator shows (pages, dialogs, menus) is inside one
/// [SelectionArea]. The selection toolbar and handles need an [Overlay] above them, and there isn't one above the
/// navigator, so this adds its own.
class AppSelection extends StatefulWidget {
  final Widget child;
  const AppSelection({super.key, required this.child});

  @override
  State<AppSelection> createState() => _AppSelectionState();
}

class _AppSelectionState extends State<AppSelection> {
  late final OverlayEntry _entry = OverlayEntry(
    builder: (context) => SelectionArea(child: PageSelection(child: widget.child)),
  );

  @override
  void didUpdateWidget(covariant AppSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    _entry.markNeedsBuild();
  }

  @override
  void dispose() {
    _entry.remove();
    _entry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_entry]);
}

/// Wraps a whole screen (the main shell, the sign-in page). While another route is on top of it, such as a dialog or a
/// menu, the screen's text cannot be selected, so a drag inside the dialog never picks up the page behind it.
///
/// A screen that is on top is added to the app's selection group exactly as it is, with no extra group around it
/// (nesting groups confused where a drag starts). A GlobalKey keeps the screen's state when it is moved under the
/// "disabled" wrapper and back.
class RouteSelection extends StatefulWidget {
  final Widget child;
  const RouteSelection({super.key, required this.child});

  @override
  State<RouteSelection> createState() => _RouteSelectionState();
}

class _RouteSelectionState extends State<RouteSelection> {
  final _key = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final screen = KeyedSubtree(key: _key, child: widget.child);
    final onTop = ModalRoute.isCurrentOf(context) ?? true;
    return onTop ? screen : SelectionContainer.disabled(child: screen);
  }
}

/// Puts all the text under it into ONE selection group with a dependable reading order.
///
/// Flutter's [SelectionArea] orders the text on a page with a rule that compares two rectangles at a time ("same
/// row? then left to right, else top to bottom"). On a dashboard, with cards side by side and lines of different
/// heights, that rule is not consistent (A < B, B < C, but C < A), so the list ends up in a scrambled order. Starting
/// a drag then searches that list and lands on the wrong entry, and in the browser some text simply cannot be
/// highlighted (staff cards, scorecards, whole pages such as Inventory).
///
/// [PageSelection] swaps in an order that cannot contradict itself: text is placed into horizontal bands, then sorted
/// left to right inside a band. Use it directly inside a [SelectionArea].
class PageSelection extends StatefulWidget {
  final Widget child;
  const PageSelection({super.key, required this.child});

  @override
  State<PageSelection> createState() => _PageSelectionState();
}

class _PageSelectionState extends State<PageSelection> {
  final _delegate = _BandedDelegate();

  @override
  void dispose() {
    _delegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SelectionContainer(delegate: _delegate, child: widget.child);
}

class _BandedDelegate extends StaticSelectionContainerDelegate {
  /// Height of a band, in logical pixels. A little taller than one line of body text, so text on the same visual row
  /// lands in the same band.
  static const double _band = 22;

  static Rect _box(Selectable s) {
    var r = s.boundingBoxes.first;
    for (var i = 1; i < s.boundingBoxes.length; i++) {
      r = r.expandToInclude(s.boundingBoxes[i]);
    }
    return MatrixUtils.transformRect(s.getTransformTo(null), r);
  }

  @override
  Comparator<Selectable> get compareOrder => (a, b) {
        final ra = _box(a);
        final rb = _box(b);
        final ba = (ra.center.dy / _band).floor();
        final bb = (rb.center.dy / _band).floor();
        if (ba != bb) return ba.compareTo(bb);
        final byLeft = ra.left.compareTo(rb.left);
        if (byLeft != 0) return byLeft;
        final byTop = ra.top.compareTo(rb.top);
        if (byTop != 0) return byTop;
        return ra.right.compareTo(rb.right);
      };
}
