import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dashboard_kit.dart';

/// Whether the keyboard is what the person is using right now, like the browser's `:focus-visible`: true after a key
/// press, false after a mouse, pen or touch press. Flutter's own highlight mode stays "traditional" for a mouse too, so a
/// control that gets the keyboard back after a click (a menu's trigger once a row is picked) would show its ring.
class FocusVisible {
  FocusVisible._();

  static final ValueNotifier<bool> keyboard = ValueNotifier<bool>(false);
  static bool _pointerStarted = false;

  static bool _onKey(KeyEvent e) {
    // Modifiers alone (Ctrl held for a shortcut, Shift for a range) don't count as using the keyboard to move.
    if (e is KeyDownEvent && !_modifiers.contains(e.logicalKey)) keyboard.value = true;
    return false;
  }

  static void _onPointer(PointerEvent e) {
    if (e is PointerDownEvent) keyboard.value = false;
  }

  /// Starts listening; [FocusRing] calls it as each ring is built. The key handler is put back each time (removing it
  /// first, so there is only ever one): the test binding clears the keyboard's handlers between tests.
  static void ensureStarted() {
    HardwareKeyboard.instance
      ..removeHandler(_onKey)
      ..addHandler(_onKey);
    if (_pointerStarted) return;
    _pointerStarted = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }

  static final Set<LogicalKeyboardKey> _modifiers = {
    LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.altLeft, LogicalKeyboardKey.altRight, LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaRight,
  };
}

/// Keyboard focus, drawn one way everywhere (interaction standard, UX audit 2026-11-20).
///
/// A 2 px ink ring around the control while it (or something inside it) has the keyboard, and only while the keyboard
/// is in use: a mouse click never leaves a ring behind. It fades in over 90 ms (at once with reduced motion) and takes no
/// room, so nothing moves when it appears.
///
/// Why a widget of its own: the catalog screens drew focus as Material ink (`InkWell.focusColor`). Ink paints on the
/// nearest `Material`, which sits under the screens' white panels, so the status tabs, the column headers, the pick
/// boxes and the service page's toggles showed no focus at all in the real app (found by tabbing through it in Chrome).
/// Others drew a grey fill or a ring of their own. This draws on top of the control, whatever is under it.
///
/// Wrap the focusable widget (an InkWell, a FocusableActionDetector...): the ring follows the focus of anything inside.
/// [outset] moves the ring out from the child's edge (negative values pull it in, e.g. round the box inside a larger
/// tap target).
class FocusRing extends StatefulWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsets outset;
  final Color color;
  const FocusRing({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.outset = EdgeInsets.zero,
    this.color = DashUi.ink,
  });

  /// The ring's width. Text boxes keep their own 1.5 px focused edge; a ring round a control is 2 px (WCAG 2.4.13).
  static const double width = 2;

  @override
  State<FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<FocusRing> {
  bool _has = false;

  @override
  void initState() {
    super.initState();
    FocusVisible.ensureStarted();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final o = widget.outset;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (v) => setState(() => _has = v),
      child: Stack(
        // The child gets exactly the constraints it would get without the ring, so wrapping changes no layout.
        fit: StackFit.passthrough,
        clipBehavior: Clip.none,
        children: [
          widget.child,
          Positioned(
            left: -o.left,
            top: -o.top,
            right: -o.right,
            bottom: -o.bottom,
            child: IgnorePointer(
              child: ValueListenableBuilder<bool>(
                valueListenable: FocusVisible.keyboard,
                builder: (context, keyboard, ring) => AnimatedOpacity(
                  opacity: _has && keyboard ? 1 : 0,
                  duration: reduced ? Duration.zero : const Duration(milliseconds: 90),
                  child: ring,
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: widget.borderRadius,
                    border: Border.all(color: widget.color, width: FocusRing.width),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
