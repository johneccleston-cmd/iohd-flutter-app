// The app's standard title bar, "the ribbon": the navy band every screen starts with (dashboards, KPI pages, full
// list pages, HR screens). One look and one set of motions everywhere, so build page titles with these and never a
// hand-made dark Container.
//
//   AppRibbon       the standard bar: icon tile, heading (with an optional quieter "kind"), subtitle, badges after the
//                   heading, controls on the right.
//   RibbonSurface   just the band (colour, light, motion) around your own content, for a toolbar that needs its own
//                   layout (Payroll's two rows).
//   RibbonActivity  what a page tells its ribbon about a refresh: the light running along the edge and the turning
//                   Refresh icon while it runs, the band of light again when new figures land.
//   RibbonMotion    read by widgets inside the ribbon: the opening and the refresh run (RibbonMotion.of(context)).
//
// Motion, all of it off with the system's reduce-motion setting: as the page opens the icon pops in, the heading
// slides in and the controls follow, while a band of light crosses the ribbon.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'dashboard_kit.dart';

/// The ribbon's colours, all derived from the app tokens.
abstract final class RibbonColors {
  static const base = DashUi.ink;

  /// The left end, behind the title: the navy turned toward blue.
  static final glow = Color.lerp(DashUi.ink, DashUi.blue, 0.24)!;

  /// The right end, under the controls: a touch of indigo.
  static final end = Color.lerp(DashUi.ink, DashUi.indigo, 0.1)!;

  /// Text that sits second on the ribbon (the "kind", subtitles, "Updated 3 min ago").
  static const quiet = DashUi.muted;

  /// Light on the ribbon: the lit bottom edge, a refresh running, a selected item in a ribbon menu.
  static const live = Color(0xFF38BDF8);

  /// A problem worth seeing on the navy ("Couldn't refresh").
  static const warn = Color(0xFFFBBF24);

  /// Menus that drop from the ribbon.
  static const menu = Color(0xFF1E293B);
  static final glass = Colors.white.withValues(alpha: 0.06);
  static final glassEdge = Colors.white.withValues(alpha: 0.14);
  static final disabled = Colors.white.withValues(alpha: 0.24);
}

/// What a page tells its ribbon about a refresh. Safe to update while the page is building: the ribbon only drives
/// its animations from it and never rebuilds.
class RibbonActivity extends ChangeNotifier {
  bool _refreshing = false;
  int _landings = 0;

  /// A refresh is out while the old figures stay on screen.
  bool get refreshing => _refreshing;

  /// How many times new figures have landed (each one sends the band of light across again).
  int get landings => _landings;

  void setRefreshing(bool value) {
    if (value == _refreshing) return;
    _refreshing = value;
    notifyListeners();
  }

  void landed() {
    _landings++;
    notifyListeners();
  }
}

/// The ribbon's animations, for widgets inside it.
class RibbonMotion extends InheritedWidget {
  /// 0 → 1 once as the page opens (already 1 with reduce motion).
  final Animation<double> open;

  /// Runs 0 → 1 over and over while a refresh is out (one turn of a Refresh icon), then comes to rest at 0.
  final Animation<double> busy;

  const RibbonMotion({super.key, required this.open, required this.busy, required super.child});

  static RibbonMotion? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<RibbonMotion>();

  @override
  bool updateShouldNotify(RibbonMotion old) => old.open != open || old.busy != busy;
}

/// The band itself: the navy gradient with light from above, the lit bottom edge, the opening sweep, and (with an
/// [activity]) the refresh light. [child] decides its own height and padding. Not clipped, so a photo can hang over.
class RibbonSurface extends StatefulWidget {
  final Widget child;
  final RibbonActivity? activity;
  const RibbonSurface({super.key, required this.child, this.activity});

  @override
  State<RibbonSurface> createState() => _RibbonSurfaceState();
}

class _RibbonSurfaceState extends State<RibbonSurface> with TickerProviderStateMixin {
  late final _open = AnimationController(vsync: this, duration: const Duration(milliseconds: 820));
  late final _sheen = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300));
  late final _busy = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  bool _still = false;
  bool _started = false;
  bool _refreshing = false;
  int _landings = 0;

  @override
  void initState() {
    super.initState();
    _follow(widget.activity);
  }

  void _follow(RibbonActivity? a) {
    a?.addListener(_onActivity);
    _refreshing = a?.refreshing ?? false;
    _landings = a?.landings ?? 0;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.disableAnimationsOf(context);
    if (_started) return;
    _started = true;
    if (_still) {
      _open.value = 1;
    } else {
      _open.forward();
      _sheen.forward();
    }
  }

  @override
  void didUpdateWidget(RibbonSurface old) {
    super.didUpdateWidget(old);
    if (old.activity != widget.activity) {
      old.activity?.removeListener(_onActivity);
      _follow(widget.activity);
    }
  }

  @override
  void dispose() {
    widget.activity?.removeListener(_onActivity);
    _open.dispose();
    _sheen.dispose();
    _busy.dispose();
    super.dispose();
  }

  // Runs while the page below is building, so it only drives controllers (painters and transitions pick them up next
  // frame) and never rebuilds the ribbon.
  void _onActivity() {
    final a = widget.activity!;
    if (a.landings != _landings) {
      _landings = a.landings;
      if (!_still) _sheen.forward(from: 0);
    }
    if (a.refreshing == _refreshing) return;
    _refreshing = a.refreshing;
    if (_still) return;
    if (_refreshing) {
      _busy.repeat();
    } else {
      // A Refresh icon finishes its turn quickly and comes to rest upright.
      _busy.animateTo(1, duration: Duration(milliseconds: (450 * (1 - _busy.value)).round() + 1), curve: Curves.easeOut).then((_) {
        if (!_refreshing) _busy.value = 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [RibbonColors.glow, RibbonColors.base, RibbonColors.base, RibbonColors.end],
            stops: const [0, 0.5, 0.78, 1],
          ),
          boxShadow: [BoxShadow(color: DashUi.ink.withValues(alpha: 0.22), blurRadius: 10, offset: const Offset(0, 2))],
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Light from above, so the ribbon reads as a raised band rather than a flat fill.
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.white.withValues(alpha: 0.06), Colors.white.withValues(alpha: 0)],
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(child: ClipRect(child: CustomPaint(painter: _SheenPainter(_sheen)))),
            ),
            RibbonMotion(open: _open, busy: _busy, child: widget.child),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 2,
              child: IgnorePointer(
                child: CustomPaint(painter: _EdgePainter(run: _busy, activity: widget.activity, still: _still)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The standard ribbon: [leading] (a back button, a photo) or the page's menu [icon] on a tile, the [title] (with
/// [kind] after it in a quieter tone, left off on a phone), a [subtitle] under it, [titleTrailing] badges after it,
/// and [controls] on the right. At least 56 px tall, the same on every screen.
class AppRibbon extends StatelessWidget {
  /// Shown as written; pass it in capitals ("PAYROLL", or a person's name).
  final String title;
  final String? kind;
  final String? subtitle;
  final Widget? leading;
  final IconData? icon;
  final Widget? titleTrailing;
  final List<Widget> controls;
  final RibbonActivity? activity;

  /// Side padding on a phone-width window (24 otherwise).
  final double compactSide;

  const AppRibbon({
    super.key,
    required this.title,
    this.kind,
    this.subtitle,
    this.leading,
    this.icon,
    this.titleTrailing,
    this.controls = const [],
    this.activity,
    this.compactSide = 12,
  });

  /// Below this window width the ribbon is on a phone: no icon tile, no [kind], no subtitle.
  static const compactWidth = 600.0;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < compactWidth;
    final heading = RibbonTitle(title, kind: compact ? null : kind, subtitle: compact ? null : subtitle);

    return RibbonSurface(
      activity: activity,
      child: SafeArea(
        bottom: false,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? compactSide : 24, vertical: 8),
            child: Row(
              children: [
                if (leading != null) ...[
                  leading!,
                  const SizedBox(width: 12),
                ] else if (icon != null && !compact) ...[
                  RibbonIcon(icon!),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: RibbonArrive(
                    interval: const Interval(0.08, 0.7, curve: Curves.easeOutCubic),
                    dx: -14,
                    child: titleTrailing == null
                        ? heading
                        : LayoutBuilder(
                            builder: (context, c) => Row(
                              children: [
                                // The heading takes the room it needs (at most 42%); the badges shrink to fit the rest.
                                ConstrainedBox(constraints: BoxConstraints(maxWidth: c.maxWidth * 0.42), child: heading),
                                const SizedBox(width: 16),
                                Flexible(
                                  child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: titleTrailing!),
                                ),
                              ],
                            ),
                          ),
                  ),
                ),
                if (controls.isNotEmpty)
                  RibbonArrive(
                    interval: const Interval(0.22, 0.9, curve: Curves.easeOutCubic),
                    dx: 10,
                    child: IconTheme.merge(
                      data: const IconThemeData(color: Colors.white),
                      child: Row(mainAxisSize: MainAxisSize.min, children: controls),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The ribbon's heading: white capitals, an optional quieter [kind] after them ("COLLECTIONS DASHBOARD"), an optional
/// [subtitle] underneath. One line each, ellipsized. Marked as the page's header for screen readers.
class RibbonTitle extends StatelessWidget {
  final String title;
  final String? kind;
  final String? subtitle;
  const RibbonTitle(this.title, {super.key, this.kind, this.subtitle});

  static const style = TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.3);

  @override
  Widget build(BuildContext context) {
    final Widget line = kind == null
        ? Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: style)
        : Text.rich(
            TextSpan(
              text: title,
              children: [
                TextSpan(text: ' $kind', style: const TextStyle(color: RibbonColors.quiet, fontWeight: FontWeight.w600)),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          );
    return Semantics(
      header: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          line,
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: RibbonColors.quiet, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

/// [child] fading in and sliding [dx] px into place over [interval] of the ribbon's opening (still outside one).
class RibbonArrive extends StatelessWidget {
  final Interval interval;
  final double dx;
  final Widget child;
  const RibbonArrive({super.key, required this.interval, required this.dx, required this.child});

  @override
  Widget build(BuildContext context) {
    final open = RibbonMotion.maybeOf(context)?.open;
    if (open == null) return child;
    final t = CurvedAnimation(parent: open, curve: interval);
    return AnimatedBuilder(
      animation: t,
      builder: (context, child) => Opacity(
        opacity: t.value,
        child: Transform.translate(offset: Offset(dx * (1 - t.value), 0), child: child),
      ),
      child: child,
    );
  }
}

/// The page's menu icon on a sky-to-indigo tile (the colours of the ring around a person's photo on the KPI pages).
/// Pops in with a little overshoot and a quarter-turn settle as the page opens.
class RibbonIcon extends StatelessWidget {
  final IconData icon;
  const RibbonIcon(this.icon, {super.key});

  @override
  Widget build(BuildContext context) {
    final tile = ExcludeSemantics(
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [DashUi.sky, DashUi.indigo],
          ),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
          boxShadow: [BoxShadow(color: DashUi.blue.withValues(alpha: 0.35), blurRadius: 12, offset: const Offset(0, 2))],
        ),
        child: Icon(icon, size: 19, color: Colors.white),
      ),
    );
    final open = RibbonMotion.maybeOf(context)?.open;
    if (open == null) return tile;
    final grow = CurvedAnimation(parent: open, curve: const Interval(0, 0.6, curve: Curves.easeOutBack));
    final show = CurvedAnimation(parent: open, curve: const Interval(0, 0.3));
    return AnimatedBuilder(
      animation: open,
      builder: (context, child) => Opacity(
        opacity: show.value,
        child: Transform.rotate(
          angle: -0.5 * (1 - grow.value),
          child: Transform.scale(scale: 0.4 + 0.6 * grow.value, child: child),
        ),
      ),
      child: tile,
    );
  }
}

/// A Refresh button for the ribbon. With [activity]-driven refreshes it turns while one runs.
class RibbonRefreshButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String tooltip;
  const RibbonRefreshButton({super.key, required this.onPressed, this.tooltip = 'Refresh'});

  @override
  Widget build(BuildContext context) {
    final busy = RibbonMotion.maybeOf(context)?.busy;
    const icon = Icon(Icons.refresh_rounded);
    return IconButton(
      tooltip: tooltip,
      iconSize: 20,
      color: Colors.white,
      disabledColor: RibbonColors.disabled,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      padding: EdgeInsets.zero,
      icon: busy == null ? icon : RotationTransition(turns: busy, child: icon),
      onPressed: onPressed,
    );
  }
}

/// A slanted band of light that crosses the ribbon once per run of [t], brightest half-way across.
class _SheenPainter extends CustomPainter {
  final Animation<double> t;
  _SheenPainter(this.t) : super(repaint: t);

  @override
  void paint(Canvas canvas, Size size) {
    final v = t.value;
    if (v <= 0 || v >= 1) return;
    final band = math.max(180.0, size.width * 0.24);
    final mid = Offset(-band + (size.width + band * 2) * Curves.easeInOutCubic.transform(v), size.height / 2);
    const lean = Offset(0.94, 0.34); // about 20 degrees off upright
    final peak = Colors.white.withValues(alpha: 0.12 * math.sin(math.pi * v));
    final clear = Colors.white.withValues(alpha: 0);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..shader = ui.Gradient.linear(mid - lean * (band / 2), mid + lean * (band / 2), [clear, peak, clear], const [0, 0.5, 1]),
    );
  }

  @override
  bool shouldRepaint(_SheenPainter old) => old.t != t;
}

/// The ribbon's lit bottom edge: a hairline of light under the heading that fades out toward the controls. While a
/// refresh is out, a brighter streak runs along it (a still bar with reduce motion).
class _EdgePainter extends CustomPainter {
  final Animation<double> run;
  final RibbonActivity? activity;
  final bool still;
  _EdgePainter({required this.run, required this.activity, required this.still})
      : super(repaint: Listenable.merge([run, activity]));

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final line = Rect.fromLTWH(0, h - 1, w, 1);
    canvas.drawRect(
      line,
      Paint()
        ..shader = ui.Gradient.linear(
          line.topLeft,
          line.topRight,
          [
            RibbonColors.live.withValues(alpha: 0),
            RibbonColors.live.withValues(alpha: 0.55),
            DashUi.indigo.withValues(alpha: 0.4),
            DashUi.indigo.withValues(alpha: 0),
          ],
          const [0, 0.12, 0.45, 0.8],
        ),
    );

    if (activity?.refreshing != true) return;
    if (still) {
      canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = RibbonColors.live.withValues(alpha: 0.7));
      return;
    }
    final seg = math.max(140.0, w * 0.28);
    final streak = Rect.fromLTWH(-seg + (w + seg) * Curves.easeInOut.transform(run.value), 0, seg, h);
    canvas.drawRect(
      streak,
      Paint()
        ..shader = ui.Gradient.linear(
          streak.centerLeft,
          streak.centerRight,
          [RibbonColors.live.withValues(alpha: 0), RibbonColors.live, Colors.white],
          const [0, 0.8, 1],
        ),
    );
  }

  @override
  bool shouldRepaint(_EdgePainter old) => old.run != run || old.activity != activity || old.still != still;
}
