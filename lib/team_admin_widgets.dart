part of 'team_admin_screen.dart';

// ---------------------------------------------------------------------------
// The Team screen's moving parts: the drifting cover behind the photo, the entrance reveals, the live status dot, the
// scorecard tiles (and what goes in them, read from /api/employees/:id/kpis), and the team overview shown before anyone
// is picked. Every animation here stops, or jumps straight to its end, when the OS asks for reduced motion.
// ---------------------------------------------------------------------------

bool _calm(BuildContext context) => MediaQuery.disableAnimationsOf(context);

final NumberFormat _money0Fmt = NumberFormat.currency(symbol: r'$', decimalDigits: 0);
String _money0(double v) => _money0Fmt.format(v);
String _whole(double v) => NumberFormat.decimalPattern().format(v.round());
String _oneDp(double v) => v.toStringAsFixed(1);

/// The big faint icon on a person's cover, by roster group.
IconData _groupIcon(int group) => switch (group) {
  0 => Icons.handyman_rounded,
  1 => Icons.request_quote_rounded,
  2 => Icons.business_center_rounded,
  3 => Icons.warehouse_rounded,
  5 => Icons.person_off_rounded,
  _ => Icons.person_rounded,
};

/// "5 yrs 7 mo", "1 yr", "7 mo": how long since [d].
String _tenure(DateTime d) {
  final now = DateTime.now();
  var months = (now.year - d.year) * 12 + now.month - d.month;
  if (now.day < d.day) months--;
  if (months <= 0) return 'New this month';
  final y = months ~/ 12, m = months % 12;
  final yrs = y == 0 ? '' : '$y ${y == 1 ? 'yr' : 'yrs'}';
  final mos = m == 0 ? '' : '$m mo';
  return [yrs, mos].where((s) => s.isNotEmpty).join(' ');
}

/// Short versions of what is wrong with someone's setup, for the overview list.
List<String> _setupProblems(_Emp u) => [
  if (u.active && u.unmatched) 'No Service Fusion work matched in 90 days',
  if (u.active && !u.hasPin) 'No PIN yet',
];

// ---- Motion ------------------------------------------------------------------

/// Fades and slides [child] in once, when it is first built. Keyed by person, so opening someone else replays it.
class _Reveal extends StatefulWidget {
  final Widget child;
  final int delayMs;
  final int ms;
  final Offset from;
  final double fromScale;
  final Curve curve;
  const _Reveal({
    super.key,
    required this.child,
    this.delayMs = 0,
    this.ms = 460,
    this.from = const Offset(0, 14),
    this.fromScale = 1,
    this.curve = Curves.easeOutCubic,
  });

  @override
  State<_Reveal> createState() => _RevealState();
}

class _RevealState extends State<_Reveal> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: widget.delayMs + widget.ms),
  );

  @override
  void initState() {
    super.initState();
    _c.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_calm(context)) _c.value = 1;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final start = widget.delayMs / (widget.delayMs + widget.ms);
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        final raw = ((_c.value - start) / (1 - start)).clamp(0.0, 1.0);
        final m = widget.curve.transform(raw);
        Widget out = Transform.translate(offset: widget.from * (1 - m), child: child);
        if (widget.fromScale != 1) {
          out = Transform.scale(scale: widget.fromScale + (1 - widget.fromScale) * m, child: out);
        }
        return Opacity(opacity: Curves.easeOut.transform(raw), child: out);
      },
    );
  }
}

/// A status dot with a soft ring that keeps pulsing outwards, like a live indicator.
class _PulseDot extends StatefulWidget {
  final Color color;
  final bool pulse;
  const _PulseDot({required this.color, this.pulse = true});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _PulseDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.pulse && !_calm(context)) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SizedBox(width: 8, height: 8, child: CustomPaint(painter: _PulsePainter(_c, widget.color)));
}

class _PulsePainter extends CustomPainter {
  final Animation<double> t;
  final Color color;
  _PulsePainter(this.t, this.color) : super(repaint: t);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    final v = t.value;
    if (v > 0) canvas.drawCircle(c, r * (1 + 1.9 * v), Paint()..color = color.withValues(alpha: 0.42 * (1 - v)));
    canvas.drawCircle(c, r, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_PulsePainter old) => old.color != color;
}

/// The soft cover at the top of a profile: slow-drifting light in the person's group colour over a fine dot grid,
/// with the group's icon floating faintly on the right. Switching to someone in another group fades the colour across.
class _CoverBanner extends StatefulWidget {
  final Color accent;
  final IconData icon;
  final double height;
  final Widget? child;
  const _CoverBanner({required this.accent, required this.icon, this.height = 116, this.child});

  @override
  State<_CoverBanner> createState() => _CoverBannerState();
}

class _CoverBannerState extends State<_CoverBanner> with SingleTickerProviderStateMixin {
  // One slow loop. Every blob turns a whole number of times per loop, so the restart is seamless.
  late final AnimationController _drift = AnimationController(vsync: this, duration: const Duration(seconds: 24));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_calm(context)) {
      _drift
        ..stop()
        ..value = 0.3;
    } else if (!_drift.isAnimating) {
      _drift.repeat();
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: widget.accent),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeInOutCubic,
      builder: (context, c, _) {
        final accent = c ?? widget.accent;
        return SizedBox(
          height: widget.height,
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                RepaintBoundary(child: CustomPaint(painter: _AuroraPainter(_drift, accent))),
                Positioned(
                  right: 30,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: AnimatedBuilder(
                      animation: _drift,
                      builder: (context, child) => Transform.translate(
                        offset: Offset(0, 5 * math.sin(_drift.value * 2 * math.pi * 3)),
                        child: child,
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 420),
                        transitionBuilder: (child, a) => FadeTransition(
                          opacity: a,
                          child: ScaleTransition(scale: Tween<double>(begin: 0.8, end: 1).animate(a), child: child),
                        ),
                        child: Icon(
                          widget.icon,
                          key: ValueKey(widget.icon),
                          size: widget.height * 0.92,
                          color: accent.withValues(alpha: 0.13),
                        ),
                      ),
                    ),
                  ),
                ),
                ?widget.child,
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AuroraPainter extends CustomPainter {
  final Animation<double> t;
  final Color accent;
  _AuroraPainter(this.t, this.accent) : super(repaint: t);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final second = accent == DashUi.indigo ? DashUi.sky : DashUi.indigo;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(accent.withValues(alpha: 0.16), Colors.white),
            Color.alphaBlend(second.withValues(alpha: 0.10), Colors.white),
          ],
        ).createShader(rect),
    );
    final a = t.value * 2 * math.pi;
    // (colour, strength, radius as a share of the height, turns across, turns down, phase)
    final blobs = [
      (accent, 0.34, 1.6, 1, 1, 0.0),
      (second, 0.24, 1.25, 2, 1, 2.1),
      (DashUi.emerald, 0.13, 1.0, 1, 2, 4.2),
    ];
    for (final (color, strength, r, kx, ky, p) in blobs) {
      final c = Offset(
        size.width * (0.5 + 0.4 * math.sin(a * kx + p)),
        size.height * (0.5 + 0.6 * math.cos(a * ky + p * 1.7)),
      );
      final radius = size.height * r;
      canvas.drawCircle(
        c,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: strength),
              color.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: c, radius: radius)),
      );
    }
    // A fine dot grid for texture, fading out toward the left where the photo sits.
    final dots = <Offset>[
      for (var x = 8.0; x < size.width; x += 16)
        for (var y = 8.0; y < size.height; y += 16) Offset(x, y),
    ];
    canvas.drawPoints(
      PointMode.points,
      dots,
      Paint()
        ..shader = LinearGradient(colors: [accent.withValues(alpha: 0), accent.withValues(alpha: 0.18)])
            .createShader(rect)
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => old.accent != accent;
}

// ---- Scorecard -----------------------------------------------------------------

/// One number on the scorecard, with everything needed to read it without already knowing what it means.
class _Stat {
  final String label;
  final IconData icon;
  final Color color;
  final double? value;
  final String Function(double) format;

  /// Printed small after the number ("jobs", "%", "of 4").
  final String unit;

  /// Drawn after the number (the star on a rating).
  final IconData? valueIcon;

  /// What the number means, in plain words.
  final String caption;

  /// A comparison pill before the caption ("18% ahead"): good = green, bad = amber, null = grey.
  final String? delta;
  final bool? deltaGood;

  /// Month by month this year, January first; drawn as a sparkline when there are at least two points.
  final List<double>? trend;

  /// The full definition, on hover.
  final String tip;

  const _Stat({
    required this.label,
    required this.icon,
    required this.color,
    required this.value,
    required this.format,
    required this.caption,
    required this.tip,
    this.unit = '',
    this.valueIcon,
    this.delta,
    this.deltaGood,
    this.trend,
  });
}

/// This year at a glance for one person, built from /api/employees/:id/kpis (and /api/tech_stats for a tech's
/// callbacks). Only what applies to them, at most four numbers. Empty for people with nothing measured (admins).
class _Glance {
  final List<_Stat> stats;

  /// Set when the numbers belong to a whole team rather than this person (warehouse, receivables).
  final String? scope;
  const _Glance(this.stats, {this.scope});

  factory _Glance.from(Map<String, dynamic> body, Map<String, dynamic>? techStats, _Emp e) {
    double? n(dynamic v) => v == null ? null : (v is num ? v.toDouble() : double.tryParse('$v'));
    int i(dynamic v) => n(v)?.round() ?? 0;
    Map<String, dynamic>? part(String key) => body[key] is Map ? Map<String, dynamic>.from(body[key] as Map) : null;
    final year = n(body['year'])?.round() ?? DateTime.now().year;
    // Months that have happened, so a trend doesn't run on into empty months.
    final monthsSoFar = year < DateTime.now().year ? 12 : DateTime.now().month;
    List<double>? trend(List<double> v) => v.length >= 2 ? v : null;
    final emp = body['employee'] is Map ? body['employee'] as Map : const {};
    final stats = <_Stat>[];
    String? scope;

    _Stat? rating(dynamic sat) {
      if (sat is! Map || n(sat['avg']) == null) return null;
      final count = i(sat['count']);
      return _Stat(
        label: 'Customer rating',
        icon: Icons.star_rounded,
        color: DashUi.amber,
        value: n(sat['avg']),
        format: _oneDp,
        valueIcon: Icons.star_rounded,
        caption: 'From $count Google ${count == 1 ? 'review' : 'reviews'} that name them',
        tip: 'Average stars on the Google reviews whose text mentions them by name.',
      );
    }

    final tech = part('tech');
    if (tech != null) {
      final perDay = n(tech['laborPerDay']);
      final team = tech['team'] is Map ? tech['team'] as Map : const {};
      final teamPerDay = n(team['laborPerDay']);
      final months = [
        for (final m in (tech['monthly'] is List ? tech['monthly'] as List : const []))
          if (m is Map) m,
      ]..sort((a, b) => i(a['month']).compareTo(i(b['month'])));
      String? delta;
      bool? good;
      var caption = 'Labor credited to them for each day on a job';
      if (perDay != null && teamPerDay != null && teamPerDay > 0) {
        final pct = (perDay - teamPerDay) / teamPerDay * 100;
        if (pct.abs() < 5) {
          delta = 'On par';
        } else {
          delta = '${pct.abs().round()}% ${pct > 0 ? 'ahead' : 'behind'}';
          good = pct > 0;
        }
        caption = 'vs ${_money0(teamPerDay)} a day for the rest of the team';
      }
      stats.add(
        _Stat(
          label: 'Labor per work day',
          icon: Icons.speed_rounded,
          color: DashUi.blue,
          value: perDay,
          format: _money0,
          caption: caption,
          delta: delta,
          deltaGood: good,
          trend: trend([
            for (final m in months)
              if (n(m['laborPerDay']) != null) n(m['laborPerDay'])!,
          ]),
          tip:
              'Their share of labor on jobs completed this year, divided by the calendar days they worked a labor job. '
              'The team figure pools every other current tech.',
        ),
      );
      final jobs = i(tech['laborJobs']);
      stats.add(
        _Stat(
          label: 'Labor this year',
          icon: Icons.construction_rounded,
          color: DashUi.sky,
          value: n(tech['laborDollars']) ?? 0,
          format: _money0,
          caption: jobs == 0 ? 'No completed labor jobs yet' : 'Across $jobs completed ${jobs == 1 ? 'job' : 'jobs'}',
          trend: trend([for (final m in months) n(m['labor']) ?? 0]),
          tip: 'Their share of the labor lines on jobs completed this year, split by who worked which days.',
        ),
      );
      Map? mine;
      for (final t in (techStats?['techs'] is List ? techStats!['techs'] as List : const [])) {
        if (t is Map && '${t['id']}'.toLowerCase() == e.username.toLowerCase()) mine = t;
      }
      if (mine != null) {
        final streak = i(mine['jobsSinceCallback']);
        final callbacks = i(mine['callbackCount']);
        stats.add(
          _Stat(
            label: 'Callback-free streak',
            icon: Icons.local_fire_department_rounded,
            color: streak > 0 ? DashUi.amber : DashUi.slate,
            value: streak.toDouble(),
            format: _whole,
            unit: streak == 1 ? 'job' : 'jobs',
            caption: callbacks == 0
                ? 'Finished in a row without a callback'
                : 'In a row since their last callback ($callbacks this year)',
            tip: 'Completed jobs since a callback last came back on one of their jobs. Counted from the commission go-live.',
          ),
        );
      }
      final r = rating(tech['satisfaction']);
      if (r != null) stats.add(r);
      if (stats.length < 4) {
        final strikes = i(emp['inventoryStrikes'] ?? e.raw['inventory_strikes']);
        final teamAvg = n(team['avgInventoryStrikes']);
        stats.add(
          _Stat(
            label: 'Inventory strikes',
            icon: Icons.inventory_2_outlined,
            color: strikes == 0 ? DashUi.emeraldDeep : DashUi.amber,
            value: strikes.toDouble(),
            format: _whole,
            caption: teamAvg == null
                ? (strikes == 0 ? 'A clean record' : 'All time, from the morning stock audit')
                : '${strikes == 0 ? 'A clean record. ' : ''}The rest of the team averages ${teamAvg.toStringAsFixed(1)}',
            tip: 'Added by the 8:30 AM inventory audit when stock is missing. All time.',
          ),
        );
      }
    }

    final sales = part('sales');
    if (sales != null) {
      final wonN = i(sales['wonCount']), lostN = i(sales['lostCount']);
      final mbt = sales['monthlyByType'] is Map ? sales['monthlyByType'] as Map : const {};
      final revenue = List<double>.filled(12, 0);
      for (final l in mbt.values) {
        if (l is! List) continue;
        for (var m = 0; m < 12 && m < l.length; m++) {
          if (l[m] is Map) revenue[m] += n((l[m] as Map)['revenue']) ?? 0;
        }
      }
      final mc = sales['monthlyClose'] is List ? sales['monthlyClose'] as List : const [];
      final close = <double>[
        for (var m = 0; m < monthsSoFar && m < mc.length; m++)
          if (mc[m] is Map && i((mc[m] as Map)['won']) + i((mc[m] as Map)['lost']) > 0)
            i((mc[m] as Map)['won']) / (i((mc[m] as Map)['won']) + i((mc[m] as Map)['lost'])) * 100,
      ];
      stats.add(
        _Stat(
          label: 'Won this year',
          icon: Icons.emoji_events_outlined,
          color: DashUi.emeraldDeep,
          value: n(sales['wonValue']) ?? 0,
          format: _money0,
          caption: '$wonN ${wonN == 1 ? 'estimate' : 'estimates'} won',
          trend: mbt.isEmpty ? null : trend(revenue.sublist(0, monthsSoFar)),
          tip: 'Total of the estimates they own that were marked Won this year.',
        ),
      );
      stats.add(
        _Stat(
          label: 'Close rate',
          icon: Icons.handshake_outlined,
          color: DashUi.indigo,
          value: n(sales['closeRatePct']),
          format: _whole,
          unit: '%',
          caption: '$wonN won, $lostN lost',
          trend: trend(close),
          tip: 'Won out of won plus lost this year. Estimates still open do not count either way.',
        ),
      );
      final profit = n(sales['grossProfit']) ?? 0;
      stats.add(
        _Stat(
          label: 'Gross margin',
          icon: Icons.pie_chart_outline_rounded,
          color: DashUi.blue,
          value: n(sales['marginPct']),
          format: _whole,
          unit: '%',
          caption: '${_money0(profit)} profit on won work',
          tip: 'Profit as a share of revenue on the won estimates that have cost data.',
        ),
      );
      final p = sales['pipeline'];
      if (p is Map) {
        final req = p['requested'] is Map ? p['requested'] as Map : const {};
        final sent = p['provided'] is Map ? p['provided'] as Map : const {};
        final count = i(req['count']) + i(sent['count']);
        stats.add(
          _Stat(
            label: 'Open pipeline',
            icon: Icons.hourglass_top_rounded,
            color: DashUi.sky,
            value: (n(req['value']) ?? 0) + (n(sent['value']) ?? 0),
            format: _money0,
            caption: '$count open ${count == 1 ? 'estimate' : 'estimates'}, not yet won or lost',
            tip: 'Open estimates they own, requested or sent, that are not yet won or lost.',
          ),
        );
      } else {
        final r = rating(sales['satisfaction']);
        if (r != null) stats.add(r);
      }
    }

    final office = part('office');
    if (office != null) {
      scope = 'Company-wide';
      final outstanding = n(office['outstanding']) ?? 0, over90 = n(office['over90']) ?? 0;
      final monthly = [
        for (final v in (office['collectedMonthly'] is List ? office['collectedMonthly'] as List : const []))
          n(v) ?? 0.0,
      ];
      stats.addAll([
        _Stat(
          label: 'Collected this year',
          icon: Icons.savings_outlined,
          color: DashUi.emeraldDeep,
          value: n(office['collected']) ?? 0,
          format: _money0,
          caption: 'Customer payments received',
          trend: trend(monthly.take(monthsSoFar).toList()),
          tip: 'Cash in from customer payments this year, refunds taken off.',
        ),
        _Stat(
          label: 'Outstanding',
          icon: Icons.receipt_long_outlined,
          color: DashUi.sky,
          value: outstanding,
          format: _money0,
          caption: 'Final invoices sent, not yet paid',
          tip: 'What customers still owe on jobs at Final Invoice Sent or Check on Payment, as of today.',
        ),
        _Stat(
          label: 'Over 90 days',
          icon: Icons.warning_amber_rounded,
          color: over90 > 0 ? DashUi.red : DashUi.emeraldDeep,
          value: over90,
          format: _money0,
          caption: outstanding > 0
              ? '${(over90 / outstanding * 100).round()}% of what is owed'
              : 'Nothing owed that long',
          tip: 'Balances on the 90 Day Notice.',
        ),
        _Stat(
          label: 'Collection rate',
          icon: Icons.task_alt_rounded,
          color: DashUi.indigo,
          value: n(office['collectionRatePct']),
          format: _whole,
          unit: '%',
          caption: 'Collected out of collected plus still owed',
          tip: 'Cash collected this year divided by that cash plus what is still outstanding.',
        ),
      ]);
    }

    final wh = part('warehouse');
    if (wh != null) {
      scope = 'Whole warehouse team';
      final strikes = i(wh['strikes']);
      final zones = [
        for (final z in (wh['zones'] is List ? wh['zones'] as List : const []))
          if (z is Map) z,
      ];
      final done = zones.where((z) => z['status'] == 'Complete').length;
      final overdue = zones.where((z) => z['overdue'] == true).length;
      final last = DateTime.tryParse('${wh['lastCycleCount'] ?? ''}')?.toLocal();
      final low = i(wh['lowStockCount']);
      stats.addAll([
        _Stat(
          label: 'Warehouse strikes',
          icon: Icons.report_gmailerrorred_rounded,
          color: strikes == 0 ? DashUi.emeraldDeep : DashUi.amber,
          value: strikes.toDouble(),
          format: _whole,
          caption: 'All time, from the morning stock audit',
          tip: 'Strikes the 8:30 AM audit records on the shared warehouse login.',
        ),
        _Stat(
          label: 'Cycle counts done',
          icon: Icons.fact_check_outlined,
          color: DashUi.sky,
          value: i(wh['cycleDone']).toDouble(),
          format: _whole,
          caption:
              '${_whole(i(wh['itemsCounted']).toDouble())} items counted${last == null ? '' : ', last on ${DateFormat.MMMd().format(last)}'}',
          tip: 'Zone counts completed this year and the items counted in them.',
        ),
        if (zones.isNotEmpty)
          _Stat(
            label: 'Zones counted',
            icon: Icons.grid_view_rounded,
            color: overdue > 0 ? DashUi.amber : DashUi.emeraldDeep,
            value: done.toDouble(),
            format: _whole,
            unit: 'of ${zones.length}',
            caption: overdue > 0 ? '$overdue overdue this period' : 'Every zone on schedule',
            tip: "Each zone is counted Wednesday to Friday of its week. Overdue once that week is over and it isn't done.",
          ),
        _Stat(
          label: 'Low stock items',
          icon: Icons.trending_down_rounded,
          color: low > 0 ? DashUi.amber : DashUi.emeraldDeep,
          value: low.toDouble(),
          format: _whole,
          caption: 'At or below their reorder point',
          tip: 'Items with a reorder point set whose quantity is at or below it.',
        ),
      ]);
    }

    return _Glance(stats.take(4).toList(), scope: scope);
  }
}

/// A scorecard tile: icon and label, the number counting up, a sparkline that draws itself after it, and a line that
/// says what the number means. Lifts and tints on hover; the full definition is on the info icon.
class _StatTile extends StatefulWidget {
  final _Stat stat;
  final int index;
  const _StatTile({super.key, required this.stat, required this.index});

  @override
  State<_StatTile> createState() => _StatTileState();
}

class _StatTileState extends State<_StatTile> with SingleTickerProviderStateMixin {
  static const _revealMs = 420;
  static const _countMs = 1000;
  static const _sparkMs = 700;
  late final int _delay = 120 + widget.index * 90;
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: _delay + _countMs + _sparkMs),
  );
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    _c.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_calm(context)) _c.value = 1;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  double _at(int startMs, int lenMs, Curve curve) {
    final ms = _c.value * _c.duration!.inMilliseconds;
    return curve.transform(((ms - startMs) / lenMs).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.stat;
    return Semantics(
      container: true,
      label:
          '${s.label}: ${s.value == null ? 'no data' : '${s.format(s.value!)}${s.unit.isEmpty ? '' : ' ${s.unit}'}'}. '
          '${s.delta == null ? '' : '${s.delta}. '}${s.caption}',
      child: ExcludeSemantics(
        // The full definition shows on hover anywhere on the tile, so the header keeps its room for the name.
        child: Tooltip(
          message: s.tip,
          waitDuration: const Duration(milliseconds: 450),
          child: MouseRegion(
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) {
                final reveal = _at(_delay, _revealMs, Curves.easeOutCubic);
                final count = _at(_delay + 60, _countMs, Curves.easeOutExpo);
                final spark = _at(_delay + _countMs - 300, _sparkMs, Curves.easeInOutCubic);
                return Opacity(
                  opacity: reveal,
                  child: Transform.translate(
                    offset: Offset(0, 20 * (1 - reveal)),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      transform: Matrix4.translationValues(0, _hover ? -3 : 0, 0),
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: _hover ? s.color.withValues(alpha: 0.45) : DashUi.line),
                        boxShadow: [
                          BoxShadow(
                            color: (_hover ? s.color : DashUi.ink).withValues(alpha: _hover ? 0.16 : 0.04),
                            blurRadius: _hover ? 24 : 8,
                            offset: Offset(0, _hover ? 10 : 2),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 30,
                                height: 30,
                                decoration: BoxDecoration(
                                  color: s.color.withValues(alpha: 0.10),
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: Icon(s.icon, size: 17, color: s.color),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  s.label,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                    color: DashUi.ink,
                                    height: 1.2,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Expanded(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.bottomLeft,
                                  child: _number(s, count),
                                ),
                              ),
                              if (s.trend != null) ...[
                                const SizedBox(width: 10),
                                SizedBox(
                                  width: 84,
                                  height: 36,
                                  child: CustomPaint(painter: _SparkPainter(s.trend!, s.color, spark)),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (s.delta != null) _deltaPill(s.delta!, s.deltaGood),
                              Text(
                                s.caption,
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  color: DashUi.slate,
                                  fontWeight: FontWeight.w500,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _number(_Stat s, double t) {
    if (s.value == null) {
      return const Text(
        '—',
        style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: DashUi.muted, height: 1.05),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          s.format(s.value! * t),
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            color: DashUi.ink,
            height: 1.05,
            letterSpacing: -0.6,
            fontFeatures: _figures,
          ),
        ),
        if (s.unit.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(left: s.unit.startsWith('%') ? 1 : 4, bottom: 3),
            child: Text(
              s.unit,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: DashUi.slate),
            ),
          ),
        if (s.valueIcon != null)
          Padding(
            padding: const EdgeInsets.only(left: 3, bottom: 2),
            child: Icon(s.valueIcon, size: 22, color: s.color),
          ),
      ],
    );
  }
}

Widget _deltaPill(String text, bool? good) {
  final (fg, bg, icon) = switch (good) {
    true => (_T.goodFg, _T.goodBg, Icons.trending_up_rounded),
    false => (_T.amberFg, _T.amberBg, Icons.trending_down_rounded),
    null => (DashUi.slate, DashUi.faint, Icons.drag_handle_rounded),
  };
  return Container(
    padding: const EdgeInsets.fromLTRB(6, 2, 8, 2),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: fg),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: fg, fontFeatures: _figures),
        ),
      ],
    ),
  );
}

/// A smooth line from zero up, with a soft fill under it, drawn left to right as [progress] goes 0 to 1.
class _SparkPainter extends CustomPainter {
  final List<double> values;
  final Color color;
  final double progress;
  const _SparkPainter(this.values, this.color, this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2 || progress <= 0) return;
    const pad = 4.0;
    final maxV = values.reduce(math.max);
    final minV = math.min(0.0, values.reduce(math.min));
    final span = maxV - minV <= 0 ? 1.0 : maxV - minV;
    final w = size.width - pad * 2, h = size.height - pad * 2;
    final pts = [
      for (var i = 0; i < values.length; i++)
        Offset(pad + w * i / (values.length - 1), pad + h * (1 - (values[i] - minV) / span)),
    ];
    final line = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      final cx = (pts[i - 1].dx + pts[i].dx) / 2;
      line.cubicTo(cx, pts[i - 1].dy, cx, pts[i].dy, pts[i].dx, pts[i].dy);
    }
    final metric = line.computeMetrics().first;
    final drawn = metric.extractPath(0, metric.length * progress);
    final head = metric.getTangentForOffset(metric.length * progress)?.position ?? pts.last;
    final fill = Path.from(drawn)
      ..lineTo(head.dx, size.height)
      ..lineTo(pts.first.dx, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      drawn,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    if (progress >= 1) canvas.drawCircle(head, 6, Paint()..color = color.withValues(alpha: 0.18));
    canvas.drawCircle(head, 3, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.progress != progress || old.color != color || old.values != values;
}

/// The shape of a scorecard tile while its numbers load.
class _StatSkeleton extends StatelessWidget {
  const _StatSkeleton();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: DashUi.line),
    ),
    child: const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [SkeletonBox(h: 30, w: 30, r: 9), SizedBox(width: 10), SkeletonBox(h: 12, w: 110)]),
        SizedBox(height: 16),
        SkeletonBox(h: 26, w: 120),
        SizedBox(height: 12),
        SkeletonBox(h: 10, w: 170),
      ],
    ),
  );
}

/// Lays tiles out evenly: all on one row when there is room, two a row when there isn't, one on a phone width.
/// Every tile in a row is as tall as the tallest.
Widget _tileRows(List<Widget> tiles, {double gap = 12}) {
  return LayoutBuilder(
    builder: (context, c) {
      final n = tiles.length;
      final perRow = c.maxWidth >= 840 ? n : (c.maxWidth >= 440 ? math.min(2, n) : 1);
      final rows = <Widget>[];
      for (var i = 0; i < n; i += perRow) {
        final slice = tiles.sublist(i, math.min(i + perRow, n));
        rows.add(
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var j = 0; j < perRow; j++) ...[
                  if (j > 0) SizedBox(width: gap),
                  Expanded(child: j < slice.length ? slice[j] : const SizedBox.shrink()),
                ],
              ],
            ),
          ),
        );
      }
      return Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[if (i > 0) SizedBox(height: gap), rows[i]],
        ],
      );
    },
  );
}

// ---- Team overview (nobody picked yet) -------------------------------------------

/// What the right side shows before anyone is picked: who is on the team by group, whose setup needs fixing, and
/// which badges have been given out. Clicking a face or a row opens that person.
class _TeamOverview extends StatelessWidget {
  final List<_Emp> users;
  final ValueChanged<_Emp> onOpen;
  const _TeamOverview({required this.users, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final active = users.where((u) => u.active).toList();
    final inactive = users.length - active.length;
    final groups = [
      for (var g = 0; g < 5; g++)
        if (active.any((u) => u.group == g))
          (
            g,
            [
              for (final u in active)
                if (u.group == g) u,
            ],
          ),
    ];
    final attention = [
      for (final u in active)
        if (_setupProblems(u).isNotEmpty) u,
    ];
    final awarded = [for (final b in _badges) (b, active.where((u) => u.raw[b.key] == true).toList())];

    Widget heading(String text, {Widget? trailing}) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Text(
            text,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: DashUi.ink, letterSpacing: -0.2),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing],
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, c) => _list(c.maxWidth, heading, active, inactive, groups, attention, awarded),
    );
  }

  Widget _list(
    double width,
    Widget Function(String, {Widget? trailing}) heading,
    List<_Emp> active,
    int inactive,
    List<(int, List<_Emp>)> groups,
    List<_Emp> attention,
    List<(_Badge, List<_Emp>)> awarded,
  ) {
    // On a very wide window the content stops where the profile sections do, instead of stretching edge to edge.
    final right = math.max(28.0, width - 1228);
    return ListView(
      padding: const EdgeInsets.only(bottom: 40),
      children: [
        _CoverBanner(
          accent: DashUi.indigo,
          icon: Icons.groups_2_rounded,
          height: 150,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 0, 160, 22),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Reveal(
                  from: Offset(0, 10),
                  child: Text(
                    'Your team',
                    style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: DashUi.ink, letterSpacing: -0.8),
                  ),
                ),
                const SizedBox(height: 2),
                _Reveal(
                  delayMs: 80,
                  from: const Offset(0, 8),
                  child: Text(
                    '${active.length} active ${active.length == 1 ? 'person' : 'people'}'
                    '${inactive > 0 ? ', $inactive inactive' : ''}. Pick someone to see their year and edit their profile.',
                    style: const TextStyle(fontSize: 14, color: DashUi.slate, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(28, 26, right, 0),
          child: _tileRows([
            for (var i = 0; i < groups.length; i++)
              _GroupTile(group: groups[i].$1, people: groups[i].$2, index: i, onOpen: onOpen),
          ]),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(28, 30, right, 0),
          child: _Reveal(
            delayMs: 300,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                heading(
                  'Needs attention',
                  trailing: attention.isEmpty ? null : _chip('${attention.length}', _T.amberFg, _T.amberBg),
                ),
                if (attention.isEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: _T.goodBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _T.goodFg.withValues(alpha: 0.2)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.check_circle_rounded, size: 18, color: _T.goodFg),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Everyone active has a PIN and matches Service Fusion.',
                            style: TextStyle(fontSize: 13.5, color: _T.goodFg, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Container(
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                    // On top, so the rows' hover colour can't paint over the frame.
                    foregroundDecoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: DashUi.line),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (var i = 0; i < attention.length; i++)
                          _AttentionRow(person: attention[i], first: i == 0, onOpen: onOpen),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(28, 30, right, 0),
          child: _Reveal(
            delayMs: 380,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                heading('Badges awarded'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (b, people) in awarded)
                      Tooltip(
                        message: people.isEmpty ? b.meaning : '${b.meaning}\n${people.map((p) => p.name).join(', ')}',
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(10, 7, 8, 7),
                          decoration: BoxDecoration(
                            color: people.isEmpty ? Colors.white : b.bg,
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(color: people.isEmpty ? DashUi.line : b.color.withValues(alpha: 0.35)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(b.icon, size: 16, color: people.isEmpty ? DashUi.muted : b.color),
                              const SizedBox(width: 6),
                              Text(
                                b.label,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: people.isEmpty ? DashUi.slate : b.fg,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                constraints: const BoxConstraints(minWidth: 22),
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: people.isEmpty ? DashUi.faint : Colors.white,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  '${people.length}',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: people.isEmpty ? DashUi.muted : b.fg,
                                    fontFeatures: _figures,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One roster group on the overview: its name, how many people (counting up), and their faces, each one clickable.
class _GroupTile extends StatelessWidget {
  final int group;
  final List<_Emp> people;
  final int index;
  final ValueChanged<_Emp> onOpen;
  const _GroupTile({required this.group, required this.people, required this.index, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final color = _groupAccent(group);
    const shown = 5;
    final extra = people.length - shown;
    return _Reveal(
      delayMs: 120 + index * 80,
      from: const Offset(0, 18),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: DashUi.line),
          boxShadow: [BoxShadow(color: DashUi.ink.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(_groupIcon(group), size: 17, color: color),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _groupNames[group],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: people.length.toDouble()),
                  duration: _calm(context) ? Duration.zero : Duration(milliseconds: 900 + index * 80),
                  curve: Curves.easeOutExpo,
                  builder: (context, v, _) => Text(
                    '${v.round()}',
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      color: DashUi.ink,
                      height: 1.05,
                      fontFeatures: _figures,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    people.length == 1 ? 'person' : 'people',
                    style: const TextStyle(fontSize: 13, color: DashUi.slate, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 34,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (var i = 0; i < people.length && i < shown; i++)
                    Positioned(
                      left: i * 27.0,
                      child: Tooltip(
                        message: people[i].name,
                        child: _Hoverable(
                          onTap: () => onOpen(people[i]),
                          builder: (hover) => AnimatedContainer(
                            duration: const Duration(milliseconds: 140),
                            transform: Matrix4.translationValues(0, hover ? -4 : 0, 0),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                              boxShadow: hover
                                  ? [
                                      BoxShadow(
                                        color: color.withValues(alpha: 0.3),
                                        blurRadius: 10,
                                        offset: const Offset(0, 4),
                                      ),
                                    ]
                                  : const [],
                            ),
                            child: DashAvatar(
                              name: people[i].name,
                              imageUrl: people[i].avatarUrl,
                              size: 30,
                              accent: color,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (extra > 0)
                    Positioned(
                      left: shown * 27.0,
                      child: Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: DashUi.faint,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: Text(
                          '+$extra',
                          style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: DashUi.slate),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttentionRow extends StatelessWidget {
  final _Emp person;
  final bool first;
  final ValueChanged<_Emp> onOpen;
  const _AttentionRow({required this.person, required this.first, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return _Hoverable(
      onTap: () => onOpen(person),
      builder: (hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
        decoration: BoxDecoration(
          color: hover ? _T.wash : Colors.white,
          border: first ? null : const Border(top: BorderSide(color: DashUi.line)),
        ),
        child: Row(
          children: [
            DashAvatar(name: person.name, imageUrl: person.avatarUrl, size: 34, accent: _groupAccent(person.group)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    person.name,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink),
                  ),
                  const SizedBox(height: 1),
                  Row(
                    children: [
                      const Icon(Icons.error_outline_rounded, size: 14, color: DashUi.amber),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          _setupProblems(person).join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5, color: _T.amberFg, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            AnimatedSlide(
              duration: const Duration(milliseconds: 160),
              offset: Offset(hover ? 0.15 : 0, 0),
              child: const Icon(Icons.chevron_right_rounded, size: 22, color: DashUi.slate),
            ),
          ],
        ),
      ),
    );
  }
}
