import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'config/api_config.dart';
import 'widgets/dashboard_data.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/dashboard_panels.dart';
import 'widgets/estimate_list_dialog.dart';
import 'widgets/dashboard_layout.dart';

// The Sales dashboard: the sales team's estimates (by the Service Fusion opportunity owner), dated in the selected
// year by estimate date.
//   scorecards  won revenue, win rate, deals won, largest deal won
//   left        each person's figures (every one opens the estimates behind it) over won revenue by month
//   right       door styles by win rate or won revenue; each opens the estimates with that style
// The page fits the window without scrolling and without shrinking text (see _Grid).

class SalesDashboardScreen extends StatelessWidget {
  const SalesDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      title: 'Sales',
      builder: (context, selectedYear) => SalesDashboardContent(selectedYear: selectedYear),
    );
  }
}

class SalesDashboardContent extends StatefulWidget {
  final int selectedYear;
  const SalesDashboardContent({super.key, required this.selectedYear});

  @override
  State<SalesDashboardContent> createState() => _SalesDashboardContentState();
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

double _d(dynamic v) => v == null ? 0.0 : (v is num ? v.toDouble() : double.tryParse(v.toString()) ?? 0.0);
int _i(dynamic v) => v == null ? 0 : (v is num ? v.toInt() : int.tryParse(v.toString()) ?? 0);

// =============================================================================
// MODELS
// =============================================================================

class _Month {
  final int monthNum;
  final double wonValue;
  final int wonCount;
  final int closedCount;
  final int sentCount;
  const _Month(this.monthNum, this.wonValue, this.wonCount, this.closedCount, this.sentCount);

  double get winRate => closedCount > 0 ? wonCount / closedCount * 100 : 0;
}

class _Person {
  final String name;
  final String role;
  final String imageUrl;
  final double wonValue;
  final int wonCount;
  final int sentCount;
  final int lostCount;
  final double largestDeal;
  final double winRate;

  /// Won value per month, January first (always 12 entries).
  final List<double> monthlyWon;

  const _Person({
    required this.name,
    required this.role,
    required this.imageUrl,
    required this.wonValue,
    required this.wonCount,
    required this.sentCount,
    required this.lostCount,
    required this.largestDeal,
    required this.winRate,
    required this.monthlyWon,
  });

  factory _Person.fromJson(Map<String, dynamic> j) => _Person(
        name: (j['name'] ?? 'Unknown').toString(),
        role: (j['role'] ?? '').toString(),
        imageUrl: (j['imageUrl'] ?? '').toString(),
        wonValue: _d(j['wonValue']),
        wonCount: _i(j['wonCount']),
        sentCount: _i(j['sentCount']),
        lostCount: _i(j['lostCount']),
        largestDeal: _d(j['largestDeal']),
        monthlyWon: [
          for (final v in (j['monthlyWon'] as List<dynamic>? ?? const [])) _d(v),
        ],
        winRate: _d(j['winRate']),
      );
}

// =============================================================================
// SCREEN STATE
// =============================================================================

class _SalesDashboardContentState extends State<SalesDashboardContent> with DashboardLoading {
  double _wonValue = 0;
  int _wonCount = 0;
  double _winRate = 0;
  double _largestDeal = 0;
  double _priorWonValue = 0;

  /// Always 12 entries, January first.
  List<_Month> _months = [];
  List<double> _priorMonths = List.filled(12, 0);
  List<_Person> _people = [];
  List<_DoorType> _doors = [];

  @override
  void initState() {
    super.initState();
    dashReload();
  }

  @override
  void didUpdateWidget(covariant SalesDashboardContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedYear != widget.selectedYear) dashReload();
  }

  @override
  Future<void> dashReload({bool fresh = false}) => dashLoad(
        '/api/dashboards/sales',
        query: {'year': '${widget.selectedYear}'},
        fresh: fresh,
        apply: _apply,
      );

  void _apply(Map<String, dynamic> body) {
      final s = (body['summary'] as Map<String, dynamic>?) ?? const <String, dynamic>{};

      List<_Month> parseMonths(dynamic raw) {
        final byNum = <int, _Month>{};
        for (final e in (raw as List<dynamic>? ?? const [])) {
          final m = _i(e['month_num']);
          byNum[m] = _Month(m, _d(e['won_value']), _i(e['won_count']), _i(e['closed_count']), _i(e['sent_count']));
        }
        return List.generate(12, (i) => byNum[i + 1] ?? _Month(i + 1, 0, 0, 0, 0));
      }

      final months = parseMonths(body['monthly']);
      final prior = parseMonths(body['priorMonthly']).map((m) => m.wonValue).toList();
      final people = ((body['people'] as List<dynamic>?) ?? const [])
          .map((e) => _Person.fromJson(e as Map<String, dynamic>))
          .toList();

      _wonValue = _d(s['wonValue']);
      _wonCount = _i(s['wonCount']);
      _winRate = _d(s['winRate']);
      _largestDeal = _d(s['largestDeal']);
      _priorWonValue = _d(s['priorWonValue']);
      _months = months;
      _priorMonths = prior;
      _people = people;
      _doors = ((body['doorTypes'] as List<dynamic>?) ?? const [])
          .map((e) => _DoorType.fromJson(e as Map<String, dynamic>))
          .toList();
  }

  List<double>? _wonTrend() => dashTrend([for (final m in _months) m.wonValue], widget.selectedYear);

  @override
  Widget build(BuildContext context) {
    if (dashLoading) return const _SalesSkeleton();
    if (dashFailure != null) {
      return DashErrorPanel.failure(dashFailure!, what: 'sales', onRetry: dashReload);
    }

    final year = widget.selectedYear;
    final period = dashPeriodLabel(year);
    final g = DashGeo.of(context);
    // Only the sales team's estimates count here (the people below), dated by the estimate date.
    final team = _people.isEmpty ? 'the sales team' : _people.map((p) => p.name.split(' ').first).join(' + ');
    final wonCaption = 'Sales team estimates won · $period';

    final tiles = <Widget>[
      AnimatedMetricCard(
        title: 'Won revenue',
        value: _wonValue,
        format: _money,
        caption: wonCaption,
        definition: 'Value of won estimates owned by $team, dated $period (by estimate date). The line '
            'shows it by finished month.',
        valueColor: DashUi.sky,
        index: 0,
        trend: _wonTrend(),
        sparkMinWidth: dashSparkRoom(context, title: 'Won revenue', value: _money(_wonValue), caption: wonCaption),
      ),
      AnimatedMetricCard(
        title: 'Win rate',
        value: _winRate,
        format: (v) => '${v.toStringAsFixed(1)}%',
        caption: 'Won ÷ (won + lost) · sales team',
        definition: 'Of the estimates owned by $team and dated $period that have been decided, the share '
            "that were won. Open estimates aren't counted. The Estimates dashboard's win rate covers "
            'every estimate, so it can differ.',
        valueColor: DashUi.emeraldDeep,
        index: 1,
      ),
      AnimatedMetricCard(
        title: 'Deals won',
        value: _wonCount.toDouble(),
        format: (v) => _whole.format(v.round()),
        caption: 'Estimates won · $period',
        definition: 'Number of estimates owned by $team, dated $period, that were won.',
        valueColor: DashUi.ink,
        index: 2,
      ),
      AnimatedMetricCard(
        title: 'Largest deal won',
        value: _largestDeal,
        format: _money,
        caption: 'Single biggest won estimate · $period',
        definition: 'The highest-value estimate owned by $team, dated $period, that was won.',
        valueColor: DashUi.blue,
        index: 3,
      ),
    ];

    return _Grid(
      tiles: tiles,
      people: _people.length,
      team: (oneLine, fill) => _TeamPanel(g: g, people: _people, year: year, oneLine: oneLine, fill: fill),
      chart: _WonChart(months: _months, prior: _priorMonths, people: _people, year: year, total: _wonValue, priorTotal: _priorWonValue),
      doors: (maxRows, fill) => _DoorPanel(g: g, doors: _doors, year: year, maxRows: maxRows, fill: fill),
    );
  }
}

// =============================================================================
// GRID (shared by the page and its skeleton)
// =============================================================================

/// Lays the page out to fit the window:
///   two columns   scorecards; the sales team over won revenue by month | door styles   (1280x600 and up)
///   one column    a window narrower than a desktop one: everything in one column that scrolls
class _Grid extends StatelessWidget {
  final List<Widget> tiles;
  final int people;

  /// `oneLine`: each person's figures in columns on one row (or under the name, a narrow column). `fill`: the panel
  /// is given a height to fill.
  final Widget Function(bool oneLine, bool fill) team;
  final Widget chart;

  /// `maxRows`: door styles that fit (the rest are a click away).
  final Widget Function(int maxRows, bool fill) doors;

  const _Grid({required this.tiles, required this.people, required this.team, required this.chart, required this.doors});

  static const _twoColumnsFrom = 1000.0;
  static const _minChart = 190.0;

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final bodyH = c.maxHeight - g.tile - dashGap;
        final leftInner = (w - dashGap) * 13 / 23 - 40;
        final oneLine = leftInner >= _TeamPanel.oneLineWidth(g);
        final teamH = _TeamPanel.height(g, people, oneLine);
        final doorRows = ((bodyH - g.panelTop - _DoorPanel.subtitleH(g)) / g.rowWide).floor();
        final Widget content;
        if (w >= _twoColumnsFrom && bodyH - teamH - dashGap >= _minChart && doorRows >= 3) {
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
                          SizedBox(height: teamH, child: team(oneLine, true)),
                          const SizedBox(height: dashGap),
                          Expanded(child: chart),
                        ],
                      ),
                    ),
                    const SizedBox(width: dashGap),
                    Expanded(flex: 10, child: doors(doorRows, true)),
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
                team(false, false),
                const SizedBox(height: dashGap),
                SizedBox(height: 320, child: chart),
                const SizedBox(height: dashGap),
                doors(10, false),
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
// THE SALES TEAM (every figure opens the estimates behind it)
// =============================================================================

class _TeamPanel extends StatelessWidget {
  final DashGeo g;
  final List<_Person> people;
  final int year;
  final bool oneLine;
  final bool fill;
  const _TeamPanel({required this.g, required this.people, required this.year, required this.oneLine, required this.fill});

  // Column widths at 100% text (they grow with the text).
  static const _avatar = 40.0;
  static const _nameMin = 128.0;
  static const _cols = <_Drill, double>{
    _Drill.won: 92,
    _Drill.sent: 62,
    _Drill.largest: 70,
    _Drill.lost: 44,
    _Drill.closed: 84,
  };

  static double oneLineWidth(DashGeo g) =>
      _avatar + 10 + (_nameMin + _cols.values.fold<double>(0, (a, b) => a + b)) * g.k + _cols.length * 8 + 16;

  /// A person on one line: a name over a role, figures over their detail. On two: the name and won revenue, then
  /// a line of the other figures.
  static double rowH(DashGeo g, bool oneLine) =>
      oneLine ? math.max(g.listRow, 48.0) : math.max(g.listRow, g.line(13.5) + 2 + g.line(12.5) + 2 + 6);

  /// The panel has no separate title row: its heading row carries the title (and, on one line, the column names).
  static double headRow(DashGeo g) => math.max(g.columnHead, g.line(15)) + 4;
  static double height(DashGeo g, int people, bool oneLine) =>
      DashGeo.padV + headRow(g) + math.max(people, 1) * rowH(g, oneLine) + 2;

  @override
  Widget build(BuildContext context) {
    final teamWon = people.fold<double>(0, (a, b) => a + b.wonValue);
    final rows = people.isEmpty
        ? [SizedBox(height: rowH(g, oneLine), child: const DashEmptyNote('No sales team estimates yet.'))]
        : [
            for (var i = 0; i < people.length; i++)
              SizedBox(height: rowH(g, oneLine), child: _row(context, people[i], teamWon, last: i == people.length - 1)),
          ];
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      decoration: DashUi.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _headings(people.isNotEmpty && oneLine),
          ...rows,
        ],
      ),
    );
  }

  /// The title, and over a one-line table the column names, on one row.
  Widget _headings(bool columns) {
    Widget h(String text, double width) =>
        SizedBox(width: width * g.k, child: Text(text, textAlign: TextAlign.right, maxLines: 1, style: DashText.column));
    return SizedBox(
      height: headRow(g),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Tooltip(
              message: "Each person's estimates dated in $year. Click a figure to see the estimates behind it.",
              child: Semantics(
                header: true,
                label: 'Sales team, $year',
                child: ExcludeSemantics(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        const TextSpan(text: 'Sales team', style: DashText.panelTitle),
                        TextSpan(text: ' · $year', style: DashText.panelNote),
                      ],
                    ),
                    maxLines: 1,
                  ),
                ),
              ),
            ),
          ),
          if (columns)
            ExcludeSemantics(
              child: Padding(
                padding: EdgeInsets.only(top: math.max(0, g.line(15) - g.line(12)), right: 8),
                child: Row(
                  children: [
                    for (final e in _cols.entries) ...[
                      const SizedBox(width: 8),
                      h(switch (e.key) {
                        _Drill.won => 'Won',
                        _Drill.sent => 'Sent',
                        _Drill.largest => 'Largest',
                        _Drill.lost => 'Lost',
                        _Drill.closed => 'Win rate',
                      }, e.value),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  int _closed(_Person p) => p.wonCount + p.lostCount;

  /// One figure as a button that opens its estimates: the value, and a quieter line under it.
  Widget _figure(BuildContext context, _Person p, _Drill d, {required String value, String? detail, Color? color, double? width}) {
    final label = switch (d) {
      _Drill.won => '${p.name}: ${_money(p.wonValue)} won on ${p.wonCount} deals',
      _Drill.sent => '${p.name}: ${p.sentCount} estimates sent',
      _Drill.largest => '${p.name}: largest deal ${_money(p.largestDeal)}',
      _Drill.lost => '${p.name}: ${p.lostCount} estimates lost',
      _Drill.closed => _closed(p) == 0
          ? '${p.name}: no closed estimates yet'
          : '${p.name}: win rate ${p.winRate.toStringAsFixed(1)}%, ${p.wonCount} won of ${_closed(p)} closed',
    };
    final cell = DashPressable(
      onTap: () => showDialog<void>(context: context, builder: (_) => _personListDialog(person: p, year: year, drill: d)),
      label: label,
      hint: 'Opens the ${d.what}',
      radius: BorderRadius.circular(6),
      builder: (hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: hover ? d.color.withValues(alpha: 0.08) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: oneLine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              value,
              maxLines: 1,
              style: DashText.money.copyWith(
                color: color ?? DashUi.ink,
                decoration: hover ? TextDecoration.underline : null,
              ),
            ),
            if (detail != null) Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.meta),
          ],
        ),
      ),
    );
    return width == null ? cell : SizedBox(width: width * g.k, child: cell);
  }

  Widget _row(BuildContext context, _Person p, double teamWon, {required bool last}) {
    final share = teamWon > 0 ? '${(p.wonValue / teamWon * 100).round()}% of team' : null;
    final closed = _closed(p);
    final avatar = DashAvatar(name: p.name, imageUrl: p.imageUrl, size: _avatar, square: true, accent: DashUi.sky);
    final name = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.name),
        if (p.role.isNotEmpty) Text(p.role, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.meta),
      ],
    );
    final won = _figure(context, p, _Drill.won, value: _money(p.wonValue), detail: share, color: DashUi.sky, width: oneLine ? _cols[_Drill.won] : null);
    final winRate = closed == 0 ? '—' : '${p.winRate.toStringAsFixed(1)}%';

    final Widget body;
    if (oneLine) {
      body = Row(
        children: [
          avatar,
          const SizedBox(width: 10),
          Expanded(child: name),
          const SizedBox(width: 8),
          won,
          const SizedBox(width: 8),
          _figure(context, p, _Drill.sent, value: _whole.format(p.sentCount), detail: '${_whole.format(p.wonCount)} won',
              width: _cols[_Drill.sent]),
          const SizedBox(width: 8),
          _figure(context, p, _Drill.largest, value: _compactMoney(p.largestDeal), color: DashUi.blue, width: _cols[_Drill.largest]),
          const SizedBox(width: 8),
          _figure(context, p, _Drill.lost, value: _whole.format(p.lostCount), color: p.lostCount > 0 ? DashUi.redText : DashUi.ink,
              width: _cols[_Drill.lost]),
          const SizedBox(width: 8),
          _figure(context, p, _Drill.closed, value: winRate, color: DashUi.emeraldText,
              detail: closed == 0 ? 'none closed' : '${p.wonCount} of $closed', width: _cols[_Drill.closed]),
        ],
      );
    } else {
      // Two lines: the name and won revenue, then the other figures as small buttons (the role and the share of the
      // team are on hover and for screen readers).
      body = Row(
        children: [
          avatar,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Tooltip(
                        message: p.role.isEmpty ? p.name : '${p.name} · ${p.role}',
                        child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.name),
                      ),
                    ),
                    _figure(context, p, _Drill.won, value: _money(p.wonValue), color: DashUi.sky),
                  ],
                ),
                const SizedBox(height: 2),
                Wrap(
                  spacing: 4,
                  children: [
                    if (share != null) _chip(context, p, _Drill.won, share),
                    _chip(context, p, _Drill.sent, '${_whole.format(p.sentCount)} sent'),
                    _chip(context, p, _Drill.largest, '${_compactMoney(p.largestDeal)} largest'),
                    _chip(context, p, _Drill.lost, '${_whole.format(p.lostCount)} lost'),
                    _chip(context, p, _Drill.closed, closed == 0 ? 'no closed' : '$winRate win · ${p.wonCount} of $closed'),
                  ],
                ),
              ],
            ),
          ),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(border: last ? null : const Border(bottom: BorderSide(color: DashUi.faint))),
      child: body,
    );
  }

  /// A figure on the second line of a narrow row, as a small button.
  Widget _chip(BuildContext context, _Person p, _Drill d, String text) => DashPressable(
    onTap: () => showDialog<void>(context: context, builder: (_) => _personListDialog(person: p, year: year, drill: d)),
    label: '${p.name}: $text',
    hint: 'Opens the ${d.what}',
    radius: BorderRadius.circular(6),
    builder: (hover) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: hover ? d.color.withValues(alpha: 0.1) : DashUi.faint,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text, maxLines: 1, style: DashText.meta.copyWith(fontSize: 12.5, color: DashUi.slate)),
    ),
  );
}

// =============================================================================
// WON REVENUE BY MONTH (the team against last year; or one person)
// =============================================================================

class _WonChart extends StatelessWidget {
  final List<_Month> months;
  final List<double> prior;
  final List<_Person> people;
  final int year;
  final double total;

  /// The same dates a year earlier (all of the year before, for a past year).
  final double priorTotal;
  const _WonChart({
    required this.months,
    required this.prior,
    required this.people,
    required this.year,
    required this.total,
    required this.priorTotal,
  });

  @override
  Widget build(BuildContext context) {
    final won = [for (var i = 0; i < 12; i++) i < months.length ? months[i].wonValue : 0.0];
    final priorMonths = [for (var i = 0; i < 12; i++) i < prior.length ? prior[i] : 0.0];
    final thisYear = year == DashClock.now().year;
    String list(List<double> v, int last) => [for (var i = 0; i <= last; i++) '${dashMonthNames[i]} ${_compactMoney(v[i])}'].join(', ');

    Widget? vsPrior;
    if (priorTotal > 0 && total > 0) {
      final pct = (total - priorTotal) / priorTotal * 100;
      vsPrior = DashChangeChip(
        pct: pct,
        text: '${pct.abs().round()}% vs ${year - 1}${thisYear ? ' to date' : ''}',
        tooltip: thisYear
            ? '${_money(total)} won so far in $year, against ${_money(priorTotal)} over the same dates in ${year - 1}.'
            : '${_money(total)} won in $year, against ${_money(priorTotal)} in ${year - 1}.',
        semanticsLabel: '${pct >= 0 ? 'Up' : 'Down'} ${pct.abs().round()}% on ${thisYear ? 'the same dates in ' : ''}${year - 1}',
      );
    }

    return DashMonthChart(
      year: year,
      views: [
        DashChartView(
          tab: 'Team',
          title: 'Won revenue',
          note: '${_compactMoney(total)} in $year',
          series: [DashSeries('$year', won, DashUi.sky)],
          prior: priorMonths,
          priorLabel: '${year - 1}',
          axis: _compactMoney,
          barLabel: _compactMoney,
          badge: vsPrior,
          tip: (i) {
            final m = i < months.length ? months[i] : null;
            return [
              DashTipRow('Won', _money(won[i]), color: DashUi.sky),
              if (m != null) DashTipRow('Deals', '${m.wonCount} · ${m.winRate.toStringAsFixed(0)}% win'),
              DashTipRow('${year - 1}', _money(priorMonths[i])),
            ];
          },
          summary: (last) => 'Won revenue by month: ${list(won, last)}',
          emptyText: 'No won estimates for $year yet.',
          semanticsLabel: 'Won revenue by month, $year, with the same month of ${year - 1} for comparison',
        ),
        for (final p in people)
          DashChartView(
            tab: p.name.split(' ').first,
            title: p.name,
            note: '${_compactMoney(p.wonValue)} won in $year',
            series: [
              DashSeries(p.name.split(' ').first, [for (var i = 0; i < 12; i++) i < p.monthlyWon.length ? p.monthlyWon[i] : 0.0], DashUi.sky),
            ],
            axis: _compactMoney,
            barLabel: _compactMoney,
            tip: (i) => [DashTipRow('Won', _money(i < p.monthlyWon.length ? p.monthlyWon[i] : 0), color: DashUi.sky)],
            summary: (last) => '${p.name} won by month: ${list([for (var i = 0; i < 12; i++) i < p.monthlyWon.length ? p.monthlyWon[i] : 0.0], last)}',
            emptyText: '${p.name} has no won estimates in $year yet.',
            semanticsLabel: 'Won revenue by month for ${p.name}, $year',
          ),
      ],
    );
  }
}

// =============================================================================
// DOOR STYLES (win rate, or won revenue in door lines; each opens its estimates)
// =============================================================================

class _DoorPanel extends StatefulWidget {
  final DashGeo g;
  final List<_DoorType> doors;
  final int year;
  final int maxRows;
  final bool fill;
  const _DoorPanel({required this.g, required this.doors, required this.year, required this.maxRows, required this.fill});

  static double subtitleH(DashGeo g) => g.line(12.5) + 6;

  @override
  State<_DoorPanel> createState() => _DoorPanelState();
}

class _DoorPanelState extends State<_DoorPanel> {
  _DoorView _view = _DoorView.winRate;

  @override
  Widget build(BuildContext context) => _panel(context, widget.maxRows, widget.fill);

  /// The panel; in the "all styles" list ([inDialog]) without the view toggle, showing the view picked here.
  Widget _panel(BuildContext context, int maxRows, bool fill, {bool inDialog = false}) {
    final w = widget;
    final g = w.g;
    final rate = _view == _DoorView.winRate;
    final slices = _doorSlices(w.doors, _view, 10);
    final all = slices.length <= maxRows;
    final shown = all ? slices : slices.take(math.max(1, maxRows - 1)).toList();
    final totalRevenue = slices.fold<double>(0, (s, d) => s + d.revenue);
    final maxRevenue = slices.fold<double>(0, (m, d) => math.max(m, d.revenue));

    final header = DashPanelHeader(
      g: g,
      title: 'Door styles',
      note: '${w.year}',
      tooltip: rate
          ? 'The top Clopay styles on the sales team\'s estimates in ${w.year}, most deals won first, with the share of '
              'closed estimates that were won. An estimate counts once per style it contains.'
          : 'The top Clopay styles by won revenue in ${w.year}: the door lines\' own totals on won estimates, not the '
              'whole estimate.',
      trailing: w.doors.isEmpty || inDialog
          ? null
          : DashSegmented<_DoorView>(
              value: _view,
              label: 'Door styles view',
              options: const [(_DoorView.winRate, 'Win rate'), (_DoorView.revenue, 'Revenue')],
              onChanged: (v) => setState(() => _view = v),
            ),
    );
    if (slices.isEmpty) {
      return DashPanel(
        fill: fill,
        header: header,
        child: SizedBox(height: 2 * g.rowWide, child: DashEmptyNote('No door styles on won or lost estimates in ${w.year}.')),
      );
    }

    final subtitle = SizedBox(
      height: _DoorPanel.subtitleH(g),
      child: Row(
        children: [
          Expanded(
            child: Text(
              rate ? 'Top ${slices.length} Clopay styles · most deals won first' : 'Top ${slices.length} Clopay styles · door lines on won estimates',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DashText.legend,
            ),
          ),
          if (!all)
            DashLink(
              text: 'All ${slices.length}',
              label: 'See all ${slices.length} door styles',
              onTap: () => _openAll(context),
            ),
        ],
      ),
    );

    final rows = DashRows(
      count: shown.length,
      base: g.rowWide,
      give: 16,
      row: (i) {
        final s = shown[i];
        final winRate = s.closed == 0 ? '—' : '${s.winRate.toStringAsFixed(0)}%';
        return DashBarRow(
          g: g,
          label: s.label,
          fraction: rate ? s.winRate / 100 : (maxRevenue > 0 ? s.revenue / maxRevenue : 0),
          color: s.color,
          amount: rate ? winRate : _compactMoney(s.revenue),
          detail: rate ? '${s.won}/${s.closed}' : dashShare(s.revenue, totalRevenue),
          tall: false,
          labelWidth: 132,
          amountWidth: 56,
          detailWidth: 48,
          onTap: () => showDialog<void>(
            context: context,
            builder: (_) => _doorListDialog(doorType: s.label, year: w.year, color: s.color, revenueView: !rate),
          ),
          hint: 'Opens the estimates with this style',
          semanticsLabel: rate
              ? '${s.label}: ${s.closed == 0 ? 'no closed estimates' : '$winRate win rate, ${s.won} won of ${s.closed} closed'}, '
                  '${s.sent} sent'
              : '${s.label}: ${_money(s.revenue)} won in door lines, ${dashShare(s.revenue, totalRevenue)} of the top styles',
        );
      },
    );

    return DashPanel(
      fill: fill,
      header: header,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          subtitle,
          if (fill) Expanded(child: Align(alignment: Alignment.topCenter, child: rows)) else rows,
        ],
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
          constraints: BoxConstraints(maxWidth: 640, maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.86),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
            child: SingleChildScrollView(child: _panel(dialogContext, 99, false, inDialog: true)),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// SKELETON (the same grid, with placeholders)
// =============================================================================

class _SalesSkeleton extends StatelessWidget {
  const _SalesSkeleton();

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    return Semantics(
      label: 'Loading sales',
      child: ExcludeSemantics(
        child: SkeletonPulse(
          child: _Grid(
            tiles: List.generate(4, (_) => const DashSkeletonTile()),
            people: 2,
            team: (oneLine, fill) => DashSkeletonPanel(rows: 2, rowH: _TeamPanel.rowH(g, oneLine) - 8),
            chart: const DashSkeletonPanel(fill: true),
            doors: (maxRows, fill) => DashSkeletonPanel(rows: math.min(6, maxRows), rowH: g.rowWide),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// DRILL-DOWN (click any metric on a person's card to see the estimates behind it)
// =============================================================================

enum _Drill { won, sent, lost, closed, largest }

extension _DrillX on _Drill {
  /// Value of the backend's `filter` query parameter.
  String get filter => switch (this) {
        _Drill.won || _Drill.largest => 'won',
        _Drill.sent => 'sent',
        _Drill.lost => 'lost',
        _Drill.closed => 'closed',
      };

  String get title => switch (this) {
        _Drill.won => 'Won estimates',
        _Drill.sent => 'Estimates sent',
        _Drill.lost => 'Lost estimates',
        _Drill.closed => 'Closed estimates (won and lost)',
        _Drill.largest => 'Won estimates, largest first',
      };

  /// Used in the hover tooltip: "See the won estimates".
  String get what => switch (this) {
        _Drill.won => 'won estimates',
        _Drill.sent => 'estimates sent',
        _Drill.lost => 'lost estimates',
        _Drill.closed => 'closed estimates',
        _Drill.largest => 'won estimates, largest first',
      };

  Color get color => switch (this) {
        _Drill.won => DashUi.sky,
        _Drill.sent => DashUi.ink,
        _Drill.lost => DashUi.red,
        _Drill.closed => DashUi.emeraldDeep,
        _Drill.largest => DashUi.blue,
      };

  IconData get icon => switch (this) {
        _Drill.won => Icons.check_circle_outline_rounded,
        _Drill.sent => Icons.send_rounded,
        _Drill.lost => Icons.highlight_off_rounded,
        _Drill.closed => Icons.rule_rounded,
        _Drill.largest => Icons.emoji_events_outlined,
      };

  bool get valueFirst => this == _Drill.largest;
}

/// The estimates behind one metric on a person's card.
EstimateListDialog _personListDialog({required _Person person, required int year, required _Drill drill}) {
  return EstimateListDialog(
    year: year,
    heading: '${person.name} · ${drill.title}',
    color: drill.color,
    icon: drill.icon,
    uri: Uri.parse(
      '$kApiBaseUrl/api/dashboards/sales/estimates'
      '?year=$year&owner=${Uri.encodeQueryComponent(person.name)}&filter=${drill.filter}',
    ),
    initialSort: drill.valueFirst ? EstimateListSort.value : EstimateListSort.newest,
  );
}

/// The estimates containing one door style from the pie chart.
EstimateListDialog _doorListDialog({
  required String doorType,
  required int year,
  required Color color,
  required bool revenueView,
}) {
  return EstimateListDialog(
    year: year,
    heading: '$doorType estimates',
    totalLabel: 'in door lines',
    color: color,
    icon: Icons.sensor_door_outlined,
    uri: Uri.parse(
      '$kApiBaseUrl/api/dashboards/sales/door-estimates'
      '?year=$year&type=${Uri.encodeQueryComponent(doorType)}',
    ),
    initialSort: revenueView ? EstimateListSort.value : EstimateListSort.newest,
    outcomeFilter: true,
    initialOutcome: revenueView ? 'won' : 'all',
  );
}
// =============================================================================
// DOOR TYPES (pie chart that cycles between win rate and revenue every 8 seconds)
// =============================================================================

class _DoorType {
  final String type;
  final int sentCount;
  final int wonCount;
  final int lostCount;
  final double revenue;
  const _DoorType({
    required this.type,
    required this.sentCount,
    required this.wonCount,
    required this.lostCount,
    required this.revenue,
  });

  factory _DoorType.fromJson(Map<String, dynamic> j) => _DoorType(
        type: (j['type'] ?? 'Unspecified').toString(),
        sentCount: _i(j['sentCount']),
        wonCount: _i(j['wonCount']),
        lostCount: _i(j['lostCount']),
        revenue: _d(j['revenue']),
      );
}

enum _DoorView { winRate, revenue }

const _doorPalette = [
  DashUi.sky,
  DashUi.indigo,
  DashUi.emeraldDeep,
  DashUi.amber,
  DashUi.blue,
  Color(0xFF8B5CF6),
  Color(0xFF0D9488),
  Color(0xFFDB2777),
  Color(0xFF475569),
  Color(0xFF65A30D),
];

class _DoorSlice {
  final String label;
  final Color color;
  final int won;
  final int lost;
  final int sent;
  final double revenue;
  const _DoorSlice({
    required this.label,
    required this.color,
    required this.won,
    required this.lost,
    required this.sent,
    required this.revenue,
  });

  int get closed => won + lost;
  double get winRate => closed > 0 ? won / closed * 100 : 0;

  /// What the slice's size means in each view: deals won, or won revenue.
  double sizeFor(_DoorView v) => v == _DoorView.winRate ? won.toDouble() : revenue;
}

/// The top [limit] styles for [view], biggest first. Lines with no style ("Unspecified") are left out.
List<_DoorSlice> _doorSlices(List<_DoorType> allDoors, _DoorView view, int limit) {
  final doors = allDoors.where((d) => d.type != 'Unspecified').toList();

  // Colors follow revenue rank, so a style keeps its color in both views.
  final ranked = [...doors]..sort((a, b) => b.revenue.compareTo(a.revenue));
  Color colorOf(String type) {
    final i = ranked.indexWhere((d) => d.type == type);
    return _doorPalette[(i < 0 ? 0 : i) % _doorPalette.length];
  }

  final all = [
    for (final d in doors)
      _DoorSlice(label: d.type, color: colorOf(d.type), won: d.wonCount, lost: d.lostCount, sent: d.sentCount, revenue: d.revenue),
  ]..sort((a, b) {
      final c = b.sizeFor(view).compareTo(a.sizeFor(view));
      return c != 0 ? c : b.sent.compareTo(a.sent);
    });

  return all.take(limit).toList();
}
