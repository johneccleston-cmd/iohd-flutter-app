// Shared building blocks for the dashboards, so the screens can't drift apart visually.
// Place this file next to dashboard_layout.dart (screens/widgets/dashboard_kit.dart).
//
// Color carries meaning across every dashboard:
//   emerald = commission paid   indigo = locked retainage   sky = gross revenue
//   blue    = profit            amber/red = strikes and callbacks
// Structure stays quiet (hairline borders, no shadows); each screen gets one bold element.

import 'dart:math' as math;
import 'package:flutter/material.dart';

class DashUi {
  static const ink = Color(0xFF0F172A);
  static const slate = Color(0xFF475569);
  static const muted = Color(0xFF94A3B8);
  static const line = Color(0xFFE2E8F0);
  static const faint = Color(0xFFF1F5F9);

  static const emerald = Color(0xFF10B981);
  static const emeraldDeep = Color(0xFF059669);
  static const indigo = Color(0xFF6366F1);
  static const sky = Color(0xFF0284C7);
  static const blue = Color(0xFF2563EB);
  static const amber = Color(0xFFD97706);
  static const red = Color(0xFFDC2626);

  static BoxDecoration panel({double radius = 16}) => BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: line),
      );
}

String dashMoney(double v) {
  final neg = v < 0;
  final s = v.abs().toStringAsFixed(2).replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+\.)'),
        (m) => '${m[1]},',
      );
  return '${neg ? '-' : ''}\$$s';
}

// =============================================================================
// AVATAR (round, with an initials fallback when there's no image or it fails)
// =============================================================================

class DashAvatar extends StatelessWidget {
  final String name;
  final String imageUrl;
  final double size;
  final Color? ringColor;
  final double ringWidth;
  final Color? glowColor;

  const DashAvatar({
    super.key,
    required this.name,
    required this.imageUrl,
    required this.size,
    this.ringColor,
    this.ringWidth = 0,
    this.glowColor,
  });

  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  Widget _fallback() => Container(
        color: DashUi.faint,
        alignment: Alignment.center,
        child: Text(
          _initials,
          style: TextStyle(fontSize: size * 0.34, fontWeight: FontWeight.w700, color: DashUi.slate),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final image = ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: imageUrl.isEmpty
            ? _fallback()
            : Image.network(
                imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _fallback(),
              ),
      ),
    );

    if (ringWidth <= 0 && glowColor == null) return image;

    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: ringWidth > 0 ? Border.all(color: ringColor ?? DashUi.line, width: ringWidth) : null,
        boxShadow: glowColor == null
            ? null
            : [BoxShadow(color: glowColor!, blurRadius: 18, offset: const Offset(0, 6))],
      ),
      child: image,
    );
  }
}

// =============================================================================
// HOVER LIFT (desktop/web): the card rises 2px; the builder can tint the border
// =============================================================================

class HoverLift extends StatefulWidget {
  final Widget Function(BuildContext context, bool hovering) builder;
  final double lift;

  const HoverLift({super.key, required this.builder, this.lift = 2});

  @override
  State<HoverLift> createState() => _HoverLiftState();
}

class _HoverLiftState extends State<HoverLift> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(0, _hovering ? -widget.lift : 0, 0),
        child: widget.builder(context, _hovering),
      ),
    );
  }
}

// =============================================================================
// ANIMATED SCORECARD
//   - staggered entrance (left to right, by `index`)
//   - value counts up from zero, and again whenever it changes
//   - optional sparkline that draws itself after the count-up
//   - hover lift with a border tinted to the value color
//   - respects the OS reduced-motion setting
// =============================================================================

class AnimatedMetricCard extends StatefulWidget {
  final String title;

  /// Null shows an em dash (for metrics with no data source yet).
  final double? value;
  final String Function(double) format;
  final String caption;
  final Color valueColor;
  final int index;
  final List<double>? trend;

  const AnimatedMetricCard({
    super.key,
    required this.title,
    required this.value,
    this.caption = '',
    required this.valueColor,
    required this.index,
    this.format = dashMoney,
    this.trend,
  });

  @override
  State<AnimatedMetricCard> createState() => _AnimatedMetricCardState();
}

class _AnimatedMetricCardState extends State<AnimatedMetricCard> with SingleTickerProviderStateMixin {
  static const _baseMs = 520;
  static const _staggerMs = 110;
  static const _countUpMs = 1100;
  static const _sparkDrawMs = 600;

  late final AnimationController _enter;
  late final Animation<double> _t;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    final totalMs = _baseMs + widget.index * _staggerMs;
    _enter = AnimationController(vsync: this, duration: Duration(milliseconds: totalMs));
    _t = CurvedAnimation(
      parent: _enter,
      curve: Interval(widget.index * _staggerMs / totalMs, 1.0, curve: Curves.easeOutCubic),
    );
    _enter.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.of(context).disableAnimations;
    if (_reduceMotion) _enter.value = 1;
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  Widget _valueText(double v) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          widget.format(v),
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            height: 1.1,
            color: widget.valueColor,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final v = w.value;

    final textColumn = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          w.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.slate),
        ),
        const SizedBox(height: 6),
        if (v == null)
          const Text(
            '—',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, height: 1.1, color: DashUi.muted),
          )
        else
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: v),
            duration: _reduceMotion ? Duration.zero : const Duration(milliseconds: _countUpMs),
            curve: Curves.easeOutCubic,
            builder: (context, value, _) => _valueText(value),
          ),
      ],
    );

    return FadeTransition(
      opacity: _t,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.12), end: Offset.zero).animate(_t),
        child: HoverLift(
          builder: (context, hovering) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: hovering ? w.valueColor.withValues(alpha: 0.55) : DashUi.line),
            ),
            child: LayoutBuilder(
              builder: (context, c) {
                // Skip the sparkline when the card is too narrow to fit it beside the number.
                final showSpark = w.trend != null && c.maxWidth > 250;
                return Row(
                  children: [
                    Expanded(child: textColumn),
                    if (showSpark) ...[
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 84,
                        height: 48,
                        child: TweenAnimationBuilder<double>(
                          tween: Tween<double>(begin: 0, end: 1),
                          duration: _reduceMotion
                              ? Duration.zero
                              : const Duration(milliseconds: _countUpMs + _sparkDrawMs),
                          builder: (context, t, _) {
                            final progress =
                                ((t * (_countUpMs + _sparkDrawMs) - _countUpMs) / _sparkDrawMs).clamp(0.0, 1.0);
                            return CustomPaint(
                              painter: _SparklinePainter(values: w.trend!, color: w.valueColor, progress: progress),
                            );
                          },
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> values;
  final Color color;
  final double progress;

  const _SparklinePainter({required this.values, required this.color, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 5.0;
    final w = size.width - pad * 2;
    final h = size.height - pad * 2;
    final maxV = values.fold<double>(0, math.max);

    if (values.length < 2 || maxV <= 0) {
      final base = Paint()
        ..color = DashUi.line
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round;
      final y = size.height / 2;
      var x = pad;
      while (x < size.width - pad) {
        canvas.drawLine(Offset(x, y), Offset(math.min(x + 4, size.width - pad), y), base);
        x += 8;
      }
      return;
    }

    final pts = <Offset>[
      for (var i = 0; i < values.length; i++)
        Offset(pad + w * i / (values.length - 1), pad + h * (1 - values[i] / maxV)),
    ];

    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      final cx = (pts[i - 1].dx + pts[i].dx) / 2;
      path.cubicTo(cx, pts[i - 1].dy, cx, pts[i].dy, pts[i].dx, pts[i].dy);
    }

    final metric = path.computeMetrics().first;
    final len = metric.length;

    if (progress > 0) {
      canvas.drawPath(
        metric.extractPath(0, len * progress),
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      final head = metric.getTangentForOffset(len * progress);
      if (head != null) {
        if (progress >= 1) {
          canvas.drawCircle(head.position, 6, Paint()..color = color.withValues(alpha: 0.18));
        }
        canvas.drawCircle(head.position, 3.2, Paint()..color = color);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.values != values || old.color != color || old.progress != progress;
}

// =============================================================================
// LOADING + ERROR
// =============================================================================

/// Wrap a skeleton layout in this to make it pulse.
class SkeletonPulse extends StatefulWidget {
  final Widget child;
  const SkeletonPulse({super.key, required this.child});

  @override
  State<SkeletonPulse> createState() => _SkeletonPulseState();
}

class _SkeletonPulseState extends State<SkeletonPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.45, end: 1).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
      child: widget.child,
    );
  }
}

class SkeletonBox extends StatelessWidget {
  final double? h;
  final double? w;
  final double r;
  const SkeletonBox({super.key, this.h, this.w, this.r = 8});

  @override
  Widget build(BuildContext context) => Container(
        height: h,
        width: w,
        decoration: BoxDecoration(color: DashUi.line, borderRadius: BorderRadius.circular(r)),
      );
}

class DashErrorPanel extends StatelessWidget {
  final String title;
  final String message;
  final VoidCallback onRetry;

  const DashErrorPanel({super.key, required this.title, required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 420,
        padding: const EdgeInsets.all(28),
        decoration: DashUi.panel(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 34, color: DashUi.muted),
            const SizedBox(height: 14),
            Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: DashUi.ink)),
            const SizedBox(height: 6),
            Text(
              message.replaceFirst('Exception: ', ''),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13.5, color: DashUi.slate),
            ),
            const SizedBox(height: 4),
            const Text(
              'Check your connection, then try again.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: DashUi.muted),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Try again'),
              style: FilledButton.styleFrom(backgroundColor: DashUi.emeraldDeep),
            ),
          ],
        ),
      ),
    );
  }
}