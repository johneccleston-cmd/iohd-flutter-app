import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'widgets/dashboard_data.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/dashboard_layout.dart';
import 'widgets/dashboard_panels.dart';

// The Technicians dashboard. Profit and jobs follow the selected year; callbacks are counted from Oct 5, 2026, when
// callback tracking began (within the selected year).
//   scorecards  average profit per tech, per tech per day, the callback rate
//   left        the monthly chart: profit per tech per day, total profit, jobs, profit per job, against last year
//   right       every technician, fewest callbacks first, with their jobs and revenue for the year
// The page fits the window without scrolling and without shrinking text (see _Grid).

class TechniciansDashboardScreen extends StatelessWidget {
  const TechniciansDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      title: 'Technicians',
      builder: (context, selectedYear) {
        return TechniciansDashboardContent(selectedYear: selectedYear);
      },
    );
  }
}

class TechniciansDashboardContent extends StatefulWidget {
  final int selectedYear;
  const TechniciansDashboardContent({super.key, required this.selectedYear});

  @override
  State<TechniciansDashboardContent> createState() => _TechniciansDashboardContentState();
}

// =============================================================================
// MODELS
// =============================================================================

int _toInt(dynamic v) => v == null ? 0 : (int.tryParse(v.toString()) ?? 0);

double _parseMoney(dynamic v) {
  if (v is num) return v.toDouble();
  if (v == null) return 0.0;
  return double.tryParse(v.toString().replaceAll(RegExp(r'[^0-9.\-]'), '')) ?? 0.0;
}

class _TechnicianProfile {
  final String id;
  final String name;
  final String role;
  final String imageUrl;
  final int completedJobsYtd;

  /// Completed jobs from the period callbacks are counted in (since Oct 5, 2026 within the year): the denominator of
  /// this tech's callback rate, the same rule as the Callback rate card.
  final int callbackJobs;
  final double revenue;
  final int callbackCount;

  const _TechnicianProfile({
    required this.id,
    required this.name,
    required this.role,
    required this.imageUrl,
    required this.completedJobsYtd,
    required this.callbackJobs,
    required this.revenue,
    required this.callbackCount,
  });

  bool get hasCallbackJobs => callbackJobs > 0;
  double get callbackRate => hasCallbackJobs ? callbackCount / callbackJobs * 100 : 0.0;

  factory _TechnicianProfile.fromJson(Map<String, dynamic> json) {
    return _TechnicianProfile(
      id: json['id']?.toString() ?? '0',
      name: (json['name'] ?? 'Unknown tech').toString(),
      role: (json['jobTitle'] ?? json['role'] ?? 'Technician').toString(),
      imageUrl: (json['avatarUrl'] ?? json['avatar_url'] ?? '').toString(),
      completedJobsYtd: _toInt(json['completedJobsYtd']),
      // A server without the field: the old denominator (every completed job of the year).
      callbackJobs: _toInt(json['callbackJobs'] ?? json['completedJobsYtd']),
      revenue: json['revenue'] != null ? _parseMoney(json['revenue']) : _parseMoney(json['revenueGenerated']),
      callbackCount: _toInt(json['callbackCount']),
    );
  }
}

class _MonthlyChartPoint {
  final String month;
  final int avgProfitPerDay;
  final int totalProfit;
  final int jobCount;
  final int priorAvgProfitPerDay;
  final int priorTotalProfit;
  final int priorJobCount;
  final bool partial;

  const _MonthlyChartPoint({
    required this.month,
    required this.avgProfitPerDay,
    required this.totalProfit,
    required this.jobCount,
    required this.priorAvgProfitPerDay,
    required this.priorTotalProfit,
    required this.priorJobCount,
    required this.partial,
  });

  factory _MonthlyChartPoint.fromJson(Map<String, dynamic> json) {
    return _MonthlyChartPoint(
      month: json['month']?.toString() ?? '',
      avgProfitPerDay: (json['avgProfitPerDay'] as num?)?.toInt() ?? 0,
      totalProfit: (json['totalProfit'] as num?)?.toInt() ?? 0,
      jobCount: (json['jobCount'] as num?)?.toInt() ?? 0,
      priorAvgProfitPerDay: (json['priorAvgProfitPerDay'] as num?)?.toInt() ?? 0,
      priorTotalProfit: (json['priorTotalProfit'] as num?)?.toInt() ?? 0,
      priorJobCount: (json['priorJobCount'] as num?)?.toInt() ?? 0,
      partial: json['partial'] == true,
    );
  }
}

List<_TechnicianProfile> _rankByCallbacks(List<_TechnicianProfile> techs) {
  final list = List<_TechnicianProfile>.from(techs);
  list.sort((a, b) {
    if (a.hasCallbackJobs != b.hasCallbackJobs) return a.hasCallbackJobs ? -1 : 1;
    final cmp = a.callbackRate.compareTo(b.callbackRate);
    if (cmp != 0) return cmp;
    return b.callbackJobs.compareTo(a.callbackJobs);
  });
  return list;
}

// =============================================================================
// SCREEN STATE
// =============================================================================

class _TechniciansDashboardContentState extends State<TechniciansDashboardContent> with DashboardLoading {
  List<_TechnicianProfile> _ranked = [];
  List<_MonthlyChartPoint> _chartData = [];

  double _avgProfitYtd = 0;
  double _avgProfitPerDay = 0;

  /// Strikes ÷ completed jobs, both since go-live (Oct 5, 2026) within the year. null = no such jobs, so no rate.
  double? _callbackRatePct;
  int _callbacks = 0;
  int _callbackJobs = 0;

  /// Where the callback count starts this year: "2026-10-05", "2027-01-01"; null when the year has no such stretch.
  String? _callbackFrom;
  double? _avgRating;

  int _techCount = 0;

  @override
  void initState() {
    super.initState();
    dashReload();
  }

  @override
  void didUpdateWidget(covariant TechniciansDashboardContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedYear != widget.selectedYear) dashReload();
  }

  @override
  Future<void> dashReload({bool fresh = false}) => dashLoad(
        '/api/tech_stats',
        query: {'year': '${widget.selectedYear}'},
        fresh: fresh,
        apply: (body) {
          final summary = (body['summary'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
          final metrics = (summary['metrics'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
          final List<dynamic> techsData = body['techs'] ?? [];
          final List<dynamic> chartRaw = summary['chartData'] ?? [];
          final techs = techsData.map((e) => _TechnicianProfile.fromJson(e as Map<String, dynamic>)).toList();

          _avgProfitYtd = _parseMoney(metrics['avgProfitYtd'] ?? summary['avgProfitYtd']);
          _avgProfitPerDay = _parseMoney(metrics['avgProfitPerDay'] ?? summary['avgProfitPerDay']);
          final rate = metrics.containsKey('callbackRatePct') ? metrics['callbackRatePct'] : summary['callbackRate'];
          _callbackRatePct = rate == null || rate == '—' ? null : _parseMoney(rate);
          _callbacks = _toInt(metrics['callbacks']);
          _callbackJobs = _toInt(metrics['callbackJobs'] ?? metrics['jobs']);
          final period = metrics['callbackPeriod'];
          _callbackFrom = period is Map ? period['from']?.toString() : null;
          _avgRating = (metrics['avgCustomerRating'] as num?)?.toDouble();
          _techCount = _toInt(metrics['techCount'] ?? techs.length);

          _ranked = _rankByCallbacks(techs);
          _chartData = chartRaw.map((e) => _MonthlyChartPoint.fromJson(e as Map<String, dynamic>)).toList();
        },
      );

  /// Where the callback count starts, in words: "Oct 5" (the go-live year) or "Jan 1" (a later year).
  String _callbackSince() => _callbackFrom == null ? 'Oct 5, 2026' : dashShortDate(_callbackFrom!);

  /// One value per calendar month (January first) from the chart data, for the scorecard trend lines.
  List<double> _monthlySeries(double Function(_MonthlyChartPoint) pick) {
    final out = List<double>.filled(12, 0);
    for (var i = 0; i < _chartData.length && i < 12; i++) {
      out[i] = pick(_chartData[i]);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    if (dashLoading) return const _TechSkeleton();
    if (dashFailure != null) {
      return DashErrorPanel.failure(dashFailure!, what: 'technicians', onRetry: dashReload);
    }

    final year = widget.selectedYear;
    final period = dashPeriodLabel(year);
    final techWord = _techCount == 1 ? 'tech' : 'techs';
    final g = DashGeo.of(context);

    // Captions word each figure exactly as it is computed. The callback rate counts strikes and completed jobs over
    // the same stretch (from Oct 5, 2026, when callback tracking began). The rating card only shows once ratings have
    // a source (until then it was an empty "Not tracked yet" card).
    final profitCaption = 'Company profit ÷ $_techCount current $techWord · $period';
    final dayCaption = 'The figure at left ÷ work days (20 a month)';
    final callbackCaption = _callbackRatePct == null
        ? 'No completed jobs since ${_callbackSince()}'
        : '$_callbacks ÷ $_callbackJobs completed jobs since ${_callbackSince()}';
    // The two profit cards show their trend lines together, only when both still have room for their words.
    final sparkRoom = math.max(
      dashSparkRoom(context, title: 'Avg profit per tech', value: dashMoney(_avgProfitYtd), caption: profitCaption),
      dashSparkRoom(context, title: 'Avg profit per tech per day', value: dashMoney(_avgProfitPerDay), caption: dayCaption),
    );
    final tiles = <Widget>[
      AnimatedMetricCard(
        title: 'Avg profit per tech',
        value: _avgProfitYtd,
        caption: profitCaption,
        definition: 'Profit on all completed jobs that started in $year ($period), divided by the '
            '$_techCount technicians active today. The line shows company profit by finished month.',
        valueColor: DashUi.blue,
        index: 0,
        trend: dashTrend(_monthlySeries((p) => p.totalProfit.toDouble()), year),
        sparkMinWidth: sparkRoom,
      ),
      AnimatedMetricCard(
        title: 'Avg profit per tech per day',
        value: _avgProfitPerDay,
        caption: dayCaption,
        definition: 'Average profit per tech divided by the work days so far in $year, counted as 240 a '
            'year (20 a month), not days actually worked. The line shows it by finished month.',
        valueColor: DashUi.blue,
        index: 1,
        trend: dashTrend(_monthlySeries((p) => p.avgProfitPerDay.toDouble()), year),
        sparkMinWidth: sparkRoom,
      ),
      AnimatedMetricCard(
        title: 'Callback rate',
        value: _callbackRatePct,
        format: (v) => '${v.toStringAsFixed(1)}%',
        caption: callbackCaption,
        definition: _callbackRatePct == null
            ? 'Callbacks are counted from Oct 5, 2026. There are no completed jobs from then in $year, '
                'so there is no rate to show.'
            : 'Callback strikes divided by completed jobs, both counted from ${_callbackSince()} (callback '
                'tracking began Oct 5, 2026) to today: $_callbacks strikes on $_callbackJobs jobs. A '
                'strike is counted for each tech who worked the original job.',
        valueColor: DashUi.amber,
        index: 2,
      ),
      if (_avgRating != null)
        AnimatedMetricCard(
          title: 'Avg customer rating',
          value: _avgRating,
          format: (v) => '${v.toStringAsFixed(2)} ★',
          caption: 'Customer ratings · $period',
          valueColor: DashUi.ink,
          index: 3,
        ),
    ];

    return _Grid(
      tiles: tiles,
      chart: _ProfitChart(data: _chartData, year: year, avgPerDayYtd: _avgProfitPerDay),
      techs: (layout) => _TechsPanel(g: g, ranked: _ranked, year: year, since: _callbackSince(), layout: layout),
      techCount: _ranked.length,
    );
  }
}

// =============================================================================
// GRID (shared by the page and its skeleton)
// =============================================================================

/// How the technicians panel lays out its rows in the space the grid gives it.
class _TechLayout {
  /// Each tech's figures on one line under column headings, or on two lines (a narrow column or larger text).
  final bool oneLine;
  final int maxRows;
  final bool fill;
  const _TechLayout({required this.oneLine, required this.maxRows, required this.fill});
}

/// Lays the page out to fit the window:
///   two columns   scorecards; the monthly chart | the technicians, fewest callbacks first   (1280x600 and up)
///   one column    a window narrower than a desktop one: everything in one column that scrolls
class _Grid extends StatelessWidget {
  final List<Widget> tiles;
  final Widget chart;
  final Widget Function(_TechLayout layout) techs;
  final int techCount;
  const _Grid({required this.tiles, required this.chart, required this.techs, required this.techCount});

  static const _twoColumnsFrom = 1000.0;
  static const _minChart = 220.0;

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final bodyH = c.maxHeight - g.tile - dashGap;
        final Widget content;
        if (w >= _twoColumnsFrom && bodyH >= _minChart) {
          final inner = (w - dashGap) * 11 / 23 - 40;
          final oneLine = inner >= _TechsPanel.oneLineWidth(g);
          final rowH = _TechsPanel.rowHeight(g, oneLine);
          final maxRows = math.max(2, ((bodyH - g.panelTop - (oneLine ? g.columnHead : 0)) / rowH).floor());
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: g.tile, child: _tileRow(tiles)),
              const SizedBox(height: dashGap),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 12, child: chart),
                    const SizedBox(width: dashGap),
                    Expanded(flex: 11, child: techs(_TechLayout(oneLine: oneLine, maxRows: maxRows, fill: true))),
                  ],
                ),
              ),
            ],
          );
        } else {
          content = SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: g.tile, child: _tileRow(tiles)),
                const SizedBox(height: dashGap),
                SizedBox(height: 320, child: chart),
                const SizedBox(height: dashGap),
                techs(const _TechLayout(oneLine: false, maxRows: 999, fill: false)),
              ],
            ),
          );
        }
        return SizedBox(width: w, height: c.maxHeight, child: content);
      },
    );
  }

  Widget _tileRow(List<Widget> row) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < row.length; i++) ...[
        if (i > 0) const SizedBox(width: 12),
        Expanded(child: row[i]),
      ],
    ],
  );
}

// =============================================================================
// TECHNICIANS (fewest callbacks per completed job first; jobs and revenue for the year)
// =============================================================================

class _TechsPanel extends StatelessWidget {
  final DashGeo g;

  /// Fewest callbacks per completed job first (techs with no such jobs last).
  final List<_TechnicianProfile> ranked;
  final int year;

  /// Where the callback count starts, in words ("Oct 5").
  final String since;
  final _TechLayout layout;
  const _TechsPanel({required this.g, required this.ranked, required this.year, required this.since, required this.layout});

  // Column widths at 100% text (they grow with the text).
  static const _rankW = 26.0;
  static const _avatar = 40.0;
  static const _nameMin = 112.0;
  static const _jobsW = 52.0;
  static const _revenueW = 96.0;
  static const _callbackW = 88.0;

  static double oneLineWidth(DashGeo g) =>
      _rankW + 8 + _avatar + 10 + (_nameMin + _jobsW + _revenueW + _callbackW) * g.k + 3 * 12 + 16;

  /// A name over a role (or, on two lines, the figures under the name).
  static double rowHeight(DashGeo g, bool oneLine) => math.max(g.listRow, _avatar + 8);

  @override
  Widget build(BuildContext context) {
    // Techs with completed jobs since the callback start are ranked; the top three stand on a podium and the rest
    // follow as rows. Techs with no such jobs yet have no rank.
    final rankOf = <String, int>{};
    var r = 0;
    for (final t in ranked) {
      if (t.hasCallbackJobs) rankOf[t.id + t.name] = ++r;
    }
    final placed = ranked.where((t) => t.hasCallbackJobs).take(3).toList();
    final rowH = rowHeight(g, layout.oneLine);

    // The podium takes the room of a few rows; with no room for it and the list, it gives way to the plain list.
    final podiumRows = (podiumHeight(g) / rowH).ceil();
    final canPodium = placed.length >= 2 && (!layout.fill || layout.maxRows - podiumRows >= math.min(4, ranked.length));
    final podium = canPodium ? placed : const <_TechnicianProfile>[];
    final restRows = layout.maxRows - (canPodium ? podiumRows : 0);
    final all = ranked.length <= restRows;
    final shown = all ? ranked : ranked.take(math.max(1, restRows - 1)).toList();

    final header = DashPanelHeader(
      g: g,
      title: 'Technicians',
      note: 'fewest callbacks first',
      tooltip: 'Ranked by callbacks per completed job since $since (callback tracking began Oct 5, 2026); the '
          'the first three stand on the podium. Jobs and revenue are for $year.',
      trailing: all
          ? null
          : DashLink(text: 'All ${ranked.length}', label: 'See all ${dashCount(ranked.length, 'technician')}',
              onTap: () => _openAll(context)),
    );

    if (ranked.isEmpty) {
      return DashPanel(
        fill: layout.fill,
        header: header,
        child: SizedBox(
          height: 2 * rowH,
          child: const DashEmptyNote('No active technicians found. Users with a tech role appear here.'),
        ),
      );
    }

    final rows = DashRows(
      count: shown.length,
      base: rowH,
      give: 22,
      row: (i) => _row(shown[i], rankOf[shown[i].id + shown[i].name], last: i == shown.length - 1),
    );
    return DashPanel(
      fill: layout.fill,
      header: header,
      child: LayoutBuilder(
        builder: (context, c) {
          // The podium takes what the list leaves, up to about 1.7 times its smallest size.
          final listH = shown.length * rowH + (layout.oneLine ? g.columnHead : 0);
          final minH = podiumHeight(g);
          final podiumH = layout.fill && c.maxHeight.isFinite
              ? (c.maxHeight - listH).clamp(minH, minH * 1.7).toDouble()
              : minH;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (podium.isNotEmpty) _podium(podium, podiumH),
              if (layout.oneLine) _headings(),
              if (layout.fill) Expanded(child: Align(alignment: Alignment.topCenter, child: rows)) else rows,
            ],
          );
        },
      ),
    );
  }

  /// The top three as a podium: second, first, third, each with their figures over a step.
  Widget _podium(List<_TechnicianProfile> top, double height) {
    final order = [
      if (top.length > 1) (top[1], 2),
      (top[0], 1),
      if (top.length > 2) (top[2], 3),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final h = height;
        // Extra height goes to the avatars and steps (up to about twice their base size), so a tall panel is filled
        // by the podium rather than left empty.
        final fixed = podiumHeight(g) - _podiumAvatar - _stepHeight[1]!;
        final sc = ((h - 12 - fixed) / (_podiumAvatar + _stepHeight[1]!)).clamp(1.0, 2.0).toDouble();
        final widthCap = c.maxWidth / 3 * 0.7 / _podiumAvatar;
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [for (final (t, rank) in order) Expanded(child: _step(t, rank, math.min(sc, math.max(1.0, widthCap))))],
          ),
        );
      },
    );
  }

  static const _stepColors = {1: Color(0xFFF59E0B), 2: Color(0xFF94A3B8), 3: Color(0xFFB45309)};
  static const _stepText = {1: Color(0xFFB45309), 2: Color(0xFF64748B), 3: Color(0xFF9A3412)};

  Widget _step(_TechnicianProfile t, int rank, double sc) {
    final color = _stepColors[rank]!;
    final first = rank == 1;
    // Screen readers hear everyone once, from the list below.
    return ExcludeSemantics(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          DashAvatar(
            name: t.name,
            imageUrl: t.imageUrl,
            // The ring is drawn outside the photo, so the whole avatar is _podiumAvatar (or 12 less) across.
            size: (first ? _podiumAvatar : _podiumAvatar - 12) * sc - 2 * (first ? 3 : 2.5),
            square: true,
            ringColor: color,
            ringWidth: first ? 3 : 2.5,
          ),
          const SizedBox(height: 6),
          Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.name.copyWith(fontWeight: first ? FontWeight.w800 : FontWeight.w700)),
          Text(
            '${t.callbackRate.toStringAsFixed(1)}%',
            maxLines: 1,
            style: DashText.meta.copyWith(color: DashUi.slate, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Container(
            height: _stepHeight[rank]! * sc,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              border: Border(top: BorderSide(color: color, width: 3)),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
            ),
            child: Text(
              '$rank',
              style: TextStyle(fontSize: (first ? 22 : 18) * math.min(sc, 1.5), fontWeight: FontWeight.w800, height: 1.1, color: _stepText[rank]),
            ),
          ),
        ],
      ),
    );
  }

  static const _podiumAvatar = 54.0;
  static const _stepHeight = {1: 44.0, 2: 34.0, 3: 26.0};

  /// The tallest column (first place): avatar, name, rate, jobs and revenue over the highest step.
  static double podiumHeight(DashGeo g) =>
      _podiumAvatar + 6 + g.line(13.5) + g.line(12) + 6 + _stepHeight[1]! + 12;

  String _label(_TechnicianProfile t, int? rank) =>
      '${rank == null ? '' : 'Number $rank. '}${t.name}${t.role.isEmpty ? '' : ', ${t.role}'}: '
      '${t.completedJobsYtd} completed jobs and ${dashMoney(t.revenue)} revenue in $year. '
      '${t.hasCallbackJobs ? '${t.callbackCount} ${t.callbackCount == 1 ? 'callback' : 'callbacks'} on ${t.callbackJobs} '
          'completed jobs since $since, ${t.callbackRate.toStringAsFixed(1)}%' : 'No completed jobs since $since'}';

  Widget _headings() => ExcludeSemantics(
    child: SizedBox(
      height: g.columnHead,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            const SizedBox(width: _rankW + 8 + _avatar + 10),
            const Expanded(child: Text('Name', style: DashText.column)),
            const SizedBox(width: 12),
            SizedBox(width: _jobsW * g.k, child: Text('Jobs', textAlign: TextAlign.right, style: DashText.column)),
            const SizedBox(width: 12),
            SizedBox(width: _revenueW * g.k, child: Text('Revenue $year', textAlign: TextAlign.right, style: DashText.column)),
            const SizedBox(width: 12),
            SizedBox(
              width: _callbackW * g.k,
              child: Text('Callbacks', textAlign: TextAlign.right, maxLines: 1, style: DashText.column),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _rate(_TechnicianProfile t) {
    if (!t.hasCallbackJobs) return const SizedBox.shrink();
    final perfect = t.callbackCount == 0;
    final color = perfect ? DashUi.emeraldText : DashUi.slate;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        color: perfect ? const Color(0xFFECFDF5) : DashUi.faint,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '${t.callbackRate.toStringAsFixed(1)}%',
        style: TextStyle(fontSize: 12, height: 1.3, fontWeight: FontWeight.w700, color: color, fontFeatures: DashText.tabular),
      ),
    );
  }

  Widget _row(_TechnicianProfile t, int? rank, {required bool last}) {
    final badge = SizedBox(
      width: _rankW,
      child: rank == null
          ? null
          : Align(alignment: Alignment.centerLeft, child: DashRankBadge(rank: rank, size: _rankW)),
    );
    final avatar = DashAvatar(name: t.name, imageUrl: t.imageUrl, size: _avatar, square: true, accent: DashUi.blue);
    final name = Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.name);
    final role = Text(t.role, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.meta);
    final jobs = Text('${t.completedJobsYtd}', textAlign: TextAlign.right, maxLines: 1, style: DashText.money);
    final revenue = Text(dashMoney(t.revenue), textAlign: TextAlign.right, maxLines: 1,
        style: DashText.money.copyWith(color: DashUi.sky));
    final callbacks = Align(alignment: Alignment.centerRight, child: _rate(t));

    final Widget body;
    if (layout.oneLine) {
      body = Row(
        children: [
          badge,
          const SizedBox(width: 8),
          avatar,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [name, if (t.role.isNotEmpty) role],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(width: _jobsW * g.k, child: jobs),
          const SizedBox(width: 12),
          SizedBox(width: _revenueW * g.k, child: revenue),
          const SizedBox(width: 12),
          SizedBox(width: _callbackW * g.k, child: callbacks),
        ],
      );
    } else {
      body = Row(
        children: [
          badge,
          const SizedBox(width: 8),
          avatar,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [Expanded(child: name), const SizedBox(width: 8), _rate(t)]),
                Text(
                  '${t.completedJobsYtd} jobs · ${dashMoney(t.revenue)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DashText.meta,
                ),
              ],
            ),
          ),
        ],
      );
    }

    final label = _label(t, rank);
    return DashPressable(
      onTap: null,
      label: label,
      radius: BorderRadius.circular(8),
      builder: (_) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          border: last ? null : const Border(bottom: BorderSide(color: DashUi.faint)),
        ),
        child: body,
      ),
    );
  }

  void _openAll(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: DashUi.line)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 760, maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.86),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Semantics(header: true, child: Text('All technicians · $year', style: DashText.panelTitle)),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close_rounded, size: 19, color: DashUi.subtle),
                      onPressed: () => Navigator.of(dialogContext).maybePop(),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      _TechsPanel(
                        g: g,
                        ranked: ranked,
                        year: year,
                        since: since,
                        layout: const _TechLayout(oneLine: false, maxRows: 999, fill: false),
                      ),
                    ],
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

// =============================================================================
// PROFIT CHART (four views; bars = the year shown, ticks = the same month a year earlier)
// =============================================================================

String _groupInt(num v) => v.round().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');

String _trimZero(double v) {
  final s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

String _compactMoney(num v) {
  final a = v.abs();
  if (a >= 1000000) return '\$${_trimZero(v / 1000000)}M';
  if (a >= 1000) return '\$${_trimZero(v / 1000)}k';
  return '\$${v.round()}';
}

bool _pointHasData(_MonthlyChartPoint p) => p.jobCount > 0 || p.totalProfit > 0 || p.avgProfitPerDay > 0;

class _ProfitChart extends StatelessWidget {
  final List<_MonthlyChartPoint> data;
  final int year;

  /// The scorecard's figure, so the chart's average line agrees with it exactly.
  final double avgPerDayYtd;
  const _ProfitChart({required this.data, required this.year, required this.avgPerDayYtd});

  @override
  Widget build(BuildContext context) {
    _MonthlyChartPoint? at(int i) => i < data.length ? data[i] : null;
    List<double> series(double Function(_MonthlyChartPoint) f) => [for (var i = 0; i < 12; i++) at(i) == null ? 0.0 : f(at(i)!)];

    final withData = [for (var i = 0; i < data.length && i < 12; i++) if (_pointHasData(data[i])) i];
    final completed = withData.where((i) => !data[i].partial).toList();
    final meanIdx = completed.isNotEmpty ? completed : withData;
    final hasPrior = data.any((p) => p.priorTotalProfit > 0 || p.priorJobCount > 0);

    DashChartView view({
      required String tab,
      required String title,
      required String row,
      required double Function(_MonthlyChartPoint) value,
      required double Function(_MonthlyChartPoint) prior,
      required String Function(num) format,
      required String Function(num) axis,
      required double average,
      required bool showsAverage,
    }) {
      final values = series(value);
      final priors = series(prior);
      final sum = withData.fold<double>(0, (a, i) => a + value(data[i]));
      return DashChartView(
        tab: tab,
        title: title,
        // Rates show their average for the year, counts and money their total, as before.
        note: showsAverage ? 'average ${format(average)}' : '${format(sum)} in $year',
        series: [DashSeries(row, values, DashUi.blue)],
        prior: hasPrior ? priors : null,
        priorLabel: '${year - 1}',
        average: average > 0 ? average : null,
        averageLabel: average > 0 ? 'Average ${format(average)}' : null,
        axis: (v) => axis(v),
        barLabel: (v) => tab == 'Jobs' ? format(v) : _compactMoney(v),
        badge: DashChangeChip.monthOverMonth(values, year, what: title),
        tip: (i) {
          final p = at(i);
          final cur = values[i];
          final pri = priors[i];
          final partial = p?.partial ?? false;
          final change = !partial && pri > 0 && cur > 0 ? (cur - pri) / pri * 100 : null;
          return [
            DashTipRow(row, format(cur), color: DashUi.blue),
            if (hasPrior) DashTipRow('${year - 1}${partial ? ' (whole month)' : ''}', format(pri)),
            if (change != null) DashTipRow('Change', '${change >= 0 ? '+' : '−'}${change.abs().round()}%'),
            if (tab != 'Jobs' && p != null) DashTipRow('Jobs', '${p.jobCount}'),
          ];
        },
        summary: (last) => '$title: ${[for (var i = 0; i <= last; i++) '${dashMonthNames[i]} ${format(values[i])}'].join(', ')}',
        emptyText: 'No completed jobs recorded for $year yet.',
        semanticsLabel: '$title by month, $year${hasPrior ? ', with the same month of ${year - 1} for comparison' : ''}',
      );
    }

    double mean(double Function(_MonthlyChartPoint) f) {
      final vals = meanIdx.map((i) => f(data[i])).toList();
      return vals.isEmpty ? 0.0 : vals.fold<double>(0, (a, b) => a + b) / vals.length;
    }

    var profit = 0, jobs = 0;
    for (final i in withData) {
      profit += data[i].totalProfit;
      jobs += data[i].jobCount;
    }

    return DashMonthChart(
      year: year,
      views: [
        view(
          tab: 'Avg / day',
          title: 'Profit per tech per day',
          row: 'Avg / day',
          value: (p) => p.avgProfitPerDay.toDouble(),
          prior: (p) => p.priorAvgProfitPerDay.toDouble(),
          format: (v) => '\$${_groupInt(v)}',
          axis: _compactMoney,
          // The same figure as the scorecard.
          average: avgPerDayYtd,
          showsAverage: true,
        ),
        view(
          tab: 'Total',
          title: 'Total profit',
          row: 'Total profit',
          value: (p) => p.totalProfit.toDouble(),
          prior: (p) => p.priorTotalProfit.toDouble(),
          format: _compactMoney,
          axis: _compactMoney,
          average: mean((p) => p.totalProfit.toDouble()),
          showsAverage: false,
        ),
        view(
          tab: 'Jobs',
          title: 'Jobs completed',
          row: 'Jobs',
          value: (p) => p.jobCount.toDouble(),
          prior: (p) => p.priorJobCount.toDouble(),
          format: (v) => _groupInt(v),
          axis: (v) => _groupInt(v),
          average: mean((p) => p.jobCount.toDouble()),
          showsAverage: false,
        ),
        view(
          tab: 'Per job',
          title: 'Profit per job',
          row: 'Per job',
          value: (p) => p.jobCount > 0 ? p.totalProfit / p.jobCount : 0.0,
          prior: (p) => p.priorJobCount > 0 ? p.priorTotalProfit / p.priorJobCount : 0.0,
          format: _compactMoney,
          axis: _compactMoney,
          average: jobs > 0 ? profit / jobs : 0.0,
          showsAverage: true,
        ),
      ],
    );
  }
}

// =============================================================================
// SKELETON (the same grid, with placeholders)
// =============================================================================

class _TechSkeleton extends StatelessWidget {
  const _TechSkeleton();

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    return Semantics(
      label: 'Loading technicians',
      child: ExcludeSemantics(
        child: SkeletonPulse(
          child: _Grid(
            tiles: List.generate(3, (_) => const DashSkeletonTile()),
            chart: const DashSkeletonPanel(fill: true),
            techs: (layout) =>
                DashSkeletonPanel(rows: math.min(4, layout.maxRows), rowH: _TechsPanel.rowHeight(g, layout.oneLine)),
            techCount: 4,
          ),
        ),
      ),
    );
  }
}
