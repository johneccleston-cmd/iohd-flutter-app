import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dashboard_kit.dart';

// The menus of the Products & Services block (the tax select, a line's actions, "Tax, discounts & fees", New option,
// Option actions), with one look and one motion of their own. Nothing outside the block uses them: the app's other
// menus keep Material's.
//
// The look: a white panel with a hairline and a soft two-layer shadow, items on an inset highlight (radius 6) that
// follows the pointer and the arrow keys, a check for the current choice of a select.
//
// The motion (round 2, user 2026-11-13: "quicker, scale-and-fade, natural movement from the trigger"; smoother in and
// out, user 2026-11-23, when the 160 ms version read as a plain pop): [PsPopMotion]. The panel unrolls out of its
// trigger: it is uncovered from the trigger's side (from 45% of its height), grows from 94% out of the corner nearest
// the trigger and slides 8 px away from it, while it fades in over the first half. Opening takes 200 ms (the Tax,
// discounts & fees panel, much bigger, 240 ms) on an ease-out-cubic, so the movement is spread across the frames
// instead of spent in the first two. Closing takes 150 ms (the panel 170 ms): it rolls back up into the trigger, quick
// at first, and fades over the second half, gone just before it is, so it never just vanishes and never lingers. A close that starts
// while the panel is still opening reverses from where it is, so a quick click-click never jumps. With reduce motion it
// opens and closes at once.
//
// Where it opens: under its trigger, lined up with the trigger's start (or end, for the menus at a row's right edge);
// over the trigger when there is more room there, as near the window's bottom edge; kept 8 px inside the window. A list
// too tall for the room scrolls.
//
// Keyboard: the panel takes focus as it opens. Up / Down (and Tab / Shift+Tab) move the highlight, wrapping round, Home /
// End jump to the ends, Enter or Space picks, Esc closes; focus goes back to whatever had it before (the open line's
// field, the button that opened it).

/// Which edge of its trigger a menu lines up with.
enum PsMenuAlign { start, end }

/// One entry in a menu: a choice, a small heading over a group of choices, or a rule between groups.
sealed class PsMenuEntry<T> {
  const PsMenuEntry();
}

/// A choice. [trailing] is a quiet figure at its end ("10.5%"); [selected] puts the select's check on it.
class PsMenuItem<T> extends PsMenuEntry<T> {
  final T value;
  final String label;
  final IconData? icon;
  final String? trailing;
  final bool selected;
  final bool enabled;

  /// A choice that removes something (Delete): red.
  final bool danger;

  /// The icon's own colour where it carries meaning (the recommended option's amber star); slate otherwise. Greyed out
  /// with the choice.
  final Color? iconColor;
  const PsMenuItem(this.value, this.label, {this.icon, this.trailing, this.selected = false, this.enabled = true, this.danger = false, this.iconColor});
}

/// A small heading over a group of choices. [maxLines] above 1 lets a long one (where an option stands: "Accepted ...
/// · price locked · sent to job #...") wrap instead of being cut to one line; the menu makes room for the lines it takes.
class PsMenuHeading<T> extends PsMenuEntry<T> {
  final String label;
  final int maxLines;
  const PsMenuHeading(this.label, {this.maxLines = 1});
}

class PsMenuDivider<T> extends PsMenuEntry<T> {
  const PsMenuDivider();
}

/// The motion's timing (see the top of this file).
const kPsMenuOpen = Duration(milliseconds: 200);
const kPsMenuClose = Duration(milliseconds: 150);

/// The Tax, discounts & fees panel's timing: a bigger panel travels further, so it gets a little longer.
const kPsPanelOpen = Duration(milliseconds: 240);
const kPsPanelClose = Duration(milliseconds: 170);

/// A P&S popup's entrance and exit (see the top of the file), driven by its route's [animation]. [down]: it opens under
/// its trigger (it unrolls downward); [origin] is the corner nearest the trigger.
class PsPopMotion extends StatefulWidget {
  final Animation<double> animation;
  final bool down;
  final Alignment origin;
  final Widget child;
  const PsPopMotion({super.key, required this.animation, required this.down, required this.origin, required this.child});

  @override
  State<PsPopMotion> createState() => _PsPopMotionState();
}

class _PsPopMotionState extends State<PsPopMotion> {
  late CurvedAnimation _fade;
  late CurvedAnimation _move;

  void _curves() {
    _fade = CurvedAnimation(
      parent: widget.animation,
      curve: const Interval(0, 0.5, curve: Curves.easeOut),
      // Closing: it stays nearly solid while it rolls back and fades over the second half, gone just before the end.
      reverseCurve: const Interval(0.2, 1, curve: Curves.easeOut),
    );
    _move = CurvedAnimation(parent: widget.animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
  }

  @override
  void initState() {
    super.initState();
    _curves();
  }

  @override
  void didUpdateWidget(PsPopMotion old) {
    super.didUpdateWidget(old);
    if (old.animation != widget.animation) {
      _fade.dispose();
      _move.dispose();
      _curves();
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    _move.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _fade,
    child: AnimatedBuilder(
      animation: _move,
      builder: (context, child) {
        final m = _move.value;
        if (m >= 1) return child!;
        return ClipRect(
          clipper: _Unroll(0.45 + 0.55 * m, down: widget.down),
          child: Transform.translate(
            offset: Offset(0, (widget.down ? -8 : 8) * (1 - m)),
            child: Transform.scale(scale: 0.94 + 0.06 * m, alignment: widget.origin, child: child),
          ),
        );
      },
      child: widget.child,
    ),
  );
}

/// How much of a popup is uncovered: [shown] of its height from the trigger's side. The sides and the far edge keep
/// room for the panel's shadow, so only the moving edge cuts.
class _Unroll extends CustomClipper<Rect> {
  final double shown;
  final bool down;
  const _Unroll(this.shown, {required this.down});

  static const _shadow = 32.0;

  @override
  Rect getClip(Size size) {
    final reach = (size.height + 2 * _shadow) * shown;
    return down
        ? Rect.fromLTRB(-_shadow, -_shadow, size.width + _shadow, -_shadow + reach)
        : Rect.fromLTRB(-_shadow, size.height + _shadow - reach, size.width + _shadow, size.height + _shadow);
  }

  @override
  bool shouldReclip(_Unroll old) => old.shown != shown || old.down != down;
}

/// Opens a menu under (or over) the widget whose [context] is given, and gives back what was picked, or null.
///
/// [width] is the panel's width; with [matchAnchorWidth] it is at least as wide as the trigger (a select). [checks]
/// keeps room at each item's start for the current choice's check, so the labels line up.
Future<T?> showPsMenu<T>({
  required BuildContext context,
  required List<PsMenuEntry<T>> entries,
  double width = 240,
  PsMenuAlign align = PsMenuAlign.start,
  bool matchAnchorWidth = false,
  bool checks = false,
  String? label,
}) {
  final nav = Navigator.of(context);
  final overlay = nav.overlay!.context.findRenderObject()! as RenderBox;
  final box = context.findRenderObject()! as RenderBox;
  final anchor = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  return nav.push(
    _PsMenuRoute<T>(
      anchor: anchor,
      entries: entries,
      width: matchAnchorWidth ? math.max(width, anchor.width) : width,
      align: align,
      checks: checks,
      label: label,
      still: MediaQuery.disableAnimationsOf(context),
      themes: InheritedTheme.capture(from: context, to: nav.context),
    ),
  );
}

/// A trigger for a menu that knows while its menu is open (for a turned chevron or a pressed look) and never opens a
/// second one over the first (a double click, Enter held down).
class PsMenuButton<T> extends StatefulWidget {
  /// The trigger, given whether its menu is open and what opens it (null while [enabled] is false).
  final Widget Function(BuildContext context, bool open, VoidCallback? show) builder;
  final List<PsMenuEntry<T>> Function() entries;
  final ValueChanged<T> onSelected;
  final double width;
  final PsMenuAlign align;
  final bool matchAnchorWidth;
  final bool checks;
  final bool enabled;
  final String? label;
  const PsMenuButton({
    super.key,
    required this.builder,
    required this.entries,
    required this.onSelected,
    this.width = 240,
    this.align = PsMenuAlign.start,
    this.matchAnchorWidth = false,
    this.checks = false,
    this.enabled = true,
    this.label,
  });

  @override
  State<PsMenuButton<T>> createState() => _PsMenuButtonState<T>();
}

class _PsMenuButtonState<T> extends State<PsMenuButton<T>> {
  bool _open = false;

  Future<void> _show() async {
    if (_open || !mounted) return;
    setState(() => _open = true);
    final v = await showPsMenu<T>(
      context: context,
      entries: widget.entries(),
      width: widget.width,
      align: widget.align,
      matchAnchorWidth: widget.matchAnchorWidth,
      checks: widget.checks,
      label: widget.label,
    );
    if (!mounted) return;
    setState(() => _open = false);
    if (v != null) widget.onSelected(v);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _open, widget.enabled ? _show : null);
}

class _PsMenuRoute<T> extends PopupRoute<T> {
  final Rect anchor;
  final List<PsMenuEntry<T>> entries;
  final double width;
  final PsMenuAlign align;
  final bool checks;
  final String? label;
  final bool still;
  final CapturedThemes themes;
  _PsMenuRoute({
    required this.anchor,
    required this.entries,
    required this.width,
    required this.align,
    required this.checks,
    required this.label,
    required this.still,
    required this.themes,
  });

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Close the menu';

  @override
  Duration get transitionDuration => still ? Duration.zero : kPsMenuOpen;

  @override
  Duration get reverseTransitionDuration => still ? Duration.zero : kPsMenuClose;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) => themes.wrap(_PsMenuPage<T>(route: this));
}

/// The gap between a trigger and its menu, and the least room the menu keeps from the window's edges.
const _gap = 4.0, _margin = 8.0;

/// The panel's padding, and its entries' heights at the reader's text size: fixed, so where the menu goes (under or over
/// its trigger) is known before it is laid out.
const _pad = 6.0;
double _itemH(TextScaler s) => math.max(36, (s.scale(13.5) * 1.3).ceilToDouble() + 16);
double _headH(TextScaler s) => math.max(28, (s.scale(12) * 1.3).ceilToDouble() + 12);
const _headStyle = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.ink, letterSpacing: 0.2, height: 1.3);
const _ruleH = 11.0;

class _PsMenuPage<T> extends StatefulWidget {
  final _PsMenuRoute<T> route;
  const _PsMenuPage({super.key, required this.route});

  @override
  State<_PsMenuPage<T>> createState() => _PsMenuPageState<T>();
}

class _PsMenuPageState<T> extends State<_PsMenuPage<T>> {
  final _focus = FocusNode(debugLabel: 'menu');
  final _scroll = ScrollController();

  /// The highlighted choice (an index into the route's entries), from the pointer or the arrow keys.
  int? _hi;
  int? _pressed;
  bool _done = false;

  _PsMenuRoute<T> get _r => widget.route;

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<int> get _choices => [
    for (var i = 0; i < _r.entries.length; i++)
      if (_r.entries[i] case PsMenuItem<T>(enabled: true)) i,
  ];

  void _step(int by) {
    final c = _choices;
    if (c.isEmpty) return;
    int next;
    final at = _hi == null ? -1 : c.indexOf(_hi!);
    if (at < 0) {
      // First press: the current choice of a select, else the first (Up: the last).
      final sel = c.where((i) => (_r.entries[i] as PsMenuItem<T>).selected).firstOrNull;
      next = sel ?? (by > 0 ? c.first : c.last);
    } else {
      next = c[(at + by) % c.length];
    }
    setState(() => _hi = next);
    _reveal(next);
  }

  void _jump(bool last) {
    final c = _choices;
    if (c.isEmpty) return;
    setState(() => _hi = last ? c.last : c.first);
    _reveal(_hi!);
  }

  /// Keeps a highlighted choice in view in a list that scrolls.
  void _reveal(int index) {
    if (!_scroll.hasClients) return;
    final s = MediaQuery.textScalerOf(context);
    var top = _pad; // the list's own padding comes first
    for (var i = 0; i < index; i++) {
      top += _heightOf(_r.entries[i], s);
    }
    final h = _heightOf(_r.entries[index], s);
    final view = _scroll.position.viewportDimension;
    final off = _scroll.offset;
    if (top < off) _scroll.jumpTo(top);
    if (top + h > off + view) _scroll.jumpTo(top + h - view);
  }

  void _pick(int index) {
    if (_done) return;
    final e = _r.entries[index];
    if (e is! PsMenuItem<T> || !e.enabled) return;
    _done = true;
    Navigator.of(context).pop(e.value);
  }

  double _heightOf(PsMenuEntry<Object?> e, TextScaler s) => switch (e) {
    PsMenuItem() => _itemH(s),
    final PsMenuHeading<Object?> h => _headingH(h, s),
    PsMenuDivider() => _ruleH,
  };

  /// A heading's height: one line's, or as many lines as a wrapping one ([PsMenuHeading.maxLines]) takes at the menu's
  /// width and the reader's text size.
  double _headingH(PsMenuHeading<Object?> h, TextScaler s) {
    if (h.maxLines <= 1) return _headH(s);
    final menuW = math.min(_r.width, MediaQuery.sizeOf(context).width - 2 * _margin);
    final p = TextPainter(
      text: TextSpan(text: h.label, style: DefaultTextStyle.of(context).style.merge(_headStyle)),
      textDirection: Directionality.of(context),
      textScaler: s,
      maxLines: h.maxLines,
      ellipsis: '…',
    )..layout(maxWidth: math.max(0.0, menuW - 2 * _pad - 2 - (_r.checks ? 32 : 10) - 10));
    final lines = p.height;
    p.dispose();
    return math.max(_headH(s), lines.ceilToDouble() + 12);
  }

  @override
  Widget build(BuildContext context) {
    final s = MediaQuery.textScalerOf(context);
    final natural = _r.entries.fold<double>(2 * _pad + 2, (h, e) => h + _heightOf(e, s));
    return LayoutBuilder(
      builder: (context, c) {
        final size = c.biggest;
        final a = _r.anchor;
        final below = size.height - a.bottom - _gap - _margin;
        final above = a.top - _gap - _margin;
        // Under the trigger, unless it doesn't fit there and there is more room over it.
        final down = natural <= below || below >= above;
        final h = math.max(0.0, math.min(natural, down ? below : above));
        final w = math.min(_r.width, size.width - 2 * _margin);
        final start = _r.align == PsMenuAlign.start;
        final left = (start ? a.left : a.right - w).clamp(_margin, math.max(_margin, size.width - _margin - w)).toDouble();
        final top = down ? a.bottom + _gap : a.top - _gap - h;
        // It grows out of the corner nearest the trigger.
        final origin = Alignment(start ? -1 : 1, down ? -1 : 1);
        return Stack(
          children: [
            Positioned(
              left: left,
              top: top,
              width: w,
              height: h,
              child: PsPopMotion(animation: _r.animation!, down: down, origin: origin, child: _panel(natural > h + 0.5)),
            ),
          ],
        );
      },
    );
  }

  Widget _panel(bool scrolls) {
    final s = MediaQuery.textScalerOf(context);
    final items = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _r.entries.length; i++)
          switch (_r.entries[i]) {
            final PsMenuItem<T> e => _Item(
              entry: e,
              height: _itemH(s),
              checks: _r.checks,
              highlighted: _hi == i,
              pressed: _pressed == i,
              onHover: (on) => setState(() => _hi = on ? i : (_hi == i ? null : _hi)),
              onPress: (down) => setState(() => _pressed = down ? i : null),
              onTap: () => _pick(i),
            ),
            final PsMenuHeading<T> e => Container(
              height: _headingH(e, s),
              alignment: Alignment.bottomLeft,
              padding: EdgeInsets.fromLTRB(_r.checks ? 32 : 10, 0, 10, 6),
              child: Text(e.label, maxLines: e.maxLines, overflow: TextOverflow.ellipsis, style: _headStyle),
            ),
            PsMenuDivider<T>() => const Padding(
              padding: EdgeInsets.symmetric(vertical: 5, horizontal: 4),
              child: Divider(height: 1, thickness: 1, color: DashUi.line),
            ),
          },
      ],
    );
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: _r.label ?? 'Menu',
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowDown): _Step(1),
          SingleActivator(LogicalKeyboardKey.arrowUp): _Step(-1),
          SingleActivator(LogicalKeyboardKey.tab): _Step(1),
          SingleActivator(LogicalKeyboardKey.tab, shift: true): _Step(-1),
          SingleActivator(LogicalKeyboardKey.home): _Jump(false),
          SingleActivator(LogicalKeyboardKey.end): _Jump(true),
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        child: Actions(
          actions: {
            _Step: CallbackAction<_Step>(onInvoke: (i) => _step(i.by)),
            _Jump: CallbackAction<_Jump>(onInvoke: (i) => _jump(i.last)),
            ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _hi == null ? null : _pick(_hi!)),
          },
          child: Focus(
            focusNode: _focus,
            autofocus: true,
            // A click anywhere in the panel that isn't a choice (a greyed-out one, a heading, a rule, the panel's edge)
            // does nothing, and must not reach the page's text selection above the navigator ([AppSelection]): it
            // took the keyboard on the press, so Esc and the arrows no longer reached the menu (P&S final polish,
            // 2026-11-23). The tap is claimed here; a press that still lets focus go (a drag) gives it back.
            child: Listener(
              onPointerUp: (_) => _keepFocus(),
              onPointerCancel: (_) => _keepFocus(),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: SelectionContainer.disabled(child: _surface(scrolls, items)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// After a press inside the panel: the menu keeps the keyboard unless that press picked (and so closed) it.
  void _keepFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_done && !_focus.hasFocus) _focus.requestFocus();
    });
  }

  /// The panel itself: white, its hairline and shadow, the choices (scrolling when they don't fit).
  Widget _surface(bool scrolls, Widget items) => MouseRegion(
    onExit: (_) => setState(() => _hi = null),
    child: Material(
      type: MaterialType.transparency,
      child: Container(
        decoration: psMenuPanelDecoration(),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: scrolls
              ? Scrollbar(
                  controller: _scroll,
                  child: SingleChildScrollView(controller: _scroll, padding: const EdgeInsets.all(_pad), child: items),
                )
              : Padding(padding: const EdgeInsets.all(_pad), child: items),
        ),
      ),
    ),
  );
}

class _Step extends Intent {
  final int by;
  const _Step(this.by);
}

class _Jump extends Intent {
  final bool last;
  const _Jump(this.last);
}

/// One choice: an inset highlight under the pointer or the arrow keys, a touch darker while pressed.
class _Item<T> extends StatelessWidget {
  final PsMenuItem<T> entry;
  final double height;
  final bool checks;
  final bool highlighted;
  final bool pressed;
  final ValueChanged<bool> onHover;
  final ValueChanged<bool> onPress;
  final VoidCallback onTap;
  const _Item({
    required this.entry,
    required this.height,
    required this.checks,
    required this.highlighted,
    required this.pressed,
    required this.onHover,
    required this.onPress,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final on = e.enabled;
    final tone = !on ? DashUi.muted : (e.danger ? DashUi.redText : DashUi.ink);
    final fill = !on
        ? Colors.white
        : pressed
        ? (e.danger ? DashUi.red.withValues(alpha: 0.12) : DashUi.line)
        : highlighted
        ? (e.danger ? DashUi.red.withValues(alpha: 0.07) : DashUi.faint)
        : Colors.white;
    final still = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      enabled: on,
      selected: e.selected,
      label: e.trailing == null ? e.label : '${e.label}, ${e.trailing}',
      excludeSemantics: true,
      onTap: on ? onTap : null,
      child: MouseRegion(
        cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: on ? (_) => onHover(true) : null,
        onExit: on ? (_) => onHover(false) : null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: on ? (_) => onPress(true) : null,
          onTapCancel: on ? () => onPress(false) : null,
          onTap: on ? onTap : null,
          child: AnimatedContainer(
            duration: still ? Duration.zero : const Duration(milliseconds: 90),
            curve: Curves.easeOut,
            height: height,
            padding: EdgeInsets.only(left: checks ? 8 : 10, right: 10),
            decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(6)),
            child: Row(
              children: [
                if (checks) SizedBox(width: 24, child: e.selected ? const Icon(Icons.check_rounded, size: 17, color: DashUi.ink) : null),
                if (e.icon != null) ...[
                  Icon(e.icon, size: 17, color: on ? (e.danger ? DashUi.redText : (e.iconColor ?? DashUi.slate)) : DashUi.muted),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(
                    e.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, color: tone, fontWeight: e.selected || e.danger ? FontWeight.w600 : FontWeight.w500, height: 1.3),
                  ),
                ),
                if (e.trailing != null) ...[
                  const SizedBox(width: 12),
                  Text(
                    e.trailing!,
                    style: TextStyle(fontSize: 12.5, color: tone, height: 1.3, fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The catalog search's results: the same entrance as the menus, growing from the field's side (they close with the
/// search itself, at once: a pick has to land without waiting on the list).
class PsMenuEntrance extends StatefulWidget {
  /// The list opens upward (it is over the field).
  final bool up;
  final Widget child;
  const PsMenuEntrance({super.key, required this.up, required this.child});

  @override
  State<PsMenuEntrance> createState() => _PsMenuEntranceState();
}

class _PsMenuEntranceState extends State<PsMenuEntrance> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: kPsMenuOpen);
  late final _fade = CurvedAnimation(
    parent: _c,
    curve: const Interval(0, 0.5, curve: Curves.easeOut),
  );
  late final _move = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c.isDismissed) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _c.value = 1;
      } else {
        _c.forward();
      }
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    _move.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _fade,
    child: AnimatedBuilder(
      animation: _move,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, (widget.up ? 8 : -8) * (1 - _move.value)),
        child: Transform.scale(scale: 0.94 + 0.06 * _move.value, alignment: widget.up ? Alignment.bottomLeft : Alignment.topLeft, child: child),
      ),
      child: widget.child,
    ),
  );
}

/// The menus' panel, for a popover that isn't a menu of choices (the catalog search's results): white, a hairline, the
/// soft shadow.
BoxDecoration psMenuPanelDecoration() => BoxDecoration(
  color: Colors.white,
  borderRadius: BorderRadius.circular(10),
  border: Border.all(color: DashUi.line),
  boxShadow: [
    BoxShadow(color: DashUi.ink.withValues(alpha: 0.06), blurRadius: 3, offset: const Offset(0, 1)),
    BoxShadow(color: DashUi.ink.withValues(alpha: 0.10), blurRadius: 24, spreadRadius: -6, offset: const Offset(0, 10)),
  ],
);
