import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dashboard_kit.dart';

/// One choice in an [AnimatedSelect]. [tag] is small coloured text at the right of the row (e.g. "Admin access").
class SelectOption<T> {
  final T value;
  final String label;
  final String? tag;
  final Color? tagColor;
  const SelectOption(this.value, this.label, {this.tag, this.tagColor});
}

/// A dropdown with its own menu: the panel grows out of the field (fade, slight slide and unfold), the rows
/// follow one after another, the chevron turns, and it closes the same way in reverse. Opens below the field, or
/// above when there is no room. Click outside or press Esc to close; arrow keys and Enter pick a row.
class AnimatedSelect<T> extends StatefulWidget {
  final T? value;
  final List<SelectOption<T>> options;
  final ValueChanged<T> onChanged;
  final String hint;

  /// Marks the field as edited (indigo tint), like the other fields on the Team screen.
  final bool changed;
  final String? errorText;

  /// The decoration of the text fields beside it. Using the same one makes the box exactly their height on any font.
  final InputDecoration? decoration;

  const AnimatedSelect({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.hint = 'Choose',
    this.changed = false,
    this.errorText,
    this.decoration,
  });

  @override
  State<AnimatedSelect<T>> createState() => _AnimatedSelectState<T>();
}

class _AnimatedSelectState<T> extends State<AnimatedSelect<T>> with SingleTickerProviderStateMixin {
  static const double _rowH = 40;
  static const double _maxPanelH = 440;
  static const Color _changedFill = Color(0xFFEEF2FF);

  final LayerLink _link = LayerLink();
  final GlobalKey _fieldKey = GlobalKey();
  late final AnimationController _ctl = AnimationController(vsync: this);
  final ValueNotifier<int> _hot = ValueNotifier<int>(-1);
  final TextEditingController _text = TextEditingController();
  final FocusNode _noFocus = FocusNode(canRequestFocus: false, skipTraversal: true);
  OverlayEntry? _entry;
  bool _open = false;
  bool _above = false;

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    _ctl.dispose();
    _hot.dispose();
    _text.dispose();
    _noFocus.dispose();
    super.dispose();
  }

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  int get _selectedIndex => widget.options.indexWhere((o) => o.value == widget.value);

  void _openMenu() {
    if (_open || widget.options.isEmpty) return;
    final box = _fieldKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final size = box.size;
    final topLeft = box.localToGlobal(Offset.zero);
    final screenH = MediaQuery.sizeOf(context).height;
    final panelH = (widget.options.length * _rowH + 8).clamp(0, _maxPanelH).toDouble();
    final spaceBelow = screenH - (topLeft.dy + size.height) - 12;
    _above = spaceBelow < panelH && topLeft.dy > spaceBelow;
    _hot.value = _selectedIndex;

    _entry = OverlayEntry(builder: (_) => _buildOverlay(size.width, size.height, panelH));
    Overlay.of(context).insert(_entry!);
    setState(() => _open = true);
    _ctl.duration = _reduceMotion ? Duration.zero : const Duration(milliseconds: 320);
    _ctl.forward(from: 0);
  }

  Future<void> _closeMenu() async {
    if (!_open) return;
    setState(() => _open = false);
    _ctl.duration = _reduceMotion ? Duration.zero : const Duration(milliseconds: 160);
    await _ctl.reverse();
    _entry?.remove();
    _entry = null;
  }

  void _pick(int i) {
    final v = widget.options[i].value;
    _closeMenu();
    if (v != widget.value) widget.onChanged(v);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final n = widget.options.length;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      _closeMenu();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      _hot.value = (_hot.value + 1) % n;
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      _hot.value = (_hot.value - 1 + n) % n;
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (_hot.value >= 0) _pick(_hot.value);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _buildOverlay(double width, double fieldH, double panelH) {
    final unfold = CurvedAnimation(
      parent: _ctl,
      curve: const Interval(0, 0.7, curve: Curves.easeOutCubic),
    );
    final fade = CurvedAnimation(
      parent: _ctl,
      curve: const Interval(0, 0.45, curve: Curves.easeOut),
    );
    final n = widget.options.length;

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: _closeMenu),
        ),
        CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: _above ? Alignment.topLeft : Alignment.bottomLeft,
          followerAnchor: _above ? Alignment.bottomLeft : Alignment.topLeft,
          offset: Offset(0, _above ? -6 : 6),
          child: SizedBox(
            width: width,
            child: Focus(
              autofocus: true,
              onKeyEvent: _onKey,
              child: AnimatedBuilder(
                animation: _ctl,
                builder: (context, child) => Opacity(
                  opacity: fade.value,
                  child: Transform.translate(
                    offset: Offset(0, (1 - unfold.value) * (_above ? 10 : -10)),
                    // Clip to the growing edge so the panel unfolds instead of just fading in; once open, let the
                    // shadow spill past the edge again.
                    child: ClipRect(
                      clipper: _UnfoldClipper(above: _above, open: unfold.value >= 1),
                      child: Align(
                        alignment: _above ? Alignment.bottomCenter : Alignment.topCenter,
                        heightFactor: 0.35 + 0.65 * unfold.value,
                        child: Transform.scale(
                          scaleY: 0.94 + 0.06 * unfold.value,
                          alignment: _above ? Alignment.bottomCenter : Alignment.topCenter,
                          child: child,
                        ),
                      ),
                    ),
                  ),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: DashUi.line),
                    boxShadow: const [
                      BoxShadow(color: Color(0x1F101828), blurRadius: 24, offset: Offset(0, 10)),
                      BoxShadow(color: Color(0x0F101828), blurRadius: 4, offset: Offset(0, 1)),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    // Gives the rows a text style and ink; an overlay has no Material above it.
                    child: Material(
                      type: MaterialType.transparency,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: panelH),
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          shrinkWrap: true,
                          itemCount: n,
                          itemExtent: _rowH,
                          itemBuilder: (_, i) => _row(i, n),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(int i, int n) {
    final o = widget.options[i];
    final selected = o.value == widget.value;
    // Rows ease in one after another once the panel is mostly open.
    final start = (0.15 + 0.5 * i / (n <= 1 ? 1 : n)).clamp(0.0, 0.8);
    final anim = CurvedAnimation(
      parent: _ctl,
      curve: Interval(start, (start + 0.4).clamp(0.0, 1.0), curve: Curves.easeOutCubic),
    );
    return AnimatedBuilder(
      animation: anim,
      builder: (context, child) => Opacity(
        opacity: anim.value,
        child: Transform.translate(offset: Offset(0, (1 - anim.value) * (_above ? 6 : -6)), child: child),
      ),
      child: ValueListenableBuilder<int>(
        valueListenable: _hot,
        builder: (context, hot, _) {
          final lit = hot == i;
          return MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => _hot.value = i,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _pick(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                margin: const EdgeInsets.symmetric(horizontal: 4),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: lit ? DashUi.faint : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        o.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          color: DashUi.ink,
                          fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                        ),
                      ),
                    ),
                    if (o.tag != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        o.tag!,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: o.tagColor ?? DashUi.indigo,
                        ),
                      ),
                    ],
                    SizedBox(
                      width: 26,
                      child: selected
                          ? const Align(
                              alignment: Alignment.centerRight,
                              child: Icon(Icons.check_rounded, size: 18, color: DashUi.emeraldDeep),
                            )
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final i = _selectedIndex;
    final label = i >= 0 ? widget.options[i].label : null;
    final base =
        widget.decoration ??
        InputDecoration(
          isDense: true,
          filled: true,
          fillColor: widget.changed ? _changedFill : Colors.white,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: DashUi.line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: widget.changed ? DashUi.indigo.withValues(alpha: 0.45) : DashUi.line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: DashUi.ink, width: 1.4),
          ),
        );

    final open = _open;
    final decoration = base.copyWith(
      errorText: widget.errorText,
      hintText: widget.hint,
      hintStyle: const TextStyle(fontSize: 13.5, color: DashUi.muted, fontWeight: FontWeight.w500),
      // An open menu looks focused: same border a focused text field gets.
      enabledBorder: open ? (base.focusedBorder ?? base.enabledBorder) : base.enabledBorder,
      // Zero-height slot: the chevron paints around the text line without making the box taller than a text field.
      suffixIcon: SizedBox(
        width: 30,
        height: 0,
        child: OverflowBox(
          maxHeight: 24,
          child: AnimatedRotation(
            turns: open ? 0.5 : 0,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: const Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: DashUi.ink),
          ),
        ),
      ),
      suffixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 0, maxHeight: 0),
    );
    _text.text = label ?? '';

    // A real (read-only) text field draws the box, so it is exactly as tall as the text fields beside it.
    return CompositedTransformTarget(
      link: _link,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _open ? _closeMenu : _openMenu,
          child: KeyedSubtree(
            key: _fieldKey,
            child: IgnorePointer(
              child: TextField(
                controller: _text,
                readOnly: true,
                showCursor: false,
                enableInteractiveSelection: false,
                focusNode: _noFocus,
                maxLines: 1,
                style: const TextStyle(fontSize: 13.5, color: DashUi.ink, fontWeight: FontWeight.w600),
                decoration: decoration,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Clips to the panel's current size on the edge it grows from, with room on the other sides for the shadow.
class _UnfoldClipper extends CustomClipper<Rect> {
  final bool above;
  final bool open;
  const _UnfoldClipper({required this.above, required this.open});

  @override
  Rect getClip(Size size) {
    const spill = 40.0;
    if (above) {
      return Rect.fromLTRB(-spill, open ? -spill : 0, size.width + spill, size.height + spill);
    }
    return Rect.fromLTRB(-spill, -spill, size.width + spill, open ? size.height + spill : size.height);
  }

  @override
  bool shouldReclip(_UnfoldClipper old) => old.above != above || old.open != open;
}
