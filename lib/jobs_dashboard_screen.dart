import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'utils/status_colors.dart';
import 'config/api_config.dart';
import 'widgets/dashboard_data.dart';
import 'widgets/dashboard_kit.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'widgets/dashboard_layout.dart';
import 'widgets/dashboard_panels.dart';
import 'widgets/estimate_list_dialog.dart';

// The Jobs dashboard. The year figures count jobs by start date; active jobs and their statuses are as of today,
// whatever year the jobs are from.
//   scorecards  completed jobs, active open jobs, profit margin, average job revenue, new customers
//   left        the monthly chart (completed jobs, average job value, residential vs commercial, install vs service)
//               over the year's quick insights
//   right       active jobs by status; each status opens its jobs
// The page fits the window without scrolling and without shrinking text (see _Grid).

class JobsDashboardScreen extends StatelessWidget {
  const JobsDashboardScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      title: 'Jobs',
      builder: (context, selectedYear) {
        return JobsDashboardContent(selectedYear: selectedYear);
      },
    );
  }
}

class JobsDashboardContent extends StatefulWidget {
  final int selectedYear;
  const JobsDashboardContent({Key? key, required this.selectedYear}) : super(key: key);

  @override
  State<JobsDashboardContent> createState() => _JobsDashboardContentState();
}

// =============================================================================
// SHARED HELPERS
// =============================================================================

String _trimZero(double v) {
  final s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

String _compactMoney(num v) {
  final a = v.abs();
  final sign = v < 0 ? '-' : '';
  if (a >= 1000000) return '$sign\$${_trimZero(a / 1000000)}M';
  if (a >= 1000) return '$sign\$${_trimZero(a / 1000)}k';
  return '$sign\$${a.round()}';
}

// =============================================================================
// MODELS
// =============================================================================

class _MonthlyJobData {
  final String month;
  final int completedTotal;
  final int installCount;
  final int serviceCount;
  final double resRevenue;
  final double comRevenue;
  final bool hasData;

  const _MonthlyJobData({
    required this.month,
    required this.completedTotal,
    required this.installCount,
    required this.serviceCount,
    required this.resRevenue,
    required this.comRevenue,
    required this.hasData,
  });

  double get totalRevenue => resRevenue + comRevenue;
}

class _PipelineStage {
  final String label;
  final int count;
  final Color color;
  const _PipelineStage({required this.label, required this.count, required this.color});
}

class _JobStatusCount {
  final String status;
  final int count;
  const _JobStatusCount({required this.status, required this.count});
}

const _categoricalPalette = [
  DashUi.sky,
  DashUi.amber,
  DashUi.emeraldDeep,
  DashUi.indigo,
  DashUi.red,
  DashUi.blue,
];

// =============================================================================
// SCREEN STATE
// =============================================================================

class _JobsDashboardContentState extends State<JobsDashboardContent> with DashboardLoading {
  int _completedYtd = 0;
  int _activeOpenJobs = 0;
  double _avgProfitMargin = 0.0;
  double _avgJobRevenue = 0.0;
  int _newCustomersYtd = 0;

  List<_MonthlyJobData> _monthlyData = [];

  /// Profit margin % and first-time customers per calendar month (January first), and daily snapshots of the
  /// active open job count (oldest first), for the scorecards' trend lines.
  List<double> _marginMonthly = List.filled(12, 0);
  List<double> _newCustMonthly = List.filled(12, 0);
  List<double> _activeHistory = [];
  List<_PipelineStage>? _pipelineStages;
  List<_JobStatusCount>? _statusCounts;
  ({int completed, int withCategories, int? withLineItems})? _splitCoverage;

  @override
  void initState() {
    super.initState();
    dashReload();
  }

  @override
  void didUpdateWidget(covariant JobsDashboardContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedYear != widget.selectedYear) dashReload();
  }

  @override
  Future<void> dashReload({bool fresh = false}) => dashLoad(
        '/api/dashboards/jobs',
        query: {'year': '${widget.selectedYear}'},
        fresh: fresh,
        apply: _apply,
      );

  int _parseInt(dynamic v) => v == null ? 0 : (v is num ? v.toInt() : int.tryParse(v.toString()) ?? 0);
  double _parseDouble(dynamic v) => v == null ? 0.0 : (v is num ? v.toDouble() : double.tryParse(v.toString()) ?? 0.0);

  static const _pipelinePalette = [DashUi.red, DashUi.amber, DashUi.sky, DashUi.emeraldDeep, DashUi.indigo];

  List<_PipelineStage>? _parsePipelineStages(dynamic raw) {
    if (raw is! List || raw.isEmpty) return null;
    final stages = <_PipelineStage>[];
    for (int i = 0; i < raw.length; i++) {
      final item = raw[i];
      if (item is! Map) continue;
      stages.add(_PipelineStage(
        label: (item['stage'] ?? 'Unknown').toString(),
        count: _parseInt(item['count']),
        color: _pipelinePalette[i % _pipelinePalette.length],
      ));
    }
    return stages.isEmpty ? null : stages;
  }

  List<_JobStatusCount>? _parseStatusCounts(dynamic raw) {
    if (raw is! List || raw.isEmpty) return null;
    final statuses = <_JobStatusCount>[];
    for (var item in raw) {
      if (item is! Map) continue;
      statuses.add(_JobStatusCount(
        status: (item['status'] ?? 'Unknown').toString(),
        count: _parseInt(item['count']),
      ));
    }
    return statuses.isEmpty ? null : statuses;
  }

  void _apply(Map<String, dynamic> body) {
        final scorecards = body['scorecards'] ?? {};

        _completedYtd = _parseInt(scorecards['completedYtd']);
        _activeOpenJobs = _parseInt(scorecards['activeOpenJobs']);
        _avgProfitMargin = _parseDouble(scorecards['avgProfitMargin']);
        _avgJobRevenue = _parseDouble(scorecards['avgJobRevenue']);
        _newCustomersYtd = _parseInt(scorecards['newCustomersYtd']);

        final hist = body['history'];
        _activeHistory = [
          for (final v in (hist is Map ? (hist['activeOpenJobs'] as List<dynamic>? ?? const []) : const <dynamic>[])) _parseDouble(v),
        ];
        _marginMonthly = List<double>.filled(12, 0);
        _newCustMonthly = List<double>.filled(12, 0);
        for (final e in (body['monthlyMetrics'] as List<dynamic>? ?? const [])) {
          final m = _parseInt(e['month_num']);
          if (m >= 1 && m <= 12) {
            _marginMonthly[m - 1] = _parseDouble(e['profit_margin']);
            _newCustMonthly[m - 1] = _parseDouble(e['new_customers']);
          }
        }
        
        _pipelineStages = _parsePipelineStages(body['pipelineStages']);
        _statusCounts = _parseStatusCounts(body['statusCounts']);
        final cov = body['splitCoverage'];
        _splitCoverage = cov is Map
            ? (
                completed: _parseInt(cov['completedJobs']),
                withCategories: _parseInt(cov['jobsWithCategories']),
                withLineItems: cov['jobsWithLineItems'] == null ? null : _parseInt(cov['jobsWithLineItems']),
              )
            : null;

        final List<dynamic> rawMonthly = body['monthlyVolume'] ?? [];
        final List<dynamic> rawWeekly = body['weeklySplit'] ?? [];

        Map<int, int> monthlyCounts = {};
        Map<int, int> monthlyInstalls = {};
        Map<int, int> monthlyServices = {};

        for (var item in rawMonthly) {
          int m = _parseInt(item['month_num']);
          monthlyCounts[m] = _parseInt(item['completed_count']);
          monthlyInstalls[m] = _parseInt(item['install_count']);
          monthlyServices[m] = _parseInt(item['service_count']);
        }

        Map<int, Map<String, double>> monthlyRevSplit = {};
        final List<dynamic>? rawMonthlySplit = body['monthlySplit'] as List<dynamic>?;
        if (rawMonthlySplit != null) {
          // Exact per-month revenue from the backend.
          for (var item in rawMonthlySplit) {
            final mNum = _parseInt(item['month_num']).clamp(1, 12);
            monthlyRevSplit[mNum] = {
              'res': _parseDouble(item['residential_rev']),
              'com': _parseDouble(item['commercial_rev']),
            };
          }
        } else {
          // Older backend: approximate months from week numbers.
          for (var item in rawWeekly) {
            int week = _parseInt(item['week_num']);
            int mNum = ((week - 1) / 4.33).floor() + 1;
            mNum = mNum.clamp(1, 12);

            monthlyRevSplit.putIfAbsent(mNum, () => {'res': 0.0, 'com': 0.0});
            monthlyRevSplit[mNum]!['res'] = (monthlyRevSplit[mNum]!['res'] ?? 0.0) + _parseDouble(item['residential_rev']);
            monthlyRevSplit[mNum]!['com'] = (monthlyRevSplit[mNum]!['com'] ?? 0.0) + _parseDouble(item['commercial_rev']);
          }
        }

        const monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        _monthlyData = List.generate(12, (i) {
          int mNum = i + 1;
          int total = monthlyCounts[mNum] ?? 0;
          int installs = monthlyInstalls[mNum] ?? 0;
          int service = monthlyServices[mNum] ?? 0;
          double res = monthlyRevSplit[mNum]?['res'] ?? 0.0;
          double com = monthlyRevSplit[mNum]?['com'] ?? 0.0;

          return _MonthlyJobData(
            month: monthNames[i],
            completedTotal: total,
            installCount: installs,
            serviceCount: service,
            resRevenue: res,
            comRevenue: com,
            hasData: total > 0 || res > 0 || com > 0,
          );
        });
  }

  static final _thousands = NumberFormat('#,##0');
  String _fmt(num v) => _thousands.format(v);
  String _money(double v) => '\$${_fmt(v)}';

  @override
  Widget build(BuildContext context) {
    if (dashLoading) return const _JobsSkeleton();
    if (dashFailure != null) return DashErrorPanel.failure(dashFailure!, what: 'jobs', onRetry: dashReload);

    final year = widget.selectedYear;
    final period = dashPeriodLabel(year);
    final g = DashGeo.of(context);
    final statuses = [...?_statusCounts]..sort((a, b) => b.count.compareTo(a.count));

    // Year figures count jobs by start date; Active open jobs is always as of today.
    double room(String title, String value, String caption) =>
        dashSparkRoom(context, title: title, value: value, caption: caption);
    final captions = (
      completed: 'By start date · $period',
      active: 'Open, from any year · today',
      margin: 'Profit ÷ revenue, completed jobs',
      avg: 'Per completed job · $period',
      fresh: 'First-ever job in $year',
    );
    // The trend lines show together, only when every card still has room for its words beside one.
    final sparkRoom = [
      room('Completed jobs', _fmt(_completedYtd), captions.completed),
      room('Active open jobs', _fmt(_activeOpenJobs), captions.active),
      room('Profit margin', '${_avgProfitMargin.toStringAsFixed(1)}%', captions.margin),
      room('Avg job revenue', _money(_avgJobRevenue), captions.avg),
      room('New customers', _fmt(_newCustomersYtd), captions.fresh),
    ].reduce(math.max);

    final tiles = <Widget>[
      AnimatedMetricCard(title: 'Completed jobs', value: _completedYtd.toDouble(), format: (v) => _fmt(v.toInt()), caption: captions.completed, definition: 'Jobs that started $period and are now at a completed status. The line shows them by finished month.', valueColor: DashUi.emeraldDeep, index: 0, trend: dashTrend([for (final m in _monthlyData) m.completedTotal.toDouble()], year), sparkMinWidth: sparkRoom),
      DashDrillCard(
        count: _activeOpenJobs,
        onOpen: () => _openStatuses(context, statuses, heading: 'All active jobs', color: DashUi.sky),
        card: AnimatedMetricCard(title: 'Active open jobs', value: _activeOpenJobs.toDouble(), format: (v) => _fmt(v.toInt()), caption: captions.active, definition: 'Every job, from any year, that is not at a completed, cancelled or written-off status, as of today. The line is one reading a day.', valueColor: DashUi.sky, index: 1, trend: _activeHistory.length >= 2 ? _activeHistory : null, sparkMinWidth: sparkRoom),
      ),
      AnimatedMetricCard(title: 'Profit margin', value: _avgProfitMargin, format: (v) => '${v.toStringAsFixed(1)}%', caption: captions.margin, definition: 'Total profit divided by total revenue on completed jobs that started $period. The line shows it by finished month.', valueColor: DashUi.indigo, index: 2, trend: dashTrend(_marginMonthly, year), sparkMinWidth: sparkRoom),
      AnimatedMetricCard(title: 'Avg job revenue', value: _avgJobRevenue, format: (v) => _money(v), caption: captions.avg, definition: 'Average revenue of the completed jobs that started $period. The line shows it by finished month.', valueColor: DashUi.amber, index: 3, trend: dashTrend([for (final m in _monthlyData) m.completedTotal > 0 ? m.totalRevenue / m.completedTotal : 0.0], year), sparkMinWidth: sparkRoom),
      AnimatedMetricCard(title: 'New customers', value: _newCustomersYtd.toDouble(), format: (v) => _fmt(v.toInt()), caption: captions.fresh, definition: 'Customers (matched by name) whose first-ever job started $period. The line shows them by finished month.', valueColor: DashUi.blue, index: 4, trend: dashTrend(_newCustMonthly, year), sparkMinWidth: sparkRoom),
    ];

    return _Grid(
      tiles: tiles,
      chart: _JobsChart(data: _monthlyData, year: year),
      insights: _InsightsStrip(g: g, monthly: _monthlyData, splitCoverage: _splitCoverage, year: year),
      statuses: (tall, maxRows, fill) => _StatusPanel(
        g: g,
        statuses: statuses,
        total: _activeOpenJobs,
        tall: tall,
        maxRows: maxRows,
        fill: fill,
        onOpen: (picked, heading, color) => _openStatuses(context, picked, heading: heading, color: color),
      ),
    );
  }
}

/// Opens the list of active jobs at [statuses] (all-time, the same "active" rule as the status panel).
void _openStatuses(BuildContext context, List<_JobStatusCount> statuses, {required String heading, required Color color}) {
  showDialog<void>(
    context: context,
    builder: (_) => EstimateListDialog(
      year: DashClock.now().year,
      periodLabel: 'All time',
      noun: 'job',
      heading: heading,
      totalLabel: 'in jobs',
      color: color,
      icon: Icons.work_outline_rounded,
      uri: Uri.parse('$kApiBaseUrl/api/dashboards/jobs/drill')
          .replace(queryParameters: {'status': [for (final s in statuses) s.status]}),
      initialSort: EstimateListSort.oldest,
    ),
  );
}

// =============================================================================
// GRID (shared by the page and its skeleton)
// =============================================================================

/// Lays the page out to fit the window:
///   two columns   scorecards; chart over quick insights | active jobs by status   (1280x600 and up)
///   one column    a window narrower than a desktop one: everything in one column that scrolls
class _Grid extends StatelessWidget {
  final List<Widget> tiles;
  final Widget chart;
  final Widget insights;

  /// `tall`: two-line rows for a narrow column. `maxRows`: statuses that fit (the rest share an "Other" row).
  final Widget Function(bool tall, int maxRows, bool fill) statuses;

  const _Grid({required this.tiles, required this.chart, required this.insights, required this.statuses});

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
        if (w >= _twoColumnsFrom && bodyH - dashGap - g.strip >= _minChart) {
          final rightInner = (w - dashGap) * 10 / 23 - 40;
          final tall = rightInner < _StatusPanel.oneLineWidth(g);
          final rowH = tall ? g.rowTall : g.rowWide;
          final maxRows = math.max(3, ((bodyH - g.panelTop) / rowH).floor());
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: g.tile, child: _tileRow(tiles)),
              const SizedBox(height: dashGap),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 13,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: chart),
                          const SizedBox(height: dashGap),
                          SizedBox(height: g.strip, child: insights),
                        ],
                      ),
                    ),
                    const SizedBox(width: dashGap),
                    Expanded(flex: 10, child: statuses(tall, maxRows, true)),
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
                SizedBox(height: g.tile, child: _tileRow(tiles.take(3).toList())),
                const SizedBox(height: dashGap),
                SizedBox(height: g.tile, child: _tileRow(tiles.skip(3).toList())),
                const SizedBox(height: dashGap),
                SizedBox(height: 320, child: chart),
                const SizedBox(height: dashGap),
                SizedBox(height: g.strip, child: insights),
                const SizedBox(height: dashGap),
                statuses(false, 99, false),
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
// MONTHLY CHART (completed jobs, average job value, residential vs commercial, install vs service)
// =============================================================================

class _JobsChart extends StatelessWidget {
  final List<_MonthlyJobData> data;
  final int year;
  const _JobsChart({required this.data, required this.year});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,##0');
    _MonthlyJobData? at(int i) => i < data.length ? data[i] : null;
    List<double> pick(double Function(_MonthlyJobData) f) => [for (var i = 0; i < 12; i++) at(i) == null ? 0.0 : f(at(i)!)];
    final active = data.where((d) => d.hasData).toList();

    final completed = pick((d) => d.completedTotal.toDouble());
    final totalCompleted = active.fold<double>(0, (s, d) => s + d.completedTotal);
    // The average month: completed jobs over the months that have any, as before.
    final avgPerMonth = active.isEmpty ? 0.0 : totalCompleted / active.length;

    final avgValue = pick((d) => d.completedTotal > 0 ? d.totalRevenue / d.completedTotal : 0.0);
    final totalRev = active.fold<double>(0, (s, d) => s + d.totalRevenue);
    final overallAvg = totalCompleted > 0 ? totalRev / totalCompleted : 0.0;

    final res = pick((d) => d.resRevenue);
    final com = pick((d) => d.comRevenue);
    final install = pick((d) => d.installCount.toDouble());
    final service = pick((d) => d.serviceCount.toDouble());
    String share(double part, double whole) => whole > 0 ? '${(part / whole * 100).round()}%' : '—';
    String months(List<double> v, int last, String Function(double) f) =>
        [for (var i = 0; i <= last; i++) '${dashMonthNames[i]} ${f(v[i])}'].join(', ');

    return DashMonthChart(
      year: year,
      views: [
        DashChartView(
          tab: 'Completed',
          title: 'Completed jobs',
          note: '${fmt.format(totalCompleted)} in $year',
          series: [DashSeries('Completed jobs', completed, DashUi.indigo)],
          average: avgPerMonth > 0 ? avgPerMonth : null,
          averageLabel: avgPerMonth > 0 ? 'Monthly average ${avgPerMonth.toStringAsFixed(1)}' : null,
          axis: (v) => fmt.format(v),
          barLabel: (v) => fmt.format(v),
          badge: DashChangeChip.monthOverMonth(completed, year, what: 'Completed jobs'),
          tip: (i) => [
            DashTipRow('Completed', fmt.format(completed[i]), color: DashUi.indigo),
            DashTipRow('Install', fmt.format(install[i])),
            DashTipRow('Service', fmt.format(service[i])),
          ],
          summary: (last) => 'Completed jobs by month: ${months(completed, last, (v) => fmt.format(v))}',
          emptyText: 'No job data for $year yet.',
          semanticsLabel: 'Completed jobs by month, $year',
        ),
        DashChartView(
          tab: 'Avg value',
          title: 'Average job value',
          note: '${_compactMoney(overallAvg)} average for $year',
          series: [DashSeries('Revenue per job', avgValue, DashUi.emeraldDeep)],
          average: overallAvg > 0 ? overallAvg : null,
          averageLabel: overallAvg > 0 ? 'Year average ${_compactMoney(overallAvg)}' : null,
          axis: _compactMoney,
          barLabel: _compactMoney,
          badge: DashChangeChip.monthOverMonth(avgValue, year, what: 'Average job value'),
          tip: (i) => [
            DashTipRow('Per job', '\$${fmt.format(avgValue[i].round())}', color: DashUi.emeraldDeep),
            DashTipRow('Revenue', _compactMoney(res[i] + com[i])),
            DashTipRow('Jobs', fmt.format(completed[i])),
          ],
          summary: (last) => 'Average job value by month: ${months(avgValue, last, _compactMoney)}',
          emptyText: 'No job data for $year yet.',
          semanticsLabel: 'Average revenue per completed job by month, $year',
        ),
        DashChartView(
          tab: 'Res vs Com',
          title: 'Residential vs commercial',
          note: '${_compactMoney(totalRev)} revenue',
          series: [
            DashSeries('Residential', res, DashUi.sky),
            DashSeries('Commercial', com, DashUi.amber),
          ],
          stacked: true,
          axis: _compactMoney,
          tip: (i) => [
            DashTipRow('Residential', _compactMoney(res[i]), color: DashUi.sky),
            DashTipRow('Commercial', _compactMoney(com[i]), color: DashUi.amber),
            DashTipRow('Commercial share', share(com[i], res[i] + com[i])),
          ],
          summary: (last) => 'Commercial revenue by month: ${months(com, last, _compactMoney)}',
          emptyText: 'No job revenue for $year yet.',
          semanticsLabel: 'Residential and commercial revenue of completed jobs by month, $year',
        ),
        DashChartView(
          tab: 'Install vs service',
          title: 'Install vs service',
          note: '${fmt.format(install.fold<double>(0, (a, b) => a + b) + service.fold<double>(0, (a, b) => a + b))} jobs',
          series: [
            DashSeries('Install', install, DashUi.indigo),
            DashSeries('Service', service, DashUi.sky),
          ],
          stacked: true,
          axis: (v) => fmt.format(v),
          tip: (i) => [
            DashTipRow('Install', '${fmt.format(install[i])} · ${share(install[i], install[i] + service[i])}', color: DashUi.indigo),
            DashTipRow('Service', '${fmt.format(service[i])} · ${share(service[i], install[i] + service[i])}', color: DashUi.sky),
          ],
          summary: (last) => 'Install jobs by month: ${months(install, last, (v) => fmt.format(v))}',
          emptyText: 'No install or service jobs for $year yet.',
          semanticsLabel: 'Install and service jobs completed by month, $year',
        ),
      ],
    );
  }
}

// =============================================================================
// QUICK INSIGHTS (the selected year)
// =============================================================================

class _InsightsStrip extends StatelessWidget {
  final DashGeo g;
  final List<_MonthlyJobData> monthly;

  /// How many of the year's completed jobs carry category data; null when the server didn't say.
  final ({int completed, int withCategories, int? withLineItems})? splitCoverage;
  final int year;
  const _InsightsStrip({required this.g, required this.monthly, required this.splitCoverage, required this.year});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,##0');
    final active = monthly.where((m) => m.hasData).toList();
    final header = DashPanelHeader(g: g, title: 'Quick insights', note: '$year');
    final contentH = g.strip - g.panelTop;
    if (active.isEmpty) {
      return DashPanel(
        header: header,
        child: SizedBox(
          height: contentH,
          child: const Align(
            alignment: Alignment.centerLeft,
            child: Text('Not enough job history yet for insights.', style: DashText.empty),
          ),
        ),
      );
    }

    final totalCompleted = active.fold<int>(0, (s, m) => s + m.completedTotal);
    final avgPerMonth = totalCompleted / active.length;
    final busiest = active.reduce((a, b) => a.completedTotal >= b.completedTotal ? a : b);
    final totalInstall = active.fold<int>(0, (s, m) => s + m.installCount);
    final totalService = active.fold<int>(0, (s, m) => s + m.serviceCount);
    final totalRes = active.fold<double>(0, (s, m) => s + m.resRevenue);
    final totalCom = active.fold<double>(0, (s, m) => s + m.comRevenue);

    // These splits come from commission line items, which only exist for some jobs. Showing them when most
    // jobs lack the data would be wrong (e.g. 100% residential just because nothing could be tagged commercial).
    // Install vs Service needs commission items; Residential vs Commercial reads the job's line items (and falls
    // back to commission items on an older server). Each is shown only when most completed jobs have its data.
    final cov = splitCoverage;
    bool covered(int? n) => cov == null || (cov.completed > 0 && (n ?? 0) / cov.completed >= 0.5);
    final installReliable = covered(cov?.withCategories);
    final comReliable = covered(cov?.withLineItems ?? cov?.withCategories);

    Widget split(String label, String left, Color lc, double lv, String right, Color rc, double rv,
        {required bool reliable, required String hidden}) {
      final total = lv + rv;
      if (!reliable || total <= 0) {
        return _item(
          label,
          Text(reliable ? 'No data yet' : 'Not enough data', style: DashText.bigMoney.copyWith(color: DashUi.subtle)),
          reliable ? '$label: no jobs yet' : '$label is hidden. $hidden',
          tooltip: reliable ? null : hidden,
        );
      }
      final lp = (lv / total * 100).round();
      return _item(
        label,
        Text.rich(
          TextSpan(
            children: [
              TextSpan(text: '$lp%', style: TextStyle(color: lc == DashUi.amber ? DashUi.amberText : lc)),
              TextSpan(text: ' / ', style: DashText.meta.copyWith(fontSize: 13)),
              TextSpan(text: '${100 - lp}%', style: TextStyle(color: rc == DashUi.amber ? DashUi.amberText : rc)),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: DashText.bigMoney,
        ),
        '$label: $lp% ${left.toLowerCase()}, ${100 - lp}% ${right.toLowerCase()}',
        tooltip: '$lp% $left, ${100 - lp}% $right',
      );
    }

    return DashPanel(
      header: header,
      child: SizedBox(
        height: contentH,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _item(
                'Busiest month',
                Text('${busiest.month} · ${fmt.format(busiest.completedTotal)}', maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: DashText.bigMoney.copyWith(color: DashUi.emeraldText)),
                'Busiest month: ${busiest.month}, ${fmt.format(busiest.completedTotal)} jobs',
                tooltip: '${fmt.format(busiest.completedTotal)} jobs completed in ${busiest.month}',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _item(
                'Jobs a month',
                Text(avgPerMonth.toStringAsFixed(1), style: DashText.bigMoney),
                'Average jobs a month: ${avgPerMonth.toStringAsFixed(1)}',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: split('Install / service', 'Install', DashUi.indigo, totalInstall.toDouble(), 'Service', DashUi.sky,
                  totalService.toDouble(),
                  reliable: installReliable,
                  hidden: cov == null
                      ? ''
                      : 'Only ${cov.withCategories} of ${cov.completed} completed jobs this year have install/service data.'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: split('Res / commercial', 'Residential', DashUi.sky, totalRes, 'Commercial', DashUi.amber, totalCom,
                  reliable: comReliable,
                  hidden: cov == null
                      ? ''
                      : 'Only ${cov.withLineItems ?? cov.withCategories} of ${cov.completed} completed jobs this year have line items.'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _item(String label, Widget value, String semantics, {String? tooltip}) {
    Widget item = Semantics(
      container: true,
      label: semantics,
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.label),
            const SizedBox(height: 3),
            value,
          ],
        ),
      ),
    );
    if (tooltip != null && tooltip.isNotEmpty) item = Tooltip(message: tooltip, child: item);
    return item;
  }
}

// =============================================================================
// ACTIVE JOBS BY STATUS (as of today, any year)
// =============================================================================

class _StatusPanel extends StatelessWidget {
  final DashGeo g;

  /// Biggest first.
  final List<_JobStatusCount> statuses;
  final int total;
  final bool tall;
  final int maxRows;
  final bool fill;
  final void Function(List<_JobStatusCount> statuses, String heading, Color color) onOpen;
  const _StatusPanel({
    required this.g,
    required this.statuses,
    required this.total,
    required this.tall,
    required this.maxRows,
    required this.fill,
    required this.onOpen,
  });

  static const labelWidth = 150.0;
  static const amountWidth = 52.0;
  static const detailWidth = 44.0;

  /// The inner width one-line rows need (text columns, paddings, the chevron and a bar of at least 70 px).
  static double oneLineWidth(DashGeo g) => (labelWidth + amountWidth + detailWidth) * g.k + 128;

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,##0');
    final sum = statuses.fold<int>(0, (s, c) => s + c.count);
    // As many statuses as fit get their own row; the rest share an "Other" row that opens all of them.
    final List<(String, int, Color, List<_JobStatusCount>)> rows;
    if (statuses.length <= maxRows) {
      rows = [
        for (var i = 0; i < statuses.length; i++)
          (statuses[i].status, statuses[i].count, _colorOf(statuses[i].status, i), [statuses[i]]),
      ];
    } else {
      final top = statuses.take(maxRows - 1).toList();
      final rest = statuses.skip(maxRows - 1).toList();
      rows = [
        for (var i = 0; i < top.length; i++) (top[i].status, top[i].count, _colorOf(top[i].status, i), [top[i]]),
        ('Other (${dashCount(rest.length, 'status')})', rest.fold<int>(0, (s, c) => s + c.count), DashUi.slate, rest),
      ];
    }
    final maxV = rows.fold<int>(0, (m, r) => math.max(m, r.$2));
    final base = tall ? g.rowTall : g.rowWide;

    return DashPanel(
      fill: fill,
      header: DashPanelHeader(
        g: g,
        title: 'Active jobs by status',
        note: 'today',
        tooltip: 'Every job from any year that is not completed, cancelled or written off, by its status.',
        trailing: sum > 0
            ? DashLink(
                text: 'All ${fmt.format(total > 0 ? total : sum)}',
                label: 'See all ${dashCount(total > 0 ? total : sum, 'active job')}',
                onTap: () => onOpen(statuses, 'All active jobs', DashUi.sky),
              )
            : null,
      ),
      child: sum <= 0
          ? SizedBox(height: 2 * base, child: const DashEmptyNote('Status breakdown not available.'))
          : Align(
              alignment: Alignment.topCenter,
              child: DashRows(
                count: rows.length,
                base: base,
                give: 22,
                row: (i) {
                  final (label, count, color, picked) = rows[i];
                  final grouped = picked.length > 1;
                  return DashBarRow(
                    g: g,
                    label: label,
                    fraction: maxV > 0 ? count / maxV : 0,
                    color: color,
                    amount: fmt.format(count),
                    detail: dashShare(count.toDouble(), sum.toDouble()),
                    tall: tall,
                    labelWidth: labelWidth,
                    amountWidth: amountWidth,
                    detailWidth: detailWidth,
                    onTap: count > 0 ? () => onOpen(picked, grouped ? 'Other active jobs' : '$label · active jobs', color) : null,
                    hint: 'Opens the list of jobs',
                    tooltip: grouped ? [for (final s in picked) '${s.status}: ${fmt.format(s.count)}'].join('\n') : null,
                    semanticsLabel: grouped
                        ? '$label: ${dashCount(count, 'job')}. ${[for (final s in picked) '${s.status} ${s.count}'].join(', ')}'
                        : '$label: ${dashCount(count, 'active job')}, ${dashShare(count.toDouble(), sum.toDouble())}',
                  );
                },
              ),
            ),
    );
  }

  static Color _colorOf(String status, int i) => knownStatusColor(status) ?? _categoricalPalette[i % _categoricalPalette.length];
}

// =============================================================================
// SKELETON (the same grid, with placeholders)
// =============================================================================

class _JobsSkeleton extends StatelessWidget {
  const _JobsSkeleton();

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    return Semantics(
      label: 'Loading jobs',
      child: ExcludeSemantics(
        child: SkeletonPulse(
          child: _Grid(
            tiles: List.generate(5, (_) => const DashSkeletonTile()),
            chart: const DashSkeletonPanel(fill: true),
            insights: DashSkeletonPanel(rows: 1, rowH: g.line(15) + 6),
            statuses: (tall, maxRows, fill) => DashSkeletonPanel(rows: math.min(7, maxRows), rowH: tall ? g.rowTall : g.rowWide),
          ),
        ),
      ),
    );
  }
}
