import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'widgets/dashboard_data.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/dashboard_layout.dart';
import 'widgets/dashboard_panels.dart';

// The Financial dashboard. Everything follows the selected year except the two pool cards (all-time).
//   scorecards  revenue + deposits, outstanding, gross profit, the projection and the two pools, on one row
//   left        the monthly chart (revenue and profit, margin, net income after expenses) over revenue by segment
//   right       operating expenses by category
// The page fits the window without scrolling and without shrinking text (see _Grid).

class ReportsScreen extends StatelessWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      title: 'Financial',
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
  State<FinancialDashboardContent> createState() => _FinancialDashboardContentState();
}

// =============================================================================
// GLOBAL HELPERS
// =============================================================================

double _parseMoney(dynamic v) {
  if (v is num) return v.toDouble();
  if (v == null) return 0.0;
  return double.tryParse(v.toString().replaceAll(RegExp(r'[^0-9.\-]'), '')) ?? 0.0;
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
  final s = r.abs().toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
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
  });

  factory _FinancialSummary.fromJson(Map<String, dynamic> json) {
    var rawChartData = json['chartData'] as List? ?? [];
    List<_MonthlyFinancials> parsedChart = rawChartData.map((item) {
      return _MonthlyFinancials.fromJson(item);
    }).toList();

    var rawExpenses = json['operatingExpenses'] as List? ?? json['expenses'] as List? ?? [];
    final List<Color> palette = [DashUi.blue, DashUi.amber, DashUi.red, DashUi.indigo, DashUi.sky, DashUi.emeraldDeep, DashUi.slate];

    // Sort expenses by amount descending
    final sorted = rawExpenses.map((e) => _ExpenseCategory.fromJson(e, DashUi.slate)).toList()
      ..sort((a, b) => b.amount.compareTo(a.amount));

    final parsedExpenses = [
      for (var i = 0; i < sorted.length; i++)
        _ExpenseCategory(sorted[i].category, sorted[i].amount, palette[i % palette.length]),
    ];

    List<double> history(String key) => [
      for (final v in ((json['history'] as Map<String, dynamic>?)?[key] as List<dynamic>? ?? const []))
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

  const _MonthlyFinancials(this.month, this.revenue, this.profit, this.expense, this.netIncome, this.hasData);

  double get marginPct => revenue > 0 ? (profit / revenue) * 100 : 0.0;

  factory _MonthlyFinancials.fromJson(Map<String, dynamic> json) {
    final rev = _parseMoney(json['revenue']);
    final prof = _parseMoney(json['profit']);
    final exp = _parseMoney(json['expense'] ?? json['operatingExpense']);
    final net = json['netIncome'] != null ? _parseMoney(json['netIncome']) : (prof - exp);

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
      json['category']?.toString() ?? json['name']?.toString() ?? 'Unknown Expense',
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
  const _NetPoint(this.month, this.revenue, this.profit, this.expense, this.net, this.cumulative, this.hasData);
}

/// Builds 12 points. If the server gave no per-month expenses, total OpEx is spread evenly
/// across the months that have data (flagged in the UI as an estimate).
List<_NetPoint> _buildNetSeries(List<_MonthlyFinancials> months, double totalOpEx) {
  final activeCount = months.where((m) => m.hasData).length;
  final hasMonthlyExpenses = months.any((m) => m.hasData && m.expense > 0);
  final spread = (!hasMonthlyExpenses && activeCount > 0) ? totalOpEx / activeCount : 0.0;

  final out = <_NetPoint>[];
  var running = 0.0;
  for (final m in months) {
    if (!m.hasData) {
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

class _FinancialDashboardContentState extends State<FinancialDashboardContent> with DashboardLoading {
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
      return DashErrorPanel.failure(dashFailure!, what: 'financials', onRetry: dashReload);
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
          i < data.chartData.length ? data.chartData[i] : _MonthlyFinancials(dashMonthNames[i], 0, 0, 0, 0, false),
      ];

  /// A daily-history line needs at least two days of snapshots; with fewer the card shows no line.
  static List<double>? _historyTrend(List<double> history) => history.length >= 2 ? history : null;

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    final months = _months;
    final period = dashPeriodLabel(year);
    // For a finished year the server sends the actual total in place of a projection, so the card says so.
    final pastYear = year < DashClock.now().year;
    // "YTD" while the year runs, the year itself once it is over (captions are kept short so six cards fit a row).
    final ytd = pastYear ? '$year' : 'YTD';

    // A trend line only shows when every main card's words still fit beside it (so the row stays even); on narrower
    // cards the lines go and the words stay whole.
    final sparkRoom = [
      dashSparkRoom(context, title: 'Revenue + deposits', value: _moneyFull(data.revenueYtd), caption: 'Jobs + deposits · $ytd'),
      dashSparkRoom(context, title: 'Outstanding (all jobs)', value: _moneyFull(data.outstandingMoney), caption: 'Unpaid · $year jobs'),
      dashSparkRoom(context, title: 'Gross profit', value: _moneyFull(data.grossProfitYtd), caption: 'Completed jobs · $ytd'),
      dashSparkRoom(
        context,
        title: pastYear ? 'Full year $year' : 'Yearly projection',
        value: _moneyFull(data.yearlyProjected),
        caption: pastYear ? 'Actual revenue + deposits' : 'At the current pace',
      ),
    ].reduce(math.max);
    final tiles = <Widget>[
      AnimatedMetricCard(
        // Completed-job revenue plus deposits received on jobs not finished yet, so it is higher than the chart,
        // which is completed jobs only. The line is the monthly completed revenue.
        title: 'Revenue + deposits',
        value: data.revenueYtd,
        format: _moneyFull,
        caption: 'Jobs + deposits · $ytd',
        definition: 'Revenue of completed jobs that started in $year, plus deposits received on jobs that '
            "aren't finished yet ($period). The chart counts completed jobs only, so it is lower. "
            'The line shows completed revenue by finished month.',
        valueColor: DashUi.sky,
        index: 0,
        trend: dashTrend([for (final m in months) m.revenue], year),
        sparkMinWidth: sparkRoom,
      ),
      AnimatedMetricCard(
        title: 'Outstanding (all jobs)',
        value: data.outstandingMoney,
        format: _moneyFull,
        caption: 'Unpaid · $year jobs',
        definition: 'Contract value of every job that started in $year (cancelled and written-off jobs left '
            'out), minus the payments received on those jobs, including jobs that are not finished. The '
            "Collections dashboard's Outstanding balance counts invoiced jobs only, so it is lower. "
            'The line is one reading a day.',
        valueColor: DashUi.amber,
        index: 1,
        trend: _historyTrend(data.outstandingHistory),
        sparkMinWidth: sparkRoom,
      ),
      AnimatedMetricCard(
        title: 'Gross profit',
        value: data.grossProfitYtd,
        format: _moneyFull,
        caption: 'Completed jobs · $ytd',
        definition: 'Total profit recorded on completed jobs that started in $year ($period). The line shows '
            'it by finished month.',
        valueColor: DashUi.emeraldDeep,
        index: 2,
        trend: dashTrend([for (final m in months) m.profit], year),
        sparkMinWidth: sparkRoom,
      ),
      AnimatedMetricCard(
        title: pastYear ? 'Full year $year' : 'Yearly projection',
        value: data.yearlyProjected,
        format: _moneyFull,
        caption: pastYear ? 'Actual revenue + deposits' : 'At the current pace',
        definition: pastYear
            ? 'The year is over, so this is the actual revenue + deposits for $year, not a projection.'
            : 'Revenue + deposits so far, divided by the share of $year that has passed. A straight-line '
                "pace: it doesn't allow for busy or quiet seasons. The line is one reading a day.",
        valueColor: DashUi.blue,
        index: 3,
        trend: _historyTrend(data.projectedHistory),
        sparkMinWidth: sparkRoom,
      ),
      AnimatedMetricCard(
        title: 'Company pool',
        value: data.companyPool,
        format: _moneyFull,
        caption: 'Finalized · all-time',
        definition: 'Money sent to the company pool from jobs whose pay week has a finalized payroll run, '
            'since commissions began. Not limited to $year.',
        valueColor: DashUi.indigo,
        index: 4,
      ),
      AnimatedMetricCard(
        title: 'Commercial pool',
        value: data.commercialPool,
        format: _moneyFull,
        caption: 'Locked · all-time',
        definition: 'Commercial retainage still locked, from jobs whose pay week has a finalized payroll '
            'run. Not limited to $year.',
        valueColor: DashUi.ink,
        index: 5,
      ),
    ];

    final opexTotal = data.expenses.fold<double>(0, (s, e) => s + e.amount);
    // The pool cards are as wide as their words; the four main cards share the rest of the row.
    final poolWidth = dashTileWidth(math.max(
      dashTileTextWidth(context, title: 'Company pool', value: _moneyFull(data.companyPool), caption: 'Finalized · all-time'),
      dashTileTextWidth(context, title: 'Commercial pool', value: _moneyFull(data.commercialPool), caption: 'Locked · all-time'),
    ));
    return _Grid(
      tiles: tiles,
      poolWidth: poolWidth,
      expenseRows: data.expenses.length,
      chart: _FinancialChart(months: months, year: year, opexTotal: opexTotal),
      segments: _SegmentsStrip(g: g, data: data, year: year),
      expenses: (tall, maxRows, fill) => _ExpensesPanel(
        g: g,
        expenses: data.expenses,
        total: opexTotal,
        year: year,
        ytd: ytd,
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
///   two columns   scorecards; chart over revenue by segment | operating expenses      (1280x600 and up)
///   one column    a window narrower than a desktop one: everything in one column that scrolls
class _Grid extends StatelessWidget {
  /// Four main cards, then the two pool cards (which are [poolWidth] wide).
  final List<Widget> tiles;
  final double poolWidth;
  final Widget chart;
  final Widget segments;

  /// `tall`: two-line rows for a narrow column. `maxRows`: categories that fit (the smallest are grouped after that).
  /// `fill`: the panel is given a height to fill (not in the one-column layout).
  final Widget Function(bool tall, int maxRows, bool fill) expenses;
  final int expenseRows;

  const _Grid({
    required this.tiles,
    required this.poolWidth,
    required this.chart,
    required this.segments,
    required this.expenses,
    required this.expenseRows,
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
        final fits = w >= _twoColumnsFrom && bodyH - dashGap - g.strip >= _minChart;
        final Widget content;
        if (fits) {
          // A one-line category row needs its three text columns, the paddings and a bar of at least 70 px; in a
          // narrower column each row stacks in two lines.
          final rightInner = (w - dashGap) * 10 / 23 - 40;
          final tall = rightInner < _ExpensesPanel.textColumns * g.k + 106;
          final rowH = tall ? g.rowTall : g.rowWide;
          final maxRows = math.max(3, ((bodyH - g.panelTop) / rowH).floor());
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
                    Expanded(flex: 10, child: expenses(tall, maxRows, true)),
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
                SizedBox(height: 340, child: chart),
                const SizedBox(height: dashGap),
                SizedBox(height: g.strip, child: segments),
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

  Widget _scorecards(DashGeo g) => SizedBox(
    height: g.tile,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < tiles.length; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          if (i < 4) Expanded(child: tiles[i]) else SizedBox(width: poolWidth, child: tiles[i]),
        ],
      ],
    ),
  );
}

// =============================================================================
// MONTHLY CHART (completed jobs: revenue and profit, margin, net income)
// =============================================================================

class _FinancialChart extends StatelessWidget {
  final List<_MonthlyFinancials> months;
  final int year;
  final double opexTotal;
  const _FinancialChart({required this.months, required this.year, required this.opexTotal});

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
    final estimated = !months.any((m) => m.hasData && m.expense > 0) && opexTotal > 0;

    String list(List<double> values, int last, String Function(double) f) =>
        [for (var i = 0; i <= last; i++) '${dashMonthNames[i]} ${f(values[i])}'].join(', ');

    return DashMonthChart(
      year: year,
      views: [
        DashChartView(
          tab: 'Revenue & profit',
          title: 'Completed jobs',
          note: '${_compactMoney(totalRev)} revenue',
          series: [
            DashSeries('Revenue', revenue, DashUi.sky),
            DashSeries('Profit', profit, DashUi.emeraldDeep),
          ],
          axis: _compactMoney,
          badge: DashChangeChip.monthOverMonth(revenue, year, what: 'Completed revenue'),
          tip: (i) => [
            DashTipRow('Revenue', _moneyFull(revenue[i]), color: DashUi.sky),
            DashTipRow('Profit', _moneyFull(profit[i]), color: DashUi.emeraldDeep),
            DashTipRow('Margin', revenue[i] > 0 ? _pct(margin[i]) : '—'),
          ],
          summary: (last) => 'Revenue by month: ${list(revenue, last, _compactMoney)}',
          emptyText: 'Nothing recorded for $year yet.',
          semanticsLabel: 'Revenue and profit of completed jobs by month, $year',
        ),
        DashChartView(
          tab: 'Margin',
          title: 'Profit margin',
          note: '${_pct(avgMargin)} for $year',
          series: [DashSeries('Margin', margin, DashUi.indigo)],
          axis: (v) => '${v.round()}%',
          barLabel: (v) => '${v.round()}%',
          badge: DashChangeChip.monthOverMonth(margin, year, what: 'Profit margin'),
          tip: (i) => [
            DashTipRow('Margin', revenue[i] > 0 ? _pct(margin[i]) : '—', color: DashUi.indigo),
            DashTipRow('Profit', _moneyFull(profit[i])),
            DashTipRow('Revenue', _moneyFull(revenue[i])),
          ],
          summary: (last) => 'Margin by month: ${list(margin, last, (v) => '${v.round()}%')}',
          emptyText: 'Nothing recorded for $year yet.',
          semanticsLabel: 'Profit margin of completed jobs by month, $year',
        ),
        DashChartView(
          tab: 'Net income',
          title: 'Net income',
          note: estimated
              ? 'expenses spread evenly (no monthly data)'
              : opexTotal <= 0
                  ? 'no expenses recorded, so net = gross profit'
                  : '${_moneyFull(netYtd)} ${year < DashClock.now().year ? 'in $year' : 'YTD'}'
                      '${opexShare == null ? '' : ' · expenses ${opexShare.round()}% of profit'}',
          series: [
            DashSeries('Monthly net', [for (final p in net) p.net], DashUi.emeraldDeep),
            // On the same axis as the bars, so both read off one zero line.
            DashSeries('Running total', [for (final p in net) p.cumulative], DashUi.indigo, kind: DashSeriesKind.line),
          ],
          axis: _compactMoney,
          tip: (i) => [
            DashTipRow('Gross profit', _moneyFull(net[i].profit), color: DashUi.emeraldDeep),
            DashTipRow('Expenses', net[i].expense > 0 ? '-${_moneyFull(net[i].expense)}' : '\$0', color: DashUi.amber),
            DashTipRow('Net', _moneyFull(net[i].net)),
            DashTipRow('Running total', _moneyFull(net[i].cumulative), color: DashUi.indigo),
          ],
          summary: (last) => 'Net income by month: ${list([for (final p in net) p.net], last, _compactMoney)}',
          emptyText: 'Nothing recorded for $year yet.',
          semanticsLabel: 'Net income by month after operating expenses, $year, with the running total',
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
  const _SegmentsStrip({required this.g, required this.data, required this.year});

  @override
  Widget build(BuildContext context) {
    final parts = [
      ('Residential', data.residentialRevenue, DashUi.sky),
      ('Commercial', data.commercialRevenue, DashUi.indigo),
      ('High Volume', data.highVolumeRevenue, DashUi.emeraldDeep),
      ('Other', data.otherRevenue, DashUi.amber),
    ];
    final total = parts.fold<double>(0, (s, p) => s + math.max(0, p.$2));
    return DashSplitPanel(
      g: g,
      title: 'Revenue by segment',
      tooltip: 'Completed jobs plus deposits on open jobs, split by the kind of work on their line items. '
          'The four add up to the Revenue + deposits card.',
      emptyText: 'No revenue recorded in $year.',
      items: [
        for (final p in parts)
          DashSplitItem(
            label: p.$1,
            amount: math.max(0, p.$2),
            value: _moneyFull(p.$2),
            color: p.$3,
            semanticsLabel: '${p.$1}: ${_moneyFull(p.$2)}, ${dashShare(math.max(0, p.$2), total)} of revenue + deposits',
          ),
      ],
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
  final String ytd;
  final bool tall;
  final int maxRows;
  final bool fill;
  const _ExpensesPanel({
    required this.g,
    required this.expenses,
    required this.total,
    required this.year,
    required this.ytd,
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
        for (final e in expenses.take(maxRows - 1)) (e, const <_ExpenseCategory>[]),
        (
          _ExpenseCategory('Other categories (${rest.length})', rest.fold(0.0, (s, e) => s + e.amount), DashUi.slate),
          rest,
        ),
      ];
    }
    final maxV = rows.fold<double>(0, (m, r) => math.max(m, r.$1.amount));
    final base = tall ? g.rowTall : g.rowWide;

    return DashPanel(
      fill: fill,
      header: DashPanelHeader(
        g: g,
        title: 'Operating expenses',
        note: total > 0 ? '${_moneyFull(total)} $ytd' : null,
        tooltip: 'Expenses recorded for $year, by category, biggest first.',
        trailing: expenses.isEmpty ? null : Text(dashCount(expenses.length, 'category'), style: DashText.meta),
      ),
      child: total <= 0
          ? const DashEmptyNote('No operating expenses recorded yet.')
          : Align(
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
                        : [for (final x in grouped) '${x.category}: ${_moneyFull(x.amount)}'].join('\n'),
                    semanticsLabel: grouped.isEmpty
                        ? '${e.category}: ${_moneyFull(e.amount)}, $share of operating expenses'
                        : '${e.category}: ${_moneyFull(e.amount)}, $share of operating expenses. '
                            '${[for (final x in grouped) '${x.category} ${_moneyFull(x.amount)}'].join(', ')}',
                  );
                },
              ),
            ),
    );
  }
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
            tiles: List.generate(6, (_) => const DashSkeletonTile()),
            poolWidth: dashTileWidth(g.k * 120),
            expenseRows: 8,
            chart: const DashSkeletonPanel(fill: true),
            segments: DashSkeletonPanel(rows: 1, rowH: g.line(15) + 6),
            expenses: (tall, maxRows, fill) =>
                DashSkeletonPanel(rows: math.min(8, maxRows), rowH: tall ? g.rowTall : g.rowWide),
          ),
        ),
      ),
    );
  }
}
