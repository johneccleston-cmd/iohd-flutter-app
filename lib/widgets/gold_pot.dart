import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'dashboard_kit.dart';

// A pot of gold for the Financial dashboard's pool card. It plays once when it appears (coins drop in and pile up,
// then a glint crosses the pot) and again when hovered or tapped; the rest of the time it stands still. With
// reduced motion it is simply drawn full.

const _goldLight = Color(0xFFFBE27A);
const _gold = Color(0xFFF2B01E);
const _goldDeep = Color(0xFFB7791F);
const _goldEdge = Color(0xFF7C4A03);

class GoldPot extends StatefulWidget {
  final double size;
  const GoldPot({super.key, this.size = 88});

  @override
  State<GoldPot> createState() => _GoldPotState();
}

class _GoldPotState extends State<GoldPot> with SingleTickerProviderStateMixin {
  late final AnimationController _run = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));
  bool _reduceMotion = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) {
      _run.value = 1;
    } else if (!_started) {
      _started = true;
      _run.forward();
    }
  }

  void _replay() {
    if (_reduceMotion || _run.isAnimating) return;
    _run.forward(from: 0);
  }

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: MouseRegion(
        onEnter: (_) => _replay(),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: _replay,
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _run,
              builder: (context, _) => CustomPaint(
                size: Size.square(widget.size),
                painter: _PotPainter(_run.value),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Coin {
  /// Where the coin comes to rest in the heap, as a share of the box.
  final double x, y;

  /// When it lands (0..1 of the run).
  final double lands;
  const _Coin(this.x, this.y, this.lands);
}

const _heap = [
  _Coin(0.30, 0.46, 0.22),
  _Coin(0.70, 0.46, 0.30),
  _Coin(0.50, 0.50, 0.26),
  _Coin(0.40, 0.38, 0.40),
  _Coin(0.60, 0.38, 0.48),
  _Coin(0.50, 0.30, 0.58),
  _Coin(0.33, 0.33, 0.66),
  _Coin(0.67, 0.33, 0.72),
  _Coin(0.50, 0.21, 0.80),
];

class _PotPainter extends CustomPainter {
  final double t;
  _PotPainter(this.t);

  double _ease(double v) => Curves.easeInCubic.transform(v.clamp(0.0, 1.0));

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final coinR = w * 0.095;

    // Soft glow behind the heap, growing as the pot fills.
    final fill = (t / 0.8).clamp(0.0, 1.0);
    canvas.drawCircle(
      Offset(w * 0.5, h * 0.42),
      w * (0.30 + 0.16 * fill),
      Paint()
        ..shader = RadialGradient(
          colors: [_gold.withValues(alpha: 0.38 * fill), _gold.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: Offset(w * 0.5, h * 0.42), radius: w * 0.5)),
    );

    // Coins resting in the heap (behind the pot's front wall).
    for (final c in _heap) {
      if (t < c.lands) continue;
      final pop = ((t - c.lands) / 0.08).clamp(0.0, 1.0);
      final scale = 0.7 + 0.3 * Curves.easeOutBack.transform(pop);
      _coin(canvas, Offset(w * c.x, h * c.y), coinR * scale, 1);
    }

    // Coins in the air: each drops from above into its place in the heap, spinning as it falls.
    for (var i = 0; i < _heap.length; i++) {
      final c = _heap[i];
      final start = c.lands - 0.2;
      if (t < start || t >= c.lands) continue;
      final p = _ease((t - start) / 0.2);
      final from = Offset(w * (0.5 + (i.isEven ? -0.12 : 0.12)), -coinR * 2);
      final to = Offset(w * c.x, h * c.y);
      _coin(canvas, Offset.lerp(from, to, p)!, coinR, (math.cos((t - start) * 38)).abs().clamp(0.25, 1.0));
    }

    _pot(canvas, size);

    // A glint crossing the pot once it is full.
    final g = ((t - 0.82) / 0.18).clamp(0.0, 1.0);
    if (g > 0 && g < 1) {
      final x = w * (-0.1 + 1.2 * g);
      canvas.save();
      canvas.clipPath(_potPath(size));
      canvas.drawPath(
        Path()
          ..moveTo(x, h * 0.4)
          ..lineTo(x + w * 0.10, h * 0.4)
          ..lineTo(x + w * 0.02, h)
          ..lineTo(x - w * 0.08, h)
          ..close(),
        Paint()..color = Colors.white.withValues(alpha: 0.22 * math.sin(g * math.pi)),
      );
      canvas.restore();
    }

    // Sparkles over the heap.
    final s = ((t - 0.78) / 0.22).clamp(0.0, 1.0);
    if (s > 0 && s < 1) {
      final a = math.sin(s * math.pi);
      _sparkle(canvas, Offset(w * 0.24, h * 0.18), w * 0.07 * a);
      _sparkle(canvas, Offset(w * 0.80, h * 0.12), w * 0.09 * a);
      _sparkle(canvas, Offset(w * 0.62, h * 0.04), w * 0.05 * a);
    }
  }

  Path _potPath(Size size) {
    final w = size.width, h = size.height;
    return Path()
      ..moveTo(w * 0.16, h * 0.50)
      ..quadraticBezierTo(w * 0.04, h * 0.80, w * 0.22, h * 0.92)
      ..quadraticBezierTo(w * 0.50, h * 1.02, w * 0.78, h * 0.92)
      ..quadraticBezierTo(w * 0.96, h * 0.80, w * 0.84, h * 0.50)
      ..close();
  }

  void _pot(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final body = _potPath(size);
    canvas.drawPath(
      body,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [DashUi.slate, DashUi.ink],
        ).createShader(Offset.zero & size),
    );
    // Gold band and the rim lip.
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.10, h * 0.50, w * 0.80, h * 0.065), Radius.circular(h * 0.03)),
      Paint()..color = _gold,
    );
    canvas.drawOval(
      Rect.fromLTWH(w * 0.34, h * 0.70, w * 0.32, h * 0.12),
      Paint()..color = _goldDeep.withValues(alpha: 0.9),
    );
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.24, h * 0.58)
        ..quadraticBezierTo(w * 0.17, h * 0.76, w * 0.26, h * 0.86),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.02
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: 0.22),
    );
  }

  void _coin(Canvas canvas, Offset c, double r, double squash) {
    final rect = Rect.fromCenter(center: c, width: r * 2 * squash, height: r * 2);
    canvas.drawOval(
      rect,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.4, -0.5),
          colors: [_goldLight, _gold, _goldDeep],
          stops: [0, 0.55, 1],
        ).createShader(rect),
    );
    canvas.drawOval(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.16
        ..color = _goldEdge.withValues(alpha: 0.75),
    );
    if (squash > 0.6) {
      canvas.drawOval(
        Rect.fromCenter(center: c, width: r * 1.0 * squash, height: r * 1.0),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.12
          ..color = _goldDeep.withValues(alpha: 0.8),
      );
    }
  }

  void _sparkle(Canvas canvas, Offset c, double r) {
    if (r <= 0.5) return;
    final p = Path()
      ..moveTo(c.dx, c.dy - r)
      ..quadraticBezierTo(c.dx, c.dy, c.dx + r, c.dy)
      ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy + r)
      ..quadraticBezierTo(c.dx, c.dy, c.dx - r, c.dy)
      ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy - r)
      ..close();
    canvas.drawPath(p, Paint()..color = _goldLight);
  }

  @override
  bool shouldRepaint(_PotPainter old) => old.t != t;
}
