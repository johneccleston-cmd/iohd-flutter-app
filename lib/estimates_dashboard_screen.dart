import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'config/api_config.dart';
import 'widgets/dashboard_data.dart';
import 'widgets/dashboard_kit.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'widgets/dashboard_layout.dart';
import 'widgets/dashboard_panels.dart';
import 'widgets/estimate_list_dialog.dart';

// The Estimates dashboard. Lost value, win rate, estimates sent and the chart follow the selected year (by estimate
// date); the open pipeline, its ages and the stale estimates are as of today, whatever year they are dated.
//   scorecards  open value, lost value, win rate, estimates sent
//   left        the monthly chart (sent and won by value or count, average estimate) over the open pipeline by age
//   right       lost reasons over the stale estimates; ages, reasons and estimates each open their list
// The page fits the window without scrolling and without shrinking text (see _Grid).

class EstimatesDashboardScreen extends StatelessWidget {
  const EstimatesDashboardScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      title: 'Estimates',
      builder: (context, selectedYear) {
        return EstimatesDashboardContent(selectedYear: selectedYear);
      },
    );
  }
}

class EstimatesDashboardContent extends StatefulWidget {
  final int selectedYear;
  const EstimatesDashboardContent({Key? key, required this.selectedYear}) : super(key: key);

  @override
  State<EstimatesDashboardContent> createState() => _EstimatesDashboardContentState();
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

class _MonthlyValueData {
  final String month;
  final double sentValue;
  final double wonValue;
  final int sentCount;
  final int wonCount;
  final bool hasData;
  final double lostValue;

  const _MonthlyValueData(this.month, this.sentValue, this.wonValue, this.sentCount, this.wonCount, this.hasData, [this.lostValue = 0.0]);

  double get avgSentValue => sentCount > 0 ? sentValue / sentCount : 0.0;
  double get winRate => sentCount > 0 ? (wonCount / sentCount) * 100 : 0.0;
}

class _LostReason {
  final String reason;
  final double lostValue;
  final int count;
  final Color color;

  const _LostReason(this.reason, this.lostValue, this.count, this.color);
}

class _AgingBucket {
  final String label;
  final int count;
  final double value;

  const _AgingBucket(this.label, this.count, this.value);
}

class _StaleEstimate {
  final String jobId;
  final String customerName;
  final double value;
  final int daysOld;

  const _StaleEstimate(this.jobId, this.customerName, this.value, this.daysOld);
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

class _EstimatesDashboardContentState extends State<EstimatesDashboardContent> with DashboardLoading {
  /// Every estimate still open today, whatever year it is dated (the same whichever year is shown).
  double _openValue = 0.0;

  /// The part of the open pipeline dated before this year, and that cut-off ("2026-01-01").
  int _openPriorCount = 0;
  double _openPriorValue = 0.0;
  String _openPriorBefore = '';
  double _lostValue = 0.0;
  double _winRate = 0.0;
  int _sentYtd = 0;

  List<_MonthlyValueData> _valueData = [];

  /// Daily snapshots of the open value (oldest first) for its trend line; empty until there are a couple of days.
  List<double> _openHistory = [];
  List<_LostReason> _lostReasons = [];
  List<_AgingBucket> _agingBuckets = [];
  List<_StaleEstimate> _staleEstimates = [];

  final List<Color> _reasonColors = const [
    DashUi.red,
    DashUi.amber,
    DashUi.sky,
    DashUi.slate,
    DashUi.indigo,
  ];

  @override
  void initState() {
    super.initState();
    dashReload();
  }

  @override
  void didUpdateWidget(covariant EstimatesDashboardContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedYear != widget.selectedYear) dashReload();
  }

  @override
  Future<void> dashReload({bool fresh = false}) => dashLoad(
        '/api/dashboards/estimates',
        query: {'year': '${widget.selectedYear}'},
        fresh: fresh,
        apply: _apply,
      );

  int _parseInt(dynamic v) => v == null ? 0 : (v is num ? v.toInt() : int.tryParse(v.toString()) ?? 0);
  double _parseDouble(dynamic v) => v == null ? 0.0 : (v is num ? v.toDouble() : double.tryParse(v.toString()) ?? 0.0);

  void _apply(Map<String, dynamic> body) {
        final scorecards = body['scorecards'] ?? {};

        _openValue = _parseDouble(scorecards['openValue']);
        final prior = scorecards['openPriorYears'];
        _openPriorCount = prior is Map ? _parseInt(prior['count']) : 0;
        _openPriorValue = prior is Map ? _parseDouble(prior['value']) : 0.0;
        _openPriorBefore = prior is Map ? (prior['before']?.toString() ?? '') : '';
        _lostValue = _parseDouble(scorecards['lostValue']);
        _winRate = _parseDouble(scorecards['winRate']);
        _sentYtd = _parseInt(scorecards['sentYtd']);
        final hist = body['history'];
        _openHistory = [
          for (final v in (hist is Map ? (hist['openValue'] as List<dynamic>? ?? const []) : const <dynamic>[])) _parseDouble(v),
        ];

        // Parse Stale Pipeline Ticker
        final List<dynamic> rawStale = body['stalePipeline'] ?? [];
        _staleEstimates = rawStale.map((e) => _StaleEstimate(
          e['job_id']?.toString() ?? '',
          e['customer_name']?.toString() ?? 'Unknown',
          _parseDouble(e['value']),
          _parseInt(e['days_old']),
        )).toList();

        // Parse Aging Buckets
        final List<dynamic> rawAging = body['agingBuckets'] ?? [];
        _agingBuckets = rawAging.map((e) => _AgingBucket(
          e['bucket']?.toString() ?? '',
          _parseInt(e['count']),
          _parseDouble(e['value']),
        )).toList();

        // Parse Monthly Value & Volume Split
        final List<dynamic> rawMonthly = body['monthlyValue'] ?? [];
        Map<int, Map<String, dynamic>> monthlyMap = {};
        for (var item in rawMonthly) {
          int m = _parseInt(item['month_num']);
          monthlyMap[m] = {
            'sent_value': _parseDouble(item['sent_value']),
            'won_value': _parseDouble(item['won_value']),
            'sent_count': _parseInt(item['sent_count']),
            'won_count': _parseInt(item['won_count']),
            'lost_value': _parseDouble(item['lost_value']),
          };
        }

        const monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        _valueData = List.generate(12, (i) {
          int mNum = i + 1;
          double sv = monthlyMap[mNum]?['sent_value'] ?? 0.0;
          double wv = monthlyMap[mNum]?['won_value'] ?? 0.0;
          int sc = monthlyMap[mNum]?['sent_count'] ?? 0;
          int wc = monthlyMap[mNum]?['won_count'] ?? 0;
          final lv = monthlyMap[mNum]?['lost_value'] ?? 0.0;
          return _MonthlyValueData(monthNames[i], sv, wv, sc, wc, sv > 0 || wv > 0 || sc > 0, lv);
        });

        // Parse Lost Reasons
        final List<dynamic> rawReasons = body['lostReasons'] ?? [];
        _lostReasons = [];
        for (int i = 0; i < rawReasons.length; i++) {
          final r = rawReasons[i];
          _lostReasons.add(_LostReason(
            r['reason']?.toString() ?? 'Unknown',
            _parseDouble(r['lost_value']),
            _parseInt(r['count']),
            _reasonColors[i % _reasonColors.length],
          ));
        }

  }

  /// The year prior-year estimates are dated before: "2026" for a cut-off of "2026-01-01".
  String _priorYearLabel() =>
      RegExp(r'^\d{4}').stringMatch(_openPriorBefore) ?? '${DashClock.now().year}';

  static final _thousands = NumberFormat('#,##0');
  String _fmt(num v) => _thousands.format(v);
  String _money(double v) => '\$${_fmt(v)}';

  @override
  Widget build(BuildContext context) {
    if (dashLoading) return const _EstimatesSkeleton();
    if (dashFailure != null) return DashErrorPanel.failure(dashFailure!, what: 'estimates', onRetry: dashReload);

    final year = widget.selectedYear;
    final period = dashPeriodLabel(year);
    final g = DashGeo.of(context);

    // Lost value, win rate and estimates sent count estimates dated in the year shown. Open value is the whole
    // pipeline as of today, every year included, so it reads the same whichever year is picked.
    final openCaption = _openPriorCount > 0
        ? 'All years · $_openPriorCount before ${_priorYearLabel()}'
        : 'All open estimates · today';
    final lostCaption = 'Estimates marked lost · $period';
    final winCaption = 'Won ÷ (won + lost) · all estimates';
    final sentCaption = 'Quoted, dated $period';
    // The trend lines show together, only when every card still has room for its words beside one.
    final sparkRoom = [
      dashSparkRoom(context, title: 'Open value', value: _money(_openValue), caption: openCaption),
      dashSparkRoom(context, title: 'Lost value', value: _money(_lostValue), caption: lostCaption),
      dashSparkRoom(context, title: 'Win rate', value: '${_winRate.toStringAsFixed(1)}%', caption: winCaption),
      dashSparkRoom(context, title: 'Estimates sent', value: _fmt(_sentYtd), caption: sentCaption),
    ].reduce(math.max);

    final tiles = <Widget>[
      AnimatedMetricCard(
        title: 'Open value',
        value: _openValue,
        format: (v) => _money(v),
        // Short enough to fit at 1280px; "as of today" and the dollar split are in the definition.
        caption: openCaption,
        definition: 'Every estimate still at Estimate Provided or Estimate Follow Up today, whatever year '
            'it is dated, so this is the same whichever year is shown. '
            '${_openPriorCount > 0 ? '${_money(_openPriorValue)} of it ($_openPriorCount estimates) is dated '
                'before ${_priorYearLabel()}; the oldest are first in the stale list. ' : ''}'
            'Nothing is closed or changed here. The line is one reading a day.',
        valueColor: DashUi.indigo,
        index: 0,
        trend: _openHistory.length >= 2 ? _openHistory : null,
        sparkMinWidth: sparkRoom,
      ),
      AnimatedMetricCard(
        title: 'Lost value',
        value: _lostValue,
        format: (v) => _money(v),
        caption: lostCaption,
        definition: 'Value of estimates dated $period that are marked lost. The line shows it by '
            'finished month.',
        valueColor: DashUi.red,
        index: 1,
        trend: dashTrend([for (final m in _valueData) m.lostValue], year),
        sparkMinWidth: sparkRoom,
      ),
      AnimatedMetricCard(
        title: 'Win rate',
        value: _winRate,
        format: (v) => '${v.toStringAsFixed(1)}%',
        caption: winCaption,
        definition: "Of the estimates dated $period that have been decided, the share that were won. Open "
            "estimates aren't counted. This covers every estimate, so it can differ from the Sales "
            "dashboard's win rate (sales team only).",
        valueColor: DashUi.emeraldDeep,
        index: 2,
        trend: dashTrend([for (final m in _valueData) m.winRate], year),
        sparkMinWidth: sparkRoom,
      ),
      AnimatedMetricCard(
        title: 'Estimates sent',
        value: _sentYtd.toDouble(),
        format: (v) => _fmt(v.toInt()),
        caption: sentCaption,
        definition: 'Estimates dated $period that got past Estimate Requested, so a quote was given. The '
            'line shows them by finished month.',
        valueColor: DashUi.sky,
        index: 3,
        trend: dashTrend([for (final m in _valueData) m.sentCount.toDouble()], year),
        sparkMinWidth: sparkRoom,
      ),
    ];

    return _Grid(
      tiles: tiles,
      chart: _EstimatesChart(data: _valueData, year: year),
      aging: _AgingStrip(g: g, buckets: _agingBuckets, year: year),
      lost: (tall) => _LostReasonsPanel(g: g, reasons: _lostReasons, year: year, tall: tall),
      lostRows: _lostReasons.length,
      stale: (maxRows, fill) => _StalePanel(g: g, rows: _staleEstimates, maxRows: maxRows, fill: fill),
      staleRows: _staleEstimates.length,
    );
  }
}

// =============================================================================
// GRID (shared by the page and its skeleton)
// =============================================================================

/// Lays the page out to fit the window, in the first arrangement that does:
///   stacked        scorecards; chart over the open pipeline by age | lost reasons over the stale estimates
///   side by side   the same, with lost reasons and the stale estimates side by side (a short window or larger text)
///   one column     a window narrower than a desktop one: everything in one column that scrolls
class _Grid extends StatelessWidget {
  final List<Widget> tiles;
  final Widget chart;
  final Widget aging;

  /// `tall`: two-line rows for a narrow column.
  final Widget Function(bool tall) lost;
  final int lostRows;

  /// `maxRows`: stale estimates that fit (the rest are a click away). `fill`: the panel is given a height to fill.
  final Widget Function(int maxRows, bool fill) stale;
  final int staleRows;

  const _Grid({
    required this.tiles,
    required this.chart,
    required this.aging,
    required this.lost,
    required this.lostRows,
    required this.stale,
    required this.staleRows,
  });

  static const _twoColumnsFrom = 1000.0;
  static const _minChart = 220.0;

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final bodyH = c.maxHeight - g.tile - dashGap;
        // Stacked, the right column is 10 parts of 23; side by side it widens to 8 of 15 (as on Collections), so each
        // of its two panels has room for a customer's name.
        final rightInner = (w - dashGap) * 10 / 23 - 40;
        final tall = rightInner < _LostReasonsPanel.oneLineWidth(g);
        final lostH = g.rows(lostRows, tall ? g.rowTall : g.rowWide);
        // Stacked, the stale list gets what the lost reasons leave; side by side, the whole height in half the width.
        final stackedFit = ((bodyH - lostH - dashGap - g.panelTop) / g.listRow).floor();
        final sideFit = ((bodyH - g.panelTop) / g.listRow).floor();
        final chartFits = w >= _twoColumnsFrom && bodyH - dashGap - g.strip >= _minChart;
        final stacked = chartFits && stackedFit >= 3;
        final side = chartFits && !stacked && bodyH >= g.rows(lostRows, g.rowTall) && sideFit >= 2;
        final Widget content;
        if (stacked || side) {
          final right = stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: lostH, child: lost(tall)),
                    const SizedBox(height: dashGap),
                    Expanded(child: stale(stackedFit, true)),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: lost(true)),
                    const SizedBox(width: dashGap),
                    Expanded(child: stale(sideFit, true)),
                  ],
                );
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
                      flex: stacked ? 13 : 7,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: chart),
                          const SizedBox(height: dashGap),
                          SizedBox(height: g.strip, child: aging),
                        ],
                      ),
                    ),
                    const SizedBox(width: dashGap),
                    Expanded(flex: stacked ? 10 : 8, child: right),
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
                SizedBox(height: g.tile, child: _tileRow(tiles.take(2).toList())),
                const SizedBox(height: dashGap),
                SizedBox(height: g.tile, child: _tileRow(tiles.skip(2).toList())),
                const SizedBox(height: dashGap),
                SizedBox(height: 320, child: chart),
                const SizedBox(height: dashGap),
                SizedBox(height: g.strip, child: aging),
                const SizedBox(height: dashGap),
                SizedBox(height: g.rows(lostRows, g.rowTall), child: lost(true)),
                const SizedBox(height: dashGap),
                stale(10, false),
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
// MONTHLY CHART (sent and won, by value or count; average estimate value)
// =============================================================================

class _EstimatesChart extends StatelessWidget {
  final List<_MonthlyValueData> data;
  final int year;
  const _EstimatesChart({required this.data, required this.year});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,##0');
    _MonthlyValueData? at(int i) => i < data.length ? data[i] : null;
    List<double> pick(double Function(_MonthlyValueData) f) => [for (var i = 0; i < 12; i++) at(i) == null ? 0.0 : f(at(i)!)];
    final active = data.where((d) => d.hasData);
    final sentValue = pick((d) => d.sentValue);
    final wonValue = pick((d) => d.wonValue);
    final sentCount = pick((d) => d.sentCount.toDouble());
    final wonCount = pick((d) => d.wonCount.toDouble());
    final avgValue = pick((d) => d.avgSentValue);
    final totalSent = active.fold<double>(0, (s, d) => s + d.sentValue);
    final totalCount = active.fold<int>(0, (s, d) => s + d.sentCount);
    // The year's average sent estimate, as before: all sent value over all sent estimates.
    final overallAvg = totalCount > 0 ? totalSent / totalCount : 0.0;
    String months(List<double> v, int last, String Function(double) f) =>
        [for (var i = 0; i <= last; i++) '${dashMonthNames[i]} ${f(v[i])}'].join(', ');

    return DashMonthChart(
      year: year,
      views: [
        DashChartView(
          tab: 'Value',
          title: 'Sent and won',
          note: '${_compactMoney(totalSent)} sent in $year',
          series: [DashSeries('Sent', sentValue, DashUi.slate), DashSeries('Won', wonValue, DashUi.emeraldDeep)],
          axis: _compactMoney,
          badge: DashChangeChip.monthOverMonth(sentValue, year, what: 'Value sent'),
          tip: (i) => [
            DashTipRow('Sent', '\$${fmt.format(sentValue[i])}', color: DashUi.slate),
            DashTipRow('Won', '\$${fmt.format(wonValue[i])}', color: DashUi.emeraldDeep),
            DashTipRow('Estimates', '${fmt.format(wonCount[i])} won of ${fmt.format(sentCount[i])}'),
          ],
          summary: (last) => 'Value sent by month: ${months(sentValue, last, _compactMoney)}',
          emptyText: 'No estimates for $year yet.',
          semanticsLabel: 'Value of estimates sent and won by month, $year',
        ),
        DashChartView(
          tab: 'Count',
          title: 'Sent and won',
          note: '${fmt.format(totalCount)} sent in $year',
          series: [DashSeries('Sent', sentCount, DashUi.slate), DashSeries('Won', wonCount, DashUi.emeraldDeep)],
          axis: (v) => fmt.format(v),
          badge: DashChangeChip.monthOverMonth(sentCount, year, what: 'Estimates sent'),
          tip: (i) => [
            DashTipRow('Sent', fmt.format(sentCount[i]), color: DashUi.slate),
            DashTipRow('Won', fmt.format(wonCount[i]), color: DashUi.emeraldDeep),
            DashTipRow('Won of sent', sentCount[i] > 0 ? '${(wonCount[i] / sentCount[i] * 100).round()}%' : '—'),
          ],
          summary: (last) => 'Estimates sent by month: ${months(sentCount, last, (v) => fmt.format(v))}',
          emptyText: 'No estimates for $year yet.',
          semanticsLabel: 'Number of estimates sent and won by month, $year',
        ),
        DashChartView(
          tab: 'Avg value',
          title: 'Average estimate',
          note: '\$${fmt.format(overallAvg)} average sent in $year',
          series: [DashSeries('Average sent', avgValue, DashUi.amber)],
          average: overallAvg > 0 ? overallAvg : null,
          averageLabel: overallAvg > 0 ? 'Year average ${_compactMoney(overallAvg)}' : null,
          axis: _compactMoney,
          barLabel: _compactMoney,
          badge: DashChangeChip.monthOverMonth(avgValue, year, what: 'Average estimate value'),
          tip: (i) => [
            DashTipRow('Average', '\$${fmt.format(avgValue[i])}', color: DashUi.amber),
            DashTipRow('Sent', fmt.format(sentCount[i])),
          ],
          summary: (last) => 'Average estimate by month: ${months(avgValue, last, _compactMoney)}',
          emptyText: 'No estimates for $year yet.',
          semanticsLabel: 'Average value of the estimates sent by month, $year',
        ),
      ],
    );
  }
}

// =============================================================================
// OPEN PIPELINE BY AGE (as of today)
// =============================================================================

class _AgingStrip extends StatelessWidget {
  final DashGeo g;
  final List<_AgingBucket> buckets;
  final int year;
  const _AgingStrip({required this.g, required this.buckets, required this.year});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,##0');
    final total = buckets.fold<double>(0, (s, b) => s + b.value);
    const tones = [DashUi.sky, DashUi.blue, DashUi.indigo, DashUi.red];
    return DashSplitPanel(
      g: g,
      title: 'Open pipeline by age',
      note: 'today',
      tooltip: 'Every open estimate, by how long ago it was dated. Click an age to see its estimates.',
      emptyText: 'No open estimates.',
      items: [
        for (var i = 0; i < buckets.length; i++)
          DashSplitItem(
            label: buckets[i].label,
            amount: buckets[i].value,
            value: '\$${fmt.format(buckets[i].value)}',
            // "0-7 days · 17", as the old panel showed it; the words are on hover and for screen readers.
            share: '· ${fmt.format(buckets[i].count)}',
            tooltip: '${dashCount(buckets[i].count, 'open estimate')}, \$${fmt.format(buckets[i].value)}',
            color: buckets[i].label.contains('31') ? DashUi.red : tones[i % 3],
            semanticsLabel: '${buckets[i].label}: \$${fmt.format(buckets[i].value)} on '
                '${dashCount(buckets[i].count, 'open estimate')}, ${dashShare(buckets[i].value, total)} of the pipeline',
            hint: 'Opens the list of estimates',
            onTap: buckets[i].count > 0 ? () => _open(context, buckets[i]) : null,
          ),
      ],
    );
  }

  /// Opens the open estimates in one age bucket.
  void _open(BuildContext context, _AgingBucket b) {
    showDialog<void>(
      context: context,
      builder: (_) => EstimateListDialog(
        year: year,
        heading: 'Open estimates · ${b.label}',
        totalLabel: 'open',
        color: b.label.contains('31') ? DashUi.red : DashUi.blue,
        icon: Icons.hourglass_bottom_rounded,
        uri: Uri.parse(
          '$kApiBaseUrl/api/dashboards/estimates/drill'
          '?year=$year&kind=aging&bucket=${Uri.encodeQueryComponent(b.label)}',
        ),
        initialSort: EstimateListSort.oldest,
      ),
    );
  }
}

// =============================================================================
// TOP LOST REASONS (the selected year)
// =============================================================================

class _LostReasonsPanel extends StatelessWidget {
  final DashGeo g;
  final List<_LostReason> reasons;
  final int year;
  final bool tall;
  const _LostReasonsPanel({required this.g, required this.reasons, required this.year, required this.tall});

  static const labelWidth = 120.0;
  static const amountWidth = 84.0;
  static const detailWidth = 62.0;
  static double oneLineWidth(DashGeo g) => (labelWidth + amountWidth + detailWidth) * g.k + 128;

  @override
  Widget build(BuildContext context) {
    final maxV = reasons.fold<double>(0, (m, r) => math.max(m, r.lostValue));
    final total = reasons.fold<double>(0, (s, r) => s + r.lostValue);
    final base = tall ? g.rowTall : g.rowWide;
    return DashPanel(
      fill: true,
      header: DashPanelHeader(
        g: g,
        title: 'Lost reasons',
        note: '$year',
        tooltip: 'Why estimates dated in $year were lost, by value. Click a reason to see its estimates.',
      ),
      child: reasons.every((r) => r.count == 0 && r.lostValue <= 0)
          ? DashEmptyNote('No estimates dated $year were lost.')
          : DashRows(
              count: reasons.length,
              base: base,
              give: 12,
              row: (i) {
                final r = reasons[i];
                return DashBarRow(
                  g: g,
                  label: r.reason,
                  fraction: maxV > 0 ? r.lostValue / maxV : 0,
                  color: r.color,
                  amount: _usd(r.lostValue),
                  detail: '${r.count} lost',
                  tall: tall,
                  labelWidth: labelWidth,
                  amountWidth: amountWidth,
                  detailWidth: detailWidth,
                  onTap: r.count == 0 ? null : () => _open(context, r),
                  hint: 'Opens the list of estimates',
                  semanticsLabel: '${r.reason}: ${_usd(r.lostValue)} lost on ${dashCount(r.count, 'estimate')}, '
                      '${dashShare(r.lostValue, total)} of the lost value',
                );
              },
            ),
    );
  }

  /// Opens the lost estimates with this reason.
  void _open(BuildContext context, _LostReason r) {
    showDialog<void>(
      context: context,
      builder: (_) => EstimateListDialog(
        year: year,
        heading: 'Lost estimates · ${r.reason}',
        totalLabel: 'lost',
        color: r.color,
        icon: Icons.highlight_off_rounded,
        uri: Uri.parse(
          '$kApiBaseUrl/api/dashboards/estimates/drill'
          '?year=$year&kind=lost&reason=${Uri.encodeQueryComponent(r.reason)}',
        ),
        initialSort: EstimateListSort.value,
      ),
    );
  }
}

String _usd(double v) => '\$${NumberFormat('#,##0').format(v)}';

String _age(int days) {
  if (days < 60) return '$days days';
  if (days < 730) return '${(days / 30.4).round()} months';
  return '${(days / 365).floor()} years';
}

// =============================================================================
// STALE ESTIMATES (open 14+ days and worth $1,000+, oldest first; as of today)
// =============================================================================

class _StalePanel extends StatelessWidget {
  final DashGeo g;
  final List<_StaleEstimate> rows;
  final int maxRows;
  final bool fill;
  const _StalePanel({required this.g, required this.rows, required this.maxRows, required this.fill});

  @override
  Widget build(BuildContext context) {
    final shown = rows.take(maxRows).toList();
    final more = rows.length > shown.length;
    return DashPanel(
      fill: fill,
      header: DashPanelHeader(
        g: g,
        title: 'Stale estimates',
        note: 'oldest first',
        tooltip: 'Open estimates 14 days old or more and worth \$1,000 or more, as of today, oldest first.',
        trailing: rows.isEmpty
            ? null
            : (more
                ? DashLink(
                    text: 'All ${rows.length}',
                    label: 'See all ${dashCount(rows.length, 'stale estimate')}',
                    onTap: () => _openAll(context),
                  )
                : Text(dashCount(rows.length, 'estimate'), style: DashText.meta)),
      ),
      child: rows.isEmpty
          ? SizedBox(height: 2 * g.listRow, child: const DashEmptyNote('No stale estimates today.'))
          : Align(
              alignment: Alignment.topCenter,
              child: DashRows(
                count: shown.length,
                base: g.listRow,
                give: 14,
                row: (i) => _row(context, shown[i], last: i == shown.length - 1),
              ),
            ),
    );
  }

  Widget _row(BuildContext context, _StaleEstimate e, {required bool last}) {
    final old = e.daysOld > 90;
    final meta = '${e.jobId.isEmpty ? '' : '#${e.jobId} · '}${_age(e.daysOld)} old';
    return DashPressable(
      onTap: () => _openAll(context, customer: e.customerName),
      label: '${e.customerName}: ${_usd(e.value)}, open for ${_age(e.daysOld)}',
      hint: 'Opens their stale estimates',
      radius: BorderRadius.circular(8),
      builder: (hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: hover ? DashUi.faint : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: last || hover ? null : const Border(bottom: BorderSide(color: DashUi.faint)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Tooltip(
                    message: e.customerName,
                    waitDuration: const Duration(milliseconds: 600),
                    child: Text(e.customerName, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.name),
                  ),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DashText.meta.copyWith(color: old ? DashUi.redText : DashUi.subtle),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(_usd(e.value), style: DashText.money.copyWith(fontSize: 14, color: DashUi.amberText)),
            SizedBox(
              width: 22,
              child: Icon(Icons.chevron_right_rounded, size: 18, color: hover ? DashUi.ink : DashUi.subtle),
            ),
          ],
        ),
      ),
    );
  }

  /// Every stale estimate (or one customer's), oldest first, in the list the other drill-downs use. The dashboard
  /// already has them all, so nothing is fetched.
  void _openAll(BuildContext context, {String? customer}) {
    final now = DashClock.now();
    final today = DateTime(now.year, now.month, now.day);
    showDialog<void>(
      context: context,
      builder: (_) => EstimateListDialog(
        year: now.year,
        periodLabel: 'As of today',
        heading: customer == null ? 'Stale estimates' : '$customer · stale estimates',
        totalLabel: 'open',
        color: DashUi.amber,
        icon: Icons.hourglass_bottom_rounded,
        items: [
          for (final e in rows)
            EstimateListItem(
              jobId: e.jobId,
              customerName: e.customerName,
              status: '',
              location: '',
              description: '',
              // Only the age is known here; the date it was dated is that many days ago.
              startDate: today.subtract(Duration(days: e.daysOld)),
              value: e.value,
              outcome: 'open',
              daysOld: e.daysOld,
            ),
        ],
        customer: customer,
        initialSort: EstimateListSort.oldest,
      ),
    );
  }
}

// =============================================================================
// SKELETON (the same grid, with placeholders)
// =============================================================================

class _EstimatesSkeleton extends StatelessWidget {
  const _EstimatesSkeleton();

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    return Semantics(
      label: 'Loading estimates',
      child: ExcludeSemantics(
        child: SkeletonPulse(
          child: _Grid(
            tiles: List.generate(4, (_) => const DashSkeletonTile()),
            chart: const DashSkeletonPanel(fill: true),
            aging: DashSkeletonPanel(rows: 1, rowH: g.line(15) + 6),
            lost: (tall) => DashSkeletonPanel(rows: 5, rowH: tall ? g.rowTall : g.rowWide),
            lostRows: 5,
            stale: (maxRows, fill) => DashSkeletonPanel(rows: math.min(3, maxRows), rowH: g.listRow),
            staleRows: 3,
          ),
        ),
      ),
    );
  }
}
