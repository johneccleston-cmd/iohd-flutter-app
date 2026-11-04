// The hover card every scorecard uses (dashboards, KPI pages, the Team profile): what the figure means, in a dark card
// that animates in under the scorecard instead of a plain grey tooltip.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'dashboard_kit.dart';

/// [color] lightened just enough to read on the hover card's navy (at least 4.5:1, the WCAG contrast for text): a red
/// turns into a lighter red, while colours that already read are only softened a touch. A neutral or near-black figure
/// (ink, slate) is simply white, since lightening it would only grey it out.
Color dashReadableOnDark(Color color) {
  const bg = Color(0xFF1E293B); // the lighter end of the card's gradient, the harder one to read against
  final hsl = HSLColor.fromColor(color);
  if (hsl.saturation < 0.3 || hsl.lightness < 0.2) return const Color(0xFFF8FAFC);
  double contrast(Color c) {
    final a = c.computeLuminance(), b = bg.computeLuminance();
    return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
  }

  var t = 0.15;
  var c = Color.lerp(color, Colors.white, t)!;
  while (contrast(c) < 4.5 && t < 1) {
    t += 0.05;
    c = Color.lerp(color, Colors.white, t)!;
  }
  return c;
}

/// The scorecard hover card's look, shared by every other hover pop-up (the app's plain tooltips, the chart tips) so
/// they all read as one family: navy gradient, soft white edge, 12px corners, a deep shadow.
const dashTipGradient = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [DashUi.ink, Color(0xFF1E293B)]);
const dashTipShadow = [BoxShadow(color: Color(0x400F172A), blurRadius: 24, offset: Offset(0, 10))];
const dashTipEdge = Color(0x1FFFFFFF);
const dashTipBodyStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w500, height: 1.45, color: Color(0xFFCBD5E1));

final dashTipDecoration = BoxDecoration(
  gradient: dashTipGradient,
  borderRadius: BorderRadius.circular(12),
  border: Border.all(color: dashTipEdge),
  boxShadow: dashTipShadow,
);

/// What a scorecard means, on hover or keyboard focus: after a short wait a dark card rises, grows and fades in under
/// [child] (above it when there is no room below, right-aligned near the window's right edge), an accent line in the
/// figure's [color] sweeping across the top, then the figure's [title] and [value] and the [body] in plain words. It
/// fades back out when the pointer leaves. Shown and hidden at once with reduced motion; it never takes the pointer.
/// With an empty [body] it is just [child].
class DashHoverCard extends StatefulWidget {
  final String title;
  final String value;
  final String body;
  final Color color;
  final Widget child;
  const DashHoverCard({super.key, required this.title, required this.value, required this.body, required this.color, required this.child});

  @override
  State<DashHoverCard> createState() => _DashHoverCardState();
}

class _DashHoverCardState extends State<DashHoverCard> with SingleTickerProviderStateMixin {
  static const _width = 320.0;
  static const _wait = Duration(milliseconds: 350);

  final _link = LayerLink();
  final _portal = OverlayPortalController();
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    reverseDuration: const Duration(milliseconds: 150),
  );
  late final Animation<double> _in = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
  late final Animation<double> _sweep = CurvedAnimation(parent: _c, curve: const Interval(0.25, 1, curve: Curves.easeOutCubic));
  Timer? _timer;
  bool _hover = false;
  bool _focus = false;
  bool _right = false;
  bool _above = false;

  bool get _still => MediaQuery.disableAnimationsOf(context);

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  void _update() {
    _timer?.cancel();
    if (_hover || _focus) {
      _timer = Timer(_focus ? Duration.zero : _wait, _show);
    } else {
      _hide();
    }
  }

  void _show() {
    if (!mounted) return;
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      final at = box.localToGlobal(Offset.zero);
      final screen = MediaQuery.sizeOf(context);
      _right = at.dx + _width > screen.width - 12;
      _above = at.dy + box.size.height + 190 > screen.height;
    }
    setState(() {});
    _portal.show();
    if (_still) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  void _hide() {
    if (!_portal.isShowing) return;
    if (_still) {
      _c.value = 0;
      _portal.hide();
      return;
    }
    _c.reverse().then((_) {
      if (mounted && _c.isDismissed) _portal.hide();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.body.trim().isEmpty) return widget.child;
    final anchorTarget = _above ? (_right ? Alignment.topRight : Alignment.topLeft) : (_right ? Alignment.bottomRight : Alignment.bottomLeft);
    final anchorCard = _above ? (_right ? Alignment.bottomRight : Alignment.bottomLeft) : (_right ? Alignment.topRight : Alignment.topLeft);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) {
        _focus = f;
        _update();
      },
      child: MouseRegion(
        onEnter: (_) {
          _hover = true;
          _update();
        },
        onExit: (_) {
          _hover = false;
          _update();
        },
        child: CompositedTransformTarget(
          link: _link,
          child: OverlayPortal(
            controller: _portal,
            overlayChildBuilder: (context) => Align(
              alignment: Alignment.topLeft,
              child: CompositedTransformFollower(
                link: _link,
                showWhenUnlinked: false,
                targetAnchor: anchorTarget,
                followerAnchor: anchorCard,
                offset: Offset(0, _above ? -8 : 8),
                child: IgnorePointer(
                  child: FadeTransition(
                    opacity: _in,
                    child: SlideTransition(
                      position: Tween<Offset>(begin: Offset(0, _above ? 0.06 : -0.06), end: Offset.zero).animate(_in),
                      child: ScaleTransition(
                        scale: Tween<double>(begin: 0.94, end: 1).animate(_in),
                        alignment: anchorCard,
                        child: _card(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }

  Widget _card() {
    final accent = dashReadableOnDark(widget.color);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _width),
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          decoration: dashTipDecoration,
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The accent line sweeps across the top once the card is in.
              Align(
                alignment: Alignment.centerLeft,
                child: SizeTransition(
                  sizeFactor: _sweep,
                  axis: Axis.horizontal,
                  alignment: Alignment.centerLeft,
                  child: Container(height: 3, width: _width, color: accent),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 11, 16, 14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Expanded(
                          child: Text(
                            widget.title,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, height: 1.3, color: Color(0xFFE2E8F0)),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          widget.value,
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, height: 1.2, color: accent, fontFeatures: const [FontFeature.tabularFigures()]),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(height: 1, color: const Color(0x1AFFFFFF)),
                    const SizedBox(height: 8),
                    Text(widget.body, style: dashTipBodyStyle),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
