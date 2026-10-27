// Shared building blocks for the dashboards, so the screens can't drift apart visually.
// Place this file next to dashboard_layout.dart (screens/widgets/dashboard_kit.dart).
//
// Color carries meaning across every dashboard:
//   emerald = commission paid   indigo = locked retainage   sky = gross revenue
//   blue    = profit            amber/red = strikes and callbacks
// Structure stays quiet (hairline borders, no shadows); each screen gets one bold element.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'dashboard_data.dart';

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

  // Text-safe tones (at least 4.5:1 on white and on `faint`). `muted`,
  // `emeraldDeep` and `amber` fail as small text, so use these for readable
  // secondary text, money and warnings under 18px; keep the brighter ones for
  // dots, bars, tints and big figures.
  static const subtle = Color(0xFF64748B);
  static const emeraldText = Color(0xFF047857);
  static const amberText = Color(0xFFB45309);
  static const redText = Color(0xFFB91C1C);

  static BoxDecoration panel({double radius = 16}) => BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: line),
  );
}

String dashMoney(double v) {
  final neg = v < 0;
  final s = v
      .abs()
      .toStringAsFixed(2)
      .replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+\.)'), (m) => '${m[1]},');
  return '${neg ? '-' : ''}\$$s';
}

/// "Nick Smith" -> "NS", "Cher" -> "C", "" -> "?".
String dashInitials(String name) {
  final parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first[0].toUpperCase();
  return (parts.first[0] + parts.last[0]).toUpperCase();
}

/// A person's photo filling its box (the left strip of the staff cards). With no photo, or one that fails to load,
/// their initials on a soft tint. Names are never sent to an outside avatar service.
class DashPhotoStrip extends StatelessWidget {
  final String name;
  final String imageUrl;
  const DashPhotoStrip({super.key, required this.name, required this.imageUrl});

  Widget _initials() => Container(
    color: DashUi.faint,
    alignment: Alignment.center,
    child: Text(
      dashInitials(name),
      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: DashUi.slate),
    ),
  );

  @override
  Widget build(BuildContext context) => imageUrl.isEmpty
      ? _initials()
      : Image.network(imageUrl, fit: BoxFit.cover, errorBuilder: (_, _, _) => _initials());
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

  /// Tints the initials fallback (soft gradient + coloured letters) instead of flat grey.
  final Color? accent;

  /// Rounded square instead of a circle.
  final bool square;

  const DashAvatar({
    super.key,
    required this.name,
    required this.imageUrl,
    required this.size,
    this.square = false,
    this.ringColor,
    this.ringWidth = 0,
    this.glowColor,
    this.accent,
  });

  String get _initials => dashInitials(name);

  Widget _fallback() => Container(
    decoration: accent == null
        ? const BoxDecoration(color: DashUi.faint)
        : BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [accent!.withValues(alpha: 0.10), accent!.withValues(alpha: 0.26)],
            ),
          ),
    alignment: Alignment.center,
    child: Text(
      _initials,
      style: TextStyle(
        fontSize: size * 0.34,
        fontWeight: FontWeight.w700,
        color: accent == null ? DashUi.slate : Color.lerp(accent, Colors.black, 0.25),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final box = SizedBox(
      width: size,
      height: size,
      child: imageUrl.isEmpty
          ? _fallback()
          : Image.network(
              imageUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _fallback(),
            ),
    );
    final image = square
        ? ClipRRect(borderRadius: BorderRadius.circular(size * 0.12), child: box)
        : ClipOval(child: box);

    if (ringWidth <= 0 && glowColor == null) return image;

    return Container(
      decoration: BoxDecoration(
        shape: square ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: square ? BorderRadius.circular(size * 0.12 + ringWidth) : null,
        border: ringWidth > 0
            ? Border.all(color: ringColor ?? DashUi.line, width: ringWidth)
            : null,
        boxShadow: glowColor == null
            ? null
            : [
                BoxShadow(
                  color: glowColor!,
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
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
        transform: Matrix4.translationValues(
          0,
          _hovering ? -widget.lift : 0,
          0,
        ),
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

/// Height of a scorecard row that shows title, value and caption at the current text size (see AnimatedMetricCard).
/// [verticalPadding] must match the cards' own (14 unless they set another).
double dashTileHeight(BuildContext context, {double verticalPadding = 14}) =>
    _AnimatedMetricCardState._neededHeight(MediaQuery.textScalerOf(context), verticalPadding);

class AnimatedMetricCard extends StatefulWidget {
  final String title;

  /// Null shows an em dash (for metrics with no data source yet).
  final double? value;
  final String Function(double) format;

  /// One plain line under the number saying what it counts and over what period. Drawn when the card is tall enough
  /// ([dashTileHeight]); always available on hover and to screen readers.
  final String caption;

  /// The full explanation shown on hover. Defaults to [caption].
  final String? definition;
  final Color valueColor;
  final int index;
  final List<double>? trend;

  /// The trend line is hidden when the card's inner width is below this (it needs room beside the number).
  final double sparkMinWidth;

  /// Space above and below the text; a screen with a fixed, shorter card height can tighten it.
  final double verticalPadding;

  const AnimatedMetricCard({
    super.key,
    required this.title,
    required this.value,
    this.caption = '',
    this.definition,
    required this.valueColor,
    required this.index,
    this.format = dashMoney,
    this.trend,
    this.sparkMinWidth = 250,
    this.verticalPadding = 14,
  });

  @override
  State<AnimatedMetricCard> createState() => _AnimatedMetricCardState();
}

class _AnimatedMetricCardState extends State<AnimatedMetricCard>
    with SingleTickerProviderStateMixin {
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
    _enter = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: totalMs),
    );
    _t = CurvedAnimation(
      parent: _enter,
      curve: Interval(
        widget.index * _staggerMs / totalMs,
        1.0,
        curve: Curves.easeOutCubic,
      ),
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

  /// Height of title + value + caption at text size [s] (title and caption are 1.3 lines high, the value 1.1).
  static double _contentHeight(TextScaler s) => s.scale(13) * 1.3 + 4 + s.scale(28) * 1.1 + 2 + s.scale(12) * 1.3 + 1;

  /// The whole card: content, [verticalPadding] above and below, and the 1px border top and bottom (a Container adds
  /// its decoration's border to its padding).
  static double _neededHeight(TextScaler s, double verticalPadding) => verticalPadding * 2 + 2 + _contentHeight(s);

  Widget _textColumn(double? v, {required bool withCaption}) {
    final w = widget;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          w.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          // A fixed line height only when the caption is drawn (so the card's height is predictable); otherwise the
          // font's own, exactly as before, so screens without captions are unchanged.
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            height: withCaption ? 1.3 : null,
            color: DashUi.slate,
          ),
        ),
        SizedBox(height: withCaption ? 4 : 6),
        if (v == null)
          const Text(
            '—',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              height: 1.1,
              color: DashUi.muted,
            ),
          )
        else
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: v),
            duration: _reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: _countUpMs),
            curve: Curves.easeOutCubic,
            builder: (context, value, _) => _valueText(value),
          ),
        if (withCaption) ...[
          const SizedBox(height: 2),
          Text(
            w.caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              height: 1.3,
              color: DashUi.subtle,
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final v = w.value;
    final scaler = MediaQuery.textScalerOf(context);
    final hover = (w.definition ?? w.caption).trim();

    Widget card = HoverLift(
      builder: (context, hovering) => Container(
        padding: EdgeInsets.symmetric(horizontal: 18, vertical: w.verticalPadding),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: hovering
                ? w.valueColor.withValues(alpha: 0.55)
                : DashUi.line,
          ),
        ),
        child: LayoutBuilder(
          builder: (context, c) {
            // The caption line only appears when the card is tall enough for it; it never squeezes the number.
            final withCaption = w.caption.isNotEmpty && c.maxHeight + 0.5 >= _contentHeight(scaler);
            // Skip the sparkline when the card is too narrow to fit it beside the number.
            final showSpark = w.trend != null && c.maxWidth > w.sparkMinWidth;
            return Row(
              children: [
                Expanded(child: _textColumn(v, withCaption: withCaption)),
                if (showSpark) ...[
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 84,
                    height: 48,
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: 1),
                      duration: _reduceMotion
                          ? Duration.zero
                          : const Duration(
                              milliseconds: _countUpMs + _sparkDrawMs,
                            ),
                      builder: (context, t, _) {
                        final progress =
                            ((t * (_countUpMs + _sparkDrawMs) -
                                        _countUpMs) /
                                    _sparkDrawMs)
                                .clamp(0.0, 1.0);
                        return CustomPaint(
                          painter: _SparklinePainter(
                            values: w.trend!,
                            color: w.valueColor,
                            progress: progress,
                          ),
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
    );
    if (hover.isNotEmpty) {
      card = Tooltip(message: hover, waitDuration: const Duration(milliseconds: 400), child: card);
    }

    // Screen readers get the finished figure and its meaning in one phrase, not the count-up in progress.
    return Semantics(
      container: true,
      label: '${w.title}: ${v == null ? 'no figure yet' : w.format(v)}${hover.isEmpty ? '' : '. $hover'}',
      child: ExcludeSemantics(
        child: FadeTransition(
          opacity: _t,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.12),
              end: Offset.zero,
            ).animate(_t),
            child: card,
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

  const _SparklinePainter({
    required this.values,
    required this.color,
    required this.progress,
  });

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
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(x + 4, size.width - pad), y),
          base,
        );
        x += 8;
      }
      return;
    }

    final pts = <Offset>[
      for (var i = 0; i < values.length; i++)
        Offset(
          pad + w * i / (values.length - 1),
          pad + h * (1 - values[i] / maxV),
        ),
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
          canvas.drawCircle(
            head.position,
            6,
            Paint()..color = color.withValues(alpha: 0.18),
          );
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

class _SkeletonPulseState extends State<SkeletonPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Reduced motion: a still placeholder instead of a pulse.
    if (MediaQuery.of(context).disableAnimations) {
      if (_pulse.isAnimating) _pulse.stop();
      return widget.child;
    }
    if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    return FadeTransition(
      opacity: Tween<double>(
        begin: 0.45,
        end: 1,
      ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
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
    decoration: BoxDecoration(
      color: DashUi.line,
      borderRadius: BorderRadius.circular(r),
    ),
  );
}

class DashErrorPanel extends StatelessWidget {
  final String title;
  final String message;

  /// Null hides the button (for problems a retry can't fix, like a missing permission).
  final VoidCallback? onRetry;
  final String? hint;
  final IconData icon;

  /// Failure titles can run to two lines, so they are centred; the plain panel keeps its original look.
  final bool _centerTitle;

  const DashErrorPanel({
    super.key,
    required this.title,
    required this.message,
    required VoidCallback this.onRetry,
    this.hint = 'Check your connection, then try again.',
    this.icon = Icons.cloud_off_rounded,
  }) : _centerTitle = false;

  /// A dashboard load failure in plain words: [what] names the data ("financials"). No raw error text is shown.
  DashErrorPanel.failure(DashLoadException failure, {super.key, required String what, required VoidCallback onRetry})
      : title = failure.title(what),
        message = failure.message,
        hint = null,
        icon = switch (failure.kind) {
          DashFailure.noAccess => Icons.lock_outline_rounded,
          DashFailure.signedOut => Icons.logout_rounded,
          DashFailure.timeout => Icons.hourglass_bottom_rounded,
          DashFailure.server || DashFailure.badData => Icons.error_outline_rounded,
          DashFailure.offline => Icons.cloud_off_rounded,
        },
        onRetry = failure.canRetry ? onRetry : null,
        _centerTitle = true;

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
            Icon(icon, size: 34, color: DashUi.muted),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: _centerTitle ? TextAlign.center : null,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: DashUi.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message.replaceFirst('Exception: ', ''),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13.5, color: DashUi.slate),
            ),
            if (hint != null) ...[
              const SizedBox(height: 4),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13.5, color: DashUi.muted),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Try again'),
                style: FilledButton.styleFrom(
                  backgroundColor: DashUi.emeraldDeep,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// AUTO-SCROLLING TICKER
// =============================================================================

/// A strip of [items] that scrolls sideways and loops forever. It pauses while the cursor is over it
/// and stands still when the OS asks for reduced motion.
class AutoScrollTicker extends StatefulWidget {
  final List<Widget> items;
  final double height;
  const AutoScrollTicker({super.key, required this.items, this.height = 56});

  @override
  State<AutoScrollTicker> createState() => _AutoScrollTickerState();
}

class _AutoScrollTickerState extends State<AutoScrollTicker>
    with SingleTickerProviderStateMixin {
  static const double _speed = 45.0; // px/sec
  static const double _gap = 12.0;

  late final Ticker _ticker;
  final GlobalKey _rowKey = GlobalKey();
  final ValueNotifier<double> _offset = ValueNotifier<double>(0.0);

  double _cycleWidth = 1.0;
  Duration? _last;
  bool _hovered = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _measure();
      if (!_reduceMotion) _ticker.start();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.of(context).disableAnimations;
    if (reduce == _reduceMotion) return;
    _reduceMotion = reduce;
    if (reduce) {
      _ticker.stop();
      _last = null;
      _offset.value = 0.0;
    } else if (!_ticker.isActive) {
      _last = null;
      _ticker.start();
    }
  }

  @override
  void didUpdateWidget(covariant AutoScrollTicker old) {
    super.didUpdateWidget(old);
    if (!identical(old.items, widget.items)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    }
  }

  void _onTick(Duration elapsed) {
    if (_hovered || _reduceMotion || _cycleWidth <= 1.0) {
      _last = elapsed;
      return;
    }
    final prev = _last;
    _last = elapsed;
    if (prev == null) return;
    final dt = (elapsed - prev).inMicroseconds / Duration.microsecondsPerSecond;
    if (dt <= 0) return;
    final next = _offset.value + _speed * math.min(dt, 0.05);
    _offset.value = next >= _cycleWidth ? next % _cycleWidth : next;
  }

  void _measure() {
    if (!mounted) return;
    final ro = _rowKey.currentContext?.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize || ro.size.width <= 0) return;
    _cycleWidth = ro.size.width + _gap;
    if (_offset.value >= _cycleWidth) _offset.value %= _cycleWidth;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _offset.dispose();
    super.dispose();
  }

  Widget _row({Key? key}) => Row(
    key: key,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < widget.items.length; i++) ...[
        if (i > 0) const SizedBox(width: _gap),
        widget.items[i],
      ],
    ],
  );

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();

    return MouseRegion(
      onEnter: (_) {
        _hovered = true;
        _last = null;
      },
      onExit: (_) {
        _hovered = false;
        _last = null;
      },
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: ClipRect(
          child: ValueListenableBuilder<double>(
            valueListenable: _offset,
            // The row is drawn twice so the loop has no gap; OverflowBox lets it be wider than the viewport.
            child: RepaintBoundary(
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                minWidth: 0,
                maxWidth: double.infinity,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _row(key: _rowKey),
                    const SizedBox(width: _gap),
                    _row(),
                  ],
                ),
              ),
            ),
            builder: (context, offset, child) =>
                Transform.translate(offset: Offset(-offset, 0), child: child),
          ),
        ),
      ),
    );
  }
}

/// Trend line for a scorecard, from a 12-entry monthly series (January first).
///
/// Only finished months are used (dashCompleteMonths): the month in progress is left off, because a few days of it
/// drawn next to whole months reads as a collapse. The line starts one month before the first non-zero value so it
/// doesn't open with a long flat stretch. Returns null when there are fewer than two points, so the card shows no
/// line rather than a dot.
List<double>? dashTrend(List<double> monthly, int year) {
  final pts = monthly.take(dashCompleteMonths(year)).toList();
  final first = pts.indexWhere((v) => v > 0);
  final trimmed = first < 0 ? pts : pts.sublist(math.max(0, first - 1));
  return trimmed.length >= 2 ? trimmed : null;
}
