import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'dashboard_data.dart';
import 'app_ribbon.dart';
import 'dashboard_kit.dart';

/// Design tokens in one place so the header, selector and body stay consistent (the ribbon's own are [RibbonColors]).
abstract final class _DashTokens {
  static const background = AppTheme.bgColor; // one shared page colour for the whole app
  static const maxContentWidth = 1600.0;
  static const compactBreakpoint = 600.0;
}

/// Exposes the selected year to any descendant without re-threading the
/// builder callback: `DashboardScope.yearOf(context)`.
class DashboardScope extends InheritedWidget {
  final int selectedYear;

  const DashboardScope({
    super.key,
    required this.selectedYear,
    required super.child,
  });

  static int yearOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<DashboardScope>();
    assert(scope != null, 'No DashboardScope found in context');
    return scope!.selectedYear;
  }

  @override
  bool updateShouldNotify(DashboardScope old) => selectedYear != old.selectedYear;
}

class DashboardLayout extends StatefulWidget {
  final String title;
  final String? subtitle;

  /// The title bar's text as written, instead of "<TITLE> DASHBOARD" (a person's page uses their name).
  final String? heading;

  /// Shown at the start of the title bar, before the heading (a back button, a photo).
  final Widget? leading;

  /// The dashboard's menu icon, on a tile before the heading (not with [leading], nor on a phone).
  final IconData? icon;

  /// Shown right after the heading (badges about the person: rank, time with the company, a score).
  final Widget? titleTrailing;
  final bool showYearSelector;

  /// Set false to drop the dark title bar entirely (the page then starts at the top).
  final bool showHeader;

  /// Years offered in the selector. Defaults to the current year and the two before it.
  final List<int>? years;

  /// Initially selected year. Defaults to the current year (or the newest available).
  final int? initialYear;

  final ValueChanged<int>? onYearChanged;

  /// Extra header widgets (refresh, export, filters) shown before the year selector.
  final List<Widget> actions;

  final Widget Function(BuildContext context, int selectedYear) builder;

  /// Show when the figures were computed and a Refresh button (the content reports through DashboardLoading).
  final bool showFreshness;

  const DashboardLayout({
    super.key,
    required this.title,
    this.subtitle,
    this.heading,
    this.leading,
    this.icon,
    this.titleTrailing,
    this.showYearSelector = true,
    this.showHeader = true,
    this.years,
    this.initialYear,
    this.onYearChanged,
    this.actions = const [],
    required this.builder,
    this.showFreshness = true,
  });

  @override
  State<DashboardLayout> createState() => _DashboardLayoutState();
}

class _DashboardLayoutState extends State<DashboardLayout> {
  late List<int> _years;
  late int _selectedYear;
  final _freshness = DashFreshness();

  @override
  void dispose() {
    _freshness.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _years = _resolveYears();
    _selectedYear = _pickInitial();
  }

  @override
  void didUpdateWidget(covariant DashboardLayout old) {
    super.didUpdateWidget(old);
    _years = _resolveYears();
    if (!_years.contains(_selectedYear)) _selectedYear = _pickInitial();
  }

  /// Newest first, de-duplicated.
  List<int> _resolveYears() {
    final now = DashClock.now().year;
    final list = {...(widget.years ?? [now, now - 1, now - 2])}.toList()
      ..sort((a, b) => b.compareTo(a));
    return list;
  }

  int _pickInitial() {
    final wanted = widget.initialYear ?? DashClock.now().year;
    return _years.contains(wanted) ? wanted : _years.first;
  }

  void _setYear(int year) {
    if (year == _selectedYear) return;
    setState(() => _selectedYear = year);
    widget.onYearChanged?.call(year);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _DashTokens.background,
      child: Column(
        children: [
          if (widget.showHeader)
            _HeaderBar(
            title: widget.heading ?? widget.title.toUpperCase(),
            kind: widget.heading == null ? 'DASHBOARD' : null,
            subtitle: widget.subtitle,
            leading: widget.leading,
            icon: widget.icon,
            titleTrailing: widget.titleTrailing,
            freshness: widget.showFreshness ? _freshness : null,
            actions: widget.actions,
            yearSelector: widget.showYearSelector
                ? _YearSelector(
                    value: _selectedYear,
                    years: _years,
                    onChanged: _setYear,
                  )
                : null,
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                final pad = w < _DashTokens.compactBreakpoint
                    ? 12.0
                    : w < 1000
                        ? 16.0
                        : 24.0;

                return Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: _DashTokens.maxContentWidth,
                    ),
                    child: Padding(
                      // A little less space under the header banner and above the bottom edge than at the sides, so the content gets more height.
                      padding: EdgeInsets.fromLTRB(pad, (pad * 0.6).roundToDouble(), pad, (pad * 0.6).roundToDouble()),
                      // Fade between years so data swaps don't feel like a hard jump.
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        switchInCurve: Curves.easeOut,
                        child: KeyedSubtree(
                          key: ValueKey(_selectedYear),
                          child: DashboardScope(
                            selectedYear: _selectedYear,
                            child: DashFreshnessScope(
                              freshness: _freshness,
                              child: widget.builder(context, _selectedYear),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The ribbon along the top of every dashboard and KPI page (the app's standard [AppRibbon]), with the freshness,
/// actions and year picker as its controls. A refresh the dashboard reports runs the ribbon's refresh light, and new
/// figures landing send its band of light across again.
class _HeaderBar extends StatefulWidget {
  /// The heading as shown ("COLLECTIONS", or a person's name).
  final String title;

  /// What the page is ("DASHBOARD"), after the heading in a quieter tone.
  final String? kind;
  final String? subtitle;
  final Widget? leading;
  final IconData? icon;
  final Widget? titleTrailing;
  final DashFreshness? freshness;
  final List<Widget> actions;
  final Widget? yearSelector;

  const _HeaderBar({
    required this.title,
    this.kind,
    required this.subtitle,
    this.leading,
    this.icon,
    this.titleTrailing,
    required this.freshness,
    required this.actions,
    required this.yearSelector,
  });

  @override
  State<_HeaderBar> createState() => _HeaderBarState();
}

class _HeaderBarState extends State<_HeaderBar> {
  final _activity = RibbonActivity();
  bool _wasRefreshing = false;

  @override
  void initState() {
    super.initState();
    widget.freshness?.addListener(_onFreshness);
  }

  @override
  void didUpdateWidget(_HeaderBar old) {
    super.didUpdateWidget(old);
    if (old.freshness != widget.freshness) {
      old.freshness?.removeListener(_onFreshness);
      widget.freshness?.addListener(_onFreshness);
    }
  }

  @override
  void dispose() {
    widget.freshness?.removeListener(_onFreshness);
    _activity.dispose();
    super.dispose();
  }

  // Reports arrive while the dashboard below is building; the activity only drives the ribbon's animations.
  void _onFreshness() {
    final f = widget.freshness!;
    final refreshing = f.busy && f.updatedAt != null;
    if (_wasRefreshing && !refreshing && f.refreshFailure == null && f.updatedAt != null) _activity.landed();
    _wasRefreshing = refreshing;
    _activity.setRefreshing(refreshing);
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < AppRibbon.compactWidth;
    return AppRibbon(
      title: widget.title,
      kind: widget.kind,
      subtitle: widget.subtitle,
      leading: widget.leading,
      icon: widget.icon,
      titleTrailing: widget.titleTrailing,
      activity: _activity,
      controls: [
        if (widget.freshness != null) ...[
          _FreshnessStatus(freshness: widget.freshness!, compact: compact),
          const SizedBox(width: 8),
        ],
        if (widget.actions.isNotEmpty) ...[
          IconTheme(
            data: const IconThemeData(color: Colors.white, size: 20),
            child: Row(mainAxisSize: MainAxisSize.min, children: widget.actions),
          ),
          const SizedBox(width: 8),
        ],
        ?widget.yearSelector,
      ],
    );
  }
}

/// "Updated 3 min ago", a status dot and a Refresh button. The hover text says whether that is when the server
/// computed the figures or only when they arrived (a server that doesn't report it yet). The dot is green when the
/// figures are in (and sends out a ring as they land), blue while a refresh runs, amber when one failed.
class _FreshnessStatus extends StatefulWidget {
  final DashFreshness freshness;
  final bool compact;
  const _FreshnessStatus({required this.freshness, required this.compact});

  @override
  State<_FreshnessStatus> createState() => _FreshnessStatusState();
}

class _FreshnessStatusState extends State<_FreshnessStatus> with SingleTickerProviderStateMixin {
  Timer? _tick;
  late final _ripple = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  bool _wasBusy = false;

  @override
  void initState() {
    super.initState();
    // Keeps "N min ago" honest. One rebuild of this label a minute; nothing else redraws.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    _wasBusy = widget.freshness.busy;
    widget.freshness.addListener(_onChange);
  }

  @override
  void didUpdateWidget(_FreshnessStatus old) {
    super.didUpdateWidget(old);
    if (old.freshness != widget.freshness) {
      old.freshness.removeListener(_onChange);
      widget.freshness.addListener(_onChange);
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    widget.freshness.removeListener(_onChange);
    _ripple.dispose();
    super.dispose();
  }

  /// Figures landing (a load or refresh that worked) send a ring out from the dot. Runs mid-build of the dashboard,
  /// so it only starts the ring; its painter picks it up next frame.
  void _onChange() {
    final f = widget.freshness;
    final landed = _wasBusy && !f.busy && f.updatedAt != null && f.refreshFailure == null;
    _wasBusy = f.busy;
    if (landed && mounted && !MediaQuery.disableAnimationsOf(context)) _ripple.forward(from: 0);
  }

  static String _ago(DateTime t) {
    final d = DashClock.now().difference(t);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return 'on ${dashMonthNames[t.month - 1]} ${t.day}';
  }

  static String _clock(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}, ${dashMonthNames[t.month - 1]} ${t.day}';
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return ListenableBuilder(
      listenable: widget.freshness,
      builder: (context, _) {
        final f = widget.freshness;
        final at = f.updatedAt;
        final failed = f.refreshFailure;
        if (at == null && !f.busy) return const SizedBox.shrink();

        final String label;
        // Only a failed refresh has anything to explain on hover; "Updated 2m ago" speaks for itself.
        String? tip;
        if (failed != null) {
          label = "Couldn't refresh";
          tip = '${failed.message}${at == null ? '' : '\nShowing figures from ${_clock(at)}.'}';
        } else if (f.busy) {
          label = at == null ? 'Loading…' : 'Refreshing…';
        } else {
          label = 'Updated ${_ago(at!)}';
        }
        final tone = failed != null
            ? RibbonColors.warn
            : f.busy
                ? RibbonColors.live
                : DashUi.emerald;

        final status = TweenAnimationBuilder<double>(
          key: ValueKey(label),
          tween: Tween(begin: still ? 1 : 0, end: 1),
          duration: still ? Duration.zero : const Duration(milliseconds: 240),
          curve: Curves.easeOut,
          builder: (context, v, child) => Opacity(
            opacity: v,
            child: Transform.translate(offset: Offset(0, 4 * (1 - v)), child: child),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: failed != null ? RibbonColors.warn : RibbonColors.quiet,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        );

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!widget.compact) ...[
              CustomPaint(size: const Size.square(7), painter: _DotPainter(color: tone, ripple: _ripple)),
              const SizedBox(width: 8),
              // Each new wording rises into place (the old one goes at once, so there is never two).
              if (tip == null) status else Tooltip(message: tip, child: status),
            ],
            RibbonRefreshButton(
              tooltip: widget.compact ? '$label. Refresh now' : 'Refresh',
              onPressed: f.onRefresh,
            ),
          ],
        );
      },
    );
  }
}

class _YearSelector extends StatefulWidget {
  final int value;
  final List<int> years; // newest first
  final ValueChanged<int> onChanged;

  const _YearSelector({
    required this.value,
    required this.years,
    required this.onChanged,
  });

  @override
  State<_YearSelector> createState() => _YearSelectorState();
}

class _YearSelectorState extends State<_YearSelector> {
  /// Which way the last change went: a newer year rolls up into place like a counter, an older one rolls down.
  bool _newer = false;

  @override
  void didUpdateWidget(_YearSelector old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _newer = widget.value > old.value;
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    final years = widget.years;
    final i = years.indexOf(value);
    final hasNewer = i > 0;
    final hasOlder = i >= 0 && i < years.length - 1;
    final still = MediaQuery.disableAnimationsOf(context);

    final year = ClipRect(
      child: AnimatedSwitcher(
        duration: still ? Duration.zero : const Duration(milliseconds: 300),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          // The outgoing year runs this backwards, so it leaves on the side opposite to where the new one came in.
          final incoming = child.key == ValueKey(value);
          final from = Offset(0, (incoming ? 0.9 : -0.9) * (_newer ? 1 : -1));
          return SlideTransition(
            position: Tween(begin: from, end: Offset.zero).animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          );
        },
        child: Text(
          '$value',
          key: ValueKey(value),
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );

    return Container(
      decoration: BoxDecoration(
        color: RibbonColors.glass,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: RibbonColors.glassEdge),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StepButton(
            icon: Icons.chevron_left_rounded,
            tooltip: 'Previous year',
            onPressed: hasOlder ? () => widget.onChanged(years[i + 1]) : null,
          ),
          PopupMenuButton<int>(
            // No hover text: the year and its arrow say what this is. Screen readers still get the label.
            tooltip: '',
            initialValue: value,
            color: RibbonColors.menu,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: RibbonColors.glassEdge),
            ),
            onSelected: widget.onChanged,
            itemBuilder: (_) => [
              for (final y in years)
                PopupMenuItem<int>(
                  value: y,
                  height: 40,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 22,
                        child: y == value ? const Icon(Icons.check_rounded, size: 16, color: RibbonColors.live) : null,
                      ),
                      Text(
                        '$y',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: y == value ? FontWeight.bold : FontWeight.normal,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  year,
                  const SizedBox(width: 2),
                  const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white, size: 18),
                ],
              ),
            ),
          ),
          _StepButton(
            icon: Icons.chevron_right_rounded,
            tooltip: 'Next year',
            onPressed: hasNewer ? () => widget.onChanged(years[i - 1]) : null,
          ),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const _StepButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // No hover popup (an arrow beside a year needs none); the label is for screen readers only.
    return Semantics(
      label: tooltip,
      button: true,
      excludeSemantics: true,
      enabled: onPressed != null,
      onTap: onPressed,
      child: IconButton(
        icon: Icon(icon),
        iconSize: 20,
        color: Colors.white,
        disabledColor: RibbonColors.disabled,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        padding: EdgeInsets.zero,
        onPressed: onPressed,
      ),
    );
  }
}

/// The freshness dot, and the ring it sends out when figures land.
class _DotPainter extends CustomPainter {
  final Color color;
  final Animation<double> ripple;
  _DotPainter({required this.color, required this.ripple}) : super(repaint: ripple);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final v = ripple.value;
    if (v > 0 && v < 1) {
      // Stays inside the gap before the label.
      canvas.drawCircle(
        c,
        r + 5 * Curves.easeOut.transform(v),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = color.withValues(alpha: 0.75 * (1 - v) * (1 - v)),
      );
    }
    canvas.drawCircle(c, r, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_DotPainter old) => old.color != color || old.ripple != ripple;
}
