import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'config/access.dart';
import 'widgets/dashboard_data.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/dashboard_layout.dart';
import 'widgets/dash_hover_card.dart';
import 'widgets/dash_story.dart';
import 'widgets/dashboard_panels.dart';
import 'widgets/gold_pot.dart';

// The Financial dashboard. Everything follows the selected year except the pools card (all-time).
//   scorecards  revenue + deposits, not yet collected, gross profit, profit margin and (this year) the projection
//   left        the monthly chart (revenue and profit, margin, net income after expenses) over revenue by segment
//   right       the pools card (company and commercial pool, with a pot of gold) over operating expenses by category
// The page fits the window without scrolling and without shrinking text (see _Grid).

class ReportsScreen extends StatelessWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      title: 'Financial',
      icon: accessIcon('dash_financial'),
      builder: (context, selectedYear) {
        return FinancialDashboardContent(selectedYear: selectedYear);
      },
    );
  }
}

class FinancialDashboardContent extends StatefulWidget {
  final int selectedYear;
  const FinancialDashboardContent({super.key, required this.selectedYear});

  @override
  State<FinancialDashboardContent> createState() =>
      _FinancialDashboardContentState();
}

// =============================================================================
// GLOBAL HELPERS
// =============================================================================

double _parseMoney(dynamic v) {
  if (v is num) return v.toDouble();
  if (v == null) return 0.0;
  return double.tryParse(v.toString().replaceAll(RegExp(r'[^0-9.\-]'), '')) ??
      0.0;
}

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

String _moneyFull(double v) {
  final r = v.round();
  final s = r.abs().toString().replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
    (m) => '${m[1]},',
  );
  return '${r < 0 ? '-' : ''}\$$s';
}

String _pct(double v) => '${v.toStringAsFixed(1)}%';

// =============================================================================
// MODELS
// =============================================================================

class _FinancialSummary {
  final double revenueYtd;
  final double outstandingMoney;
  final double grossProfitYtd;
  final double yearlyProjected;
  final double companyPool;
  final double commercialPool;

  final double residentialRevenue;
  final double commercialRevenue;
  final double highVolumeRevenue;
  final double otherRevenue;

  final List<_MonthlyFinancials> chartData;
  final List<_ExpenseCategory> expenses;

  /// Daily history of the balance cards (oldest first), for their trend lines. Empty until the backend has
  /// a couple of days of snapshots.
  final List<double> outstandingHistory;
  final List<double> projectedHistory;
  final List<double> companyPoolHistory;
  final List<double> commercialPoolHistory;

  const _FinancialSummary({
    this.revenueYtd = 0.0,
    this.outstandingMoney = 0.0,
    this.grossProfitYtd = 0.0,
    this.yearlyProjected = 0.0,
    this.companyPool = 0.0,
    this.commercialPool = 0.0,
    this.residentialRevenue = 0.0,
    this.commercialRevenue = 0.0,
    this.highVolumeRevenue = 0.0,
    this.otherRevenue = 0.0,
    this.chartData = const [],
    this.expenses = const [],
    this.outstandingHistory = const [],
    this.projectedHistory = const [],
    this.companyPoolHistory = const [],
    this.commercialPoolHistory = const [],
  });

  factory _FinancialSummary.fromJson(Map<String, dynamic> json) {
    var rawChartData = json['chartData'] as List? ?? [];
    List<_MonthlyFinancials> parsedChart = rawChartData.map((item) {
      return _MonthlyFinancials.fromJson(item);
    }).toList();

    var rawExpenses =
        json['operatingExpenses'] as List? ?? json['expenses'] as List? ?? [];

    // Biggest first. Every category's bar is the same quiet slate: a colour per row carried no meaning, and red or
    // amber on an ordinary bill read as a warning.
    final parsedExpenses =
        rawExpenses
            .map((e) => _ExpenseCategory.fromJson(e, DashUi.slate))
            .toList()
          ..sort((a, b) => b.amount.compareTo(a.amount));

    List<double> history(String key) => [
      for (final v
          in ((json['history'] as Map<String, dynamic>?)?[key]
                  as List<dynamic>? ??
              const []))
        (v as num).toDouble(),
    ];

    return _FinancialSummary(
      revenueYtd: _parseMoney(json['revenueYtd']),
      outstandingMoney: _parseMoney(json['outstandingMoney']),
      grossProfitYtd: _parseMoney(json['grossProfitYtd']),
      yearlyProjected: _parseMoney(json['yearlyProjected']),
      companyPool: _parseMoney(json['companyPool']),
      commercialPool: _parseMoney(json['commercialPool']),
      residentialRevenue: _parseMoney(json['residentialRevenue']),
      commercialRevenue: _parseMoney(json['commercialRevenue']),
      highVolumeRevenue: _parseMoney(json['highVolumeRevenue']),
      otherRevenue: _parseMoney(json['otherRevenue']),
      chartData: parsedChart,
      expenses: parsedExpenses,
      outstandingHistory: history('outstanding'),
      projectedHistory: history('projected'),
      companyPoolHistory: history('companyPool'),
      commercialPoolHistory: history('commercialPool'),
    );
  }
}

class _MonthlyFinancials {
  final String month;
  final double revenue;
  final double profit;
  final double expense;
  final double netIncome;
  final bool hasData;

  const _MonthlyFinancials(
    this.month,
    this.revenue,
    this.profit,
    this.expense,
    this.netIncome,
    this.hasData,
  );

  double get marginPct => revenue > 0 ? (profit / revenue) * 100 : 0.0;

  factory _MonthlyFinancials.fromJson(Map<String, dynamic> json) {
    final rev = _parseMoney(json['revenue']);
    final prof = _parseMoney(json['profit']);
    final exp = _parseMoney(json['expense'] ?? json['operatingExpense']);
    final net = json['netIncome'] != null
        ? _parseMoney(json['netIncome'])
        : (prof - exp);

    return _MonthlyFinancials(
      json['month'] ?? '',
      rev,
      prof,
      exp,
      net,
      json['hasData'] ?? true,
    );
  }
}

class _ExpenseCategory {
  final String category;
  final double amount;
  final Color color;

  const _ExpenseCategory(this.category, this.amount, this.color);

  factory _ExpenseCategory.fromJson(Map<String, dynamic> json, Color c) {
    return _ExpenseCategory(
      json['category']?.toString() ??
          json['name']?.toString() ??
          'Unknown Expense',
      _parseMoney(json['amount'] ?? json['value']),
      c,
    );
  }
}

// =============================================================================
// NET INCOME (gross profit less operating expenses, by month)
// =============================================================================

class _NetPoint {
  final String month;
  final double revenue;
  final double profit;
  final double expense;
  final double net;
  final double cumulative;
  final bool hasData;
  const _NetPoint(
    this.month,
    this.revenue,
    this.profit,
    this.expense,
    this.net,
    this.cumulative,
    this.hasData,
  );
}

/// Builds 12 points. If the server gave no per-month expenses, total OpEx is spread evenly
/// across the months that have data (flagged in the UI as an estimate). A month with expenses
/// recorded but no completed job yet still counts: its net is the expenses, below zero.
List<_NetPoint> _buildNetSeries(
  List<_MonthlyFinancials> months,
  double totalOpEx,
) {
  final activeCount = months.where((m) => m.hasData).length;
  final hasMonthlyExpenses = months.any((m) => m.expense > 0);
  final spread = (!hasMonthlyExpenses && activeCount > 0)
      ? totalOpEx / activeCount
      : 0.0;

  final out = <_NetPoint>[];
  var running = 0.0;
  for (final m in months) {
    if (!m.hasData && m.expense <= 0) {
      out.add(_NetPoint(m.month, 0, 0, 0, 0, running, false));
      continue;
    }
    final exp = m.expense > 0 ? m.expense : spread;
    final net = m.profit - exp;
    running += net;
    out.add(_NetPoint(m.month, m.revenue, m.profit, exp, net, running, true));
  }
  return out;
}

// =============================================================================
// SCREEN STATE
// =============================================================================

class _FinancialDashboardContentState extends State<FinancialDashboardContent>
    with DashboardLoading {
  _FinancialSummary _data = const _FinancialSummary();

  @override
  void initState() {
    super.initState();
    dashReload();
  }

  @override
  void didUpdateWidget(covariant FinancialDashboardContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedYear != widget.selectedYear) dashReload();
  }

  @override
  Future<void> dashReload({bool fresh = false}) => dashLoad(
    '/api/financial_dashboard',
    query: {'year': '${widget.selectedYear}'},
    fresh: fresh,
    apply: (body) => _data = _FinancialSummary.fromJson(body),
  );

  @override
  Widget build(BuildContext context) {
    if (dashLoading) return const _FinancialSkeleton();
    if (dashFailure != null) {
      return DashErrorPanel.failure(
        dashFailure!,
        what: 'financials',
        onRetry: dashReload,
      );
    }
    return _FinancialPage(data: _data, year: widget.selectedYear);
  }
}

// =============================================================================
// PAGE
// =============================================================================

class _FinancialPage extends StatelessWidget {
  final _FinancialSummary data;
  final int year;
  const _FinancialPage({required this.data, required this.year});

  /// Twelve months, January first, whatever the server sent (missing months have no data).
  List<_MonthlyFinancials> get _months => [
    for (var i = 0; i < 12; i++)
      i < data.chartData.length
          ? data.chartData[i]
          : _MonthlyFinancials(dashMonthNames[i], 0, 0, 0, 0, false),
  ];

  /// A daily-history line needs at least two days of snapshots; with fewer the card shows no line.
  static List<double>? _historyTrend(List<double> history) =>
      history.length >= 2 ? history : null;

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    final months = _months;
    // "Jan 1 – today" while the year runs, "all of 2025" once it is over (the other dashboards' wording). The captions
    // leave out what the title already says, so five cards keep room for their trend lines at 1920 px.
    final period = dashPeriodLabel(year);
    final pastYear = year < DashClock.now().year;

    final activeMonths = months.where((m) => m.hasData);
    final totalRev = activeMonths.fold<double>(0, (s, m) => s + m.revenue);
    final totalProfit = activeMonths.fold<double>(0, (s, m) => s + m.profit);
    final margin = totalRev > 0 ? totalProfit / totalRev * 100 : 0.0;

    // The scorecards: title, figure, caption and the full definition. A past year has no projection card: the server
    // sends that year's actual revenue + deposits in its place, the same figure as the first card.
    final cards = <({
      String title,
      double value,
      String Function(double) format,
      String caption,
      String definition,
      Color color,
      List<double>? trend,
    })>[
      (
        // Completed-job revenue plus deposits received on jobs not finished yet, so it is higher than the chart,
        // which is completed jobs only. The line is the monthly completed revenue.
        title: 'Revenue + deposits',
        value: data.revenueYtd,
        format: _moneyFull,
        caption: '${period[0].toUpperCase()}${period.substring(1)}',
        definition:
            'Revenue of completed jobs that started in $year, plus deposits received on jobs that '
            "aren't finished yet ($period). The chart counts completed jobs only, so it is lower. "
            'The line shows completed revenue by finished month.',
        color: DashUi.sky,
        trend: dashTrend([for (final m in months) m.revenue], year),
      ),
      (
        // All money not yet in on this year's jobs, billed or not. Deliberately bigger than the Collections
        // dashboard's Outstanding balance (invoiced jobs only), so it doesn't share its name.
        title: 'Not yet collected',
        value: data.outstandingMoney,
        format: _moneyFull,
        caption: '$year jobs, finished or not',
        definition:
            'Contract value of every job that started in $year, finished or not (cancelled and written-off '
            'jobs left out), minus the payments received on those jobs so far. The Collections dashboard\'s '
            'Outstanding balance counts invoiced jobs only, so it is lower.'
            '${pastYear ? '' : ' The line is one reading a day.'}',
        color: data.outstandingMoney > 0 ? DashUi.amber : DashUi.ink,
        trend: _historyTrend(data.outstandingHistory),
      ),
      (
        title: 'Gross profit',
        value: data.grossProfitYtd,
        format: _moneyFull,
        caption: 'Completed · $period',
        definition:
            'Total profit recorded on completed jobs that started in $year ($period). The line shows '
            'it by finished month.',
        // Emerald, as on the chart, where profit sits beside sky revenue (blue next to sky was too alike to tell apart).
        color: DashUi.emeraldDeep,
        trend: dashTrend([for (final m in months) m.profit], year),
      ),
      (
        title: 'Profit margin',
        value: margin,
        format: _pct,
        caption: 'Of revenue · $period',
        definition:
            'Total profit divided by total revenue on completed jobs that started in $year ($period). '
            'The line shows it by finished month.',
        color: DashUi.blue,
        trend: dashTrend([for (final m in months) m.marginPct], year),
      ),
      if (!pastYear)
        (
          title: 'Yearly projection',
          value: data.yearlyProjected,
          format: _moneyFull,
          caption: 'At the current pace',
          definition:
              'Revenue + deposits so far, divided by the share of $year that has passed. A straight-line '
              "pace: it doesn't allow for busy or quiet seasons. The line is one reading a day.",
          color: DashUi.sky,
          trend: _historyTrend(data.projectedHistory),
        ),
    ];
    // A trend line only shows when every card's words still fit beside it (so the row stays even); on narrower
    // cards the lines go and the words stay whole.
    final sparkRoom = [
      for (final c in cards) dashSparkRoom(context, title: c.title, value: c.format(c.value), caption: c.caption),
    ].reduce(math.max);
    final tiles = <Widget>[
      for (final (i, c) in cards.indexed)
        AnimatedMetricCard(
          title: c.title,
          value: c.value,
          format: c.format,
          caption: c.caption,
          definition: c.definition,
          valueColor: c.color,
          index: i,
          trend: c.trend,
          sparkMinWidth: sparkRoom,
        ),
    ];

    final opexTotal = data.expenses.fold<double>(0, (s, e) => s + e.amount);
    return _Grid(
      tiles: tiles,
      pools: _PoolsPanel(
        g: g,
        company: data.companyPool,
        commercial: data.commercialPool,
        companyHistory: data.companyPoolHistory,
        commercialHistory: data.commercialPoolHistory,
      ),
      chart: _FinancialChart(months: months, year: year, opexTotal: opexTotal),
      segments: _SegmentsStrip(g: g, data: data, year: year),
      expenses: (tall, maxRows, fill) => _ExpensesPanel(
        g: g,
        expenses: data.expenses,
        total: opexTotal,
        year: year,
        tall: tall,
        maxRows: maxRows,
        fill: fill,
      ),
    );
  }
}

// =============================================================================
// GRID (shared by the page and its skeleton)
// =============================================================================

/// Lays the page out to fit the window:
///   two columns   scorecards; chart over revenue by segment | pools over operating expenses      (1280x600 and up)
///   one column    a window narrower than a desktop one: everything in one column that scrolls
class _Grid extends StatelessWidget {
  /// The five scorecards.
  final List<Widget> tiles;

  /// The pools card, over the expenses in the right column (after the chart in one column).
  final Widget pools;
  final Widget chart;
  final Widget segments;

  /// `tall`: two-line rows for a narrow column. `maxRows`: categories that fit (the smallest are grouped after that).
  /// `fill`: the panel is given a height to fill (not in the one-column layout).
  final Widget Function(bool tall, int maxRows, bool fill) expenses;

  const _Grid({
    required this.tiles,
    required this.pools,
    required this.chart,
    required this.segments,
    required this.expenses,
  });

  /// The chart panel never gets shorter than this.
  static const _minChart = 220.0;

  /// Narrowest content that still takes two columns.
  static const _twoColumnsFrom = 1000.0;

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final bodyH = c.maxHeight - g.tile - dashGap;
        final poolsH = _PoolsPanel.height(g) + dashGap;
        // A one-line category row needs its three text columns, the paddings and a bar of at least 70 px; in a
        // narrower column each row stacks in two lines.
        final rightInner = (w - dashGap) * 10 / 23 - 40;
        final tall = rightInner < _ExpensesPanel.textColumns * g.k + 106;
        final rowH = tall ? g.rowTall : g.rowWide;
        // Two columns when the chart keeps its height and the expenses keep their finding and three rows of the height
        // they really get (one-line rows at 1280x600 with 130% text, so that window doesn't scroll either).
        final fits =
            w >= _twoColumnsFrom &&
            bodyH - dashGap - g.strip >= _minChart &&
            bodyH - poolsH >= g.panelTop + g.callout + 3 * rowH;
        final Widget content;
        if (fits) {
          // When the window is short the smallest expense categories share one row (the panel's own rule).
          final maxRows = math.max(
            3,
            ((bodyH - poolsH - g.panelTop - g.callout) / rowH).floor(),
          );
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _scorecards(g),
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
                          SizedBox(height: g.strip, child: segments),
                        ],
                      ),
                    ),
                    const SizedBox(width: dashGap),
                    Expanded(
                      flex: 10,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(height: poolsH - dashGap, child: pools),
                          const SizedBox(height: dashGap),
                          Expanded(child: expenses(tall, maxRows, true)),
                        ],
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
                SizedBox(
                  height: g.tile,
                  child: _tileRow(tiles.take((tiles.length + 1) ~/ 2).toList()),
                ),
                const SizedBox(height: dashGap),
                SizedBox(
                  height: g.tile,
                  child: _tileRow(tiles.skip((tiles.length + 1) ~/ 2).toList()),
                ),
                const SizedBox(height: dashGap),
                SizedBox(height: 340, child: chart),
                const SizedBox(height: dashGap),
                SizedBox(height: g.strip, child: segments),
                const SizedBox(height: dashGap),
                SizedBox(height: _PoolsPanel.height(g), child: pools),
                const SizedBox(height: dashGap),
                expenses(false, 99, false),
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

  Widget _scorecards(DashGeo g) =>
      SizedBox(height: g.tile, child: _tileRow(tiles));
}

// =============================================================================
// MONTHLY CHART (completed jobs: revenue and profit, margin, net income)
// =============================================================================

class _FinancialChart extends StatelessWidget {
  final List<_MonthlyFinancials> months;
  final int year;
  final double opexTotal;
  const _FinancialChart({
    required this.months,
    required this.year,
    required this.opexTotal,
  });

  @override
  Widget build(BuildContext context) {
    final revenue = [for (final m in months) m.hasData ? m.revenue : 0.0];
    final profit = [for (final m in months) m.hasData ? m.profit : 0.0];
    final margin = [for (final m in months) m.hasData ? m.marginPct : 0.0];
    final active = months.where((m) => m.hasData);
    final totalRev = active.fold<double>(0, (s, m) => s + m.revenue);
    final totalProfit = active.fold<double>(0, (s, m) => s + m.profit);
    final avgMargin = totalRev > 0 ? totalProfit / totalRev * 100 : 0.0;

    final net = _buildNetSeries(months, opexTotal);
    final netYtd = net.last.cumulative;
    final expenseYtd = net.fold<double>(0, (s, p) => s + p.expense);
    final opexShare = totalProfit > 0 ? expenseYtd / totalProfit * 100 : null;
    // No expense recorded by month: the year's total is spread evenly over the months with data (an estimate).
    final estimated = !months.any((m) => m.expense > 0) && opexTotal > 0;

    // The comparison point for each view: the average of the finished months (no earlier year comes with these figures).
    final now = DashClock.now();
    final finished = [
      for (var i = 0; i < months.length && i < 12; i++)
        if (months[i].hasData && !(year == now.year && i == now.month - 1)) i,
    ];
    double avgOf(List<double> v) => finished.isEmpty
        ? 0
        : finished.fold<double>(0, (a, i) => a + v[i]) / finished.length;
    final avgRevenue = avgOf(revenue);
    final netValues = [for (final p in net) p.net];
    final current = year == now.year;
    // "yet" only while the year can still fill in.
    final empty = year < now.year ? 'Nothing recorded for $year.' : 'Nothing recorded for $year yet.';

    String list(List<double> values, int last, String Function(double) f) =>
        [for (var i = 0; i <= last; i++) '${dashMonthNames[i]} ${f(values[i])}']
            .join(', ');

    return DashMonthChart(
      year: year,
      views: [
        DashChartView(
          tab: 'Revenue & profit',
          title: 'Revenue & profit',
          note: 'completed jobs, by start month',
          story: dashMonthStory(
            values: revenue,
            year: year,
            figure: totalRev,
            figureFormat: dashWholeMoney,
            figureLabel: current ? 'revenue so far' : 'revenue in $year',
            figureColor: DashUi.sky,
            format: _compactMoney,
            unit: ' revenue',
            extra: [
              DashStoryStat(
                totalProfit,
                dashWholeMoney,
                'profit, ${_pct(avgMargin)} margin',
                DashUi.emeraldText,
              ),
            ],
          ),
          series: [
            DashSeries('Revenue', revenue, DashUi.sky),
            DashSeries('Profit', profit, DashUi.emeraldDeep),
          ],
          average: avgRevenue > 0 && finished.length >= 2 ? avgRevenue : null,
          averageLabel: avgRevenue > 0 && finished.length >= 2
              ? 'Average revenue ${_compactMoney(avgRevenue)}'
              : null,
          axis: _compactMoney,
          badge: DashChangeChip.monthOverMonth(
            revenue,
            year,
            what: 'Completed revenue',
          ),
          tip: (i) => [
            DashTipRow('Revenue', _moneyFull(revenue[i]), color: DashUi.sky),
            DashTipRow(
              'Profit',
              _moneyFull(profit[i]),
              color: DashUi.emeraldDeep,
            ),
            DashTipRow('Margin', revenue[i] > 0 ? _pct(margin[i]) : '—'),
          ],
          summary: (last) =>
              'Revenue by month: ${list(revenue, last, _compactMoney)}',
          emptyText: empty,
          semanticsLabel:
              'Revenue and profit of completed jobs by month, $year',
        ),
        DashChartView(
          tab: 'Margin',
          title: 'Profit margin',
          note: 'completed jobs, by start month',
          story: dashMonthStory(
            values: margin,
            year: year,
            figure: avgMargin,
            figureFormat: (v) => '${v.toStringAsFixed(1)}%',
            figureLabel: 'of revenue kept as profit',
            figureColor: DashUi.blue,
            // Against the dashed line (the year's margin), in points.
            average: avgMargin > 0 ? avgMargin : null,
            points: true,
            format: (v) => '${v.round()}%',
            unit: ' margin',
          ),
          series: [DashSeries('Margin', margin, DashUi.blue)],
          average: avgMargin > 0 && finished.length >= 2 ? avgMargin : null,
          averageLabel: avgMargin > 0 && finished.length >= 2
              ? 'Year average ${_pct(avgMargin)}'
              : null,
          axis: (v) => '${v.round()}%',
          barLabel: (v) => '${v.round()}%',
          // No month-over-month chip: it would be a relative change of a percentage ("down 14%" for 45% to 39%).
          tip: (i) => [
            DashTipRow(
              'Margin',
              revenue[i] > 0 ? _pct(margin[i]) : '—',
              color: DashUi.blue,
            ),
            DashTipRow('Profit', _moneyFull(profit[i])),
            DashTipRow('Revenue', _moneyFull(revenue[i])),
          ],
          summary: (last) =>
              'Margin by month: ${list(margin, last, (v) => '${v.round()}%')}',
          emptyText: empty,
          semanticsLabel: 'Profit margin of completed jobs by month, $year',
        ),
        DashChartView(
          tab: 'Net income',
          title: 'Net income',
          note: estimated
              ? 'expenses spread evenly (no monthly data)'
              : opexTotal <= 0
              ? 'no expenses recorded, so net = gross profit'
              : 'gross profit less operating expenses, by month',
          story: dashMonthStory(
            values: netValues,
            year: year,
            figure: netYtd,
            figureFormat: dashWholeMoney,
            figureLabel: opexTotal <= 0
                ? 'net (no expenses recorded)'
                : 'left after expenses',
            figureColor: netYtd >= 0 ? DashUi.emeraldText : DashUi.redText,
            format: _compactMoney,
            unit: ' net',
            extra: [
              if (opexShare != null)
                DashStoryStat(
                  opexShare,
                  (v) => '${v.round()}%',
                  'of profit went on expenses',
                  DashUi.ink,
                ),
            ],
          ),
          series: [
            // A month that lost money is red, so it doesn't read as profit.
            DashSeries('Monthly net', [
              for (final p in net) p.net,
            ], DashUi.emeraldDeep, below: DashUi.red, belowLabel: 'Loss month'),
            // On the same axis as the bars, so both read off one zero line.
            DashSeries(
              'Running total',
              [for (final p in net) p.cumulative],
              DashUi.indigo,
              kind: DashSeriesKind.line,
            ),
          ],
          axis: _compactMoney,
          tip: (i) => [
            DashTipRow(
              'Gross profit',
              _moneyFull(net[i].profit),
              color: DashUi.emeraldDeep,
            ),
            DashTipRow(
              'Expenses',
              net[i].expense > 0 ? '-${_moneyFull(net[i].expense)}' : '\$0',
              color: DashUi.amber,
            ),
            DashTipRow('Net', _moneyFull(net[i].net)),
            DashTipRow(
              'Running total',
              _moneyFull(net[i].cumulative),
              color: DashUi.indigo,
            ),
          ],
          summary: (last) =>
              'Net income by month: ${list([for (final p in net) p.net], last, _compactMoney)}',
          emptyText: empty,
          semanticsLabel:
              'Net income by month after operating expenses, $year, with the running total',
        ),
      ],
    );
  }
}

// =============================================================================
// REVENUE BY SEGMENT (adds up to Revenue + deposits)
// =============================================================================

class _SegmentsStrip extends StatelessWidget {
  final DashGeo g;
  final _FinancialSummary data;
  final int year;
  const _SegmentsStrip({
    required this.g,
    required this.data,
    required this.year,
  });

  @override
  Widget build(BuildContext context) {
    final parts = [
      ('Residential', data.residentialRevenue, DashUi.sky),
      ('Commercial', data.commercialRevenue, DashUi.indigo),
      ('High Volume', data.highVolumeRevenue, DashUi.emeraldDeep),
      ('Other', data.otherRevenue, DashUi.slate),
    ];
    final total = parts.fold<double>(0, (s, p) => s + math.max(0, p.$2));
    return DashSplitPanel(
      g: g,
      title: 'Revenue by segment',
      tooltip:
          'Completed jobs plus deposits on open jobs, split by the kind of work on their line items. '
          'The four add up to the Revenue + deposits card.',
      emptyText: 'No revenue recorded in $year.',
      items: [
        for (final p in parts)
          DashSplitItem(
            label: p.$1,
            amount: math.max(0, p.$2),
            value: _moneyFull(p.$2),
            color: p.$3,
            semanticsLabel:
                '${p.$1}: ${_moneyFull(p.$2)}, ${dashShare(math.max(0, p.$2), total)} of revenue + deposits',
          ),
      ],
    );
  }
}

// =============================================================================
// POOLS (the company pool and the locked commercial retainage, all-time)
// =============================================================================

class _PoolsPanel extends StatelessWidget {
  final DashGeo g;
  final double company;
  final double commercial;
  final List<double> companyHistory;
  final List<double> commercialHistory;
  const _PoolsPanel({
    required this.g,
    required this.company,
    required this.commercial,
    required this.companyHistory,
    required this.commercialHistory,
  });

  /// The pot and the two figures: a label, the amount and its caption.
  static double bodyHeight(DashGeo g) =>
      math.max(84.0, g.line(12) + g.line(28, 1.15) + g.line(12) + 8);
  static double height(DashGeo g) => g.panelTop + bodyHeight(g);

  @override
  Widget build(BuildContext context) {
    final body = bodyHeight(g);
    return DashPanel(
      header: DashPanelHeader(
        g: g,
        title: 'Commission pools',
        note: 'all time',
      ),
      child: SizedBox(
        height: body,
        child: Row(
          children: [
            GoldPot(size: math.min(body, 88)),
            const SizedBox(width: 18),
            Expanded(
              child: _PoolFigure(
                label: 'Company pool',
                caption: 'Set aside from jobs',
                value: company,
                history: companyHistory,
                color: DashUi.indigo,
                definition:
                    "The company's share set aside from each commissioned job, less the callback charges taken "
                    "from the pool, since commissions began. A job counts once its pay week's payroll run is "
                    'finalized. Callback charges can take it below zero.',
              ),
            ),
            Container(width: 1, height: body * 0.7, color: DashUi.line),
            const SizedBox(width: 18),
            Expanded(
              child: _PoolFigure(
                label: 'Commercial pool',
                caption: 'Locked until release',
                value: commercial,
                history: commercialHistory,
                color: DashUi.ink,
                definition:
                    "Commercial retainage still locked for the techs, from jobs whose pay week's payroll run is "
                    'finalized. It is paid out at the quarterly release (Apr 1, Jul 1 and Oct 1).',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PoolFigure extends StatelessWidget {
  final String label;
  final String caption;
  final double value;

  /// One reading a day, oldest first. Fewer than two (or none above zero) draws no line: the kit's dashed placeholder
  /// would only fill the space.
  final List<double> history;
  final Color color;
  final String definition;
  const _PoolFigure({
    required this.label,
    required this.caption,
    required this.value,
    required this.history,
    required this.color,
    required this.definition,
  });

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    return DashHoverCard(
      title: label,
      value: _moneyFull(value),
      body: '$definition Not limited to the selected year.',
      color: color,
      child: Semantics(
        container: true,
        label: '$label: ${_moneyFull(value)}, $caption, all time',
        child: ExcludeSemantics(
          child: LayoutBuilder(
            builder: (context, c) {
              final text = Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DashText.label,
                  ),
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: value),
                    duration: reduce
                        ? Duration.zero
                        : const Duration(milliseconds: 1600),
                    curve: Curves.easeOutCubic,
                    builder: (context, v, _) => FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _moneyFull(v),
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          height: 1.15,
                          color: color,
                        ),
                      ),
                    ),
                  ),
                  Text(
                    caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DashText.meta,
                  ),
                ],
              );
              // The trend line takes the blank space beside the words, and goes when there isn't room for both.
              final line = history.length >= 2 && history.any((v) => v > 0);
              final room = c.maxWidth >= 215 * DashGeo.of(context).k;
              if (!line || !room) return text;
              return Row(
                children: [
                  // Capped so a long caption is cut short with an ellipsis instead of pushing the line out of the card.
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: math.max(0.0, c.maxWidth - 14 - 60),
                    ),
                    child: text,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: DashSparkline(
                      values: history,
                      color: color,
                      width: null,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// OPERATING EXPENSES BY CATEGORY
// =============================================================================

class _ExpensesPanel extends StatelessWidget {
  final DashGeo g;
  final List<_ExpenseCategory> expenses;
  final double total;
  final int year;
  final bool tall;
  final int maxRows;
  final bool fill;
  const _ExpensesPanel({
    required this.g,
    required this.expenses,
    required this.total,
    required this.year,
    required this.tall,
    required this.maxRows,
    required this.fill,
  });

  /// Widths of a row's label, amount and share columns at 100% text.
  static const labelWidth = 140.0;
  static const amountWidth = 84.0;
  static const shareWidth = 46.0;
  static const textColumns = labelWidth + amountWidth + shareWidth;

  @override
  Widget build(BuildContext context) {
    // Every category gets its own row when they fit. When they don't (a short window with many categories), the
    // biggest keep theirs and the rest share one row, named with how many it holds, so the total still adds up.
    final List<(_ExpenseCategory, List<_ExpenseCategory>)> rows;
    if (expenses.length <= maxRows) {
      rows = [for (final e in expenses) (e, const <_ExpenseCategory>[])];
    } else {
      final rest = expenses.skip(maxRows - 1).toList();
      rows = [
        for (final e in expenses.take(maxRows - 1))
          (e, const <_ExpenseCategory>[]),
        (
          _ExpenseCategory(
            'Other categories (${rest.length})',
            rest.fold(0.0, (s, e) => s + e.amount),
            DashUi.slate,
          ),
          rest,
        ),
      ];
    }
    final maxV = rows.fold<double>(0, (m, r) => math.max(m, r.$1.amount));
    final base = tall ? g.rowTall : g.rowWide;
    final top = expenses.isEmpty
        ? null
        : expenses.reduce((a, b) => b.amount > a.amount ? b : a);
    final topThree =
        (expenses.toList()..sort((a, b) => b.amount.compareTo(a.amount)))
            .take(3)
            .fold<double>(0, (t, e) => t + e.amount);

    return DashPanel(
      fill: fill,
      header: DashPanelHeader(
        g: g,
        title: 'Operating expenses',
        // "in 2026", not "to date": the server counts every expense dated in the year (it is not cut off at today).
        // Every category has a row (or a share of the grouped one), so the count needs no note of its own.
        note: total > 0 ? '${_moneyFull(total)} in $year' : null,
        tooltip: 'Expenses recorded for $year, by category, biggest first.',
      ),
      child: total <= 0
          ? DashEmptyNote(
              year < DashClock.now().year
                  ? 'No operating expenses recorded for $year.'
                  : 'No operating expenses recorded yet.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
              children: [
                DashCallout(
                  g: g,
                  text:
                      '${top!.category} is ${dashShare(top.amount, total)} of spending'
                      '${expenses.length > 3 ? ' · the top 3 are ${dashShare(topThree, total)}' : ''}',
                  color: DashUi.slate,
                ),
                _fill(
                  Align(
                    alignment: Alignment.topCenter,
                    child: DashRows(
                      count: rows.length,
                      base: base,
                      give: 22,
                      row: (i) {
                        final (e, grouped) = rows[i];
                        final share = dashShare(e.amount, total);
                        return DashBarRow(
                          g: g,
                          label: e.category,
                          fraction: maxV > 0 ? e.amount / maxV : 0,
                          color: e.color,
                          amount: _moneyFull(e.amount),
                          detail: share,
                          tall: tall,
                          labelWidth: labelWidth,
                          amountWidth: amountWidth,
                          detailWidth: shareWidth,
                          tooltip: grouped.isEmpty
                              ? (e.category.length > 18 ? e.category : null)
                              : [
                                  for (final x in grouped)
                                    '${x.category}: ${_moneyFull(x.amount)}',
                                ].join('\n'),
                          semanticsLabel: grouped.isEmpty
                              ? '${e.category}: ${_moneyFull(e.amount)}, $share of operating expenses'
                              : '${e.category}: ${_moneyFull(e.amount)}, $share of operating expenses. '
                                    '${[for (final x in grouped) '${x.category} ${_moneyFull(x.amount)}'].join(', ')}',
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _fill(Widget child) => fill ? Expanded(child: child) : child;
}

// =============================================================================
// SKELETON (the same grid, with placeholders)
// =============================================================================

class _FinancialSkeleton extends StatelessWidget {
  const _FinancialSkeleton();

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    return Semantics(
      label: 'Loading financials',
      child: ExcludeSemantics(
        child: SkeletonPulse(
          child: _Grid(
            tiles: List.generate(5, (_) => const DashSkeletonTile()),
            pools: DashSkeletonPanel(
              rows: 1,
              rowH: _PoolsPanel.bodyHeight(g) - 6,
            ),
            chart: const DashSkeletonPanel(fill: true),
            segments: DashSkeletonPanel(rows: 1, rowH: g.line(15) + 6),
            expenses: (tall, maxRows, fill) => DashSkeletonPanel(
              rows: math.min(8, maxRows),
              rowH: tall ? g.rowTall : g.rowWide,
            ),
          ),
        ),
      ),
    );
  }
}
