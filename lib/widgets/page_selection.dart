import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show Selectable, SelectionRegistrar;

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
    // Text does not bring its own I-beam: left alone, every label inside a button, tab, menu row or tile showed the
    // I-beam over the button's hand. With `defer`, text takes the cursor of whatever it sits in: the hand on anything
    // clickable, the I-beam in an input box (the box sets it), the arrow elsewhere.
    builder: (context) => DefaultSelectionStyle.merge(
      mouseCursor: MouseCursor.defer,
      child: SelectionArea(child: PageSelection(child: widget.child)),
    ),
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
/// (nesting groups confused where a drag starts). While it is covered, its text registers with a registrar that keeps
/// nothing. Only the registrar changes: the screen stays where it is in the tree. (It used to be moved under a
/// `SelectionContainer.disabled` with a GlobalKey, and moving a whole screen like that broke pages with lists in them,
/// such as the job page: "Duplicate GlobalKeys" and detached parts every time a dialog or menu opened over it.)
class RouteSelection extends StatelessWidget {
  final Widget child;
  const RouteSelection({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final onTop = ModalRoute.isCurrentOf(context) ?? true;
    final group = SelectionContainer.maybeOf(context);
    if (group == null) return child; // no selection area above (tests that pump a screen on its own)
    return SelectionRegistrarScope(registrar: onTop ? group : _covered, child: child);
  }
}

/// The nav shell's tabs, one per menu (go_router's indexedStack container, plus selection). The hidden tabs stay laid
/// out at full size behind the one on screen, so their text sits at the same place as the visible tab's. Left in the
/// selection, highlighting the job number in a job's ribbon also picked up the hidden Product Catalog ribbon's title
/// in the same spot. A hidden tab's text registers nowhere, as a covered screen's does.
class BranchStack extends StatelessWidget {
  final int currentIndex;
  final List<Widget> children;
  const BranchStack({super.key, required this.currentIndex, required this.children});

  @override
  Widget build(BuildContext context) {
    final group = SelectionContainer.maybeOf(context);
    return IndexedStack(
      index: currentIndex,
      children: [
        for (var i = 0; i < children.length; i++)
          Offstage(
            offstage: i != currentIndex,
            child: TickerMode(
              enabled: i == currentIndex,
              child: group == null ? children[i] : SelectionRegistrarScope(registrar: i == currentIndex ? group : _covered, child: children[i]),
            ),
          ),
      ],
    );
  }
}

/// Where a covered screen's text registers: nowhere.
final _covered = _NoSelection();

class _NoSelection implements SelectionRegistrar {
  @override
  void add(Selectable selectable) {}

  @override
  void remove(Selectable selectable) {}
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

  /// Where [s] sits on screen, or null if it can't be measured yet. Text on a page that is still loading, or on a
  /// page the nav shell keeps alive offstage, has no layout; reading its size throws, and in release that throw
  /// left the page as a blank grey box.
  static Rect? _box(Selectable s) {
    try {
      final boxes = s.boundingBoxes;
      if (boxes.isEmpty) return null;
      var r = boxes.first;
      for (var i = 1; i < boxes.length; i++) {
        r = r.expandToInclude(boxes[i]);
      }
      return MatrixUtils.transformRect(s.getTransformTo(null), r);
    } catch (_) {
      return null;
    }
  }

  @override
  Comparator<Selectable> get compareOrder => (a, b) {
        final ra = _box(a);
        final rb = _box(b);
        // Unmeasured text goes last, so the order stays consistent.
        if (ra == null || rb == null) return (ra == null ? 1 : 0) - (rb == null ? 1 : 0);
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

/// The pointer over [child], words included. Flutter's own popup button (and other widgets that take a `child` and
/// bring their own cursor) show the arrow on Windows and macOS, so a button face built from a Container and a Text
/// is wrapped in this. A bare [MouseRegion] is not enough: the words in the face pick their own cursor first.
class ClickCursor extends StatelessWidget {
  const ClickCursor({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: DefaultSelectionStyle.merge(mouseCursor: SystemMouseCursors.click, child: child),
      );
}
