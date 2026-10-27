import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' hide TextDirection;

import 'config/api_config.dart';
import 'widgets/dashboard_data.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/dashboard_layout.dart';
import 'widgets/estimate_list_dialog.dart';

// The Collections dashboard. Two kinds of figure share the page:
//   left   the selected year: cash collected, write-offs, the monthly chart, how customers paid (changes with the year)
//   right  as of today: outstanding, over 90 days, notice stages, biggest balances (the same whatever the year)
// The page fits the window without scrolling and without shrinking text: on a short window the two "today" panels
// sit side by side, on a taller one they stack (see _Grid).

class CollectionsDashboardScreen extends StatelessWidget {
  const CollectionsDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      title: 'Collections',
      builder: (context, selectedYear) =>
          CollectionsDashboardContent(selectedYear: selectedYear),
    );
  }
}

class CollectionsDashboardContent extends StatefulWidget {
  final int selectedYear;
  const CollectionsDashboardContent({super.key, required this.selectedYear});

  @override
  State<CollectionsDashboardContent> createState() =>
      _CollectionsDashboardContentState();
}

// =============================================================================
// HELPERS
// =============================================================================

final _whole = NumberFormat('#,##0');

String _money(num v) => '${v < 0 ? '-' : ''}\$${_whole.format(v.abs())}';

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

/// A bar's label: whole thousands from $10k up ("$396k"), so twelve of them stay easy to compare.
String _barLabel(num v) => v.abs() >= 10000 && v.abs() < 1000000
    ? '${v < 0 ? '-' : ''}\$${(v.abs() / 1000).round()}k'
    : _compactMoney(v);

double _d(dynamic v) => v == null
    ? 0.0
    : (v is num ? v.toDouble() : double.tryParse(v.toString()) ?? 0.0);
int _i(dynamic v) =>
    v == null ? 0 : (v is num ? v.toInt() : int.tryParse(v.toString()) ?? 0);

/// "1 job", "209 jobs".
String _count(int n, String noun) => '${_whole.format(n)} $noun${n == 1 ? '' : 's'}';

String _age(int days) {
  if (days < 60) return '$days days';
  if (days < 730) return '${(days / 30.4).round()} months';
  return '${(days / 365).floor()} years';
}

/// A share as a whole percentage; a sliver reads "<1%" rather than a misleading 0%.
String _share(double part, double whole) {
  if (whole <= 0) return '0%';
  final p = part / whole * 100;
  return p > 0 && p < 1 ? '<1%' : '${p.round()}%';
}

/// The dates this year's figures cover so far: "Jan 1 – Oct 22".
String _toDateRange() {
  final now = DashClock.now();
  return 'Jan 1 – ${dashMonthNames[now.month - 1]} ${now.day}';
}

class _Scale {
  final double max;
  final double step;
  const _Scale(this.max, this.step);
  int get ticks => (max / step).round();
}

_Scale _niceScale(double maxV) {
  if (maxV <= 0) return const _Scale(10000, 2500);
  final raw = maxV / 4;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  final nice = norm <= 1 ? 1.0 : (norm <= 2 ? 2.0 : (norm <= 5 ? 5.0 : 10.0));
  final step = nice * mag;
  var top = (maxV / step).ceil() * step;
  if (top < maxV * 1.08) top += step;
  return _Scale(top, step);
}

/// Opens the jobs behind an unpaid balance: one notice stage, or 'all'; [customer] narrows it to one customer.
/// Same endpoint and rules as the dashboard, so the list adds up to the figure it was opened from.
void _openUnpaidJobs(
  BuildContext context, {
  required String stage,
  required String heading,
  required Color color,
  String? customer,
}) {
  showDialog<void>(
    context: context,
    builder: (_) => EstimateListDialog(
      year: DashClock.now().year,
      periodLabel: 'As of today',
      heading: heading,
      totalLabel: 'unpaid',
      noun: 'job',
      ageLabel: 'overdue',
      color: color,
      icon: Icons.schedule_rounded,
      uri: Uri.parse(
        '$kApiBaseUrl/api/dashboards/collections/jobs?stage=${Uri.encodeQueryComponent(stage)}',
      ),
      initialSort: EstimateListSort.oldest, // oldest date = most overdue first
      customer: customer,
    ),
  );
}

// =============================================================================
// TYPE
// =============================================================================

/// Text styles for this page. Every style sets its line height, so the panel heights in [_Geo] are exact.
abstract final class _T {
  static const _tabular = [FontFeature.tabularFigures()];

  static const panelTitle = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w700,
    height: 1.3,
    letterSpacing: -0.1,
    color: DashUi.ink,
  );
  static const panelNote = TextStyle(fontSize: 13, fontWeight: FontWeight.w500, height: 1.3, color: DashUi.subtle);
  static const label = TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.3, color: DashUi.ink);
  static const name = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, height: 1.3, color: DashUi.ink);
  static const meta = TextStyle(fontSize: 12, fontWeight: FontWeight.w500, height: 1.3, color: DashUi.subtle);
  static const money = TextStyle(
    fontSize: 13.5,
    fontWeight: FontWeight.w700,
    height: 1.3,
    color: DashUi.ink,
    fontFeatures: _tabular,
  );
  static const bigMoney = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w700,
    height: 1.2,
    color: DashUi.ink,
    fontFeatures: _tabular,
  );
  static const link = TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.3, color: DashUi.blue);
  static const legend = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.3, color: DashUi.slate);
  static const empty = TextStyle(fontSize: 14, fontWeight: FontWeight.w500, height: 1.3, color: DashUi.slate);
}

// =============================================================================
// MODELS
// =============================================================================

class _Stage {
  final String stage;
  final String label;
  final double amount;
  final int jobCount;
  const _Stage(this.stage, this.label, this.amount, this.jobCount);

  Color get color => switch (stage) {
    'none' => DashUi.sky,
    '14' || '30' || 'check' => DashUi.amber,
    '60' || '90' => DashUi.red,
    _ => DashUi.muted,
  };
}

class _Method {
  final String method;
  final double amount;
  final int count;
  const _Method(this.method, this.amount, this.count);

  Color get color => switch (method) {
    'Check' => DashUi.emeraldDeep,
    'Card' => DashUi.sky,
    'ACH' => DashUi.indigo,
    'Cash' => DashUi.amber,
    _ => DashUi.muted,
  };
}

class _Owing {
  final String customer;
  final double amount;
  final int jobCount;
  final int? oldestDays;
  const _Owing(this.customer, this.amount, this.jobCount, this.oldestDays);
}

class _Overdue {
  final String jobId;
  final String customer;
  final double amount;
  final int days;
  const _Overdue(this.jobId, this.customer, this.amount, this.days);
}

/// Everything the page shows, read once per answer from GET /api/dashboards/collections.
class _Figures {
  // The selected year, capped at today.
  final double collected;

  /// The same dates a year earlier (all of the year before, for a past year).
  final double priorCollected;
  final int paymentCount;
  final int writeOffJobs;
  final double writeOffBalance;

  /// Always 12 entries, January first.
  final List<double> writeOffMonthly;
  final List<double> months;

  /// All twelve months of the year before.
  final List<double> priorMonths;
  final List<_Method> methods;

  // As of today, whatever year the jobs are from.
  final double outstanding;
  final int outstandingJobs;
  final double over90;
  final int over90Jobs;

  /// One reading a day.
  final List<double> outstandingTrend;
  final List<double> over90Trend;
  final List<_Stage> stages;
  final List<_Owing> owing;

  /// Every overdue job, oldest first, for the ticker.
  final List<_Overdue> overdue;

  const _Figures({
    required this.collected,
    required this.priorCollected,
    required this.paymentCount,
    required this.writeOffJobs,
    required this.writeOffBalance,
    required this.writeOffMonthly,
    required this.months,
    required this.priorMonths,
    required this.methods,
    required this.outstanding,
    required this.outstandingJobs,
    required this.over90,
    required this.over90Jobs,
    required this.outstandingTrend,
    required this.over90Trend,
    required this.stages,
    required this.owing,
    required this.overdue,
  });

  static List<double> _monthly(dynamic raw, String field) {
    final out = List<double>.filled(12, 0);
    for (final e in (raw as List<dynamic>? ?? const [])) {
      final m = _i(e['month_num']);
      if (m >= 1 && m <= 12) out[m - 1] = _d(e[field]);
    }
    return out;
  }

  factory _Figures.parse(Map<String, dynamic> body) {
    final s = (body['summary'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final stages = [
      for (final e in (body['stages'] as List<dynamic>? ?? const []))
        _Stage(
          (e['stage'] ?? '').toString(),
          (e['label'] ?? '').toString(),
          _d(e['amount']),
          _i(e['jobCount']),
        ),
    ];
    final history = (body['history'] as List<dynamic>? ?? const []);
    // The server's job counts are the stage counts added up; a server too old to send them gets the same sum here.
    final stageJobs = stages.fold<int>(0, (t, x) => t + x.jobCount);
    final ninety = stages.where((x) => x.stage == '90').fold<int>(0, (t, x) => t + x.jobCount);
    return _Figures(
      collected: _d(s['collected']),
      priorCollected: _d(s['priorCollected']),
      paymentCount: _i(s['paymentCount']),
      writeOffJobs: _i(s['writeOffJobs']),
      writeOffBalance: _d(s['writeOffBalance']),
      writeOffMonthly: _monthly(body['writeOffMonthly'], 'balance'),
      months: _monthly(body['monthly'], 'collected'),
      priorMonths: _monthly(body['priorMonthly'], 'collected'),
      methods: [
        for (final e in (body['methods'] as List<dynamic>? ?? const []))
          _Method(
            (e['method'] ?? 'Other').toString(),
            _d(e['amount']),
            _i(e['paymentCount']),
          ),
      ].where((m) => m.amount > 0).toList(),
      outstanding: _d(s['outstanding']),
      outstandingJobs: s['outstandingJobs'] == null ? stageJobs : _i(s['outstandingJobs']),
      over90: _d(s['over90']),
      over90Jobs: s['over90Jobs'] == null ? ninety : _i(s['over90Jobs']),
      outstandingTrend: [for (final h in history) _d(h['outstanding'])],
      over90Trend: [for (final h in history) _d(h['over90'])],
      stages: stages,
      owing: [
        for (final e in (body['topOwing'] as List<dynamic>? ?? const []))
          _Owing(
            (e['customer'] ?? 'Unknown').toString(),
            _d(e['amount']),
            _i(e['jobCount']),
            e['oldestDays'] == null ? null : _i(e['oldestDays']),
          ),
      ],
      overdue: [
        for (final e in (body['overdue'] as List<dynamic>? ?? const []))
          _Overdue(
            (e['jobId'] ?? '').toString(),
            (e['customer'] ?? 'Unknown').toString(),
            _d(e['amount']),
            _i(e['daysOverdue']),
          ),
      ],
    );
  }
}

// =============================================================================
// SCREEN STATE
// =============================================================================

class _CollectionsDashboardContentState
    extends State<CollectionsDashboardContent>
    with DashboardLoading {
  _Figures? _figures;

  @override
  void initState() {
    super.initState();
    dashReload();
  }

  @override
  void didUpdateWidget(covariant CollectionsDashboardContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedYear != widget.selectedYear) dashReload();
  }

  // A slower, older request can't overwrite a newer year: DashRequests ignores it.
  @override
  Future<void> dashReload({bool fresh = false}) => dashLoad(
        '/api/dashboards/collections',
        query: {'year': '${widget.selectedYear}'},
        fresh: fresh,
        apply: (body) => _figures = _Figures.parse(body),
      );

  @override
  Widget build(BuildContext context) {
    final figures = _figures;
    if (dashLoading) return const _CollectionsSkeleton();
    if (dashFailure != null) {
      return DashErrorPanel.failure(
        dashFailure!,
        what: 'collections',
        onRetry: dashReload,
      );
    }
    if (figures == null) return const _CollectionsSkeleton();
    return _CollectionsPage(figures: figures, year: widget.selectedYear);
  }
}

// =============================================================================
// PAGE
// =============================================================================

class _CollectionsPage extends StatelessWidget {
  final _Figures figures;
  final int year;
  const _CollectionsPage({required this.figures, required this.year});

  @override
  Widget build(BuildContext context) {
    final f = figures;
    final period = dashPeriodLabel(year);
    final g = _Geo.of(context);

    return _Grid(
      stageRows: f.stages.length,
      owingRows: f.owing.length,
      periodTiles: [
        AnimatedMetricCard(
          title: 'Collected $year',
          value: f.collected,
          format: _money,
          caption: 'Net of refunds · $period',
          definition:
              'Payments received $period, with refunds taken off (${_count(f.paymentCount, 'payment')}). '
              'The line shows it by finished month.',
          valueColor: DashUi.emeraldDeep,
          index: 0,
          trend: dashTrend(f.months, year),
        ),
        AnimatedMetricCard(
          title: 'Written off $year',
          value: f.writeOffBalance,
          format: _money,
          caption: '${_count(f.writeOffJobs, 'job')} · by job date',
          definition:
              'What was still owed on the ${_count(f.writeOffJobs, 'job')} at Write-Off dated in $year (by their '
              'end, close or start date). The line shows it by finished month.',
          valueColor: DashUi.red,
          index: 1,
          trend: dashTrend(f.writeOffMonthly, year),
        ),
      ],
      todayTiles: [
        _DrillCard(
          jobs: f.outstandingJobs,
          onOpen: () => _openUnpaidJobs(
            context,
            stage: 'all',
            heading: 'All unpaid balances',
            color: DashUi.amber,
          ),
          card: AnimatedMetricCard(
            title: 'Outstanding balance',
            value: f.outstanding,
            format: _money,
            caption: 'Invoiced, not yet paid · today',
            definition:
                'Unpaid balance on jobs at Final Invoice Sent or Check on Payment, as of today, whatever year '
                'they are from (${_count(f.outstandingJobs, 'job')}). The line is one reading a day.',
            valueColor: DashUi.amber,
            index: 2,
            trend: f.outstandingTrend.length >= 2 ? f.outstandingTrend : null,
          ),
        ),
        _DrillCard(
          jobs: f.over90Jobs,
          onOpen: () => _openUnpaidJobs(
            context,
            stage: '90',
            heading: '90 Day Notice · unpaid balances',
            color: DashUi.red,
          ),
          card: AnimatedMetricCard(
            title: 'Over 90 days',
            value: f.over90,
            format: _money,
            caption: 'At 90 Day Notice · today',
            definition:
                'Unpaid balance on invoiced jobs that have reached the 90 Day Notice, as of today '
                '(${_count(f.over90Jobs, 'job')}). The line is one reading a day.',
            valueColor: DashUi.red,
            index: 3,
            trend: f.over90Trend.length >= 2 ? f.over90Trend : null,
          ),
        ),
      ],
      chart: _MonthlyChart(
        data: f.months,
        prior: f.priorMonths,
        year: year,
        total: f.collected,
        priorTotal: f.priorCollected,
      ),
      methods: _MethodsPanel(g: g, methods: f.methods, year: year),
      stages: (tall, fill) => _StagesPanel(
        g: g,
        stages: f.stages,
        total: f.outstanding,
        jobs: f.outstandingJobs,
        tall: tall,
        fill: fill,
      ),
      owing: (fill, max) => _OwingPanel(g: g, rows: f.owing.take(max).toList(), fill: fill),
      ticker: f.overdue.isEmpty ? null : _OverdueTicker(g: g, rows: f.overdue),
    );
  }
}

// =============================================================================
// GRID (shared by the page and its skeleton)
// =============================================================================

const double _gap = 14;

/// Heights of the fixed pieces at the current text size, so the grid can tell which arrangement fits the window
/// and give every panel at least what its rows need (text is never scaled down to fit).
class _Geo {
  final TextScaler s;
  final double tile;
  _Geo.of(BuildContext context)
      : s = MediaQuery.textScalerOf(context),
        tile = dashTileHeight(context);

  double line(double size, [double height = 1.3]) => s.scale(size) * height;

  /// Panel padding (12 top and bottom) plus its 1px border top and bottom, and the gap under the title row.
  static const padV = 26.0;
  static const headerGap = 8.0;
  double get panelHeader => math.max(26.0, math.max(line(15), line(13) + 8));

  /// Everything in a panel above its rows.
  double get panelTop => padV + panelHeader + headerGap;

  /// A stage on one line (a wide column) or on two (label and amount over bar and job count, a narrow column).
  double get stageRowWide => math.max(34.0, line(13.5) + 14);
  double get stageRowTall => math.max(42.0, line(13.5) + line(12) + 9);
  double get owingRow => math.max(44.0, line(13.5) + line(12) + 10);
  double stages(int rows, {required bool tall}) =>
      panelTop + math.max(rows, 2) * (tall ? stageRowTall : stageRowWide);
  double owing(int rows) => panelTop + math.max(rows, 2) * owingRow;

  /// The +4 absorbs the half pixels text lines round up to.
  double get methods => panelTop + line(13) + 3 + line(15, 1.2) + 4;
}

/// Lays the page out to fit the window, in the first arrangement that does:
///   stacked        scorecards; chart + payment methods | stages over biggest balances   (1500x800, 1366x768 ...)
///   side by side   scorecards; chart + payment methods | stages | biggest balances       (1280x600 ...)
///   one column     a window too small for either: everything in one column that scrolls
class _Grid extends StatelessWidget {
  final List<Widget> periodTiles;
  final List<Widget> todayTiles;
  final Widget chart;
  final Widget methods;

  /// `tall`: two-line stage rows for a narrow column. `fill`: spread the rows over the panel's height.
  final Widget Function(bool tall, bool fill) stages;
  final Widget Function(bool fill, int maxRows) owing;
  final int stageRows;
  final int owingRows;

  /// Overdue jobs scrolling under the two "today" panels, level with the payment methods panel.
  final Widget? ticker;

  const _Grid({
    required this.periodTiles,
    required this.todayTiles,
    required this.chart,
    required this.methods,
    required this.stages,
    required this.owing,
    required this.stageRows,
    required this.owingRows,
    this.ticker,
  });

  /// The chart panel never gets shorter than this.
  static const _minChart = 220.0;

  /// Fewest customers the biggest-balances list shrinks to when the ticker needs its height.
  static const _minOwing = 3;

  /// Narrowest content that still takes each arrangement: a one-line stage row needs about 400 px, and side by
  /// side each of the two columns needs about 280.
  static const _stackedFrom = 934.0;
  static const _sideBySideFrom = 1078.0;

  @override
  Widget build(BuildContext context) {
    final g = _Geo.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final rowH = c.maxHeight - g.tile - _gap;
        final chartFits = rowH - _gap - g.methods >= _minChart;
        final tickerH = ticker == null ? 0.0 : _gap + g.methods;
        double stackedH(int owingN) => g.stages(stageRows, tall: false) + _gap + g.owing(owingN);
        double sideH(int owingN) => math.max(g.stages(stageRows, tall: true), g.owing(owingN));

        // The ticker comes first, and the biggest-balances list gives up rows (down to _minOwing) to make room for it.
        // On a window too short even for that the ticker goes: better without it than a page that scrolls.
        final minOwing = math.min(owingRows, _minOwing);
        int? withTicker(double Function(int) h) {
          if (ticker == null) return null;
          for (var n = owingRows; n >= minOwing; n--) {
            if (rowH >= h(n) + tickerH) return n;
          }
          return null;
        }

        final Widget content;
        final stacked = chartFits && w >= _stackedFrom;
        final side = chartFits && w >= _sideBySideFrom;
        final stackedN = stacked ? withTicker(stackedH) : null;
        final sideN = side ? withTicker(sideH) : null;
        if (stackedN != null) {
          content = _stacked(g, stackedN, true);
        } else if (stacked && rowH >= stackedH(owingRows)) {
          content = _stacked(g, owingRows, false);
        } else if (sideN != null) {
          content = _sideBySide(g, sideN, true);
        } else if (side && rowH >= sideH(owingRows)) {
          content = _sideBySide(g, owingRows, false);
        } else {
          content = SingleChildScrollView(child: _oneColumn(g));
        }
        return SizedBox(width: w, height: c.maxHeight, child: content);
      },
    );
  }

  Widget _pair(List<Widget> tiles) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [Expanded(child: tiles[0]), const SizedBox(width: _gap), Expanded(child: tiles[1])],
  );

  /// The scorecards, split to line up with the columns below them.
  Widget _scorecards(_Geo g, int yearFlex, int todayFlex) => SizedBox(
    height: g.tile,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: yearFlex, child: _pair(periodTiles)),
        const SizedBox(width: _gap),
        Expanded(flex: todayFlex, child: _pair(todayTiles)),
      ],
    ),
  );

  Widget _yearColumn(_Geo g) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(child: chart),
      const SizedBox(height: _gap),
      SizedBox(height: g.methods, child: methods),
    ],
  );

  Widget _arrange(_Geo g, int yearFlex, int todayFlex, Widget today) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _scorecards(g, yearFlex, todayFlex),
      const SizedBox(height: _gap),
      Expanded(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: yearFlex, child: _yearColumn(g)),
            const SizedBox(width: _gap),
            Expanded(flex: todayFlex, child: today),
          ],
        ),
      ),
    ],
  );

  Widget _withTicker(_Geo g, bool show, Widget body) => ticker == null || !show
      ? body
      : Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: body),
            const SizedBox(height: _gap),
            SizedBox(height: g.methods, child: ticker),
          ],
        );

  Widget _stacked(_Geo g, int owingN, bool showTicker) => _arrange(
    g,
    13,
    10,
    _withTicker(
      g,
      showTicker,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: g.stages(stageRows, tall: false), child: stages(false, false)),
          const SizedBox(height: _gap),
          Expanded(child: owing(true, owingN)),
        ],
      ),
    ),
  );

  Widget _sideBySide(_Geo g, int owingN, bool showTicker) => _arrange(
    g,
    7,
    8,
    _withTicker(
      g,
      showTicker,
      Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: stages(true, true)),
          const SizedBox(width: _gap),
          Expanded(child: owing(true, owingN)),
        ],
      ),
    ),
  );

  Widget _oneColumn(_Geo g) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(height: g.tile, child: _pair(periodTiles)),
      const SizedBox(height: _gap),
      SizedBox(height: g.tile, child: _pair(todayTiles)),
      const SizedBox(height: _gap),
      SizedBox(height: 320, child: chart),
      const SizedBox(height: _gap),
      SizedBox(height: g.methods, child: methods),
      const SizedBox(height: _gap),
      SizedBox(height: g.stages(stageRows, tall: false), child: stages(false, false)),
      const SizedBox(height: _gap),
      owing(false, owingRows),
      if (ticker != null) ...[
        const SizedBox(height: _gap),
        SizedBox(height: g.methods, child: ticker),
      ],
    ],
  );
}

// =============================================================================
// BUILDING BLOCKS
// =============================================================================

/// White panel with a title row. With [fill], [child] takes the height left under the title.
class _Panel extends StatelessWidget {
  final Widget header;
  final Widget child;
  final bool fill;
  const _Panel({required this.header, required this.child, this.fill = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      decoration: DashUi.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          header,
          const SizedBox(height: _Geo.headerGap),
          if (fill) Expanded(child: child) else child,
        ],
      ),
    );
  }
}

/// A one-line panel title, an optional quieter [note] after it ("today"), and something small on the right.
class _PanelHeader extends StatelessWidget {
  final _Geo g;
  final String title;
  final String? note;
  final Widget? trailing;
  const _PanelHeader({required this.g, required this.title, this.note, this.trailing});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: g.panelHeader,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              label: note == null ? title : '$title, $note',
              child: ExcludeSemantics(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: title, style: _T.panelTitle),
                      if (note != null) TextSpan(text: ' · $note', style: _T.panelNote),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ],
      ),
    );
  }
}

class _EmptyNote extends StatelessWidget {
  final String text;
  const _EmptyNote(this.text);

  @override
  Widget build(BuildContext context) =>
      Center(child: Text(text, textAlign: TextAlign.center, style: _T.empty));
}

/// The blue keyboard-focus ring (never shown after a click). Always a decoration, transparent when unfocused:
/// Container only wraps its child in a DecoratedBox when it has one, and adding that wrapper on focus would rebuild
/// everything inside from scratch (replaying the scorecard entrance and the bar growth).
BoxDecoration _focusRing(bool focused, BorderRadius radius) => BoxDecoration(
  borderRadius: radius,
  border: Border.all(color: focused ? DashUi.blue : Colors.transparent, width: 2),
);

/// Something you can click, or reach with Tab and open with Enter or Space: a pointer cursor, a hover state for
/// [builder] to draw, a blue ring for keyboard focus only, and one screen-reader button named [label]. Without
/// [onTap] it is plain content (a stage with no jobs has nothing to open).
class _Pressable extends StatefulWidget {
  final VoidCallback? onTap;
  final String label;
  final String? hint;
  final BorderRadius radius;
  final Widget Function(bool hover) builder;
  const _Pressable({
    required this.onTap,
    required this.label,
    this.hint,
    required this.radius,
    required this.builder,
  });

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final onTap = widget.onTap;
    if (onTap == null) {
      return Semantics(
        container: true,
        label: widget.label,
        child: ExcludeSemantics(child: widget.builder(false)),
      );
    }
    return Semantics(
      container: true,
      button: true,
      label: widget.label,
      hint: widget.hint,
      onTap: onTap,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onTap();
              return null;
            },
          ),
        },
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // The tap is already on the button node above; a second one would split off an unlabelled node.
          excludeFromSemantics: true,
          onTap: onTap,
          child: ExcludeSemantics(
            child: Container(
              foregroundDecoration: _focusRing(_focus, widget.radius),
              child: SelectionContainer.disabled(child: widget.builder(_hover)),
            ),
          ),
        ),
      ),
    );
  }
}

/// "All 209 jobs ›": a small text link in a panel's title row.
class _Link extends StatelessWidget {
  final String text;
  final String label;
  final VoidCallback? onTap;
  const _Link({required this.text, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return _Pressable(
      onTap: onTap,
      label: label,
      radius: BorderRadius.circular(6),
      builder: (hover) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 2, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              style: _T.link.copyWith(decoration: hover ? TextDecoration.underline : null),
            ),
            const Icon(Icons.chevron_right_rounded, size: 18, color: DashUi.blue),
          ],
        ),
      ),
    );
  }
}

/// A scorecard that opens the jobs behind it. The chevron in the bottom corner says it can be opened (the trend
/// line, when there is room for one, sits above it).
class _DrillCard extends StatelessWidget {
  final AnimatedMetricCard card;
  final int jobs;
  final VoidCallback onOpen;
  const _DrillCard({required this.card, required this.jobs, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final c = card;
    final open = jobs > 0;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return _Pressable(
      onTap: open ? onOpen : null,
      label: '${c.title}: ${c.value == null ? 'no figure yet' : c.format(c.value!)}. ${c.definition ?? c.caption}',
      hint: open ? 'Opens the list of ${_count(jobs, 'job')}' : null,
      radius: BorderRadius.circular(12),
      builder: (hover) => Stack(
        fit: StackFit.expand,
        children: [
          c,
          if (open)
            Positioned(
              bottom: 8,
              right: 10,
              // Fades in with the card's own entrance.
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 900),
                curve: const Interval(0.4, 1),
                builder: (context, t, child) => Opacity(opacity: t, child: child),
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: hover ? c.valueColor : DashUi.subtle,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A horizontal bar on a faint track, growing in once (still under reduced motion).
class _Bar extends StatelessWidget {
  final double fraction;
  final Color color;
  const _Bar({required this.fraction, required this.color});

  static const height = 8.0;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return LayoutBuilder(
      builder: (context, c) => Container(
        height: height,
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(height / 2)),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: fraction.clamp(0.0, 1.0)),
          duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 700),
          curve: Curves.easeOutCubic,
          builder: (context, t, _) => Container(
            width: math.max(fraction > 0 ? height : 0.0, c.maxWidth * t),
            height: height,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(height / 2)),
          ),
        ),
      ),
    );
  }
}

/// Rows spread over a panel's height when it is given one (a little: never below [base], at most [base] + [give]),
/// or at [base] when the panel sizes to its content.
class _Rows extends StatelessWidget {
  final int count;
  final double base;
  final double give;
  final Widget Function(int i) row;
  const _Rows({required this.count, required this.base, required this.give, required this.row});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final h = c.maxHeight.isFinite ? (c.maxHeight / count).clamp(base, base + give).toDouble() : base;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [for (var i = 0; i < count; i++) SizedBox(height: h, child: row(i))],
        );
      },
    );
  }
}

// =============================================================================
// MONTHLY CHART (bars = the selected year, tick = the same month a year earlier)
// =============================================================================

class _MonthIntent extends Intent {
  final int delta;
  const _MonthIntent(this.delta);
}

class _MonthlyChart extends StatefulWidget {
  final List<double> data;
  final List<double> prior;
  final int year;
  final double total;
  final double priorTotal;
  const _MonthlyChart({
    required this.data,
    required this.prior,
    required this.year,
    required this.total,
    required this.priorTotal,
  });

  @override
  State<_MonthlyChart> createState() => _MonthlyChartState();
}

class _MonthlyChartState extends State<_MonthlyChart> with SingleTickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  /// The month under the pointer, or picked with the arrow keys.
  int? _index;
  bool _focused = false;

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduceMotion) {
      _intro.value = 1;
    } else if (_intro.isDismissed) {
      _intro.forward();
    }
  }

  @override
  void didUpdateWidget(covariant _MonthlyChart old) {
    super.didUpdateWidget(old);
    if (!identical(old.data, widget.data)) {
      _index = null;
      if (_reduceMotion) {
        _intro.value = 1;
      } else {
        _intro.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  /// This year's month in progress (its bar is drawn lighter: it isn't a whole month yet). Null for a past year.
  int? get _inProgress {
    final now = DashClock.now();
    return widget.year == now.year ? now.month - 1 : null;
  }

  int? _indexFor(double dx, double width) {
    final plotW = width - _ChartPainter.left - _ChartPainter.right;
    if (plotW <= 0) return null;
    final i = ((dx - _ChartPainter.left) / (plotW / 12)).floor();
    return (i < 0 || i >= 12) ? null : i;
  }

  void _step(int delta) {
    final start = _index ?? (_inProgress ?? 11);
    setState(() => _index = (start + (_index == null ? 0 : delta)).clamp(0, 11));
  }

  /// One month in words, for the tooltip's screen-reader twin.
  String _describe(int i) {
    final w = widget;
    final month = dashMonthNames[i];
    final ip = _inProgress;
    if (ip != null && i > ip) return '$month ${w.year}: not here yet. ${w.year - 1}: ${_money(w.prior[i])}';
    final partial = i == ip;
    return '$month ${w.year}${partial ? ' so far' : ''}: ${_money(w.data[i])}. '
        '${w.year - 1}${partial ? ', whole month' : ''}: ${_money(w.prior[i])}';
  }

  String _summary() {
    final last = _inProgress ?? 11;
    return [for (var i = 0; i <= last; i++) '${dashMonthNames[i]} ${_compactMoney(widget.data[i])}'].join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final maxV = [...w.data, ...w.prior].fold<double>(0, math.max);
    final scale = _niceScale(maxV);
    final inProgress = _inProgress;
    final empty = maxV <= 0;
    final font = DefaultTextStyle.of(context).style.fontFamily;

    final header = Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 16,
      runSpacing: 6,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(header: true, child: const Text('Cash collected', style: _T.panelTitle)),
            if (w.priorTotal > 0 && w.total > 0) ...[const SizedBox(width: 10), _vsPrior()],
          ],
        ),
        if (!empty)
          ExcludeSemantics(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _legendSwatch(DashUi.emeraldDeep, '${w.year}'),
                if (inProgress != null && w.data[inProgress] > 0) ...[
                  const SizedBox(width: 14),
                  _legendSwatch(DashUi.emeraldDeep.withValues(alpha: 0.4), '${dashMonthNames[inProgress]} so far'),
                ],
                const SizedBox(width: 14),
                _legendSwatch(DashUi.slate, '${w.year - 1}', tick: true),
              ],
            ),
          ),
      ],
    );

    return _Panel(
      fill: true,
      header: header,
      child: empty
          ? _EmptyNote('No payments recorded in ${w.year}.')
          : Semantics(
              container: true,
              label: 'Cash collected by month, ${w.year}, with the same month of ${w.year - 1} for comparison',
              value: _index == null ? _summary() : _describe(_index!),
              hint: 'Left and right arrow keys move between months',
              child: FocusableActionDetector(
                shortcuts: const {
                  SingleActivator(LogicalKeyboardKey.arrowLeft): _MonthIntent(-1),
                  SingleActivator(LogicalKeyboardKey.arrowRight): _MonthIntent(1),
                  SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
                },
                actions: {
                  _MonthIntent: CallbackAction<_MonthIntent>(onInvoke: (i) {
                    _step(i.delta);
                    return null;
                  }),
                  DismissIntent: CallbackAction<DismissIntent>(onInvoke: (_) {
                    setState(() => _index = null);
                    return null;
                  }),
                },
                onShowFocusHighlight: (v) => setState(() {
                  _focused = v;
                  // Keyboard focus starts on the latest month; leaving clears the pick.
                  _index = v ? (_index ?? inProgress ?? 11) : null;
                }),
                child: ExcludeSemantics(
                  child: LayoutBuilder(
                    builder: (context, c) {
                      return MouseRegion(
                        onHover: (e) {
                          final i = _indexFor(e.localPosition.dx, c.maxWidth);
                          if (i != _index) setState(() => _index = i);
                        },
                        onExit: (_) {
                          if (!_focused) setState(() => _index = null);
                        },
                        child: Container(
                          foregroundDecoration: _focusRing(_focused, BorderRadius.circular(8)),
                          child: Stack(
                            children: [
                              RepaintBoundary(
                                child: AnimatedBuilder(
                                  animation: _intro,
                                  builder: (context, _) => CustomPaint(
                                    size: Size(c.maxWidth, c.maxHeight),
                                    painter: _ChartPainter(
                                      data: w.data,
                                      prior: w.prior,
                                      scale: scale,
                                      hover: _index,
                                      inProgress: inProgress,
                                      intro: Curves.easeOutCubic.transform(_intro.value),
                                      fontFamily: font,
                                    ),
                                  ),
                                ),
                              ),
                              if (_index != null) _tooltip(c, _index!),
                            ],
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

  Widget _tooltip(BoxConstraints c, int i) {
    final w = widget;
    final plotW = c.maxWidth - _ChartPainter.left - _ChartPainter.right;
    final slot = plotW / 12;
    final cx = _ChartPainter.left + slot * i + slot / 2;
    const tipW = 196.0;
    // Beside the month rather than over it, so the bar and its label stay visible.
    final rightSide = cx + slot / 2 + 8 + tipW <= c.maxWidth;
    final left = rightSide ? cx + slot / 2 + 4 : math.max(0.0, cx - slot / 2 - 4 - tipW);
    final ip = _inProgress;
    final future = ip != null && i > ip;
    final partial = i == ip;
    final cur = w.data[i];
    final pri = w.prior[i];
    final change = !future && !partial && pri > 0 && cur > 0 ? (cur - pri) / pri * 100 : null;

    const dim = TextStyle(fontSize: 12, fontWeight: FontWeight.w600, height: 1.3, color: Color(0xFFCBD5E1));
    return Positioned(
      left: left,
      top: 4,
      width: tipW,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(color: DashUi.ink, borderRadius: BorderRadius.circular(10)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${dashMonthNames[i]} ${w.year}${partial ? ' so far' : ''}', style: dim),
              const SizedBox(height: 2),
              Text(
                future ? 'Not here yet' : _money(cur),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  height: 1.25,
                  color: Colors.white,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 4),
              Text('${w.year - 1}${partial ? ' (whole month)' : ''}: ${_money(pri)}', style: dim),
              if (change != null)
                Text(
                  '${change >= 0 ? '+' : '−'}${change.abs().round()}% on ${w.year - 1}',
                  style: dim.copyWith(color: change >= 0 ? const Color(0xFF6EE7B7) : const Color(0xFFFCA5A5)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _legendSwatch(Color color, String text, {bool tick = false}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: tick ? 14 : 11,
        height: tick ? 3 : 11,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(tick ? 1.5 : 3)),
      ),
      const SizedBox(width: 6),
      Text(text, style: _T.legend),
    ],
  );

  /// "↓ 6% vs 2025 to date": the selected stretch against the same dates a year earlier.
  Widget _vsPrior() {
    final w = widget;
    final pct = (w.total - w.priorTotal) / w.priorTotal * 100;
    final up = pct >= 0;
    final color = up ? DashUi.emeraldText : DashUi.redText;
    final thisYear = w.year == DashClock.now().year;
    return Tooltip(
      message: thisYear
          ? '${_money(w.total)} collected ${_toDateRange()}, ${w.year}, against ${_money(w.priorTotal)} '
              'over the same dates in ${w.year - 1}.'
          : '${_money(w.total)} collected in ${w.year}, against ${_money(w.priorTotal)} in ${w.year - 1}.',
      child: Semantics(
        label: '${up ? 'Up' : 'Down'} ${pct.abs().round()}% on ${thisYear ? 'the same dates in ' : ''}${w.year - 1}',
        child: ExcludeSemantics(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 13, color: color),
                const SizedBox(width: 3),
                Text(
                  '${pct.abs().round()}% vs ${w.year - 1}${thisYear ? ' to date' : ''}',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, height: 1.3, color: color),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  /// Room for the axis labels on the left, the month labels below, and the value labels above the tallest bar.
  static const left = 54.0;
  static const right = 4.0;
  static const bottom = 22.0;
  static const top = 18.0;

  final List<double> data;
  final List<double> prior;
  final _Scale scale;
  final int? hover;
  final int? inProgress;
  final double intro;
  final String? fontFamily;

  const _ChartPainter({
    required this.data,
    required this.prior,
    required this.scale,
    required this.hover,
    required this.inProgress,
    required this.intro,
    required this.fontFamily,
  });

  void _text(Canvas canvas, String s, Offset at, TextStyle style, {TextAlign align = TextAlign.left}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style.copyWith(fontFamily: fontFamily)),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = align == TextAlign.right
        ? at.dx - tp.width
        : (align == TextAlign.center ? at.dx - tp.width / 2 : at.dx);
    tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(left, top, size.width - right, size.height - bottom);
    if (plot.width <= 0 || plot.height <= 0) return;
    const axis = TextStyle(
      fontSize: 11.5,
      color: DashUi.subtle,
      fontWeight: FontWeight.w500,
      fontFeatures: [FontFeature.tabularFigures()],
    );

    for (var t = 0; t <= scale.ticks; t++) {
      final y = plot.bottom - plot.height * (t * scale.step / scale.max);
      canvas.drawLine(
        Offset(plot.left, y),
        Offset(plot.right, y),
        Paint()
          ..color = t == 0 ? DashUi.line : DashUi.faint
          ..strokeWidth = 1,
      );
      _text(canvas, _compactMoney(t * scale.step), Offset(plot.left - 10, y), axis, align: TextAlign.right);
    }

    final slot = plot.width / 12;
    final barW = math.min(slot * 0.54, 42.0);
    // Value labels only when each month has room for "$396k" without touching its neighbours.
    final labels = slot >= 34;
    final labelAlpha = ((intro - 0.6) / 0.4).clamp(0.0, 1.0);

    for (var i = 0; i < 12; i++) {
      final cx = plot.left + slot * i + slot / 2;
      final focus = hover == i;
      final dim = hover != null && !focus;
      _text(
        canvas,
        dashMonthNames[i],
        Offset(cx, plot.bottom + 12),
        TextStyle(
          fontSize: 11.5,
          fontWeight: focus ? FontWeight.w800 : FontWeight.w600,
          color: focus ? DashUi.ink : DashUi.subtle,
        ),
        align: TextAlign.center,
      );

      // Months that haven't happened yet draw nothing, not a zero-height bar.
      final ip = inProgress;
      final future = ip != null && i > ip;
      final partial = i == ip;
      final barTop = plot.bottom - plot.height * (data[i] / scale.max);
      if (!future && data[i] > 0) {
        final h = plot.height * (data[i] / scale.max) * intro;
        final rect = RRect.fromRectAndCorners(
          Rect.fromLTWH(cx - barW / 2, plot.bottom - h, barW, h),
          topLeft: const Radius.circular(5),
          topRight: const Radius.circular(5),
        );
        // The month in progress is lighter with an outline: a part month, not a collapse.
        final alpha = partial ? 0.4 : 1.0;
        canvas.drawRRect(rect, Paint()..color = DashUi.emeraldDeep.withValues(alpha: dim ? alpha * 0.35 : alpha));
        if (partial) {
          canvas.drawRRect(
            rect.deflate(0.75),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..color = DashUi.emeraldDeep.withValues(alpha: dim ? 0.35 : 1),
          );
        }
      }

      // The label sits on its own bar; only when last year's tick would cross it does it move above the tick.
      var labelY = barTop - 10;
      if (prior[i] > 0) {
        final y = plot.bottom - plot.height * (prior[i] / scale.max);
        canvas.drawLine(
          Offset(cx - barW / 2 - 4, y),
          Offset(cx + barW / 2 + 4, y),
          Paint()
            ..color = DashUi.slate.withValues(alpha: dim ? 0.3 : 0.9)
            ..strokeWidth = 2.5
            ..strokeCap = StrokeCap.round,
        );
        if (y > labelY - 11 && y < barTop + 2) labelY = y - 11;
      }

      if (labels && labelAlpha > 0 && !future && data[i] > 0) {
        _text(
          canvas,
          _barLabel(data[i]),
          Offset(cx, labelY),
          TextStyle(
            fontSize: 11.5,
            fontWeight: focus ? FontWeight.w800 : FontWeight.w600,
            color: (focus ? DashUi.ink : DashUi.slate).withValues(alpha: labelAlpha * (dim ? 0.45 : 1)),
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
          align: TextAlign.center,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.data != data ||
      old.prior != prior ||
      old.hover != hover ||
      old.intro != intro ||
      old.inProgress != inProgress ||
      old.fontFamily != fontFamily ||
      old.scale.max != scale.max;
}

// =============================================================================
// HOW CUSTOMERS PAID (the selected year)
// =============================================================================

class _MethodsPanel extends StatelessWidget {
  final _Geo g;
  final List<_Method> methods;
  final int year;
  const _MethodsPanel({required this.g, required this.methods, required this.year});

  @override
  Widget build(BuildContext context) {
    final total = methods.fold<double>(0, (s, m) => s + m.amount);

    // The title shares its row with the split bar; the methods are listed under it.
    return _Panel(
      header: SizedBox(
        height: g.panelHeader,
        child: Row(
          children: [
            Semantics(header: true, child: const Text('How customers paid', style: _T.panelTitle)),
            const SizedBox(width: 16),
            Expanded(child: total <= 0 ? const SizedBox.shrink() : _splitBar(total)),
          ],
        ),
      ),
      child: total <= 0
          ? SizedBox(
              height: g.line(13) + 3 + g.line(15, 1.2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('No payments recorded in $year.', style: _T.empty),
              ),
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < methods.length; i++) ...[
                  if (i > 0) const SizedBox(width: 14),
                  Expanded(child: _method(methods[i], total)),
                ],
              ],
            ),
    );
  }

  /// Repeats the figures listed under it, so screen readers skip it.
  Widget _splitBar(double total) => ExcludeSemantics(
    child: ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: SizedBox(
        height: 10,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < methods.length; i++) ...[
              if (i > 0) const SizedBox(width: 2),
              Expanded(
                flex: math.max(1, (methods[i].amount / total * 1000).round()),
                child: ColoredBox(color: methods[i].color),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _method(_Method m, double total) => Tooltip(
    message: '${_count(m.count, 'payment')} by ${m.method.toLowerCase()}',
    waitDuration: const Duration(milliseconds: 400),
    child: Semantics(
      container: true,
      label: '${m.method}: ${_money(m.amount)}, ${_share(m.amount, total)} of cash collected, '
          '${_count(m.count, 'payment')}',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: m.color, borderRadius: BorderRadius.circular(3)),
                ),
                const SizedBox(width: 6),
                Flexible(child: Text(m.method, maxLines: 1, overflow: TextOverflow.ellipsis, style: _T.label)),
                const SizedBox(width: 6),
                Text(_share(m.amount, total), style: _T.meta),
              ],
            ),
            const SizedBox(height: 3),
            Text(_money(m.amount), maxLines: 1, overflow: TextOverflow.ellipsis, style: _T.bigMoney),
          ],
        ),
      ),
    ),
  );
}

// =============================================================================
// UNPAID BALANCES BY STAGE (as of today)
// =============================================================================

class _StagesPanel extends StatelessWidget {
  final _Geo g;
  final List<_Stage> stages;
  final double total;
  final int jobs;

  /// Two-line rows, for a narrow column.
  final bool tall;
  final bool fill;
  const _StagesPanel({
    required this.g,
    required this.stages,
    required this.total,
    required this.jobs,
    required this.tall,
    required this.fill,
  });

  @override
  Widget build(BuildContext context) {
    final maxV = stages.fold<double>(0, (m, b) => math.max(m, b.amount));
    final base = tall ? g.stageRowTall : g.stageRowWide;

    return _Panel(
      fill: fill,
      header: _PanelHeader(
        g: g,
        title: 'Unpaid by stage',
        note: 'today',
        trailing: jobs > 0
            ? _Link(
                text: 'All ${_count(jobs, 'job')}',
                label: 'See all ${_count(jobs, 'unpaid job')}',
                onTap: () => _openUnpaidJobs(
                  context,
                  stage: 'all',
                  heading: 'All unpaid balances',
                  color: DashUi.amber,
                ),
              )
            : null,
      ),
      child: total <= 0
          ? SizedBox(height: math.max(stages.length, 2) * base, child: const _EmptyNote('Nothing is owed today.'))
          : _Rows(
              count: stages.length,
              base: base,
              give: 28,
              row: (i) => _row(context, stages[i], maxV),
            ),
    );
  }

  Widget _row(BuildContext context, _Stage s, double maxV) {
    final open = s.jobCount > 0;
    final scale = g.s.scale(1);
    final fraction = maxV > 0 ? s.amount / maxV : 0.0;
    final amount = Text(
      _money(s.amount),
      textAlign: TextAlign.right,
      style: _T.money.copyWith(color: s.amount > 0 ? DashUi.ink : DashUi.subtle),
    );
    final count = Text(_count(s.jobCount, 'job'), textAlign: TextAlign.right, style: _T.meta);
    final label = Text(s.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: _T.label);

    return _Pressable(
      onTap: open
          ? () => _openUnpaidJobs(context, stage: s.stage, heading: '${s.label} · unpaid balances', color: s.color)
          : null,
      label: '${s.label}: ${_money(s.amount)} unpaid on ${_count(s.jobCount, 'job')}',
      hint: open ? 'Opens the list of jobs' : null,
      radius: BorderRadius.circular(8),
      builder: (hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: hover ? s.color.withValues(alpha: 0.08) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(
              child: tall
                  // Label and amount, then the bar and the job count under them.
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(children: [Expanded(child: label), const SizedBox(width: 8), amount]),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(child: _Bar(fraction: fraction, color: s.color)),
                            const SizedBox(width: 10),
                            count,
                          ],
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        SizedBox(width: 126 * scale, child: label),
                        const SizedBox(width: 8),
                        Expanded(child: _Bar(fraction: fraction, color: s.color)),
                        const SizedBox(width: 12),
                        SizedBox(width: 76 * scale, child: amount),
                        SizedBox(width: 62 * scale, child: count),
                      ],
                    ),
            ),
            SizedBox(
              width: 22,
              child: open
                  ? Icon(Icons.chevron_right_rounded, size: 18, color: hover ? DashUi.ink : DashUi.subtle)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// BIGGEST OPEN BALANCES (as of today)
// =============================================================================

class _OwingPanel extends StatelessWidget {
  final _Geo g;
  final List<_Owing> rows;
  final bool fill;
  const _OwingPanel({required this.g, required this.rows, required this.fill});

  @override
  Widget build(BuildContext context) {
    return _Panel(
      fill: fill,
      header: _PanelHeader(
        g: g,
        title: 'Biggest balances',
        note: 'today',
        trailing: rows.isEmpty ? null : Text('Top ${rows.length}', style: _T.meta),
      ),
      child: rows.isEmpty
          ? SizedBox(height: 2 * g.owingRow, child: const _EmptyNote('No customer owes a balance today.'))
          : _Rows(
              count: rows.length,
              base: g.owingRow,
              give: 36,
              row: (i) => _row(context, rows[i], last: i == rows.length - 1),
            ),
    );
  }

  Widget _row(BuildContext context, _Owing r, {required bool last}) {
    final old = (r.oldestDays ?? 0) > 90;
    final meta = '${_count(r.jobCount, 'job')}${r.oldestDays == null ? '' : ' · oldest ${_age(r.oldestDays!)}'}';
    return _Pressable(
      onTap: () => _openUnpaidJobs(
        context,
        stage: 'all',
        heading: '${r.customer} · unpaid balances',
        color: DashUi.amber,
        customer: r.customer,
      ),
      label: '${r.customer}: ${_money(r.amount)} unpaid, $meta',
      hint: 'Opens their unpaid jobs',
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
                  // A long name is cut short in a narrow column; the full one is a hover away.
                  Tooltip(
                    message: r.customer,
                    waitDuration: const Duration(milliseconds: 600),
                    child: Text(r.customer, maxLines: 1, overflow: TextOverflow.ellipsis, style: _T.name),
                  ),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _T.meta.copyWith(color: old ? DashUi.redText : DashUi.subtle),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(_money(r.amount), style: _T.money.copyWith(fontSize: 14)),
            SizedBox(
              width: 22,
              child: Icon(Icons.chevron_right_rounded, size: 18, color: hover ? DashUi.ink : DashUi.subtle),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// SKELETON
// =============================================================================

// =============================================================================
// OVERDUE TICKER
// =============================================================================

/// Overdue jobs, oldest first, scrolling sideways in a panel the height of the payment methods panel beside it.
class _OverdueTicker extends StatelessWidget {
  final _Geo g;
  final List<_Overdue> rows;
  const _OverdueTicker({required this.g, required this.rows});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: DashUi.panel(),
      child: Semantics(
        label: '${_count(rows.length, 'overdue job')}, oldest first',
        child: ExcludeSemantics(
          child: AutoScrollTicker(
            height: g.methods - 26,
            items: [for (final o in rows) _OverdueCard(o)],
          ),
        ),
      ),
    );
  }
}

class _OverdueCard extends StatelessWidget {
  final _Overdue o;
  const _OverdueCard(this.o);

  @override
  Widget build(BuildContext context) {
    final old = o.days > 90;
    final tone = old ? DashUi.red : DashUi.amber;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DashUi.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule_rounded, color: tone, size: 16),
          const SizedBox(width: 8),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(o.customer, maxLines: 1, overflow: TextOverflow.ellipsis, style: _T.name),
              ),
              Text('${o.jobId.isEmpty ? '' : '#${o.jobId} · '}${_age(o.days)} overdue', style: _T.meta),
            ],
          ),
          const SizedBox(width: 10),
          Text(_money(o.amount), style: _T.money.copyWith(color: tone)),
        ],
      ),
    );
  }
}

class _CollectionsSkeleton extends StatelessWidget {
  const _CollectionsSkeleton();

  Widget _tile() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
    decoration: DashUi.panel(radius: 12),
    child: const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SkeletonBox(h: 12, w: 120),
        SizedBox(height: 10),
        SkeletonBox(h: 26, w: 170),
        SizedBox(height: 8),
        SkeletonBox(h: 10, w: 140),
      ],
    ),
  );

  Widget _panel({bool fill = false, int rows = 0, double rowH = 34}) => Container(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
    decoration: DashUi.panel(),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SkeletonBox(h: 14, w: 160),
        const SizedBox(height: 16),
        if (fill)
          const Expanded(child: SkeletonBox(r: 10))
        else
          for (var i = 0; i < rows; i++)
            SizedBox(height: rowH, child: const Align(alignment: Alignment.centerLeft, child: SkeletonBox(h: 12))),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final g = _Geo.of(context);
    return Semantics(
      label: 'Loading collections',
      child: ExcludeSemantics(
        child: SkeletonPulse(
          child: _Grid(
            stageRows: 6,
            owingRows: 5,
            periodTiles: [_tile(), _tile()],
            todayTiles: [_tile(), _tile()],
            chart: _panel(fill: true),
            methods: _panel(rows: 1, rowH: 24),
            stages: (tall, fill) => _panel(rows: 6, rowH: tall ? g.stageRowTall : g.stageRowWide),
            owing: (fill, max) => _panel(rows: 5, rowH: g.owingRow),
          ),
        ),
      ),
    );
  }
}
