import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'catalog_kit.dart';
import 'dashboard_kit.dart';
import 'focus_ring.dart';

/// One menu for the catalog screens (UX audit 2026-11-19). Before it, the Services Catalog had three kinds of menu that
/// each moved differently: the sort menu (PopupMenuButton) waited about 150 ms, then unrolled from its corner for 350 ms
/// with its items fading in one by one; the selection bar's Status menu (MenuAnchor) popped in with no motion at all; and
/// the service page's category list (DropdownButtonFormField) grew over its own field, hiding it, with 48 px rows and two
/// grey rows at once. Everything that opens a list now uses [AppMenu]:
///
///   * one motion: opens in 150 ms (fade, a 4 px drift away from the trigger and a 2% scale, ease-out), closes in 100 ms;
///     both instant when the system asks for reduced motion. No bounce, no stagger, no delay.
///   * one look: white, a hairline edge, a soft shadow, 10 px corners, 36 px rows; hover and keyboard focus are one
///     highlight (pointing at a row moves the keyboard there too), the current choice has a tick.
///   * placed under its trigger, 4 px away, never over it; above it when there is not room below; as wide as the trigger
///     for a select field; scrolls inside itself when it is longer than the window.
///   * keyboard: Up / Down (wrapping), Home / End, Enter or Space picks, Esc closes, Tab closes and moves on; focus goes
///     back to the trigger. A click outside closes it.
class AppMenuStyle {
  AppMenuStyle._();

  static const Duration openDuration = Duration(milliseconds: 150);
  static const Duration closeDuration = Duration(milliseconds: 100);
  static const Curve openCurve = Curves.easeOutCubic;
  static const Curve closeCurve = Curves.easeInCubic;

  /// How far the menu drifts in from (towards its trigger), and how much it grows, while opening.
  static const double drift = 4;
  static const double startScale = 0.98;

  static const double gap = 4; // between the trigger and the menu
  static const double margin = 8; // kept from the window's edges
  static const double itemHeight = 36;
  static const double radius = 10;

  static final BoxDecoration panel = BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: DashUi.line),
    boxShadow: [
      BoxShadow(color: Colors.black.withValues(alpha: 0.10), blurRadius: 24, offset: const Offset(0, 8)),
      BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 3, offset: const Offset(0, 1)),
    ],
  );

  static const Color highlight = DashUi.faint; // hover / keyboard
  static const Color pressed = DashUi.rowHover;
  static const TextStyle itemText = TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: DashUi.ink, height: 1.3);
}

/// What a trigger needs from its menu: whether it is open, how to open or close it, and the focus node the trigger
/// must use (so focus can come back to it when the menu closes).
class AppMenuHandle {
  final bool isOpen;
  final VoidCallback toggle;
  final VoidCallback open;
  final FocusNode focusNode;
  const AppMenuHandle({required this.isOpen, required this.toggle, required this.open, required this.focusNode});
}

/// A trigger and the menu it opens. [items] are usually [AppMenuItem]s.
class AppMenu extends StatefulWidget {
  final Widget Function(BuildContext context, AppMenuHandle menu) builder;
  final List<Widget> items;

  /// The menu is as wide as its trigger (a select field). Otherwise as wide as its items, between [minWidth] and [maxWidth].
  final bool matchTriggerWidth;
  final double minWidth;
  final double maxWidth;
  final double maxHeight;

  /// Lines the menu's right edge up with the trigger's (a trigger at the right of a bar).
  final bool alignEnd;

  /// Opens above the trigger when it fits there (a bar at the foot of a pane).
  final bool preferAbove;
  final String? semanticLabel;
  const AppMenu({
    super.key,
    required this.builder,
    required this.items,
    this.matchTriggerWidth = false,
    this.minWidth = 180,
    this.maxWidth = 360,
    this.maxHeight = 420,
    this.alignEnd = false,
    this.preferAbove = false,
    this.semanticLabel,
  });

  @override
  State<AppMenu> createState() => _AppMenuState();
}

class _AppMenuState extends State<AppMenu> with SingleTickerProviderStateMixin {
  final MenuController _controller = MenuController();
  final FocusNode _triggerFocus = FocusNode(debugLabel: 'menu trigger');
  final FocusScopeNode _menuScope = FocusScopeNode(debugLabel: 'menu');
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: AppMenuStyle.openDuration,
    reverseDuration: AppMenuStyle.closeDuration,
  );
  late final CurvedAnimation _t = CurvedAnimation(parent: _anim, curve: AppMenuStyle.openCurve, reverseCurve: AppMenuStyle.closeCurve);

  /// Open or opening (false while it closes, so it stops taking clicks and keys at once).
  bool _open = false;

  /// The menu was opened from the keyboard: the first row takes the keyboard even when nothing is ticked.
  bool _byKeyboard = false;

  bool get _reduced => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void dispose() {
    _t.dispose();
    _anim.dispose();
    _triggerFocus.dispose();
    _menuScope.dispose();
    super.dispose();
  }

  void _toggle() => _open ? _controller.close() : _openMenu();

  void _openMenu() {
    _byKeyboard = FocusManager.instance.highlightMode == FocusHighlightMode.traditional && _triggerFocus.hasFocus;
    _controller.open();
  }

  void _onOpenRequested(Offset? position, VoidCallback showOverlay) {
    // Already on screen (closing): turn it round rather than building it again.
    if (!_controller.isOpen) showOverlay();
    setState(() => _open = true);
    if (_reduced) {
      _anim.value = 1;
    } else {
      _anim.forward();
    }
  }

  void _onCloseRequested(VoidCallback hideOverlay) {
    if (!_open) return;
    // The keyboard goes back to the trigger (unless it went somewhere else, e.g. a click on another box).
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null || focus == _menuScope || _menuScope.hasFocus) _triggerFocus.requestFocus();
    setState(() => _open = false);
    // Reduced motion, or a page that has just gone off screen (its animations are paused): close at once.
    if (_reduced || !TickerMode.valuesOf(context).enabled) {
      _anim.value = 0;
      hideOverlay();
      return;
    }
    _anim.reverse().whenComplete(() {
      if (!_open && mounted) hideOverlay();
    });
  }

  @override
  Widget build(BuildContext context) {
    return RawMenuAnchor(
      controller: _controller,
      // The click that closes a menu does only that (as a desktop menu does): it must not also open the row or press
      // the button under it. Found in the real-browser audit: without this an outside click opened a service.
      consumeOutsideTaps: true,
      onOpenRequested: _onOpenRequested,
      onCloseRequested: _onCloseRequested,
      overlayBuilder: _overlay,
      builder: (context, controller, _) => widget.builder(
        context,
        AppMenuHandle(isOpen: _open, toggle: _toggle, open: _openMenu, focusNode: _triggerFocus),
      ),
    );
  }

  Widget _overlay(BuildContext context, RawMenuOverlayInfo info) {
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final anchor = info.anchorRect;
    final room = info.overlaySize;
    final below = room.height - anchor.bottom - AppMenuStyle.gap - AppMenuStyle.margin;
    final above = anchor.top - AppMenuStyle.gap - AppMenuStyle.margin;
    // Its likely height, to choose a side before it is laid out (rows, the panel's padding and edge).
    final wanted = (widget.items.length * AppMenuStyle.itemHeight * scale + 10).clamp(0.0, widget.maxHeight);
    final up = widget.preferAbove ? (above >= wanted || above > below) : (below < wanted && above > below);
    final maxHeight = (up ? above : below).clamp(80.0, widget.maxHeight);
    final width = widget.matchTriggerWidth ? anchor.width.clamp(widget.minWidth, room.width - 2 * AppMenuStyle.margin) : null;

    Widget panel = Container(
      decoration: AppMenuStyle.panel,
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: width ?? widget.minWidth,
          maxWidth: width ?? widget.maxWidth,
          maxHeight: maxHeight,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(4),
          child: IntrinsicWidth(
            stepWidth: width == null ? null : 0,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: widget.items,
            ),
          ),
        ),
      ),
    );

    panel = AnimatedBuilder(
      animation: _t,
      builder: (context, child) {
        final v = _t.value;
        return Opacity(
          opacity: v.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, (1 - v) * (up ? AppMenuStyle.drift : -AppMenuStyle.drift)),
            child: Transform.scale(
              scale: AppMenuStyle.startScale + (1 - AppMenuStyle.startScale) * v,
              alignment: up ? (widget.alignEnd ? Alignment.bottomRight : Alignment.bottomLeft) : (widget.alignEnd ? Alignment.topRight : Alignment.topLeft),
              child: child,
            ),
          ),
        );
      },
      child: panel,
    );

    return Positioned.fill(
      child: CustomSingleChildLayout(
        delegate: _MenuLayout(anchor: anchor, up: up, alignEnd: widget.alignEnd),
        child: TapRegion(
          groupId: info.tapRegionGroupId,
          onTapOutside: (_) => _controller.close(),
          child: IgnorePointer(
            ignoring: !_open,
            child: ExcludeFocus(
              excluding: !_open,
              child: Semantics(
                explicitChildNodes: true,
                scopesRoute: true,
                namesRoute: true,
                label: widget.semanticLabel,
                // Menu text is not page text: no I-beam over it, no drag-select.
                child: SelectionContainer.disabled(
                  child: Shortcuts(
                    shortcuts: const {
                      // Esc is the menu's own: without this it reached the page's Esc first (the service page's
                      // Cancel edit), so closing the category list also left edit mode.
                      SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
                      SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
                      SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
                      SingleActivator(LogicalKeyboardKey.home): _EdgeIntent(first: true),
                      SingleActivator(LogicalKeyboardKey.end): _EdgeIntent(first: false),
                      SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
                      SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
                      SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
                      SingleActivator(LogicalKeyboardKey.tab): DismissIntent(),
                      SingleActivator(LogicalKeyboardKey.tab, shift: true): DismissIntent(),
                    },
                    child: Actions(
                      actions: {_EdgeIntent: CallbackAction<_EdgeIntent>(onInvoke: (i) => _focusEdge(i.first))},
                      child: FocusScope(
                        node: _menuScope,
                        child: _AutoFocus(scope: _menuScope, firstWhenNone: _byKeyboard, child: panel),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _focusEdge(bool first) {
    final nodes = _menuScope.traversalDescendants.where((n) => n.canRequestFocus && !n.skipTraversal).toList();
    if (nodes.isEmpty) return;
    (first ? nodes.first : nodes.last).requestFocus();
  }
}

class _EdgeIntent extends Intent {
  final bool first;
  const _EdgeIntent({required this.first});
}

/// Puts the keyboard on the ticked row (or the first row when opened from the keyboard) once the menu is built, and
/// scrolls it into view.
class _AutoFocus extends StatefulWidget {
  final FocusScopeNode scope;
  final bool firstWhenNone;
  final Widget child;
  const _AutoFocus({required this.scope, required this.firstWhenNone, required this.child});

  @override
  State<_AutoFocus> createState() => _AutoFocusState();
}

class _AutoFocusState extends State<_AutoFocus> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rows = widget.scope.traversalDescendants.where((n) => n.canRequestFocus && !n.skipTraversal).toList();
      final ticked = rows.where((n) => n.context?.findAncestorWidgetOfExactType<_MenuRowMark>()?.selected ?? false).firstOrNull;
      final target = ticked ?? (widget.firstWhenNone ? rows.firstOrNull : null);
      if (target != null) {
        target.requestFocus();
        final ctx = target.context;
        if (ctx != null) Scrollable.ensureVisible(ctx, alignment: 0.5);
      } else {
        widget.scope.requestFocus(); // the keys work, nothing is highlighted until the person moves
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Marks a row as the current choice, for [_AutoFocus].
class _MenuRowMark extends InheritedWidget {
  final bool selected;
  const _MenuRowMark({required this.selected, required super.child});

  @override
  bool updateShouldNotify(_MenuRowMark old) => old.selected != selected;
}

/// Positions the menu under (or over) its trigger, inside the window.
class _MenuLayout extends SingleChildLayoutDelegate {
  final Rect anchor;
  final bool up;
  final bool alignEnd;
  const _MenuLayout({required this.anchor, required this.up, required this.alignEnd});

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => BoxConstraints.loose(constraints.biggest).deflate(const EdgeInsets.all(AppMenuStyle.margin));

  @override
  Offset getPositionForChild(Size size, Size child) {
    const m = AppMenuStyle.margin;
    var x = alignEnd ? anchor.right - child.width : anchor.left;
    x = x.clamp(m, (size.width - m - child.width).clamp(m, double.infinity));
    var y = up ? anchor.top - AppMenuStyle.gap - child.height : anchor.bottom + AppMenuStyle.gap;
    y = y.clamp(m, (size.height - m - child.height).clamp(m, double.infinity));
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_MenuLayout old) => old.anchor != anchor || old.up != up || old.alignEnd != alignEnd;
}

/// A row of an [AppMenu]: 36 px (more with larger text), a leading icon if any, the label, and a tick when [selected].
/// Hovering it moves the keyboard to it, so a menu never shows two highlighted rows.
class AppMenuItem extends StatefulWidget {
  final String? label;
  final Widget? child;
  final IconData? icon;
  final Widget? trailing;
  final bool selected;
  final bool danger;
  final VoidCallback? onPressed;

  /// Closes the menu before [onPressed] runs (the usual). False keeps it open (a row that toggles in place).
  final bool closesMenu;
  const AppMenuItem({super.key, this.label, this.child, this.icon, this.trailing, this.selected = false, this.danger = false, required this.onPressed, this.closesMenu = true})
    : assert(label != null || child != null);

  @override
  State<AppMenuItem> createState() => _AppMenuItemState();
}

class _AppMenuItemState extends State<AppMenuItem> {
  final FocusNode _focus = FocusNode(debugLabel: 'menu row');
  bool _focused = false;
  bool _pressed = false;

  bool get _enabled => widget.onPressed != null;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _activate() {
    if (!_enabled) return;
    if (widget.closesMenu) MenuController.maybeOf(context)?.close();
    widget.onPressed!();
  }

  @override
  Widget build(BuildContext context) {
    final fg = !_enabled ? DashUi.muted : (widget.danger ? DashUi.redText : DashUi.ink);
    final bg = !_enabled ? Colors.transparent : (_pressed ? AppMenuStyle.pressed : (_focused ? AppMenuStyle.highlight : Colors.transparent));
    final text = widget.child ??
        Text(
          widget.label!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppMenuStyle.itemText.copyWith(color: fg, fontWeight: widget.selected ? FontWeight.w700 : FontWeight.w500),
        );
    return _MenuRowMark(
      selected: widget.selected,
      child: Semantics(
        button: true,
        enabled: _enabled,
        selected: widget.selected,
        child: Actions(
          actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _activate())},
          child: Focus(
            focusNode: _focus,
            canRequestFocus: _enabled,
            onFocusChange: (f) => setState(() => _focused = f),
            child: MouseRegion(
              cursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
              onEnter: (_) {
                if (_enabled) _focus.requestFocus();
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
                onTapCancel: () => setState(() => _pressed = false),
                onTapUp: _enabled
                    ? (_) {
                        setState(() => _pressed = false);
                        _activate();
                      }
                    : null,
                child: AnimatedContainer(
                  duration: CatalogUi.motion(context, 90),
                  constraints: BoxConstraints(minHeight: AppMenuStyle.itemHeight * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.4)),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
                  child: Row(
                    children: [
                      if (widget.icon != null) ...[Icon(widget.icon, size: 18, color: !_enabled ? DashUi.muted : (widget.danger ? DashUi.redText : DashUi.slate)), const SizedBox(width: 10)],
                      Expanded(child: text),
                      if (widget.trailing != null) ...[const SizedBox(width: 10), widget.trailing!],
                      if (widget.selected) ...[const SizedBox(width: 10), const Icon(Icons.check_rounded, size: 17, color: DashUi.ink)],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A quiet trigger for a menu on a white bar (the list's sort): an icon, what is chosen, and a chevron that turns over
/// while the menu is open. Hover and open draw a light fill; keyboard focus draws the shared ring ([FocusRing]).
class AppMenuTriggerButton extends StatefulWidget {
  final AppMenuHandle menu;
  final IconData icon;
  final String? label;
  final String semanticLabel;
  final String? tooltip;
  final double height;
  const AppMenuTriggerButton({super.key, required this.menu, required this.icon, this.label, required this.semanticLabel, this.tooltip, this.height = 36});

  @override
  State<AppMenuTriggerButton> createState() => _AppMenuTriggerButtonState();
}

class _AppMenuTriggerButtonState extends State<AppMenuTriggerButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.menu;
    final motion = CatalogUi.motion(context, 150);
    Widget body = FocusableActionDetector(
      focusNode: m.focusNode,
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (v) => setState(() => _hover = v),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowDown): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => m.toggle())},
      child: GestureDetector(
        onTap: m.toggle,
        child: AnimatedContainer(
          duration: motion,
          curve: Curves.easeOutCubic,
          height: widget.height,
          padding: const EdgeInsets.only(left: 10, right: 6),
          decoration: BoxDecoration(
            color: m.isOpen || _hover ? DashUi.faint : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            // Its old focus edge, kept clear: it holds the trigger's size (the ring is FocusRing's now).
            border: Border.all(color: Colors.transparent, width: 1.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 17, color: DashUi.slate),
              if (widget.label != null) ...[
                const SizedBox(width: 6),
                Text(
                  widget.label!,
                  maxLines: 1,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.ink),
                ),
              ],
              const SizedBox(width: 2),
              AnimatedRotation(
                turns: m.isOpen ? 0.5 : 0,
                duration: motion,
                curve: Curves.easeOutCubic,
                child: const Icon(Icons.expand_more_rounded, size: 17, color: DashUi.slate),
              ),
            ],
          ),
        ),
      ),
    );
    // The shared keyboard ring (focus_ring.dart): after a row is picked with the mouse the trigger gets the keyboard
    // back, and its own ring used to show then too.
    body = FocusRing(child: body);
    body = Semantics(button: true, expanded: m.isOpen, label: widget.semanticLabel, excludeSemantics: true, child: body);
    // A tooltip only where the trigger is an icon with no words; never over the menu it opens.
    if (widget.tooltip != null && !m.isOpen) body = Tooltip(message: widget.tooltip!, child: body);
    return SelectionContainer.disabled(child: body);
  }
}

/// A pick-one field that looks and sizes exactly like the catalog's text boxes ([catalogFieldDecoration]): the choice,
/// and a chevron. Its menu opens under it, as wide as it, with the current choice ticked and highlighted.
class AppSelectField<T> extends StatefulWidget {
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T>? onChanged;
  final String? errorText;
  final String semanticLabel;

  /// Draws an option's label quieter (a choice that is not one of the real categories).
  final bool Function(T value)? quiet;

  /// The record-page form look (catalogFieldDecoration `filled`), to sit with filled text boxes.
  final bool filled;
  const AppSelectField({super.key, required this.value, required this.options, required this.onChanged, required this.semanticLabel, this.errorText, this.quiet, this.filled = false});

  @override
  State<AppSelectField<T>> createState() => _AppSelectFieldState<T>();
}

class _AppSelectFieldState<T> extends State<AppSelectField<T>> {
  bool _hover = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null;
    final current = widget.options.where((o) => o.$1 == widget.value).firstOrNull?.$2 ?? '';
    final quiet = widget.quiet?.call(widget.value) ?? false;
    return AppMenu(
      matchTriggerWidth: true,
      minWidth: 160,
      maxHeight: 360,
      semanticLabel: widget.semanticLabel,
      items: [
        for (final (v, label) in widget.options)
          AppMenuItem(
            key: ValueKey('option:$label'),
            selected: v == widget.value,
            onPressed: () {
              if (v != widget.value) widget.onChanged?.call(v);
            },
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppMenuStyle.itemText.copyWith(
                fontWeight: v == widget.value ? FontWeight.w700 : FontWeight.w500,
                color: (widget.quiet?.call(v) ?? false) ? DashUi.slate : DashUi.ink,
              ),
            ),
          ),
      ],
      builder: (context, menu) => Semantics(
        button: true,
        enabled: enabled,
        expanded: menu.isOpen,
        label: widget.semanticLabel,
        value: current,
        excludeSemantics: true,
        child: Focus(
          focusNode: menu.focusNode,
          canRequestFocus: enabled,
          onFocusChange: (f) => setState(() => _focused = f),
          onKeyEvent: (node, e) {
            if (!enabled || e is! KeyDownEvent) return KeyEventResult.ignored;
            final k = e.logicalKey;
            if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.arrowUp) {
              if (!menu.isOpen) menu.open();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: MouseRegion(
            cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              onTap: enabled
                  ? () {
                      menu.focusNode.requestFocus();
                      menu.toggle();
                    }
                  : null,
              child: InputDecorator(
                isFocused: _focused || menu.isOpen,
                isHovering: _hover,
                isEmpty: false,
                decoration: catalogFieldDecoration(error: widget.errorText, enabled: enabled, filled: widget.filled).copyWith(
                  contentPadding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                  suffixIcon: AnimatedRotation(
                    turns: menu.isOpen ? 0.5 : 0,
                    duration: CatalogUi.motion(context, 150),
                    curve: Curves.easeOutCubic,
                    child: Icon(Icons.expand_more_rounded, size: 20, color: enabled ? DashUi.slate : DashUi.muted),
                  ),
                  suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 20),
                ),
                child: Text(
                  current,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CatalogUi.fieldText.copyWith(color: quiet ? DashUi.slate : DashUi.ink),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
