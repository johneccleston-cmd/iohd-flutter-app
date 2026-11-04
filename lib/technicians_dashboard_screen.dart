import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'config/access.dart';
import 'widgets/dash_hover_card.dart';
import 'widgets/dash_story.dart';
import 'widgets/dashboard_data.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/dashboard_layout.dart';
import 'widgets/dashboard_panels.dart';

// The Technicians dashboard. Profit and jobs follow the selected year; callbacks are counted from Oct 5, 2026, when
// callback tracking began (within the selected year).
//   scorecards  average profit per tech, per tech per day, the callback rate, and (this year) the longest
//               callback-free streak: the leader's photo in a ring of fire
//   left        the monthly chart: profit per tech per day, total profit, jobs, profit per job, against last year
//   right       two views: Callbacks (every technician, fewest callbacks first, the top three on a podium, with their
//               jobs and revenue for the year) and Work pace (each tech against their own targets for work days,
//               profit a work day and profit for the year, on pace or off; sample figures until the server sends
//               a tech's `pace`, see _PaceGoals)
// The page fits the window without scrolling and without shrinking text (see _Grid).

class TechniciansDashboardScreen extends StatelessWidget {
  const TechniciansDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      title: 'Technicians',
      icon: accessIcon('dash_technicians'),
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

  /// Completed jobs since this tech's last callback (counted from Oct 5, 2026): today's figure, whatever the year.
  /// Null from a server that doesn't send it.
  final int? jobsSinceCallback;

  /// This tech's targets for the year and their figures so far, for the Work pace view. Null from a server that
  /// doesn't send them yet (the view then shows sample figures).
  final _PaceGoals? pace;

  const _TechnicianProfile({
    required this.id,
    required this.name,
    required this.role,
    required this.imageUrl,
    required this.completedJobsYtd,
    required this.callbackJobs,
    required this.revenue,
    required this.callbackCount,
    this.jobsSinceCallback,
    this.pace,
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
      jobsSinceCallback: json.containsKey('jobsSinceCallback') ? _toInt(json['jobsSinceCallback']) : null,
      pace: json['pace'] is Map ? _PaceGoals.fromJson((json['pace'] as Map).cast<String, dynamic>()) : null,
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

/// Fewest callbacks per completed job first, then the most such jobs; ties (and a year before callback tracking, when
/// nobody has a rate) by revenue, highest first.
List<_TechnicianProfile> _rankByCallbacks(List<_TechnicianProfile> techs) {
  final list = List<_TechnicianProfile>.from(techs);
  list.sort((a, b) {
    if (a.hasCallbackJobs != b.hasCallbackJobs) return a.hasCallbackJobs ? -1 : 1;
    final cmp = a.callbackRate.compareTo(b.callbackRate);
    if (cmp != 0) return cmp;
    final jobs = b.callbackJobs.compareTo(a.callbackJobs);
    return jobs != 0 ? jobs : b.revenue.compareTo(a.revenue);
  });
  return list;
}

/// The year callback tracking began (Oct 5, 2026): an earlier year has no callbacks to count.
const _callbackStartYear = 2026;

// =============================================================================
// SCREEN STATE
// =============================================================================

class _TechniciansDashboardContentState extends State<TechniciansDashboardContent> with DashboardLoading {
  List<_TechnicianProfile> _ranked = [];
  List<_MonthlyChartPoint> _chartData = [];

  double _avgProfitYtd = 0;
  double _avgProfitPerDay = 0;

  /// Callbacks (each once) ÷ completed jobs, both since go-live (Oct 5, 2026) within the year. null = no such jobs.
  double? _callbackRatePct;
  int _callbacks = 0;
  int _callbackJobs = 0;

  /// Where the callback count starts this year: "2026-10-05", "2027-01-01"; null when the year has no such stretch.
  String? _callbackFrom;
  double? _avgRating;

  int _techCount = 0;

  /// Every tech by current callback-free streak, longest first (empty from a server without streaks).
  List<_TechnicianProfile> _streaks = [];

  /// Each tech's (and Dennis's) work days and profit so far by username, from the server's `pace` list (empty from a
  /// server that doesn't send it, which leaves the Work pace view on sample figures).
  Map<String, _PaceActual> _paceActuals = {};

  /// Company-wide work days by calendar month (January first) from the server's `paceMonthly`; null from a server that
  /// doesn't send it, which leaves the chart without its Work days view.
  List<double>? _workDaysByMonth;

  /// The days behind Actual / day by month (`fieldDaysMonthly`): the Work pace roster's, Zac's install days and former
  /// techs', everyone whose share is in the profit. Null from an older server, which divides by [_workDaysByMonth].
  List<double>? _fieldDaysByMonth;

  /// The technicians panel's view. Kept here (not in the panel) so it survives a reload, and in the page's storage
  /// so it survives a change of year too (the layout builds this content afresh for each year).
  _TechTab _techTab = _TechTab.callbacks;
  static const _techTabKey = 'technicians_dashboard.view';

  @override
  void initState() {
    super.initState();
    final saved = PageStorage.maybeOf(context)?.readState(context, identifier: _techTabKey);
    if (saved is _TechTab) _techTab = saved;
    dashReload();
  }

  void _setTechTab(_TechTab v) {
    setState(() => _techTab = v);
    PageStorage.maybeOf(context)?.writeState(context, v, identifier: _techTabKey);
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
      _streaks = techs.where((t) => t.jobsSinceCallback != null).toList()
        ..sort((a, b) {
          final c = b.jobsSinceCallback!.compareTo(a.jobsSinceCallback!);
          return c != 0 ? c : a.name.compareTo(b.name);
        });
      _chartData = chartRaw.map((e) => _MonthlyChartPoint.fromJson(e as Map<String, dynamic>)).toList();
      List<double>? byMonth(Object? monthly) => monthly is List
          ? [
              for (var m = 1; m <= 12; m++)
                _parseMoney(monthly.whereType<Map>().where((e) => _toInt(e['month']) == m).firstOrNull?['workDays']),
            ]
          : null;
      _workDaysByMonth = byMonth(body['paceMonthly']);
      _fieldDaysByMonth = byMonth(body['fieldDaysMonthly']);
      _paceActuals = {
        for (final e in (body['pace'] is List ? body['pace'] as List : const []).whereType<Map>())
          if (e['id'] != null) e['id'].toString(): _PaceActual.fromJson(e.cast<String, dynamic>()),
      };
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

    // Captions word each figure exactly as it is computed. The callback rate counts callbacks and completed jobs over
    // the same stretch (from Oct 5, 2026, when callback tracking began; a year before that has none). The rating card
    // only shows once ratings have a source (until then it was an empty "Not tracked yet" card).
    final tracked = year >= _callbackStartYear;
    final profitCaption = _techCount == 0 ? 'No active technicians' : 'Company profit ÷ $_techCount $techWord';
    final dayCaption = 'Per tech ÷ 20 days a month';
    // The server's divisor (240 a year, prorated to today): the ratio of the two figures it sends.
    final assumedDays = _avgProfitPerDay > 0 ? (_avgProfitYtd / _avgProfitPerDay).round() : null;
    final callbackCaption = !tracked
        ? 'Counted from Oct 5, 2026'
        : _callbackRatePct == null
        ? 'No completed jobs since ${_callbackSince()}'
        : '$_callbacks ÷ $_callbackJobs completed jobs since ${_callbackSince()}';
    // Each profit card shows its trend line when it has room beside its words.
    final profitRoom = dashSparkRoom(
      context,
      title: 'Avg profit per tech',
      value: dashWholeMoney(_avgProfitYtd),
      caption: profitCaption,
    );
    final dayRoom = dashSparkRoom(
      context,
      title: 'Avg profit per tech per day',
      value: dashWholeMoney(_avgProfitPerDay),
      caption: dayCaption,
    );
    final tiles = <Widget>[
      AnimatedMetricCard(
        title: 'Avg profit per tech',
        value: _avgProfitYtd,
        format: dashWholeMoney,
        caption: profitCaption,
        definition:
            "Profit on all completed jobs that started in $year ($period), less Jarred Brandenburg's share of the "
            'jobs he worked, divided by the $_techCount technicians active today. The line shows that profit by '
            'finished month.',
        valueColor: DashUi.blue,
        index: 0,
        trend: dashTrend(_monthlySeries((p) => p.totalProfit.toDouble()), year),
        sparkMinWidth: profitRoom,
      ),
      AnimatedMetricCard(
        title: 'Avg profit per tech per day',
        value: _avgProfitPerDay,
        format: dashWholeMoney,
        caption: dayCaption,
        definition:
            'Average profit per tech divided by the work days so far in $year, counted as 240 a '
            'year (20 a month), not days actually worked${assumedDays == null ? '' : ': $assumedDays for $period'}. '
            'The line shows it by finished month.',
        valueColor: DashUi.blue,
        index: 1,
        trend: dashTrend(_monthlySeries((p) => p.avgProfitPerDay.toDouble()), year),
        sparkMinWidth: dayRoom,
      ),
      AnimatedMetricCard(
        title: 'Callback rate',
        // A year before tracking has no rate: the server's figure is counted from Oct 5, 2026 whatever the year.
        value: tracked ? _callbackRatePct : null,
        format: (v) => '${v.toStringAsFixed(1)}%',
        caption: callbackCaption,
        definition: !tracked
            ? 'Callbacks are counted from Oct 5, 2026, when callback tracking began, so $year has no callback rate.'
            : _callbackRatePct == null
            ? 'Callbacks are counted from Oct 5, 2026. There are no completed jobs from then in $year, '
                  'so there is no rate to show.'
            : 'Callbacks divided by completed jobs, both counted from ${_callbackSince()} (callback '
                  'tracking began Oct 5, 2026) to today: $_callbacks '
                  '${_callbacks == 1 ? 'callback' : 'callbacks'} on $_callbackJobs jobs. Each callback counts '
                  'once, however many techs worked the job. In the list below, each tech is struck for every '
                  'callback on a job they worked.',
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
      // A "today" figure, so only on this year's page (like the techs' own KPI pages).
      if (_streaks.isNotEmpty && year == DashClock.now().year)
        _StreakCard(ranked: _streaks, index: _avgRating == null ? 3 : 4),
    ];

    final pace = _paceRows(year);
    return _Grid(
      tiles: tiles,
      chart: _ProfitChart(
        data: _chartData,
        year: year,
        avgPerDayYtd: _avgProfitPerDay,
        workDays: _workDaysByMonth,
        fieldDays: _fieldDaysByMonth,
        workDayTarget: pace.fold<double>(0, (a, p) => a + p.goals.workDayTarget),
      ),
      techs: (layout) => _TechsPanel(
        g: g,
        ranked: _ranked,
        year: year,
        since: _callbackSince(),
        tracked: tracked,
        layout: layout,
        teamRate: _callbackRatePct,
        tab: _techTab,
        onTab: _setTechTab,
        pace: pace,
      ),
      techCount: _ranked.length,
    );
  }

  /// Every tech, and Dennis, against their targets for [year], furthest ahead of their profit pace first. Work days and
  /// profit come from the server (the commission work days); someone it sends nothing for (an older server) gets
  /// sample figures, the same each time (by their place in the roster).
  List<_Pace> _paceRows(int year) {
    final gone = _yearGone(year);
    bool isDennis(String id, String name) => id == _dennis.id || name.toLowerCase().startsWith('dennis');
    final roster = [..._ranked.where((t) => !isDennis(t.id, t.name))]..sort((a, b) => a.id.compareTo(b.id));
    _PaceGoals goalsFor(_PaceActual? a, _Targets t, int i) => a == null
        ? _samplePace(i, gone, t)
        : _PaceGoals(
            workDayTarget: t.days,
            dayProfitTarget: t.perDay,
            yearProfitTarget: t.year,
            fireGoal: t.fire,
            workDays: a.workDays,
            profit: a.profit,
          );
    // Dennis isn't normally in the technicians list: he comes from the pace list (or, from an older server, as a
    // sample). If the list does carry him, that entry wins.
    final dennisListed = _ranked.where((t) => isDennis(t.id, t.name)).firstOrNull;
    final dennisActual = _paceActuals.values.where((a) => isDennis(a.id, a.name)).firstOrNull;
    final dennis =
        dennisListed ??
        (dennisActual == null
            ? _dennis
            : _TechnicianProfile(
                id: dennisActual.id,
                name: dennisActual.name,
                role: dennisActual.jobTitle.isEmpty ? _dennis.role : dennisActual.jobTitle,
                imageUrl: dennisActual.avatarUrl,
                completedJobsYtd: 0,
                callbackJobs: 0,
                revenue: 0,
                callbackCount: 0,
              ));
    return [
      for (final (i, t) in roster.indexed) _Pace(t, t.pace ?? goalsFor(_paceActuals[t.id], _techTargets, i), gone),
      if (_ranked.isNotEmpty) _Pace(dennis, dennis.pace ?? goalsFor(dennisActual, _dennisTargets, roster.length), gone),
    ]..sort((a, b) {
      final c = b.share.compareTo(a.share);
      return c != 0 ? c : a.tech.name.compareTo(b.tech.name);
    });
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

  /// The panel's inner width, and its whole height when it fills one (for the Work pace view's own rows).
  final double inner;
  final double? height;
  const _TechLayout({required this.oneLine, required this.maxRows, required this.fill, this.inner = 640, this.height});
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
          final maxRows = math.max(
            2,
            ((bodyH - g.panelTop - _TechsPanel.calloutH(g) - (oneLine ? g.columnHead : 0)) / rowH).floor(),
          );
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: g.tile, child: _tileRow(context, tiles)),
              const SizedBox(height: dashGap),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 12, child: chart),
                    const SizedBox(width: dashGap),
                    Expanded(
                      flex: 11,
                      child: techs(
                        _TechLayout(oneLine: oneLine, maxRows: maxRows, fill: true, inner: inner, height: bodyH),
                      ),
                    ),
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
                SizedBox(height: g.tile, child: _tileRow(context, tiles)),
                const SizedBox(height: dashGap),
                SizedBox(height: 320, child: chart),
                const SizedBox(height: dashGap),
                techs(_TechLayout(oneLine: false, maxRows: 999, fill: false, inner: w - 40)),
              ],
            ),
          );
        }
        return SizedBox(width: w, height: c.maxHeight, child: content);
      },
    );
  }

  /// The scorecards side by side, the row shared by what each card needs: its words, and the room for its trend line
  /// when it has one (so a wide caption is not cut, and a card's line isn't squeezed out by its neighbour's words);
  /// placeholders share it evenly.
  Widget _tileRow(BuildContext context, List<Widget> row) => LayoutBuilder(
    builder: (context, c) {
      // The trend lines' room is only claimed when the whole row can give it; otherwise the words share the row.
      final withLines = [for (final w in row) _tileNeed(context, w, lines: true)];
      final fits =
          withLines.every((n) => n != null) &&
          withLines.fold<double>(0, (a, n) => a + n!) + 12 * (row.length - 1) <= c.maxWidth;
      final needs = fits ? withLines : [for (final w in row) _tileNeed(context, w, lines: false)];
      final even = needs.any((n) => n == null);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < row.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(flex: even ? 1 : needs[i]!.round(), child: row[i]),
          ],
        ],
      );
    },
  );

  double? _tileNeed(BuildContext context, Widget w, {required bool lines}) => switch (w) {
    AnimatedMetricCard c => dashTileWidth(
      c.trend == null || !lines
          ? dashTileTextWidth(
              context,
              title: c.title,
              value: c.value == null ? '—' : c.format(c.value!),
              caption: c.caption,
            )
          : dashSparkRoom(
              context,
              title: c.title,
              value: c.value == null ? '—' : c.format(c.value!),
              caption: c.caption,
            ),
    ),
    _StreakCard c => _StreakCardState.needWidth(context, c.ranked),
    _ => null,
  };
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

  /// False for a year before callback tracking began (Oct 5, 2026): nobody has a callback rate, so the list is by
  /// revenue.
  final bool tracked;
  final _TechLayout layout;

  /// The team's callback rate (the scorecard's), the comparison the ranking is read against.
  final double? teamRate;

  /// Which view the panel shows: the callback podium or the techs' work pace. With [onTab] the title row has the
  /// switch between them; without it (the "All" dialog) the panel just shows [tab].
  final _TechTab tab;
  final ValueChanged<_TechTab>? onTab;

  /// Every tech against their targets, furthest ahead of their profit pace first.
  final List<_Pace> pace;
  const _TechsPanel({
    required this.g,
    required this.ranked,
    required this.year,
    required this.since,
    this.tracked = true,
    required this.layout,
    this.teamRate,
    this.tab = _TechTab.callbacks,
    this.onTab,
    this.pace = const [],
  });

  /// The line under the title naming the finding.
  static double calloutH(DashGeo g) => g.line(12) + 6;

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

    // The Work pace view plans its own rows in the panel's height (null: it shows everyone).
    final onPace = tab == _TechTab.pace;
    final pacePlan = _PacePlan.of(
      g,
      inner: layout.inner,
      height: layout.height == null ? null : layout.height! - g.panelTop,
      count: pace.length,
    );
    final everyone = onPace ? pacePlan.shown >= pace.length : all;
    final sample = pace.any((p) => p.goals.sample);
    final link = everyone
        ? null
        : DashLink(
            text: 'All ${onPace ? pace.length : ranked.length}',
            label: 'See all ${dashCount(onPace ? pace.length : ranked.length, 'technician')}',
            onTap: () => _openAll(context),
          );
    // What the Jobs and Revenue columns count (Jobs includes callback visits, site checks and deliveries, so it can be
    // higher than the jobs on a tech's own KPI page).
    const columns =
        ' Jobs: completed jobs that started in the year with any visit by the tech, callback visits, site checks and '
        'deliveries included. Revenue: their share of those jobs\' revenue, split by the days each tech worked.';
    final header = DashPanelHeader(
      g: g,
      title: 'Technicians',
      note: onPace
          ? (sample ? 'sample figures' : 'against their targets')
          : (tracked ? 'fewest callbacks first' : 'by revenue'),
      tooltip: onPace
          ? 'Each technician against their own targets for $year: work days, profit a work day and profit for the '
                'year (a main goal and a stretch "fire" goal). '
                '${year < DashClock.now().year ? 'The ink line on each bar is the target.' : 'The ink line on each bar is where they should be by today (on profit a day, the target).'}'
                '${sample ? ' The targets are the office\'s; the figures so far are samples until the real ones are sent.' : ''}'
          : tracked
          ? 'Ranked by callbacks per completed job since $since (callback tracking began Oct 5, 2026); the first '
                'three stand on the podium. Jobs and revenue are for $year.$columns'
          : 'Callbacks are counted from Oct 5, 2026, when callback tracking began, so $year has no callback '
                'ranking: technicians are listed by revenue for $year.$columns',
      trailing: onTab == null
          ? link
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (link != null) ...[link, const SizedBox(width: 12)],
                DashSegmented<_TechTab>(
                  value: tab,
                  options: const [(_TechTab.callbacks, 'Callbacks'), (_TechTab.pace, 'Work pace')],
                  onChanged: onTab!,
                  label: 'Technicians view',
                ),
              ],
            ),
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

    final Widget body = onPace
        ? _PaceBoard(
            key: const ValueKey(_TechTab.pace),
            g: g,
            rows: pace,
            year: year,
            plan: pacePlan,
            fill: layout.fill,
          )
        : KeyedSubtree(key: const ValueKey(_TechTab.callbacks), child: _callbacks(podium, shown, rankOf, rowH));
    return DashPanel(
      fill: layout.fill,
      header: header,
      child: !layout.fill
          ? body
          // Switching views: the old one fades out as the new one fades in and rises into place.
          : AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 280),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
              transitionBuilder: (child, a) => FadeTransition(
                opacity: a,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, 0.03), end: Offset.zero).animate(a),
                  child: child,
                ),
              ),
              child: body,
            ),
    );
  }

  /// The callback view: the finding, the podium (when there's room), then everyone fewest callbacks first.
  Widget _callbacks(
    List<_TechnicianProfile> podium,
    List<_TechnicianProfile> shown,
    Map<String, int> rankOf,
    double rowH,
  ) {
    final rows = DashRows(
      count: shown.length,
      base: rowH,
      give: 22,
      row: (i) => _row(shown[i], rankOf[shown[i].id + shown[i].name], last: i == shown.length - 1),
    );
    final anyPlaced = ranked.any((t) => t.hasCallbackJobs);
    return LayoutBuilder(
      builder: (context, c) {
        // The podium takes what the list leaves, up to about 1.7 times its smallest size.
        final listH = calloutH(g) + shown.length * rowH + (layout.oneLine ? g.columnHead : 0);
        final minH = podiumHeight(g);
        final podiumH = layout.fill && c.maxHeight.isFinite
            ? (c.maxHeight - listH).clamp(minH, minH * 1.7).toDouble()
            : minH;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: calloutH(g),
              child: Text(
                _finding(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DashText.meta.copyWith(
                  fontWeight: FontWeight.w700,
                  color: anyPlaced ? DashUi.emeraldText : DashUi.slate,
                ),
              ),
            ),
            if (podium.isNotEmpty) _podium(podium, podiumH),
            if (layout.oneLine) _headings(),
            if (layout.fill)
              Expanded(
                child: Align(alignment: Alignment.topCenter, child: rows),
              )
            else
              rows,
          ],
        );
      },
    );
  }

  /// The finding under the title: "Fewest callbacks: Casey Morgan, 0.0% · team 6.9% since Oct 5".
  String _finding() {
    if (!tracked) return 'Callbacks are counted from Oct 5, 2026, so $year has no callback ranking';
    final placed = ranked.where((t) => t.hasCallbackJobs).toList();
    if (placed.isEmpty) return 'No completed jobs since $since to rank yet';
    final first = placed.first;
    final team = teamRate == null ? '' : ' · team ${teamRate!.toStringAsFixed(1)}%';
    return 'Fewest callbacks: ${first.name}, ${first.callbackRate.toStringAsFixed(1)}%$team since $since';
  }

  Widget _podium(List<_TechnicianProfile> top, double height) {
    final order = [if (top.length > 1) (top[1], 2), (top[0], 1), if (top.length > 2) (top[2], 3)];
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
            children: [
              for (final (t, rank) in order) Expanded(child: _step(t, rank, math.min(sc, math.max(1.0, widthCap)))),
            ],
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
          Text(
            t.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: DashText.name.copyWith(fontWeight: first ? FontWeight.w800 : FontWeight.w700),
          ),
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
              style: TextStyle(
                fontSize: (first ? 22 : 18) * math.min(sc, 1.5),
                fontWeight: FontWeight.w800,
                height: 1.1,
                color: _stepText[rank],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static const _podiumAvatar = 54.0;
  static const _stepHeight = {1: 44.0, 2: 34.0, 3: 26.0};

  /// The tallest column (first place): avatar, name and rate over the highest step.
  static double podiumHeight(DashGeo g) => _podiumAvatar + 6 + g.line(13.5) + g.line(12) + 6 + _stepHeight[1]! + 12;

  String _label(_TechnicianProfile t, int? rank) =>
      '${rank == null ? '' : 'Number $rank. '}${t.name}${t.role.isEmpty ? '' : ', ${t.role}'}: '
      '${t.completedJobsYtd} completed jobs and ${dashWholeMoney(t.revenue)} revenue in $year. '
      '${t.hasCallbackJobs ? '${t.callbackCount} ${t.callbackCount == 1 ? 'callback' : 'callbacks'} on ${t.callbackJobs} '
                'completed jobs since $since, ${t.callbackRate.toStringAsFixed(1)}%' : tracked ? 'No completed jobs since $since' : 'Callbacks are counted from Oct 5, 2026'}';

  /// A column heading, with what it counts on hover.
  Widget _heading(String text, double width, String tip) => SizedBox(
    width: width,
    child: Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 500),
      child: Text(text, textAlign: TextAlign.right, maxLines: 1, style: DashText.column),
    ),
  );

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
            _heading(
              'Jobs',
              _jobsW * g.k,
              'Completed jobs that started in $year with any visit by the tech: callback visits, site checks and '
              'deliveries included.',
            ),
            const SizedBox(width: 12),
            _heading(
              'Revenue $year',
              _revenueW * g.k,
              'Their share of the revenue on those jobs, split by the days each tech worked.',
            ),
            const SizedBox(width: 12),
            _heading(
              'Callback rate',
              _callbackW * g.k,
              tracked
                  ? 'Callbacks on jobs they worked, divided by the completed jobs they worked, since $since.'
                  : 'Callbacks are counted from Oct 5, 2026, so $year has none.',
            ),
          ],
        ),
      ),
    ),
  );

  Widget _rate(_TechnicianProfile t) {
    // No completed jobs to rate: a dash in the column (the two-line rows have no column, so nothing).
    if (!t.hasCallbackJobs) {
      return layout.oneLine ? Text('—', style: DashText.meta.copyWith(color: DashUi.muted)) : const SizedBox.shrink();
    }
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
        style: TextStyle(
          fontSize: 12,
          height: 1.3,
          fontWeight: FontWeight.w700,
          color: color,
          fontFeatures: DashText.tabular,
        ),
      ),
    );
  }

  Widget _row(_TechnicianProfile t, int? rank, {required bool last}) {
    final badge = SizedBox(
      width: _rankW,
      child: rank == null
          ? null
          : Align(
              alignment: Alignment.centerLeft,
              child: DashRankBadge(rank: rank, size: _rankW),
            ),
    );
    final avatar = DashAvatar(name: t.name, imageUrl: t.imageUrl, size: _avatar, square: true, accent: DashUi.blue);
    final name = Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.name);
    final role = Text(t.role, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.meta);
    final jobs = Text('${t.completedJobsYtd}', textAlign: TextAlign.right, maxLines: 1, style: DashText.money);
    // Whole dollars, like the other ranking tables (cents on a year's revenue are noise).
    final revenue = Text(
      dashWholeMoney(t.revenue),
      textAlign: TextAlign.right,
      maxLines: 1,
      style: DashText.money.copyWith(color: DashUi.sky),
    );
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
                Row(
                  children: [
                    Expanded(child: name),
                    const SizedBox(width: 8),
                    _rate(t),
                  ],
                ),
                Text(
                  '${t.completedJobsYtd} jobs · ${dashWholeMoney(t.revenue)}',
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: DashUi.line),
        ),
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
                      child: Semantics(
                        header: true,
                        child: Text(
                          'All technicians · ${tab == _TechTab.pace ? 'work pace · ' : ''}$year',
                          style: DashText.panelTitle,
                        ),
                      ),
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
                        tracked: tracked,
                        teamRate: teamRate,
                        layout: const _TechLayout(oneLine: false, maxRows: 999, fill: false),
                        tab: tab,
                        pace: pace,
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
// WORK PACE (each tech against their own targets for the year: work days, profit a work day, profit for the year)
// =============================================================================

enum _TechTab { callbacks, pace }

/// A tech's three targets for a year and their figures so far. The year's profit target is its own figure (not work
/// days times profit a day), so the real targets can be set however the office sets them.
class _PaceGoals {
  /// Days to work in the year, profit to make on a work day, and profit to make in the year.
  final double workDayTarget;
  final double dayProfitTarget;
  final double yearProfitTarget;

  /// Work days so far (a half day counts a half) and the profit on their completed jobs so far.
  final double workDays;
  final double profit;

  /// The stretch goal for the year's profit, the "fire goal" above [yearProfitTarget]; 0 when a tech has none.
  final double fireGoal;

  /// The figures so far are made up, standing in until the server sends the real ones (the targets are the office's).
  final bool sample;

  const _PaceGoals({
    required this.workDayTarget,
    required this.dayProfitTarget,
    required this.yearProfitTarget,
    this.fireGoal = 0,
    required this.workDays,
    required this.profit,
    this.sample = false,
  });

  factory _PaceGoals.fromJson(Map<String, dynamic> json) => _PaceGoals(
    workDayTarget: _parseMoney(json['workDayTarget']),
    dayProfitTarget: _parseMoney(json['dayProfitTarget']),
    yearProfitTarget: _parseMoney(json['yearProfitTarget']),
    fireGoal: _parseMoney(json['fireGoal']),
    workDays: _parseMoney(json['workDays']),
    profit: _parseMoney(json['profit']),
  );
}

/// What the server counted for one person so far this year (its `pace` list): work days to the half day, from the
/// commission work days, and profit on their completed jobs.
class _PaceActual {
  final String id;
  final String name;
  final String jobTitle;
  final String avatarUrl;
  final double workDays;
  final double profit;
  const _PaceActual({
    required this.id,
    required this.name,
    required this.jobTitle,
    required this.avatarUrl,
    required this.workDays,
    required this.profit,
  });

  factory _PaceActual.fromJson(Map<String, dynamic> json) => _PaceActual(
    id: json['id'].toString(),
    name: (json['name'] ?? '').toString(),
    jobTitle: (json['jobTitle'] ?? '').toString(),
    avatarUrl: (json['avatarUrl'] ?? '').toString(),
    workDays: _parseMoney(json['workDays']),
    profit: _parseMoney(json['profit']),
  );
}

/// The office's targets for a year: days to work, profit to make on a work day, the main profit goal and the fire goal.
typedef _Targets = ({double days, double perDay, double year, double fire});

/// Every technician: 240 work days, $1,900 profit a work day, $456,000 for the year, and a fire goal of $600,000.
const _techTargets = (days: 240.0, perDay: 1900.0, year: 456000.0, fire: 600000.0);

/// Dennis Gray (warehouse), who is measured on the same board with his own, smaller targets.
const _dennisTargets = (days: 53.0, perDay: 1900.0, year: 99000.0, fire: 130000.0);

/// The warehouse technician on the pace board: the office's targets, but no figures from the server yet (the
/// technicians list only carries field techs), so his are sample ones.
const _dennis = _TechnicianProfile(
  id: 'dgray',
  name: 'Dennis Gray',
  role: 'Warehouse Technician',
  imageUrl: '',
  completedJobsYtd: 0,
  callbackJobs: 0,
  revenue: 0,
  callbackCount: 0,
);

/// Sample figures so far for the tech at [i] in the roster against [t], standing in until the server sends the real
/// ones. They mix techs ahead and behind (one short on profit a day but ahead for the year, one the other way round),
/// so every part of the view shows. [gone] is the share of the year's work days gone by.
_PaceGoals _samplePace(int i, double gone, _Targets t) {
  // Work days and profit a day, each against its target.
  const vs = [(1.02, 1.06), (0.96, 0.93), (1.05, 0.97), (0.92, 1.03), (1.0, 1.1), (0.97, 0.97)];
  final (dayVs, rateVs) = vs[i % vs.length];
  final workDays = (t.days * gone * dayVs * 2).round() / 2;
  return _PaceGoals(
    workDayTarget: t.days,
    dayProfitTarget: t.perDay,
    yearProfitTarget: t.year,
    fireGoal: t.fire,
    workDays: workDays,
    profit: (workDays * t.perDay * rateVs).roundToDouble(),
    sample: true,
  );
}

/// The share of [year]'s work days (Monday to Friday) gone by today, today included: all of a past year, none of a
/// future one.
double _yearGone(int year) {
  final now = DashClock.now();
  if (year < now.year) return 1;
  if (year > now.year) return 0;
  return _weekdays(year, now) / _weekdays(year, DateTime(year, 12, 31));
}

/// Mondays to Fridays from Jan 1 of [year] to [to], both included (counted in UTC, so no clock change skips a day).
int _weekdays(int year, DateTime to) {
  final end = DateTime.utc(to.year, to.month, to.day);
  var n = 0;
  for (var d = DateTime.utc(year); !d.isAfter(end); d = d.add(const Duration(days: 1))) {
    if (d.weekday <= DateTime.friday) n++;
  }
  return n;
}

/// "182", "182.5": work days to the half day.
String _days(double v) => _trimZero((v * 2).round() / 2);

/// "$1,240".
String _dollars(double v) => '\$${_groupInt(v)}';

/// "$226k", "$1.01M", "$640": profit to the thousand, for the bars' figures.
String _kMoney(double v) {
  final a = v.abs();
  if (a >= 1000000) return '\$${(a / 1000000).toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '')}M';
  if (a >= 1000) return '\$${_groupInt(a / 1000)}k';
  return '\$${a.round()}';
}

/// "4 ahead", "$160 under", or [even] ("on pace") when the gap rounds to nothing.
String _gapWords(String amount, bool up, String over, String under, String even) =>
    RegExp(r'^\$?0$').hasMatch(amount) ? even : '$amount ${up ? over : under}';

/// One tech's standing against their targets: where they should be by today on each goal, and whether they are.
class _Pace {
  final _TechnicianProfile tech;
  final _PaceGoals goals;

  /// The share of the year's work days gone by (1 for a past year).
  final double gone;
  const _Pace(this.tech, this.goals, this.gone);

  bool get past => gone >= 1;

  /// Where they should be by today. The profit-a-day target holds all year, so it is its own pace.
  double get dayPace => goals.workDayTarget * gone;
  double get profitPace => goals.yearProfitTarget * gone;
  double get perDay => goals.workDays > 0 ? goals.profit / goals.workDays : 0;

  /// Profit so far against where it should be by today (1 is exactly on pace): what the techs are ranked by.
  double get share => profitPace > 0 ? goals.profit / profitPace : 0;

  bool get daysOk => goals.workDays >= dayPace;
  bool get rateOk => perDay >= goals.dayProfitTarget;

  /// On pace for the year's profit: the goal the other two add up to, so the tech's verdict.
  bool get onPace => goals.profit >= profitPace;
}

/// One goal of one tech, as a bar and in words: "182 / 220", "4 ahead"; [fill] is the bar's length and [mark] the pace
/// line's place, both as shares of the bar; [about] says it all in a sentence for the hover card.
class _GoalView {
  final String goal;
  final String figure;
  final String target;
  final String gap;
  final bool ok;
  final double fill;
  final double mark;
  final String about;

  /// The main profit goal's place on the year bar and the fire goal's amount, for a bar that has a fire goal (the bar
  /// then runs to the fire goal): null for the others.
  final double? goalMark;
  final String? fireText;
  const _GoalView(
    this.goal,
    this.figure,
    this.target,
    this.gap,
    this.ok,
    this.fill,
    this.mark,
    this.about, {
    this.goalMark,
    this.fireText,
  });

  /// Each goal of [p] in turn: work days, profit a work day, profit for the year. The two yearly bars run to the
  /// year's target with the line where they should be by today, the same place on every row; profit a day runs to a
  /// quarter past its target, with the line on the target. A bar past its end grows to fit and the line moves back.
  static List<_GoalView> of(_Pace p, int year) {
    final g = p.goals;
    final first = p.tech.name.split(' ').first;
    final note = g.sample ? ' Sample figures until the real ones are sent.' : '';
    final past = p.past;
    final ahead = past ? 'over' : 'ahead';
    final even = past ? 'on target' : 'on pace';

    final daysDiff = g.workDays - p.dayPace;
    final daysScale = math.max(g.workDayTarget, g.workDays);
    final rateDiff = p.perDay - g.dayProfitTarget;
    final rateScale = math.max(g.dayProfitTarget * 1.25, p.perDay);
    final profitDiff = g.profit - p.profitPace;
    final fire = g.fireGoal > g.yearProfitTarget;
    final profitScale = math.max(fire ? g.fireGoal : g.yearProfitTarget, g.profit);
    // Where they stand on the two goals, in words for the hover card.
    final reach =
        '${dashWholeMoney(g.yearProfitTarget)} main goal (${(g.profit / g.yearProfitTarget * 100).round()}% there)'
        '${fire ? ' and a ${dashWholeMoney(g.fireGoal)} fire goal (${(g.profit / g.fireGoal * 100).round()}%)' : ''}';
    // A finished year: how far over or short of the target.
    String by(double diff, String Function(double) f) =>
        '${f(diff.abs())} ${diff >= 0 ? 'over' : 'short of'} the target';
    // What makes a work day (the server's rule): for Dennis a day he marked a job complete (he worked in the field);
    // for the techs a Service Fusion visit marked complete, or before Oct 5, 2026 (rarely marked then) any visit.
    final workDayRule = p.tech.id == _dennis.id
        ? ' A work day is a day he marked a job complete in Service Fusion on a visit booked as a full or half day.'
        : ' A work day is a day with a Service Fusion visit marked complete (before Oct 5, 2026, any visit).';

    return [
      _GoalView(
        'Work days',
        _days(g.workDays),
        _days(g.workDayTarget),
        _gapWords(_days(daysDiff.abs()), daysDiff >= 0, ahead, 'short', even),
        p.daysOk,
        daysScale > 0 ? g.workDays / daysScale : 0,
        daysScale > 0 ? p.dayPace / daysScale : 0,
        past
            ? '$first worked ${_days(g.workDays)} days in $year against a target of ${_days(g.workDayTarget)}: '
                  '${by(daysDiff, _days)}.$note'
            : '$first has worked ${_days(g.workDays)} days of a ${_days(g.workDayTarget)}-day target for $year. By today '
                  'they should be on ${_days(p.dayPace)}, so ${_days(daysDiff.abs())} ${daysDiff >= 0 ? 'ahead' : 'behind'}. '
                  'At this rate: ${_days(g.workDays / p.gone)} by Dec 31.$workDayRule$note',
      ),
      _GoalView(
        'Profit a day',
        _dollars(p.perDay),
        _dollars(g.dayProfitTarget),
        _gapWords(_dollars(rateDiff.abs()), rateDiff >= 0, 'over', 'under', 'on target'),
        p.rateOk,
        rateScale > 0 ? p.perDay / rateScale : 0,
        rateScale > 0 ? g.dayProfitTarget / rateScale : 0,
        '$first ${past ? 'made' : 'makes'} ${_dollars(p.perDay)} profit a work day (${dashWholeMoney(g.profit)} over '
            '${_days(g.workDays)} days) against a target of ${_dollars(g.dayProfitTarget)}: ${_dollars(rateDiff.abs())} '
            '${rateDiff >= 0 ? 'over' : 'under'}. The line is the target.$note',
      ),
      _GoalView(
        'Profit for the year',
        _kMoney(g.profit),
        _kMoney(g.yearProfitTarget),
        _gapWords(_kMoney(profitDiff.abs()), profitDiff >= 0, ahead, 'short', even),
        p.onPace,
        profitScale > 0 ? g.profit / profitScale : 0,
        profitScale > 0 ? p.profitPace / profitScale : 0,
        past
            ? '$first made ${dashWholeMoney(g.profit)} profit in $year against a target of '
                  '${dashWholeMoney(g.yearProfitTarget)}: ${by(profitDiff, dashWholeMoney)}. That is $reach.$note'
            : '$first has made ${dashWholeMoney(g.profit)} profit for $year: $reach. By today they should be on '
                  '${dashWholeMoney(p.profitPace)} for the main goal, so ${dashWholeMoney(profitDiff.abs())} '
                  '${profitDiff >= 0 ? 'ahead' : 'behind'}. At this rate: ${dashWholeMoney(g.profit / p.gone)} by Dec 31.$note',
        goalMark: fire && profitScale > 0 ? g.yearProfitTarget / profitScale : null,
        fireText: fire ? _kMoney(g.fireGoal) : null,
      ),
    ];
  }
}

/// What the Work pace view shows in the height it has, most first: the team's figure for each goal over the board,
/// the headline (or a one-line one), the key, and each goal's gap in words under its bar (or just an arrow before its
/// figure). When even the leanest form can't fit everyone, as many rows as fit; the rest are in the "All" dialog.
class _PacePlan {
  final bool tally;
  final bool compactHead;
  final bool keyed;
  final bool roomy;

  /// Each tech on one line (name, then the three bars), or the bars under the name (a narrow panel or larger text).
  final bool oneLine;
  final int shown;
  const _PacePlan({
    required this.tally,
    required this.compactHead,
    required this.keyed,
    required this.roomy,
    required this.oneLine,
    required this.shown,
  });

  // (tally, one-line headline, key, gaps in words), the fullest first.
  static const _forms = [
    (true, false, true, true),
    (false, false, true, true),
    (false, false, false, true),
    (false, false, true, false),
    (false, false, false, false),
    (false, true, false, false),
  ];

  /// [height] is the room under the panel's title row; null (a dialog) shows everything.
  static _PacePlan of(DashGeo g, {required double inner, required double? height, required int count}) {
    final oneLine = inner >= _PaceBoard.oneLineWidth(g);
    _PacePlan plan((bool, bool, bool, bool) f, int shown) =>
        _PacePlan(tally: f.$1, compactHead: f.$2, keyed: f.$3, roomy: f.$4, oneLine: oneLine, shown: shown);
    if (height == null) return plan(_forms.first, count);
    for (final f in _forms) {
      if (_need(g, f, oneLine, count) <= height) return plan(f, count);
    }
    final lean = _forms.last;
    final fits = (height - _need(g, lean, oneLine, 0)) / _PaceBoard.rowHeight(g, oneLine: oneLine, roomy: false);
    return plan(lean, math.max(1, fits.floor()));
  }

  static double _need(DashGeo g, (bool, bool, bool, bool) f, bool oneLine, int rows) {
    final (tally, compact, keyed, roomy) = f;
    return (compact ? DashStoryFrame.compactHeight(g) + 8 : DashStoryFrame.headHeight(g) + 12) +
        (tally ? _PaceBoard.tallyHeight(g) + 10 : 0) +
        g.columnHead +
        rows * _PaceBoard.rowHeight(g, oneLine: oneLine, roomy: roomy) +
        (keyed ? DashStoryFrame.keyHeight(g) : 0);
  }
}

/// The Work pace view: is each tech on pace for their targets, and how do they stack up? The headline answers it (how
/// many are on pace for the year's profit, and the team against its pace) and names who is furthest behind. In a tall
/// panel the team's figure for each goal follows. Then each tech is a row of three bars, one per goal, best first:
/// blue for what they've done, the ink line where they should be by today, emerald past the line when ahead and a red
/// hatched gap back to it when short, with the gap in words under each bar.
/// Rows rise in one after another, their bars run in and each tech's verdict pops in after them; a row swells its bars
/// under the pointer, and a bar's hover card says it all in words. Reduced motion: the finished board at once.
class _PaceBoard extends StatefulWidget {
  final DashGeo g;

  /// Furthest ahead of their profit pace first.
  final List<_Pace> rows;
  final int year;
  final _PacePlan plan;
  final bool fill;
  const _PaceBoard({
    super.key,
    required this.g,
    required this.rows,
    required this.year,
    required this.plan,
    required this.fill,
  });

  // Column widths at 100% text (they grow with the text).
  static const _avatar = 36.0;
  static const _nameW = 104.0;
  static const _cellMin = 96.0;
  static const _bar = 8.0;

  static double nameColumn(DashGeo g) => _avatar + 10 + _nameW * g.k;
  static double oneLineWidth(DashGeo g) => 16 + nameColumn(g) + 3 * (12 + _cellMin * g.k);

  /// A goal: its figure, the bar and (roomy) the gap in words.
  static double _cell(DashGeo g, bool roomy) => g.line(13.5) + 3 + _bar + (roomy ? 3 + g.line(12) : 0);

  static double rowHeight(DashGeo g, {required bool oneLine, required bool roomy}) => oneLine
      ? math.max(g.listRow, _cell(g, roomy) + 10)
      : math.max(g.line(13.5), g.line(12) + 2) + 4 + _cell(g, roomy) + 10;

  /// The team's three figures: a title, the figure and its gap, and how many are on pace (in 8 px padding and a
  /// 1 px border, top and bottom). The +3 absorbs the half pixels text lines round up to.
  static double tallyHeight(DashGeo g) => 18 + g.line(12) + 2 + g.line(18, 1.15) + 2 + g.line(12) + 3;

  @override
  State<_PaceBoard> createState() => _PaceBoardState();
}

class _PaceBoardState extends State<_PaceBoard> with TickerProviderStateMixin {
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 1000 + 90 * math.min(widget.rows.length, 8)),
  );

  /// One loop of the flames on the fire goals; every flicker repeats a whole number of times in it, so it has no seam.
  late final AnimationController _burn = AnimationController(vsync: this, duration: const Duration(seconds: 4));
  int? _hover;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _in.value = 1;
    } else if (_in.value == 0 && !_in.isAnimating) {
      _in.forward();
    }
    _syncBurn();
  }

  @override
  void didUpdateWidget(covariant _PaceBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncBurn();
  }

  /// The flames burn only while a row has a fire goal and motion is on; reduced motion holds one full frame.
  void _syncBurn() {
    final lit = widget.rows.any((p) => p.goals.fireGoal > p.goals.yearProfitTarget);
    if (!lit || MediaQuery.disableAnimationsOf(context)) {
      _burn.stop();
      _burn.value = 0.3;
    } else if (!_burn.isAnimating) {
      _burn.repeat();
    }
  }

  @override
  void dispose() {
    _in.dispose();
    _burn.dispose();
    super.dispose();
  }

  /// Row [i]'s part of the entrance, [from] to [to] of its own stretch; each row starts a little after the one above
  /// (all have started by 30% of the way).
  Animation<double> _phase(int i, double from, double to, [Curve curve = Curves.easeOutCubic]) {
    final n = math.min(widget.rows.length, 8);
    final start = n <= 1 ? 0.0 : math.min(i, n - 1) * 0.3 / (n - 1);
    return CurvedAnimation(
      parent: _in,
      curve: Interval(start + from * 0.7, start + to * 0.7, curve: curve),
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.g;
    final plan = widget.plan;
    final rows = widget.rows;
    final year = widget.year;
    if (rows.isEmpty) return const DashEmptyNote('No active technicians found. Users with a tech role appear here.');
    if (rows.first.gone <= 0) return DashEmptyNote('$year hasn\'t started yet, so there are no work days to measure.');
    final past = rows.first.past;
    final n = rows.length;

    // The headline: how many are on pace for the year's profit, and the team against its pace.
    final on = rows.where((p) => p.onPace).length;
    final profit = rows.fold<double>(0, (a, p) => a + p.goals.profit);
    final profitPace = rows.fold<double>(0, (a, p) => a + p.profitPace);
    final teamPct = profitPace > 0 ? (profit / profitPace - 1) * 100 : 0.0;
    // The one-line headline keeps just the answer (the count of the verdicts below) and the finding its short form, so
    // both read whole on one line.
    final compact = plan.compactHead;
    final headline = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        DashStoryStat(
          on.toDouble(),
          (v) => '${v.round()} of $n',
          compact
              ? (past ? 'hit target' : 'on pace')
              : (past ? 'hit their profit target' : 'on pace for their profit target'),
          DashUi.ink,
        ),
        if (!plan.compactHead) ...[
          const SizedBox(width: 18),
          DashStoryStat(
            teamPct.abs(),
            (v) => '${teamPct >= 0 ? '▲' : '▼'} ${v.round()}%',
            past ? 'team profit against target' : 'team profit against pace',
            teamPct >= 0 ? DashUi.emeraldText : DashUi.redText,
          ),
        ],
      ],
    );

    // The finding: who is furthest behind, or (everyone on pace) who is furthest ahead.
    final behind = [...rows.where((p) => !p.onPace)]..sort((a, b) => a.share.compareTo(b.share));
    final String callout;
    if (behind.isEmpty) {
      final best = rows.first;
      callout =
          '${compact ? 'Furthest ahead' : '${past ? 'Everyone hit their target' : 'Everyone is on pace'} · furthest ahead'}: '
          '${best.tech.name}, ${((best.share - 1) * 100).round()}% over';
    } else {
      final worst = behind.first;
      callout =
          '${past ? 'Missed by the most' : 'Furthest behind'}: ${worst.tech.name}, '
          '${_kMoney(worst.profitPace - worst.goals.profit)} short${compact ? '' : ' of ${past ? 'target' : 'pace'} on profit'}';
    }
    final calloutText = Text(
      callout,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: DashText.meta.copyWith(
        fontWeight: FontWeight.w700,
        color: behind.isEmpty ? DashUi.emeraldText : DashUi.redText,
      ),
    );
    final head = compact
        ? SizedBox(
            height: DashStoryFrame.compactHeight(g),
            // The headline takes what it needs (up to half the line), the finding the rest.
            child: LayoutBuilder(
              builder: (context, c) => Row(
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: c.maxWidth / 2),
                    child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: headline),
                  ),
                  const SizedBox(width: 14),
                  Expanded(child: calloutText),
                ],
              ),
            ),
          )
        : SizedBox(
            height: DashStoryFrame.headHeight(g),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: headline),
                ),
                calloutText,
              ],
            ),
          );

    final shown = rows.take(plan.shown).toList();
    final base = _PaceBoard.rowHeight(g, oneLine: plan.oneLine, roomy: plan.roomy);
    final list = DashRows(
      count: shown.length,
      base: base,
      give: _give,
      row: (i) => _row(shown[i], i, base: base, last: i == shown.length - 1),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        head,
        SizedBox(height: plan.compactHead ? 8 : 12),
        if (plan.tally) ...[
          SizedBox(height: _PaceBoard.tallyHeight(g), child: _tally(rows, on)),
          const SizedBox(height: 10),
        ],
        _headings(past),
        if (widget.fill)
          Expanded(
            child: Align(alignment: Alignment.topCenter, child: list),
          )
        else
          list,
        if (plan.keyed)
          SizedBox(
            height: DashStoryFrame.keyHeight(g),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: SizedBox(
                height: g.line(12) + 2,
                child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: _key(past)),
              ),
            ),
          ),
      ],
    );
  }

  /// The team's figure for each goal against its pace, and how many techs are on pace for it.
  Widget _tally(List<_Pace> rows, int onPace) {
    final n = rows.length;
    final past = rows.first.past;
    double sum(double Function(_Pace) f) => rows.fold<double>(0, (a, p) => a + f(p));
    final days = sum((p) => p.goals.workDays);
    final daysPace = sum((p) => p.dayPace);
    final profit = sum((p) => p.goals.profit);
    final profitPace = sum((p) => p.profitPace);
    // The team's profit-a-day target: each tech's, weighted by the days they've worked.
    final perDay = days > 0 ? profit / days : 0.0;
    final dayTarget = days > 0 ? sum((p) => p.goals.dayProfitTarget * p.goals.workDays) / days : 0.0;
    final ahead = past ? 'over' : 'ahead';
    final even = past ? 'on target' : 'on pace';
    final tiles = [
      (
        'Team work days',
        _days(days),
        days - daysPace,
        (double d) => _gapWords(_days(d.abs()), d >= 0, ahead, 'short', even),
        '${rows.where((p) => p.daysOk).length} of $n ${past ? 'hit target' : 'on pace'}',
      ),
      (
        'Team profit a day',
        _dollars(perDay),
        perDay - dayTarget,
        (double d) => _gapWords(_dollars(d.abs()), d >= 0, 'over', 'under', 'on target'),
        '${rows.where((p) => p.rateOk).length} of $n at target',
      ),
      (
        'Team profit',
        _kMoney(profit),
        profit - profitPace,
        (double d) => _gapWords(_kMoney(d.abs()), d >= 0, ahead, 'short', even),
        '$onPace of $n ${past ? 'hit target' : 'on pace'}',
      ),
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, (title, figure, diff, gap, count)) in tiles.indexed) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(
            child: Semantics(
              container: true,
              label: '$title: $figure, ${gap(diff)}. $count.',
              child: ExcludeSemantics(
                child: FadeTransition(
                  opacity: _phase(i, 0, 0.4),
                  child: SlideTransition(
                    position: Tween(begin: const Offset(0, 0.15), end: Offset.zero).animate(_phase(i, 0, 0.4)),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      decoration: BoxDecoration(
                        color: DashUi.faint.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: DashUi.line),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: DashText.meta.copyWith(fontWeight: FontWeight.w600, color: DashUi.slate),
                          ),
                          const SizedBox(height: 2),
                          // Held to its line: the two sizes on one baseline stand a pixel taller than the figure alone.
                          SizedBox(
                            height: widget.g.line(18, 1.15),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.baseline,
                                textBaseline: TextBaseline.alphabetic,
                                children: [
                                  Text(
                                    figure,
                                    maxLines: 1,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800,
                                      height: 1.15,
                                      color: DashUi.ink,
                                      fontFeatures: DashText.tabular,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '${diff >= 0 ? '▲' : '▼'} ${gap(diff)}',
                                    maxLines: 1,
                                    style: DashText.meta.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: diff >= 0 ? DashUi.emeraldText : DashUi.redText,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(count, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.meta),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _headings(bool past) {
    final g = widget.g;
    final oneLine = widget.plan.oneLine;
    final tips = past
        ? [
            'Days worked in the year against its target. The line is the target.',
            'Profit on their completed jobs divided by the days they worked, against their daily target. The line is '
                'the target.',
            'Profit on their completed jobs in the year against its target. The line is the target.',
          ]
        : [
            'Days worked so far against the year\'s target. The line is where they should be by today: the target '
                'times the share of the year\'s weekdays gone by.',
            'Profit on their completed jobs divided by the days they worked, against their daily target. The line is '
                'the target.',
            'Profit on their completed jobs so far against the year\'s target. The line is where they should be by '
                'today.',
          ];
    const titles = ['Work days', 'Profit a day', 'Profit for the year'];
    return ExcludeSemantics(
      child: SizedBox(
        height: g.columnHead,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              if (oneLine) ...[
                SizedBox(
                  width: _PaceBoard.nameColumn(g),
                  child: const Padding(
                    padding: EdgeInsets.only(left: _PaceBoard._avatar + 10),
                    child: Text('Name', maxLines: 1, style: DashText.column),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(
                  child: Tooltip(
                    message: tips[i],
                    waitDuration: const Duration(milliseconds: 500),
                    child: Text(titles[i], maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.column),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The key, in the words the bars use ("4 ahead", "$19k short"), short enough to read at full size in the narrowest
  /// panel (it used to be scaled down to about 9 px there).
  Widget _key(bool past) {
    Widget gap() => const SizedBox(width: 16);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        dashKeyItem(dashKeyBox(DashUi.blue), 'Done so far'),
        gap(),
        dashKeyItem(dashKeyBox(DashUi.emerald), past ? 'Over' : 'Ahead'),
        gap(),
        dashKeyItem(
          dashKeyBox(DashUi.red.withValues(alpha: 0.16), border: DashUi.red.withValues(alpha: 0.7)),
          'Short',
        ),
        gap(),
        dashKeyItem(
          Container(
            width: 2.5,
            height: 12,
            decoration: BoxDecoration(color: DashUi.ink, borderRadius: BorderRadius.circular(1.25)),
          ),
          past ? 'Target' : 'Today\'s pace',
        ),
        if (widget.rows.any((p) => p.goals.fireGoal > p.goals.yearProfitTarget)) ...[
          gap(),
          dashKeyItem(
            Container(
              width: 2.5,
              height: 12,
              decoration: BoxDecoration(color: DashUi.muted, borderRadius: BorderRadius.circular(1.25)),
            ),
            'Main goal',
          ),
          gap(),
          dashKeyItem(
            const Icon(Icons.local_fire_department_rounded, size: 14, color: DashUi.amber),
            'Fire goal',
          ),
        ],
      ],
    );
  }

  String _label(_Pace p, int rank, List<_GoalView> goals) {
    final verdict = p.past
        ? (p.onPace ? 'hit the profit target' : 'missed the profit target')
        : (p.onPace ? 'on pace' : 'off pace');
    return 'Number $rank. ${p.tech.name}: $verdict. '
        '${[for (final v in goals) '${v.goal} ${v.figure} of ${v.target}${v.fireText == null ? '' : ', fire goal ${v.fireText}'}, ${v.gap}'].join('. ')}.'
        '${p.goals.sample ? ' Sample figures.' : ''}';
  }

  /// How much taller than its base a row grows in a tall panel; its bars thicken with it (8 to 12 px).
  static const _give = 40.0;

  Widget _row(_Pace p, int i, {required double base, required bool last}) => LayoutBuilder(
    builder: (context, c) {
      final extra = c.maxHeight.isFinite ? (c.maxHeight - base).clamp(0.0, _give) : 0.0;
      return _rowAt(p, i, bar: _PaceBoard._bar + 4 * extra / _give, last: last);
    },
  );

  Widget _rowAt(_Pace p, int i, {required double bar, required bool last}) {
    final g = widget.g;
    final plan = widget.plan;
    final t = p.tech;
    final hover = _hover == i;
    final rise = _phase(i, 0, 0.35);
    final grow = _phase(i, 0.1, 0.75);
    final goals = _GoalView.of(p, widget.year);
    final name = Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.name);
    final chip = _PaceChip(on: p.onPace, past: p.past, pop: _phase(i, 0.6, 0.95, Curves.easeOutBack));
    final cells = Row(
      children: [
        for (final (c, v) in goals.indexed) ...[
          if (c > 0) const SizedBox(width: 12),
          Expanded(child: _cell(v, grow, hover, plan.roomy, t.name, bar)),
        ],
      ],
    );
    final Widget body;
    if (plan.oneLine) {
      body = Row(
        children: [
          DashAvatar(name: t.name, imageUrl: t.imageUrl, size: _PaceBoard._avatar, square: true, accent: DashUi.blue),
          const SizedBox(width: 10),
          SizedBox(
            width: _PaceBoard._nameW * g.k,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [name, const SizedBox(height: 3), chip],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: cells),
        ],
      );
    } else {
      body = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: name),
              const SizedBox(width: 8),
              chip,
            ],
          ),
          const SizedBox(height: 4),
          cells,
        ],
      );
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = i),
      onExit: (_) => setState(() => _hover = _hover == i ? null : _hover),
      child: DashPressable(
        onTap: null,
        label: _label(p, i + 1, goals),
        radius: BorderRadius.circular(8),
        builder: (_) => AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: DashUi.faint.withValues(alpha: hover ? 0.8 : 0),
            borderRadius: BorderRadius.circular(8),
            border: last ? null : const Border(bottom: BorderSide(color: DashUi.faint)),
          ),
          child: FadeTransition(
            opacity: rise,
            child: SlideTransition(
              position: Tween(begin: const Offset(0.03, 0), end: Offset.zero).animate(rise),
              child: body,
            ),
          ),
        ),
      ),
    );
  }

  /// One goal: "182 / 220", the bar, and the gap in words ("4 ahead"); without room for the words, an arrow before
  /// the figure says which way it goes.
  Widget _cell(_GoalView v, Animation<double> grow, bool hover, bool roomy, String who, double bar) {
    final color = v.ok ? DashUi.emeraldText : DashUi.redText;
    final arrow = v.ok ? '▲' : '▼';
    final cell = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(
              children: [
                if (!roomy)
                  TextSpan(
                    text: '$arrow ',
                    style: DashText.meta.copyWith(fontWeight: FontWeight.w800, color: color),
                  ),
                TextSpan(text: v.figure, style: DashText.money),
                TextSpan(text: ' / ${v.target}', style: DashText.meta),
              ],
            ),
            maxLines: 1,
          ),
        ),
        const SizedBox(height: 3),
        SizedBox(
          height: bar,
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: v.goalMark == null ? grow : Listenable.merge([grow, _burn]),
              builder: (context, _) => TweenAnimationBuilder<double>(
                tween: Tween(end: hover ? 1.0 : 0.0),
                duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 160),
                builder: (context, swell, _) => CustomPaint(
                  painter: _PaceBarPainter(
                    fill: v.fill,
                    mark: v.mark,
                    goal: v.goalMark,
                    grow: grow.value,
                    swell: swell,
                    burn: v.goalMark == null ? 0 : _burn.value,
                  ),
                ),
              ),
            ),
          ),
        ),
        if (roomy) ...[
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              '$arrow ${v.gap}',
              maxLines: 1,
              style: DashText.meta.copyWith(fontWeight: FontWeight.w700, color: color),
            ),
          ),
        ],
      ],
    );
    return DashHoverCard(
      title: '${v.goal} · $who',
      value: '${v.figure} / ${v.target}',
      body: v.about,
      color: v.ok ? DashUi.emerald : DashUi.red,
      child: cell,
    );
  }
}

/// A tech's verdict: "On pace" with a tick, or "Off pace" with a down arrow (for a past year, "Hit target" or
/// "Missed"). It pops in once their bars have run in.
class _PaceChip extends StatelessWidget {
  final bool on;
  final bool past;
  final Animation<double> pop;
  const _PaceChip({required this.on, required this.past, required this.pop});

  @override
  Widget build(BuildContext context) {
    final color = on ? DashUi.emeraldText : DashUi.redText;
    return ScaleTransition(
      scale: pop,
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(on ? Icons.check_rounded : Icons.arrow_downward_rounded, size: 12, color: color),
            const SizedBox(width: 3),
            Text(
              past ? (on ? 'Hit target' : 'Missed') : (on ? 'On pace' : 'Off pace'),
              maxLines: 1,
              style: TextStyle(fontSize: 12, height: 1.3, fontWeight: FontWeight.w700, color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// One goal's bar: blue up to what's done (or the line), emerald past the line when ahead, a red hatched gap back to
/// the line when short, and the ink line itself standing proud of the bar. [grow] runs the bar in from the left (the
/// line drops in as it starts, the gap shows once it has landed); [swell] thickens it under the pointer.
///
/// A bar with a fire goal ([goal] is the main goal's place on it, the bar's end the fire goal) has the stretch between
/// them tinted amber, a slate tick at the main goal, and a live flame at its end: it ignites with a flare once the bar
/// has landed, then flickers and sways on its own ([burn], one seamless loop) with a breathing glow and embers rising
/// off it. It burns bigger the nearer the tech is to the fire goal. What's done past the main goal is amber, with a heat
/// shimmer running along it.
class _PaceBarPainter extends CustomPainter {
  final double fill;
  final double mark;
  final double? goal;
  final double grow;
  final double swell;
  final double burn;
  const _PaceBarPainter({
    required this.fill,
    required this.mark,
    this.goal,
    required this.grow,
    required this.swell,
    this.burn = 0,
  });

  static final _core = Color.lerp(dashBestMark, Colors.white, 0.75)!;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final s = 1.5 * swell;
    final track = RRect.fromLTRBR(0, -s, w, h + s, Radius.circular(h / 2 + s));
    canvas.drawRRect(track, Paint()..color = DashUi.faint);
    final f = fill.clamp(0.0, 1.0) * w;
    final m = mark.clamp(0.0, 1.0) * w;
    final x = f * grow;
    canvas.save();
    canvas.clipRRect(track);
    final gx = goal == null ? null : goal!.clamp(0.0, 1.0) * w;
    if (gx != null) {
      canvas.drawRect(Rect.fromLTRB(gx, -s, w, h + s), Paint()..color = DashUi.amber.withValues(alpha: 0.2));
    }
    canvas.drawRect(Rect.fromLTRB(0, -s, math.min(x, m), h + s), Paint()..color = DashUi.blue);
    if (x > m) {
      canvas.drawRect(Rect.fromLTRB(m, -s, gx == null ? x : math.min(x, gx), h + s), Paint()..color = DashUi.emerald);
    }
    if (gx != null && x > gx) {
      final zone = Rect.fromLTRB(gx, -s, x, h + s);
      canvas.drawRect(zone, Paint()..color = DashUi.amber);
      // Heat shimmer: a bright band sweeping along the amber, twice a loop.
      final band = math.max(18.0, zone.width * 0.4);
      final bx = zone.left - band + ((burn * 2) % 1) * (zone.width + band);
      canvas.drawRect(
        zone,
        Paint()
          ..shader = LinearGradient(
            colors: [
              Colors.white.withValues(alpha: 0),
              Colors.white.withValues(alpha: 0.45),
              Colors.white.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromLTWH(bx, 0, band, h)),
      );
    }
    final landed = ((grow - 0.8) / 0.2).clamp(0.0, 1.0);
    if (f < m && landed > 0) {
      final gap = Rect.fromLTRB(f, -s, m, h + s);
      canvas.drawRect(gap, Paint()..color = DashUi.red.withValues(alpha: 0.16 * landed));
      canvas.save();
      canvas.clipRect(gap);
      final hatch = Paint()
        ..color = DashUi.red.withValues(alpha: 0.55 * landed)
        ..strokeWidth = 1.2;
      for (var hx = gap.left - gap.height; hx < gap.right; hx += 4) {
        canvas.drawLine(Offset(hx, gap.bottom), Offset(hx + gap.height, gap.top), hatch);
      }
      canvas.restore();
    }
    canvas.restore();
    final a = (grow * 3).clamp(0.0, 1.0);
    if (a > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(m, h / 2), width: 2.5, height: (h + 8 + 2 * s) * a),
          const Radius.circular(1.25),
        ),
        Paint()..color = DashUi.ink.withValues(alpha: a),
      );
      if (gx != null) {
        // The main goal's tick, then the flame at the fire goal (the bar's end).
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset(gx, h / 2), width: 2, height: (h + 4 + 2 * s) * a),
            const Radius.circular(1),
          ),
          Paint()..color = DashUi.muted.withValues(alpha: a),
        );
      }
    }
    if (gx != null && landed > 0) _flame(canvas, size, s, Curves.easeOutBack.transform(landed));
  }

  /// The flame at the bar's end, rising from the bar; [k] is its ignition (overshooting 1 as it flares up).
  void _flame(Canvas canvas, Size size, double s, double k) {
    const tau = math.pi * 2;
    final w = size.width, h = size.height, t = burn;
    // 70% of full size at no profit, full at the fire goal.
    final heat = fill.clamp(0.0, 1.0);
    final fh = (h + 13 + 2 * s) * (0.7 + 0.3 * heat) * k;
    if (fh < 1) return;
    final fw = fh * 0.58;
    final base = Offset(w - (h + 13) * 0.58 / 2 - 1, h / 2 + fh * 0.3);
    final fade = k.clamp(0.0, 1.0);

    // The glow, breathing.
    final pulse = 0.75 + 0.25 * math.sin(tau * 4 * t);
    final glowC = base.translate(0, -fh * 0.42);
    final glowR = fh * (0.85 + 0.15 * heat);
    canvas.drawCircle(
      glowC,
      glowR,
      Paint()
        ..shader = RadialGradient(
          colors: [
            DashUi.amber.withValues(alpha: 0.45 * pulse * fade),
            DashUi.amber.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: glowC, radius: glowR)),
    );

    // One tongue of flame: a round foot and a tip that flickers in height and sways; [p] sets its phase.
    Path tongue(Offset foot, double height, double width, double p) {
      final hh = height * (1 + 0.12 * math.sin(tau * 9 * t + p) + 0.06 * math.sin(tau * 23 * t + p * 1.7));
      final ww = width * (1 - 0.06 * math.sin(tau * 11 * t + p * 0.6));
      final sway = ww * (0.26 * math.sin(tau * 5 * t + p) + 0.1 * math.sin(tau * 13 * t + p * 2.1));
      final x = foot.dx, y = foot.dy, tip = Offset(x + sway, y - hh);
      return Path()
        ..moveTo(x, y)
        ..cubicTo(x - ww * 0.58, y, x - ww * 0.62, y - hh * 0.42, x - ww * 0.22 + sway * 0.3, y - hh * 0.66)
        ..cubicTo(x - ww * 0.04 + sway * 0.6, y - hh * 0.8, tip.dx - ww * 0.06, y - hh * 0.9, tip.dx, tip.dy)
        ..cubicTo(
          tip.dx + ww * 0.12,
          y - hh * 0.84,
          x + ww * 0.36 + sway * 0.4,
          y - hh * 0.6,
          x + ww * 0.46,
          y - hh * 0.36,
        )
        ..cubicTo(x + ww * 0.62, y - hh * 0.12, x + ww * 0.36, y, x, y)
        ..close();
    }

    Shader upward(Rect r, List<Color> colors) =>
        LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: colors).createShader(r);
    final box = Rect.fromLTRB(base.dx - fw, base.dy - fh * 1.2, base.dx + fw, base.dy);

    // Two small licks either side, out of step with each other, then red, amber and a white-hot core.
    for (final side in const [-1.0, 1.0]) {
      canvas.drawPath(
        tongue(base.translate(side * fw * 0.3, -fh * 0.02), fh * 0.55, fw * 0.55, side * 2.4 + 1),
        Paint()
          ..shader = upward(box, [DashUi.red.withValues(alpha: 0.1 * fade), DashUi.red.withValues(alpha: 0.9 * fade)]),
      );
    }
    canvas.drawPath(
      tongue(base, fh, fw, 0),
      Paint()
        ..shader = upward(box, [
          DashUi.red.withValues(alpha: 0.25 * fade),
          DashUi.red.withValues(alpha: fade),
          DashUi.amber.withValues(alpha: fade),
        ]),
    );
    canvas.drawPath(
      tongue(base.translate(0, -fh * 0.02), fh * 0.7, fw * 0.66, 1.3),
      Paint()..shader = upward(box, [DashUi.amber.withValues(alpha: 0.4 * fade), DashUi.amber.withValues(alpha: fade)]),
    );
    canvas.drawPath(
      tongue(base.translate(0, -fh * 0.04), fh * 0.4, fw * 0.4, 2.6),
      Paint()..color = _core.withValues(alpha: 0.95 * fade),
    );

    // Embers drifting up off the tip, more the nearer the fire goal; each starts at its own point of the loop.
    final embers = 2 + (3 * heat).round();
    for (var j = 0; j < embers; j++) {
      final seed = (j * 0.618034) % 1;
      final speed = 2 + j % 2;
      final p = (t * speed + seed) % 1;
      final at = base.translate(math.sin(tau * (p + seed)) * fw * 0.4 + (seed - 0.5) * fw * 0.6, -fh * (0.7 + 0.9 * p));
      final r = (0.8 + 0.8 * ((seed * 3.17) % 1)) * (1 - p) * fade;
      final a = (1 - p) * math.min(1.0, p * 5) * fade;
      if (r <= 0 || a <= 0) continue;
      canvas.drawCircle(at, r, Paint()..color = Color.lerp(DashUi.amber, DashUi.red, p)!.withValues(alpha: a));
    }
  }

  @override
  bool shouldRepaint(_PaceBarPainter old) =>
      old.fill != fill ||
      old.mark != mark ||
      old.goal != goal ||
      old.grow != grow ||
      old.swell != swell ||
      old.burn != burn;
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

  /// Company-wide work days by calendar month and the year's target for all of them together (every tech's and Dennis's
  /// target added up), for the Work days view; no [workDays] leaves that view out.
  final List<double>? workDays;
  final double workDayTarget;

  /// The days Actual / day divides by: everyone whose share is in the profit (the roster, Zac's install days, former
  /// techs). Null from an older server, which uses [workDays].
  final List<double>? fieldDays;
  const _ProfitChart({
    required this.data,
    required this.year,
    required this.avgPerDayYtd,
    this.workDays,
    this.workDayTarget = 0,
    this.fieldDays,
  });

  /// The Work days view: the company's work days each month (bars) against what that month needed (ticks). A month
  /// needs what was still to do at its start, the year's target (every tech's and Dennis's added up) less the days
  /// worked before it, spread over the months left counting it; so the tick moves up when the company falls behind and
  /// down when it gets ahead. This month and the ones after it carry the same figure (the months finished so far decide
  /// it) and a month's need is for the whole month, not to the day.
  DashChartView? _workDaysView() {
    final days = workDays;
    if (days == null || workDayTarget <= 0) return null;
    final now = DashClock.now();
    final thisYear = year == now.year;
    final lastMonth = year < now.year ? 11 : (thisYear ? now.month - 1 : -1);
    if (lastMonth < 0) return null;
    final values = [for (var m = 0; m < 12; m++) m <= lastMonth ? days[m] : 0.0];
    // The first month that hasn't finished (none in a past year): its need holds for the rest of the year.
    final open = thisYear ? lastMonth : 12;
    final targets = <double>[];
    var worked = 0.0;
    for (var m = 0; m < 12; m++) {
      final from = math.min(m, open);
      final before = from == m ? worked : days.take(from).fold<double>(0, (a, b) => a + b);
      targets.add(math.max(0.0, workDayTarget - before) / (12 - from));
      if (m <= lastMonth) worked += values[m];
    }
    final done = values.fold<double>(0, (a, b) => a + b);
    if (done <= 0) return null;
    String n(num v) => _groupInt((v * 2).round() / 2);
    final left = math.max(0.0, workDayTarget - done);
    final monthsLeft = thisYear ? 12 - now.month + 1 : 0;
    final doneMonths = values.take(thisYear ? lastMonth : 12).where((v) => v > 0).toList();
    final pace = doneMonths.isEmpty ? 0.0 : doneMonths.fold<double>(0, (a, b) => a + b) / doneMonths.length;
    final need = thisYear ? targets[lastMonth] : 0.0;
    // Needing more a month than the finished months have managed is the warning.
    final behind = thisYear ? need > pace : done < workDayTarget;
    return DashChartView(
      tab: 'Work days',
      title: 'Work days against target',
      note: '${n(done)} of ${n(workDayTarget)} for $year',
      headline: [
        DashStoryStat(done, n, thisYear ? 'work days so far' : 'work days in $year', DashUi.blue),
        if (thisYear && monthsLeft > 0 && left > 0)
          DashStoryStat(
            need,
            (v) => '${behind ? '▲' : '▼'} ${n(v)} a month',
            'needed for the $monthsLeft ${monthsLeft == 1 ? 'month' : 'months'} left',
            behind ? DashUi.redText : DashUi.emeraldText,
          ),
      ],
      callout: left > 0
          ? (thisYear
                ? '${n(left)} of the ${n(workDayTarget)} target days still to work'
                : '${n(left)} days short of the ${n(workDayTarget)}-day target')
          : 'The ${n(workDayTarget)}-day target ${thisYear ? 'is' : 'was'} met',
      calloutColor: behind ? DashUi.redText : DashUi.emeraldText,
      series: [DashSeries('Work days', values, DashUi.blue)],
      prior: targets,
      priorLabel: 'Needed that month',
      axis: (v) => _groupInt(v),
      barLabel: (v) => _groupInt(v),
      badge: DashChangeChip.monthOverMonth(values, year, what: 'Work days'),
      tip: (i) {
        final diff = values[i] - targets[i];
        return [
          if (i <= lastMonth) DashTipRow('Work days', n(values[i]), color: DashUi.blue),
          DashTipRow(i <= lastMonth ? 'Needed' : 'Needed a month', n(targets[i])),
          if (i <= lastMonth && targets[i] > 0) DashTipRow(diff >= 0 ? 'Ahead by' : 'Behind by', n(diff.abs())),
        ];
      },
      summary: (last) =>
          'Work days by month against what each needed: ${[for (var i = 0; i <= last; i++) '${dashMonthNames[i]} ${n(values[i])} of ${n(targets[i])}'].join(', ')}',
      emptyText: 'No work days recorded for $year yet.',
      semanticsLabel: 'Company work days by month against what each month needed to reach the target, $year',
    );
  }

  /// The Actual / day view, a line: each month's gross profit divided by the work days the company actually worked that
  /// month (the same days as the Work days view, so one tech's day is one day), against the $1,900 a day target.
  DashChartView? _profitPerDayView() {
    final days = fieldDays ?? workDays;
    if (days == null) return null;
    final now = DashClock.now();
    final lastMonth = year < now.year ? 11 : (year == now.year ? now.month - 1 : -1);
    if (lastMonth < 0) return null;
    final profits = [
      for (var m = 0; m < 12; m++) m < data.length && m <= lastMonth ? data[m].totalProfit.toDouble() : 0.0,
    ];
    final values = [for (var m = 0; m < 12; m++) m <= lastMonth && days[m] > 0 ? profits[m] / days[m] : 0.0];
    final counted = [
      for (var m = 0; m <= lastMonth; m++)
        if (values[m] > 0) m,
    ];
    if (counted.isEmpty) return null;
    final profit = counted.fold<double>(0, (a, m) => a + profits[m]);
    final worked = counted.fold<double>(0, (a, m) => a + days[m]);
    final actual = profit / worked;
    final target = _techTargets.perDay;
    final diff = actual - target;
    final ahead = diff >= 0;
    // The finding is read from finished months only, like the other views: the month in progress has its days but
    // not yet the profit of the jobs started in it that are still open.
    final finished = [
      for (final m in counted)
        if (year < now.year || m < now.month - 1) m,
    ];
    final best = finished.isEmpty ? null : finished.reduce((a, b) => values[a] >= values[b] ? a : b);
    final latest = finished.isEmpty ? null : finished.last;
    String d(num v) => _dollars(v.toDouble());
    return DashChartView(
      tab: 'Actual / day',
      title: 'Actual profit per work day',
      // Short enough that the view toggle keeps the title's row (the bars are plainly by month).
      note: 'company profit ÷ days worked',
      headline: [
        DashStoryStat(actual, d, 'profit per work day', DashUi.blue),
        DashStoryStat(
          diff.abs(),
          (v) => '${ahead ? '▲' : '▼'} ${d(v)}',
          '${ahead ? 'over' : 'under'} the ${d(target)} target',
          ahead ? DashUi.emeraldText : DashUi.redText,
        ),
      ],
      callout: best == null
          ? 'The first month is still in progress'
          : 'Best month: ${dashMonthNames[best]}, ${d(values[best])} a day'
                '${latest != best ? ' · ${dashMonthNames[latest!]} was ${d(values[latest])}' : ''}',
      calloutColor: ahead ? DashUi.emeraldText : DashUi.redText,
      series: [DashSeries('Profit per work day', values, DashUi.blue, kind: DashSeriesKind.line)],
      liveLine: true,
      barLabel: d,
      average: target,
      averageLabel: 'Target ${d(target)}',
      axis: _compactMoney,
      badge: DashChangeChip.monthOverMonth(values, year, what: 'Profit per work day'),
      tip: (i) {
        final v = values[i];
        return [
          DashTipRow('Profit per work day', d(v), color: DashUi.blue),
          if (v > 0) DashTipRow(v >= target ? 'Over target by' : 'Under target by', d((v - target).abs())),
          DashTipRow('Profit', _compactMoney(profits[i])),
          DashTipRow('Work days', _groupInt((days[i] * 2).round() / 2)),
        ];
      },
      summary: (last) =>
          'Profit per work day by month: ${[for (var i = 0; i <= last; i++) '${dashMonthNames[i]} ${d(values[i])}'].join(', ')}',
      emptyText: 'No work days recorded for $year yet.',
      semanticsLabel: 'Company profit per work day by month against the ${d(target)} target, $year',
    );
  }

  @override
  Widget build(BuildContext context) {
    _MonthlyChartPoint? at(int i) => i < data.length ? data[i] : null;
    List<double> series(double Function(_MonthlyChartPoint) f) => [
      for (var i = 0; i < 12; i++) at(i) == null ? 0.0 : f(at(i)!),
    ];

    final withData = [
      for (var i = 0; i < data.length && i < 12; i++)
        if (_pointHasData(data[i])) i,
    ];
    final completed = withData.where((i) => !data[i].partial).toList();
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
      required String headLabel,
      required String Function(double) headFormat,
      required String unit,
    }) {
      final values = series(value);
      final priors = series(prior);
      final sum = withData.fold<double>(0, (a, i) => a + value(data[i]));

      // Against last year, like with like: the finished months that have figures both years.
      final both = [
        for (final i in completed)
          if (priors[i] > 0 && values[i] > 0) i,
      ];
      double over(List<double> v) => both.fold<double>(0, (a, i) => a + v[i]);
      final change = both.isEmpty ? null : (over(values) - over(priors)) / over(priors) * 100;
      int? best;
      for (final i in completed) {
        if (values[i] > 0 && (best == null || values[i] > values[best])) best = i;
      }
      final String callout;
      var calloutColor = DashUi.slate;
      if (best == null) {
        callout = withData.isEmpty ? 'Nothing recorded yet' : 'The first month is still in progress';
      } else {
        final latest = completed.last;
        final vsAvg = average > 0 ? (values[latest] - average) / average * 100 : 0.0;
        callout =
            'Best month: ${dashMonthNames[best]}, ${format(values[best])}$unit'
            '${latest != best && vsAvg.abs() >= 5 ? ' · ${dashMonthNames[latest]} was ${vsAvg.abs().round()}% ${vsAvg < 0 ? 'under' : 'over'} the average' : ''}';
        calloutColor = DashUi.emeraldText;
      }
      return DashChartView(
        tab: tab,
        title: title,
        headline: [
          DashStoryStat(showsAverage ? average : sum, headFormat, headLabel, DashUi.blue),
          if (change != null)
            DashStoryStat(
              change.abs(),
              (v) => '${change >= 0 ? '▲' : '▼'} ${v.round()}%',
              'on ${year - 1}, same months',
              change >= 0 ? DashUi.emeraldText : DashUi.redText,
            ),
        ],
        callout: callout,
        calloutColor: calloutColor,
        // The headline carries the figure (the year's average for a rate, its total otherwise), so the title's note
        // says what the bars are instead of repeating it.
        note: 'by start month',
        series: [DashSeries(row, values, DashUi.blue)],
        prior: hasPrior ? priors : null,
        priorLabel: '${year - 1}',
        average: average > 0 ? average : null,
        averageLabel: average > 0 ? 'Year average ${format(average)}' : null,
        axis: (v) => axis(v),
        barLabel: _compactMoney,
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
            if (p != null) DashTipRow('Jobs', '${p.jobCount}'),
          ];
        },
        summary: (last) =>
            '$title: ${[for (var i = 0; i <= last; i++) '${dashMonthNames[i]} ${format(values[i])}'].join(', ')}',
        emptyText: 'No completed jobs recorded for $year yet.',
        semanticsLabel:
            '$title by month, $year${hasPrior ? ', with the same month of ${year - 1} for comparison' : ''}',
      );
    }

    final workDaysView = _workDaysView();
    final perDayView = _profitPerDayView();

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
          headLabel: 'profit per tech per day',
          headFormat: (v) => '\$${_groupInt(v)}',
          unit: ' a day',
        ),
        ?workDaysView,
        ?perDayView,
      ],
    );
  }
}

// =============================================================================
// LONGEST CALLBACK-FREE STREAK (the leader's photo in a ring of fire)
// =============================================================================

/// The longest callback-free streak on the team today: a dark ember card with the number counting up in fire colours,
/// who holds it, and their photo in a ring of fire. The ring ignites when the card appears, then burns on its own:
/// three layers of flame tongues (red, amber, a white-hot core) lick up around the photo, taller at the top, sparks
/// rise past it and the glow breathes. It burns bigger the longer the streak (full at 40 jobs). Reduced motion: one
/// still frame of the full fire. No streak: a cold grey ring.
class _StreakCard extends StatefulWidget {
  /// Every tech by streak, longest first.
  final List<_TechnicianProfile> ranked;
  final int index;
  const _StreakCard({required this.ranked, required this.index});

  @override
  State<_StreakCard> createState() => _StreakCardState();
}

class _StreakCardState extends State<_StreakCard> with TickerProviderStateMixin {
  /// One loop of the fire; every flicker and spark repeats a whole number of times in it, so the loop has no seam.
  late final AnimationController _burn = AnimationController(vsync: this, duration: const Duration(seconds: 6));
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 1500 + widget.index * 110),
  );
  bool _still = false;

  static const _title = 'Longest callback-free streak';

  /// The fire's box beside the words: the photo nearly as tall as the card, and flames either side of it.
  static double fireWidthFor(double cardHeight) => cardHeight * 1.18;

  /// The card's width with its words and the fire side by side (for sharing the row by what each card needs).
  static double needWidth(BuildContext context, List<_TechnicianProfile> ranked) {
    final leader = ranked.first;
    final streak = leader.jobsSinceCallback ?? 0;
    final tied = streak > 0 ? ranked.where((t) => t.jobsSinceCallback == streak).length - 1 : 0;
    final words = dashTileTextWidth(
      context,
      title: _title,
      value: '$streak jobs in a row',
      caption: '${leader.name}${tied > 0 ? ' + $tied tied' : ''} · no callbacks',
    );
    return 18 + words + fireWidthFor(dashTileHeight(context)) + 2;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.disableAnimationsOf(context);
    if (_still) {
      _burn.stop();
      _burn.value = 0.37;
      _enter.value = 1;
    } else {
      if (!_burn.isAnimating) _burn.repeat();
      if (_enter.value == 0 && !_enter.isAnimating) _enter.forward();
    }
  }

  @override
  void dispose() {
    _burn.dispose();
    _enter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final leader = widget.ranked.first;
    final streak = leader.jobsSinceCallback ?? 0;
    final lit = streak > 0;
    final tied = lit ? widget.ranked.where((t) => t.jobsSinceCallback == streak).length - 1 : 0;
    final first = leader.name.split(' ').first;
    final caption = !lit
        ? 'Every tech had a callback on their last job'
        : '${leader.name}${tied > 0 ? ' + $tied tied' : ''} · no callbacks';
    final others = widget.ranked
        .skip(1)
        .take(3)
        .map((t) => '${t.name.split(' ').first} ${t.jobsSinceCallback}')
        .join(', ');
    final definition = lit
        ? 'The most completed jobs any current technician has done in a row without a callback: $first\'s last '
              '${dashCount(streak, 'job')}${tied > 0 ? ' (tied with ${dashCount(tied, 'other tech')})' : ''}, counted since '
              'their last callback or since Oct 5, 2026, when callback tracking began. Today\'s figure. '
              '${others.isEmpty ? '' : 'Next: $others.'}'
        : 'Every current technician\'s most recent job had a callback, so no one has a streak going today.';
    final heat = lit ? 0.5 + 0.5 * (streak.clamp(0, 40) / 40.0) : 0.0;
    final photo = leader.imageUrl.contains('ui-avatars.com') ? '' : leader.imageUrl;
    final bright = Color.lerp(dashBestMark, Colors.white, 0.6)!;
    final enter = CurvedAnimation(
      parent: _enter,
      curve: Interval(widget.index * 110 / (1500 + widget.index * 110), 0.45, curve: Curves.easeOutCubic),
    );
    final ignite = CurvedAnimation(
      parent: _enter,
      curve: const Interval(0.25, 1, curve: Curves.easeOutCubic),
    );

    // The photo nearly fills the card's height; the fire burns round it and its crown bursts out over the card's top.
    Widget card = HoverLift(
      builder: (context, hovering) => LayoutBuilder(
        builder: (context, c) {
          final box = _StreakCardState.fireWidthFor(c.maxHeight);
          final withFire = c.maxWidth - box >= 170;
          final fireSize = Size(box, c.maxHeight + _FireRingPainter.over);
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [DashUi.ink, Color.lerp(DashUi.ink, lit ? DashUi.red : DashUi.slate, 0.3)!],
                    ),
                    border: Border.all(
                      color: (lit ? DashUi.amber : DashUi.slate).withValues(alpha: hovering ? 0.75 : 0.4),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: (lit ? DashUi.amber : DashUi.ink).withValues(alpha: hovering ? 0.32 : 0.16),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  padding: EdgeInsets.fromLTRB(18, 0, withFire ? box : 14, 0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                          color: Colors.white.withValues(alpha: 0.88),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          ShaderMask(
                            blendMode: BlendMode.srcIn,
                            shaderCallback: (r) => LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: lit ? [bright, dashBestMark, DashUi.red] : [DashUi.muted, DashUi.muted],
                              stops: lit ? const [0, 0.55, 1] : null,
                            ).createShader(r),
                            child: TweenAnimationBuilder<double>(
                              tween: Tween(begin: _still ? streak.toDouble() : 0, end: streak.toDouble()),
                              duration: _still ? Duration.zero : const Duration(milliseconds: 1100),
                              curve: Curves.easeOutCubic,
                              builder: (context, x, _) => Text(
                                '${x.round()}',
                                maxLines: 1,
                                style: const TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w800,
                                  height: 1.1,
                                  color: Colors.white,
                                  fontFeatures: DashText.tabular,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            streak == 1 ? 'job in a row' : 'jobs in a row',
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              height: 1.3,
                              color: Colors.white.withValues(alpha: 0.72),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
                          color: Colors.white.withValues(alpha: 0.66),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (withFire)
                Positioned(
                  right: 0,
                  top: -_FireRingPainter.over,
                  bottom: 0,
                  width: box,
                  child: RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: Listenable.merge([_burn, _enter]),
                      builder: (context, child) {
                        final fire = (t: _burn.value, ignite: ignite.value, heat: heat);
                        return CustomPaint(
                          painter: _FireRingPainter(fire: fire, back: true),
                          foregroundPainter: _FireRingPainter(fire: fire, back: false),
                          child: child,
                        );
                      },
                      // Centred exactly where the painter draws the ring, on a light disc so initials read.
                      child: Stack(
                        children: [
                          Positioned.fromRect(
                            rect: Rect.fromCircle(
                              center: _FireRingPainter.centerIn(fireSize),
                              radius: _FireRingPainter.radiusIn(fireSize),
                            ),
                            child: Container(
                              decoration: const BoxDecoration(color: DashUi.faint, shape: BoxShape.circle),
                              child: DashAvatar(
                                name: leader.name,
                                imageUrl: photo,
                                size: _FireRingPainter.radiusIn(fireSize) * 2,
                                accent: lit ? DashUi.amber : DashUi.slate,
                                ringColor: lit ? bright : DashUi.muted,
                                ringWidth: 2.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
    card = DashHoverCard(
      title: _title,
      value: '${dashCount(streak, 'job')} · ${leader.name}',
      body: definition,
      color: DashUi.amber,
      child: card,
    );
    return Semantics(
      container: true,
      label: lit
          ? '$_title: ${leader.name}, ${dashCount(streak, 'job')} in a row with no callback. $definition'
          : '$_title: none today. $definition',
      child: ExcludeSemantics(
        child: FadeTransition(
          opacity: enter,
          child: SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, 0.12), end: Offset.zero).animate(enter),
            child: card,
          ),
        ),
      ),
    );
  }
}

/// A ring of fire around a round photo in the middle of the box. [back] draws the glow and the flame tongues behind the
/// photo; the front draws the sparks over it. Every flicker runs a whole number of times per loop of [fire.t].
class _FireRingPainter extends CustomPainter {
  final ({double t, double ignite, double heat}) fire;
  final bool back;
  const _FireRingPainter({required this.fire, required this.back});

  static const _tongues = 18;

  /// The photo's radius as a share of the box, and its centre's place down the box (Alignment y: -1 top, 1 bottom).
  /// How far the fire rises over the card's top edge.
  static const over = 14.0;

  /// The card's height, the photo's radius (most of the card) and its centre, a little below the card's middle.
  static double _card(Size size) => size.height - over;
  static double radiusIn(Size size) => _card(size) * 0.41;
  static Offset centerIn(Size size) => Offset(size.width / 2, over + _card(size) * 0.53);
  static final _core = Color.lerp(dashBestMark, Colors.white, 0.7)!;

  @override
  void paint(Canvas canvas, Size size) {
    final c = centerIn(size);
    final r = radiusIn(size);
    final k = fire.ignite;
    final t = fire.t;
    const tau = math.pi * 2;
    if (fire.heat <= 0) {
      // No streak: a cold ring of smoke.
      if (back) {
        canvas.drawCircle(
          c,
          r * 1.12,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = r * 0.2
            ..color = DashUi.muted.withValues(alpha: 0.25 * k),
        );
      }
      return;
    }
    final heat = fire.heat;
    if (back) {
      // The glow, breathing.
      final pulse = 0.82 + 0.18 * math.sin(tau * 5 * t);
      final glowR = r * (1.35 + 0.3 * heat);
      canvas.drawCircle(
        c,
        glowR,
        Paint()
          ..shader = RadialGradient(
            colors: [
              DashUi.amber.withValues(alpha: 0.6 * k * pulse),
              DashUi.red.withValues(alpha: 0.22 * k * pulse),
              DashUi.red.withValues(alpha: 0),
            ],
            stops: const [0.35, 0.68, 1],
          ).createShader(Rect.fromCircle(center: c, radius: glowR)),
      );
      // Three layers of tongues: red outside, amber, then the white-hot core, each a little shorter and offset.
      final layers = [
        (DashUi.red, 1.0, 0.0, BlendMode.srcOver),
        (DashUi.amber, 0.78, 0.5, BlendMode.plus),
        (_core, 0.5, 0.25, BlendMode.plus),
      ];
      for (final (li, layer) in layers.indexed) {
        final (color, scale, shift, blend) = layer;
        for (var i = 0; i < _tongues; i++) {
          final a = -math.pi / 2 + (i + shift) * tau / _tongues;
          final o = Offset(math.cos(a), math.sin(a));
          // Taller at the top (fire rises), short licks underneath.
          final top = (1 - o.dy) / 2;
          final flicker =
              0.74 + 0.16 * math.sin(tau * 13 * t + i * 1.9 + li) + 0.1 * math.sin(tau * 21 * t + i * 0.7 + li * 2.3);
          final len = _card(size) * (0.16 + 0.24 * heat) * (0.22 + 0.78 * math.pow(top, 2.4)) * flicker * scale * k;
          if (len < 0.5) continue;
          // Leaning upward as they burn.
          final lean = o * (1 - 0.5 * top) + const Offset(0, -1) * (0.35 + 0.4 * top);
          final dir = lean / lean.distance;
          final perp = Offset(-dir.dy, dir.dx);
          final sway = math.sin(tau * 8 * t + i * 2.3 + li) * len * 0.22;
          final halfW = tau / _tongues * (0.75 + 0.35 * top);
          final b1 = c + Offset(math.cos(a - halfW), math.sin(a - halfW)) * r * 0.96;
          final b2 = c + Offset(math.cos(a + halfW), math.sin(a + halfW)) * r * 0.96;
          final base = c + o * r * 0.96;
          final tip = base + dir * len + perp * sway;
          final path = Path()
            ..moveTo(b1.dx, b1.dy)
            ..quadraticBezierTo(
              b1.dx + dir.dx * len * 0.55 - perp.dx * len * 0.05,
              b1.dy + dir.dy * len * 0.55 - perp.dy * len * 0.05,
              tip.dx,
              tip.dy,
            )
            ..quadraticBezierTo(
              b2.dx + dir.dx * len * 0.55 + perp.dx * len * 0.05,
              b2.dy + dir.dy * len * 0.55 + perp.dy * len * 0.05,
              b2.dx,
              b2.dy,
            )
            ..close();
          canvas.drawPath(
            path,
            Paint()
              ..blendMode = blend
              ..shader = LinearGradient(colors: [color.withValues(alpha: 0.95), color.withValues(alpha: 0.05)])
                  .createShader(Rect.fromPoints(base, tip)),
          );
        }
      }
      // The burning rim the tongues grow from.
      canvas.drawCircle(
        c,
        r * 1.02,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.12
          ..blendMode = BlendMode.plus
          ..color = DashUi.amber.withValues(alpha: 0.7 * k),
      );
      return;
    }
    // Sparks rising past the photo, more the hotter the fire; each starts at a different point of the loop.
    final sparks = 6 + (10 * heat).round();
    for (var j = 0; j < sparks; j++) {
      final seed = (j * 0.618034) % 1;
      final speed = 3 + j % 2;
      final p = (t * speed + seed) % 1;
      final x = c.dx + ((seed * 7.31) % 1 - 0.5) * r * 1.8 + math.sin(tau * (p * 1.5 + seed)) * r * 0.15;
      final y = c.dy - r * 1.05 - p * (c.dy - r * 1.05);
      final size = (1.3 + 1.8 * ((seed * 3.17) % 1)) * (1 - p);
      final fade = (1 - p) * k * math.min(1.0, p * 6);
      if (fade <= 0 || size <= 0) continue;
      canvas.drawCircle(
        Offset(x, y),
        size,
        Paint()
          ..blendMode = BlendMode.plus
          ..color = Color.lerp(_core, DashUi.red, p)!.withValues(alpha: fade),
      );
    }
  }

  @override
  bool shouldRepaint(_FireRingPainter old) => old.fire != fire || old.back != back;
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
