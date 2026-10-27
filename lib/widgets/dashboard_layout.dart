import 'dart:async';

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'dashboard_data.dart';

/// Design tokens in one place so the header, selector and body stay consistent.
abstract final class _DashTokens {
  static const background = AppTheme.bgColor; // one shared page colour for the whole app
  static const header = Color(0xFF0F172A);
  static const surface = Color(0xFF1E293B);
  static const border = Color(0xFF334155);
  static const muted = Color(0xFF94A3B8);
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
            title: widget.title,
            subtitle: widget.subtitle,
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

class _HeaderBar extends StatelessWidget {
  final String title;
  final String? subtitle;
  final DashFreshness? freshness;
  final List<Widget> actions;
  final Widget? yearSelector;

  const _HeaderBar({
    required this.title,
    required this.subtitle,
    required this.freshness,
    required this.actions,
    required this.yearSelector,
  });

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < _DashTokens.compactBreakpoint;

    final bar = Container(
      decoration: const BoxDecoration(
        color: _DashTokens.header,
        border: Border(bottom: BorderSide(color: _DashTokens.border)),
        boxShadow: [
          BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      child: SafeArea(
        bottom: false,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 24, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${title.toUpperCase()} DASHBOARD',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2,
                          ),
                        ),
                        if (subtitle != null && !compact)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _DashTokens.muted,
                                fontSize: 12,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (freshness != null) ...[
                  _FreshnessStatus(freshness: freshness!, compact: compact),
                  const SizedBox(width: 8),
                ],
                if (actions.isNotEmpty) ...[
                  IconTheme(
                    data: const IconThemeData(color: Colors.white, size: 20),
                    child: Row(mainAxisSize: MainAxisSize.min, children: actions),
                  ),
                  const SizedBox(width: 8),
                ],
                ?yearSelector,
              ],
            ),
          ),
        ),
      ),
    );

    if (freshness == null) return bar;
    // A thin bar along the bottom edge while a refresh runs, drawn over the header so nothing below moves.
    return Stack(
      children: [
        bar,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: ListenableBuilder(
            listenable: freshness!,
            builder: (context, _) => freshness!.busy && freshness!.updatedAt != null
                ? const LinearProgressIndicator(
                    minHeight: 2,
                    backgroundColor: Colors.transparent,
                    color: Color(0xFF38BDF8),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}

/// "Updated 3 min ago" and a Refresh button. The hover text says whether that is when the server computed the
/// figures or only when they arrived (a server that doesn't report it yet).
class _FreshnessStatus extends StatefulWidget {
  final DashFreshness freshness;
  final bool compact;
  const _FreshnessStatus({required this.freshness, required this.compact});

  @override
  State<_FreshnessStatus> createState() => _FreshnessStatusState();
}

class _FreshnessStatusState extends State<_FreshnessStatus> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Keeps "N min ago" honest. One rebuild of this label a minute; nothing else redraws.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
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
    return ListenableBuilder(
      listenable: widget.freshness,
      builder: (context, _) {
        final f = widget.freshness;
        final at = f.updatedAt;
        final failed = f.refreshFailure;
        if (at == null && !f.busy) return const SizedBox.shrink();

        final String label;
        final String tip;
        if (failed != null) {
          label = "Couldn't refresh";
          tip = '${failed.message}${at == null ? '' : '\nShowing figures from ${_clock(at)}.'}';
        } else if (f.busy) {
          label = at == null ? 'Loading…' : 'Refreshing…';
          tip = at == null ? 'Loading the latest figures.' : 'Showing figures from ${_clock(at)} until the new ones arrive.';
        } else {
          label = 'Updated ${_ago(at!)}';
          tip = f.isComputedTime ? 'Figures computed at ${_clock(at)}.' : 'Figures loaded at ${_clock(at)}.';
        }

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!widget.compact)
              Tooltip(
                message: tip,
                child: Text(
                  label,
                  style: TextStyle(
                    color: failed != null ? const Color(0xFFFBBF24) : _DashTokens.muted,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: widget.compact ? '$label. Refresh now' : 'Refresh now',
              iconSize: 20,
              color: Colors.white,
              disabledColor: _DashTokens.border,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              padding: EdgeInsets.zero,
              onPressed: f.onRefresh,
            ),
          ],
        );
      },
    );
  }
}

class _YearSelector extends StatelessWidget {
  final int value;
  final List<int> years; // newest first
  final ValueChanged<int> onChanged;

  const _YearSelector({
    required this.value,
    required this.years,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final i = years.indexOf(value);
    final hasNewer = i > 0;
    final hasOlder = i >= 0 && i < years.length - 1;

    return Container(
      decoration: BoxDecoration(
        color: _DashTokens.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _DashTokens.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StepButton(
            icon: Icons.chevron_left_rounded,
            tooltip: 'Previous year',
            onPressed: hasOlder ? () => onChanged(years[i + 1]) : null,
          ),
          PopupMenuButton<int>(
            tooltip: 'Select year',
            initialValue: value,
            color: _DashTokens.surface,
            onSelected: onChanged,
            itemBuilder: (_) => [
              for (final y in years)
                PopupMenuItem<int>(
                  value: y,
                  child: Text(
                    '$y',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: y == value ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$value',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 2),
                  const Icon(Icons.keyboard_arrow_down_rounded,
                      color: Colors.white, size: 18),
                ],
              ),
            ),
          ),
          _StepButton(
            icon: Icons.chevron_right_rounded,
            tooltip: 'Next year',
            onPressed: hasNewer ? () => onChanged(years[i - 1]) : null,
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
    return IconButton(
      icon: Icon(icon),
      tooltip: tooltip,
      iconSize: 20,
      color: Colors.white,
      disabledColor: _DashTokens.border,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      padding: EdgeInsets.zero,
      onPressed: onPressed,
    );
  }
}