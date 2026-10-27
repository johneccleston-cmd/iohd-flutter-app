import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'payroll_history_dialog.dart';
import 'payroll_run_dialog.dart';
import 'widgets/dashboard_data.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/dashboard_layout.dart';
import 'widgets/dashboard_panels.dart';

// The Commissions dashboard. Most of it follows the selected year; the retainage pool, the payroll card and the
// retainage release are about today, whatever year is shown.
//   scorecards  payouts, sales commission, retainage pool, average per recipient, commission % of revenue
//   left        everyone paid: paid this year, locked retainage, and (this year only) this pay week against the hurdle
//   right       paid (or revenue) by month, over two strips: payroll (is last week run, run it, the run history) and
//               the next retainage release
// The page fits the window without scrolling and without shrinking text (see _Grid).

String _money(double v) {
  final neg = v < 0;
  final s = v.abs().toStringAsFixed(2).replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+\.)'), (m) => '${m[1]},');
  return '${neg ? '-' : ''}\$$s';
}

/// "$781.74", "$750" (no cents when there are none).
String _moneyShort(double v) => _money(v).replaceAll('.00', '');

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
// SCREEN
// =============================================================================

class CommissionDashboardScreen extends StatelessWidget {
  const CommissionDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      title: 'Commissions',
      builder: (context, selectedYear) {
        return CommissionDashboardContent(selectedYear: selectedYear);
      },
    );
  }
}

class CommissionDashboardContent extends StatefulWidget {
  final int selectedYear;
  const CommissionDashboardContent({super.key, required this.selectedYear});

  @override
  State<CommissionDashboardContent> createState() => _CommissionDashboardContentState();
}

// =============================================================================
// MODELS
// =============================================================================

class _StaffCommissionProfile {
  final String id;
  final String name;
  final String jobTitle;
  final String imageUrl;

  /// In a sales role. Kept off the hurdle meters (sales reps have no weekly hurdle).
  final bool isSales;

  /// Receives pool commission, so their pay is shown and they count in the average. Everyone except sales-only reps:
  /// an install-rate rep (sales role, on the job pool) is on it.
  final bool onPool;
  final double commission;
  final double lockedRetainage;
  final int strikes;
  final double penalties;

  /// Gross for the current pay week, which the hurdle meters compare with the weekly hurdle.
  final double weekGross;

  /// Pay weeks in a row at or above the hurdle (the week in progress counts once cleared), and how many in total.
  final int hurdleStreak;
  final int hurdleWeeksHit;

  const _StaffCommissionProfile({
    required this.id,
    required this.name,
    required this.jobTitle,
    required this.imageUrl,
    required this.isSales,
    required this.onPool,
    required this.commission,
    required this.lockedRetainage,
    required this.strikes,
    required this.penalties,
    this.weekGross = 0,
    this.hurdleStreak = 0,
    this.hurdleWeeksHit = 0,
  });

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  factory _StaffCommissionProfile.fromJson(Map<String, dynamic> json) {
    return _StaffCommissionProfile(
      id: json['id']?.toString() ?? '0',
      name: (json['name'] ?? 'Unknown').toString(),
      jobTitle: (json['jobTitle'] ?? '').toString(),
      imageUrl: (json['imageUrl'] ?? '').toString(),
      isSales: json['isSales'] == true,
      // A server without the field: the old rule (non-sales people are the ones paid from the pool).
      onPool: json['onPool'] is bool ? json['onPool'] == true : json['isSales'] != true,
      commission: (json['ytdCommission'] as num?)?.toDouble() ?? 0.0,
      lockedRetainage: (json['lockedBalance'] as num?)?.toDouble() ?? 0.0,
      strikes: (json['strikes'] as num?)?.toInt() ?? 0,
      penalties: (json['totalPenalties'] as num?)?.toDouble() ?? 0.0,
      weekGross: (json['weekGross'] as num?)?.toDouble() ?? 0.0,
      hurdleStreak: (json['hurdleStreak'] as num?)?.toInt() ?? 0,
      hurdleWeeksHit: (json['hurdleWeeksHit'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Commission as a % of completed revenue, over the same finalized pay weeks since go-live (/commissions_stats
/// summary.commissionRate). The server sends null when there is no fair comparison yet, and then there is no card.
class _CommissionRate {
  final double pct;
  final double payouts;
  final double completedRevenue;
  final int completedJobs;
  final String from;
  final String to;

  /// One % per finalized week, oldest first (for the trend line once there are two).
  final List<double> weeklyPct;

  const _CommissionRate({
    required this.pct,
    required this.payouts,
    required this.completedRevenue,
    required this.completedJobs,
    required this.from,
    required this.to,
    required this.weeklyPct,
  });

  static _CommissionRate? fromJson(Object? json) {
    if (json is! Map) return null;
    final pct = (json['pct'] as num?)?.toDouble();
    final revenue = (json['completedRevenue'] as num?)?.toDouble() ?? 0;
    if (pct == null || !pct.isFinite || revenue <= 0) return null;
    final weeks = json['weeks'] is List ? json['weeks'] as List : const [];
    return _CommissionRate(
      pct: pct,
      payouts: (json['payouts'] as num?)?.toDouble() ?? 0,
      completedRevenue: revenue,
      completedJobs: (json['completedJobs'] as num?)?.toInt() ?? 0,
      from: json['from']?.toString() ?? '',
      to: json['to']?.toString() ?? '',
      weeklyPct: [
        for (final w in weeks)
          if (w is Map && ((w['completedRevenue'] as num?) ?? 0) > 0)
            ((w['payouts'] as num?) ?? 0) / (w['completedRevenue'] as num) * 100,
      ],
    );
  }
}

class _MonthlyPayoutPoint {
  final String month;
  final double payout;
  final double revenue;

  const _MonthlyPayoutPoint({required this.month, required this.payout, required this.revenue});

  factory _MonthlyPayoutPoint.fromJson(Map<String, dynamic> json) {
    return _MonthlyPayoutPoint(
      month: json['month']?.toString() ?? '',
      payout: (json['payout'] as num?)?.toDouble() ?? 0.0,
      revenue: (json['revenue'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

// =============================================================================
// DASHBOARD STATE
// =============================================================================

class _CommissionDashboardContentState extends State<CommissionDashboardContent> with DashboardLoading {
  List<_StaffCommissionProfile> _staff = [];
  List<_MonthlyPayoutPoint> _chartData = [];

  double _totalPayouts = 0;
  double _retainagePool = 0;

  /// Daily snapshots of the pool (oldest first) for its trend line; empty until there are a couple of days.
  List<double> _retainageHistory = [];

  /// Paid YTD to the people on the job pool ÷ how many of them there are (both counted over the same people).
  double _avgPerRecipient = 0;
  int _recipientCount = 0;

  /// null when there is no finalized pay week to compare: the card is left out rather than showing a misleading %.
  _CommissionRate? _rate;
  double _weeklyHurdle = 750;

  /// Sales rep commission on estimates won this year (a percent of labor on each).
  double _salesCommission = 0;
  double _nextDisbursement = 0;
  int _nextDisbursementTechs = 0;

  @override
  void initState() {
    super.initState();
    dashReload();
    payrollRunVersion.addListener(_onPayrollRun);
  }

  @override
  void dispose() {
    payrollRunVersion.removeListener(_onPayrollRun);
    super.dispose();
  }

  // A payroll run changes what counts as paid: reload past the server cache, keeping the figures on screen meanwhile.
  void _onPayrollRun() {
    if (mounted) dashReload(fresh: true);
  }

  @override
  void didUpdateWidget(covariant CommissionDashboardContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedYear != widget.selectedYear) dashReload();
  }

  @override
  Future<void> dashReload({bool fresh = false}) =>
      dashLoad('/api/commissions_stats', query: {'year': '${widget.selectedYear}'}, fresh: fresh, apply: _apply);

  void _apply(Map<String, dynamic> body) {
    final summary = (body['summary'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final List<dynamic> techsData = body['technicians'] ?? [];
    final List<dynamic> chartRaw = body['monthlyData'] ?? [];

    _totalPayouts = (summary['totalPayoutsYtd'] as num?)?.toDouble() ?? 0.0;
    _retainagePool = (summary['commercialRetainagePool'] as num?)?.toDouble() ?? 0.0;
    final hist = body['history'];
    _retainageHistory = [
      for (final v in (hist is Map ? (hist['retainagePool'] as List<dynamic>? ?? const []) : const <dynamic>[]))
        (v as num).toDouble(),
    ];
    _avgPerRecipient =
        ((summary['avgCommissionPerRecipient'] ?? summary['avgCommissionPerTech']) as num?)?.toDouble() ?? 0.0;
    _rate = _CommissionRate.fromJson(summary['commissionRate']);
    _weeklyHurdle = ((body['meta'] as Map?)?['weeklyThreshold'] as num?)?.toDouble() ?? 750;
    final sales = (summary['salesCommission'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    _salesCommission = (sales['total'] as num?)?.toDouble() ?? 0.0;
    final next = (summary['nextDisbursement'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    _nextDisbursement = (next['amount'] as num?)?.toDouble() ?? 0.0;
    _nextDisbursementTechs = (next['techCount'] as num?)?.toInt() ?? 0;

    _staff = techsData.map((e) => _StaffCommissionProfile.fromJson(e as Map<String, dynamic>)).toList();
    _recipientCount =
        ((body['meta'] as Map?)?['averageHeadcount'] as num?)?.toInt() ?? _staff.where((p) => p.onPool).length;
    _chartData = chartRaw.map((e) => _MonthlyPayoutPoint.fromJson(e as Map<String, dynamic>)).toList();
  }

  List<double>? _payoutTrend() =>
      _chartData.isEmpty ? null : dashTrend([for (final p in _chartData) p.payout], widget.selectedYear);

  @override
  Widget build(BuildContext context) {
    if (dashLoading) return const _CommissionSkeleton();
    if (dashFailure != null) {
      return DashErrorPanel.failure(dashFailure!, what: 'commissions', onRetry: dashReload);
    }

    final year = widget.selectedYear;
    final rate = _rate;
    final people = _recipientCount == 1 ? 'person' : 'people';
    final g = DashGeo.of(context);
    // The meters are for the CURRENT pay week, so they only show for the current year.
    final thisWeek = year == DashClock.now().year;

    // Each caption says what is counted and over what period. The % of revenue card only shows when the server
    // has a fair comparison (finalized pay weeks with completed revenue); otherwise the other four share the row.
    final tiles = <Widget>[
      AnimatedMetricCard(
        title: 'Total payouts',
        value: _totalPayouts,
        caption: 'Finalized runs · $year pay weeks',
        definition:
            'What finalized payroll runs paid out for pay weeks that start in $year (voided runs '
            'left out, adjustments netted). The line shows it by finished month.',
        index: 0,
        trend: _payoutTrend(),
        sparkMinWidth: dashSparkRoom(
          context,
          title: 'Total payouts',
          value: _money(_totalPayouts),
          caption: 'Finalized runs · $year pay weeks',
        ),
        valueColor: DashUi.emeraldDeep,
      ),
      AnimatedMetricCard(
        title: 'Sales commission',
        value: _salesCommission,
        caption: 'Earned by sales reps · $year',
        definition:
            'Commission sales reps earned on won estimates, counted in the pay week it falls due, for '
            "weeks in $year that have started. It doesn't wait for a finalized payroll run.",
        index: 1,
        valueColor: DashUi.amber,
      ),
      AnimatedMetricCard(
        title: 'Commercial retainage pool',
        value: _retainagePool,
        caption: 'Locked · all-time',
        definition:
            'Commercial retainage still locked, from jobs settled in a finalized payroll run. Not '
            'limited to $year. The line is one reading a day.',
        index: 2,
        trend: _retainageHistory.length >= 2 ? _retainageHistory : null,
        sparkMinWidth: dashSparkRoom(
          context,
          title: 'Commercial retainage pool',
          value: _money(_retainagePool),
          caption: 'Locked · all-time',
        ),
        valueColor: DashUi.indigo,
      ),
      AnimatedMetricCard(
        title: 'Avg commission per recipient',
        value: _avgPerRecipient,
        caption: 'Paid ÷ $_recipientCount on the job pool',
        definition:
            'What finalized payroll runs paid the $_recipientCount $people on the job pool in $year, '
            'divided by $_recipientCount. That is the technicians and anyone else paid from the pool, '
            'such as a sales rep with a pool cap. Sales reps paid only sales commission are in neither '
            'number.',
        index: 3,
        valueColor: DashUi.ink,
      ),
      if (rate != null)
        AnimatedMetricCard(
          title: 'Commission % of revenue',
          value: rate.pct,
          // Short enough to fit beside four other cards at 1280px; the full rule is in the definition.
          caption: 'Of completed revenue · ${dashDateRange(rate.from, rate.to)}',
          definition:
              'What finalized payroll runs paid for the pay weeks ${dashShortDate(rate.from)} to '
              '${dashShortDate(rate.to)} (${_money(rate.payouts)}), divided by the revenue of the '
              '${rate.completedJobs} jobs that closed in those same weeks (${_money(rate.completedRevenue)}). '
              'Only jobs started on or after Oct 5, 2026 count, as commission is only paid on them. '
              'A week counts once its payroll is finalized. The line is one point per week.',
          index: 4,
          valueColor: DashUi.sky,
          trend: rate.weeklyPct.length >= 2 ? rate.weeklyPct : null,
          sparkMinWidth: dashSparkRoom(
            context,
            title: 'Commission % of revenue',
            value: '${rate.pct.toStringAsFixed(1)}%',
            caption: 'Of completed revenue · ${dashDateRange(rate.from, rate.to)}',
          ),
          format: (v) => '${v.toStringAsFixed(1)}%',
        ),
    ];

    return _Grid(
      tiles: tiles,
      people: (layout) =>
          _PeoplePanel(g: g, staff: _staff, year: year, thisWeek: thisWeek, hurdle: _weeklyHurdle, layout: layout),
      peopleCount: _staff.length,
      chart: _PayoutChart(data: _chartData, year: year),
      payroll: _PayrollRunsCard(onChanged: () => dashReload(fresh: true)),
      release: QuarterlyPayoutCountdownCard(amount: _nextDisbursement, techCount: _nextDisbursementTechs),
      thisWeek: thisWeek,
    );
  }
}

// =============================================================================
// GRID (shared by the page and its skeleton)
// =============================================================================

/// How the people panel lays out its rows in the space the grid gives it.
class _PeopleLayout {
  /// Everyone's figures on one line under column headings, or each person on two lines (a narrow column).
  final bool oneLine;

  /// People that fit; the rest are a click away ("All 9").
  final int maxRows;

  /// The panel is given a height to fill (not in the one-column layout).
  final bool fill;
  const _PeopleLayout({required this.oneLine, required this.maxRows, required this.fill});
}

/// Lays the page out to fit the window:
///   two columns   scorecards; people | paid by month over payroll and the retainage release   (1280x600 and up)
///   one column    a window narrower than a desktop one: everything in one column that scrolls
class _Grid extends StatelessWidget {
  final List<Widget> tiles;
  final Widget Function(_PeopleLayout layout) people;
  final int peopleCount;
  final Widget chart;
  final Widget payroll;
  final Widget release;
  final bool thisWeek;

  const _Grid({
    required this.tiles,
    required this.people,
    required this.peopleCount,
    required this.chart,
    required this.payroll,
    required this.release,
    required this.thisWeek,
  });

  static const _twoColumnsFrom = 1100.0;

  /// The chart panel never gets shorter than this.
  static const _minChart = 200.0;

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final bodyH = c.maxHeight - g.tile - dashGap;
        final stripH = _StripGeo.height(g);
        final Widget content;
        if (w >= _twoColumnsFrom && bodyH - dashGap - stripH >= _minChart) {
          final peopleInner = (w - dashGap) * 11 / 23 - 40;
          final oneLine = peopleInner >= _PeoplePanel.oneLineWidth(g, thisWeek);
          final rowH = oneLine ? g.rowWide : _PeoplePanel.twoLineRow(g);
          final rowsH = bodyH - g.panelTop - (oneLine ? g.columnHead : 0);
          final maxRows = math.max(2, (rowsH / rowH).floor());
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
                      flex: 11,
                      child: people(_PeopleLayout(oneLine: oneLine, maxRows: maxRows, fill: true)),
                    ),
                    const SizedBox(width: dashGap),
                    Expanded(
                      flex: 12,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: chart),
                          const SizedBox(height: dashGap),
                          SizedBox(
                            height: stripH,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(flex: 6, child: payroll),
                                const SizedBox(width: dashGap),
                                Expanded(flex: 5, child: release),
                              ],
                            ),
                          ),
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
                SizedBox(height: g.tile, child: _tileRow(tiles.take(3).toList())),
                const SizedBox(height: dashGap),
                SizedBox(height: g.tile, child: _tileRow(tiles.skip(3).toList())),
                const SizedBox(height: dashGap),
                people(const _PeopleLayout(oneLine: false, maxRows: 999, fill: false)),
                const SizedBox(height: dashGap),
                SizedBox(height: 320, child: chart),
                const SizedBox(height: dashGap),
                SizedBox(height: stripH, child: payroll),
                const SizedBox(height: dashGap),
                SizedBox(height: stripH, child: release),
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
      for (var i = 0; i < row.length; i++) ...[if (i > 0) const SizedBox(width: 12), Expanded(child: row[i])],
    ],
  );
}

/// The two strips under the chart: a small label line over one bold line.
abstract final class _StripGeo {
  static double content(DashGeo g) => g.line(12.5) + 3 + g.line(15, 1.2) + 4;

  /// The +2 absorbs the half pixels text lines round up to.
  static double height(DashGeo g) => g.panelTop + content(g) + 2;
}

// =============================================================================
// PEOPLE (paid this year, locked retainage, this pay week against the hurdle)
// =============================================================================

/// The text scale and photo size every row of the People panel shares.
class _RowSize {
  final double f;
  final double photo;
  const _RowSize(this.f, this.photo);
}

class _PeoplePanel extends StatelessWidget {
  final DashGeo g;
  final List<_StaffCommissionProfile> staff;
  final int year;

  /// The current pay week's hurdle column (the current year only).
  final bool thisWeek;
  final double hurdle;
  final _PeopleLayout layout;
  const _PeoplePanel({
    required this.g,
    required this.staff,
    required this.year,
    required this.thisWeek,
    required this.hurdle,
    required this.layout,
  });

  // Column widths at 100% text (they grow with the text).
  static const _avatar = 28.0;
  static const _paidW = 86.0;
  static const _lockedW = 74.0;
  static const _weekAmountW = 22.0; // the check mark beside a cleared bar
  static const _flameW = 34.0;
  static const _barMin = 60.0;
  static const _nameW = 112.0;

  /// A two-line row: the name over the hurdle bar, whose streak flame stands 24 px tall (and the 1 px rule under it).
  static double twoLineRow(DashGeo g) => math.max(g.listRow, g.line(13.5) + 2 + 26 + 3);

  /// The inner width one-line rows need.
  static double oneLineWidth(DashGeo g, bool thisWeek) =>
      _avatar +
      10 +
      _nameW * g.k +
      12 +
      _paidW * g.k +
      12 +
      _lockedW * g.k +
      (thisWeek ? 14 + _barMin + 8 + _weekAmountW * g.k + _flameW : 0) +
      16;

  /// On the hurdle meters: everyone but sales reps (they have no weekly hurdle).
  bool _onHurdle(_StaffCommissionProfile p) => !p.isSales;

  @override
  Widget build(BuildContext context) {
    final techs = staff.where(_onHurdle).toList();
    final cleared = techs.where((p) => p.weekGross >= hurdle).length;
    final all = staff.length <= layout.maxRows;
    final shown = all ? staff : staff.take(math.max(1, layout.maxRows - 1)).toList();
    final rowH = layout.oneLine ? g.rowWide : twoLineRow(g);

    final header = DashPanelHeader(
      g: g,
      title: 'Commission by person',
      note: '$year',
      tooltip:
          'Everyone eligible for commission: what finalized payroll runs paid them for pay weeks in $year, the '
          'commercial retainage still locked for them (all-time)'
          '${thisWeek ? ', and their gross for the current pay week against the ${_moneyShort(hurdle)} weekly hurdle' : ''}.',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (thisWeek && techs.isNotEmpty)
            Text(
              '$cleared of ${techs.length} cleared',
              style: DashText.meta.copyWith(color: DashUi.emeraldText, fontWeight: FontWeight.w700),
            ),
          if (!all) ...[
            const SizedBox(width: 10),
            DashLink(
              text: 'All ${staff.length}',
              label: 'See all ${dashCount(staff.length, 'person')} paid commission',
              onTap: () => _openAll(context),
            ),
          ],
        ],
      ),
    );

    if (staff.isEmpty) {
      return DashPanel(
        fill: layout.fill,
        header: header,
        child: SizedBox(height: 2 * rowH, child: const DashEmptyNote('No one is set up for commission yet.')),
      );
    }

    final give = layout.fill ? 600.0 : (layout.oneLine ? 24.0 : 14.0);
    return DashPanel(
      fill: layout.fill,
      header: header,
      child: LayoutBuilder(
        builder: (context, c) {
          // One size for the headings and every row, so the columns line up under their labels.
          final area = c.maxHeight.isFinite ? c.maxHeight - (layout.oneLine ? g.columnHead : 0) : double.infinity;
          final h = area.isFinite ? (area / shown.length).clamp(rowH, rowH + give).toDouble() : rowH;
          final size = _RowSize(_scale(h, c.maxWidth), _photo(h));
          final rows = DashRows(count: shown.length, base: rowH, give: give, row: (i) => _row(shown[i], i, size));
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (layout.oneLine) _headings(size),
              if (layout.fill)
                Expanded(
                  child: Align(alignment: Alignment.topCenter, child: rows),
                )
              else
                rows,
            ],
          );
        },
      ),
    );
  }

  Widget _headings(_RowSize z) => ExcludeSemantics(
    child: SizedBox(
      height: g.columnHead,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            SizedBox(width: z.photo + 10),
            if (thisWeek)
              SizedBox(
                width: _nameW * g.k * z.f,
                child: const Text('Name', style: DashText.column),
              )
            else
              const Expanded(child: Text('Name', style: DashText.column)),
            const SizedBox(width: 12),
            SizedBox(
              width: _paidW * g.k * z.f,
              child: Text('Paid $year', textAlign: TextAlign.right, style: DashText.column),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: _lockedW * g.k * z.f,
              child: const Text('Locked', textAlign: TextAlign.right, style: DashText.column),
            ),
            if (thisWeek) ...[
              const SizedBox(width: 14),
              Expanded(
                child: Text('This week', maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.column),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  String _describe(_StaffCommissionProfile p) {
    final paid = p.onPool ? 'paid ${_money(p.commission)} in $year' : 'sales commission only';
    final week = !thisWeek || !_onHurdle(p)
        ? ''
        : p.weekGross >= hurdle
        ? '. This pay week ${_money(p.weekGross)}, ${_moneyShort(p.weekGross - hurdle)} over the '
              '${_moneyShort(hurdle)} hurdle'
        : '. This pay week ${_money(p.weekGross)} of the ${_moneyShort(hurdle)} hurdle';
    final streak = thisWeek && p.hurdleStreak > 0
        ? ', ${p.hurdleStreak} ${p.hurdleStreak == 1 ? 'week' : 'weeks'} in a row at or above it'
        : '';
    return '${p.name}: $paid, locked retainage ${_money(p.lockedRetainage)}$week$streak';
  }

  /// How much bigger than its base size a row's content grows when the panel has height to spare (the same few people
  /// then fill the card instead of leaving it blank). Held back by the width the one-line columns need.
  double _scale(double rowHeight, double width) {
    final base = layout.oneLine ? g.rowWide : twoLineRow(g);
    var f = (1 + (rowHeight / base - 1) * 0.6).clamp(1.0, 1.3).toDouble();
    if (layout.oneLine && width.isFinite) {
      final fixed = 16 + 10 + 24 + _photo(rowHeight) + (thisWeek ? 14 + _barMin + 8 + _flameW : 0);
      final scalable = (_nameW + _paidW + _lockedW + (thisWeek ? _weekAmountW : 0)) * g.k;
      f = math.min(f, math.max(1.0, (width - fixed) / scalable));
    }
    return f;
  }

  /// The photo is a square as tall as the row allows (less its rule and a little air).
  double _photo(double rowHeight) => (rowHeight - 10).clamp(_avatar, 64.0).toDouble();

  Widget _row(_StaffCommissionProfile p, int index, _RowSize z) => _rowAt(p, index, z.f, z.photo);

  Widget _rowAt(_StaffCommissionProfile p, int index, double f, double photo) {
    TextStyle big(TextStyle t) => t.copyWith(fontSize: (t.fontSize ?? 13.5) * f);
    final paidText = Text(
      // Anyone paid from the pool shows what they were paid, a sales rep on the pool included. Only sales-only reps
      // (no pool pay) show "Sales".
      p.onPool ? _money(p.commission) : 'Sales',
      textAlign: TextAlign.right,
      maxLines: 1,
      style: big(DashText.money).copyWith(color: p.onPool ? DashUi.emeraldText : DashUi.subtle),
    );
    final lockedText = Text(
      _money(p.lockedRetainage),
      textAlign: TextAlign.right,
      maxLines: 1,
      style: big(DashText.money).copyWith(color: p.lockedRetainage > 0 ? DashUi.indigo : DashUi.subtle),
    );
    final avatar = DashAvatar(
      name: p.name,
      imageUrl: p.imageUrl,
      size: photo,
      square: true,
      accent: DashUi.emeraldDeep,
    );
    final name = Tooltip(
      message: p.jobTitle.isEmpty ? p.name : '${p.name} · ${p.jobTitle}',
      waitDuration: const Duration(milliseconds: 600),
      child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: big(DashText.name)),
    );
    final week = thisWeek && _onHurdle(p)
        ? _HurdleMeter(person: p, hurdle: hurdle, index: index, g: g, scale: f)
        : null;

    final Widget body;
    if (layout.oneLine) {
      body = Row(
        children: [
          avatar,
          const SizedBox(width: 10),
          if (thisWeek) SizedBox(width: _nameW * g.k * f, child: name) else Expanded(child: name),
          const SizedBox(width: 12),
          SizedBox(width: _paidW * g.k * f, child: paidText),
          const SizedBox(width: 12),
          SizedBox(width: _lockedW * g.k * f, child: lockedText),
          if (thisWeek) ...[const SizedBox(width: 14), Expanded(child: week ?? const SizedBox.shrink())],
        ],
      );
    } else {
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
                    Expanded(child: name),
                    const SizedBox(width: 8),
                    paidText,
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Expanded(
                      child:
                          week ?? Text(p.jobTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.meta),
                    ),
                    const SizedBox(width: 10),
                    Text('Locked ', style: DashText.meta),
                    lockedText,
                  ],
                ),
              ],
            ),
          ),
        ],
      );
    }

    return DashPressable(
      onTap: null,
      label: _describe(p),
      radius: BorderRadius.circular(8),
      builder: (_) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          border: index == staff.length - 1 ? null : const Border(bottom: BorderSide(color: DashUi.faint)),
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
          constraints: BoxConstraints(maxWidth: 720, maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.86),
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
                        child: Text('Everyone paid commission · $year', style: DashText.panelTitle),
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
                      _PeoplePanel(
                        g: g,
                        staff: staff,
                        year: year,
                        thisWeek: thisWeek,
                        hurdle: hurdle,
                        layout: const _PeopleLayout(oneLine: false, maxRows: 999, fill: false),
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

/// One person's gross for the current pay week against the weekly hurdle: the bar fills in once (rows one after
/// another), turns green with a tick once cleared, and a flame shows the weeks in a row at or above it. Gross
/// includes the commercial retainage held that week (it counts toward the hurdle but is not paid).
class _HurdleMeter extends StatelessWidget {
  final _StaffCommissionProfile person;
  final double hurdle;
  final int index;
  final DashGeo g;
  final double scale;
  const _HurdleMeter({
    required this.person,
    required this.hurdle,
    required this.index,
    required this.g,
    this.scale = 1,
  });

  @override
  Widget build(BuildContext context) {
    final p = person;
    final h = hurdle <= 0 ? 1.0 : hurdle;
    final cleared = p.weekGross >= h;
    final color = cleared ? DashUi.emeraldDeep : DashUi.amber;
    final over = p.weekGross - h;
    return Tooltip(
      message: cleared
          ? '${_money(p.weekGross)} this pay week, ${_moneyShort(over)} over the ${_moneyShort(h)} hurdle'
          : '${_money(p.weekGross)} this pay week, ${_moneyShort(-over)} short of the ${_moneyShort(h)} hurdle',
      waitDuration: const Duration(milliseconds: 500),
      child: Row(
        children: [
          Expanded(
            child: DashBar(fraction: (p.weekGross / h).clamp(0.0, 1.0), color: color, height: 10 * scale),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: _PeoplePanel._weekAmountW * g.k * scale,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [if (cleared) Icon(Icons.check_circle_rounded, size: 14 * scale, color: color)],
            ),
          ),
          SizedBox(
            width: _PeoplePanel._flameW,
            child: p.hurdleStreak > 0
                ? Align(
                    alignment: Alignment.centerRight,
                    child: _StreakFlame(streak: p.hurdleStreak, weeksHit: p.hurdleWeeksHit),
                  )
                : null,
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// PAID BY MONTH
// =============================================================================

class _PayoutChart extends StatelessWidget {
  final List<_MonthlyPayoutPoint> data;
  final int year;
  const _PayoutChart({required this.data, required this.year});

  @override
  Widget build(BuildContext context) {
    List<double> pick(double Function(_MonthlyPayoutPoint) f) => [
      for (var i = 0; i < 12; i++) i < data.length ? f(data[i]) : 0.0,
    ];
    final payouts = pick((p) => p.payout);
    final revenue = pick((p) => p.revenue);

    DashChartView view({
      required String tab,
      required String title,
      required String what,
      required String row,
      required List<double> values,
      required Color color,
    }) {
      final withData = values.where((v) => v > 0).toList();
      final total = withData.fold<double>(0, (a, b) => a + b);
      // The average of the months that have something in them, as before.
      final avg = withData.isEmpty ? 0.0 : total / withData.length;
      return DashChartView(
        tab: tab,
        title: title,
        note: '${_compactMoney(total)} in $year',
        series: [DashSeries(row, values, color)],
        average: avg > 0 ? avg : null,
        averageLabel: avg > 0 ? 'Monthly average ${_compactMoney(avg)}' : null,
        axis: _compactMoney,
        barLabel: _compactMoney,
        badge: DashChangeChip.monthOverMonth(values, year, what: what),
        tip: (i) => [
          DashTipRow(row, _money(values[i]), color: color),
          if (values[i] > 0 && total > 0) DashTipRow('Share of year', '${(values[i] / total * 100).round()}%'),
          if (values[i] > 0 && avg > 0)
            DashTipRow(
              'Vs average',
              '${values[i] >= avg ? '+' : '-'}${((values[i] - avg).abs() / avg * 100).round()}%',
            ),
        ],
        summary: (last) =>
            '$title: ${[for (var i = 0; i <= last; i++) '${dashMonthNames[i]} ${_compactMoney(values[i])}'].join(', ')}',
        emptyText: 'Nothing recorded for $year yet.',
        semanticsLabel: '$title, $year',
      );
    }

    return DashMonthChart(
      year: year,
      views: [
        view(
          tab: 'Commissions',
          title: 'Paid by month',
          what: 'Commission paid',
          row: 'Disbursed',
          values: payouts,
          color: DashUi.emeraldDeep,
        ),
        view(
          tab: 'Revenue',
          title: 'Revenue by month',
          what: 'Revenue',
          row: 'Revenue',
          values: revenue,
          color: DashUi.sky,
        ),
      ],
    );
  }
}

/// A flickering flame with the number of weeks in a row a technician has hit the hurdle. The flame gets bigger and
/// hotter as the streak grows. Static when the system asks for reduced motion.
class _StreakFlame extends StatefulWidget {
  final int streak;
  final int weeksHit;
  const _StreakFlame({required this.streak, required this.weeksHit});

  @override
  State<_StreakFlame> createState() => _StreakFlameState();
}

class _StreakFlameState extends State<_StreakFlame> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduce) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
    final s = widget.streak;
    // 1-2 weeks: small; 3-5: medium; 6+: big and hot (the core goes white-yellow, the glow grows).
    final level = s >= 6 ? 2 : (s >= 3 ? 1 : 0);
    final h = 20.0 + level * 4;
    final w = 15.0 + level * 3;
    return Tooltip(
      message:
          '$s ${s == 1 ? 'week' : 'weeks'} in a row at or above the hurdle'
          '${widget.weeksHit > s ? ' · ${widget.weeksHit} weeks in total' : ''}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: w + 4,
            height: h + 4,
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) => CustomPaint(
                painter: _FlamePainter(t: reduce ? 0.25 : _c.value, level: level),
              ),
            ),
          ),
          const SizedBox(width: 2),
          Text(
            '$s',
            style: TextStyle(
              fontSize: 14 + level.toDouble(),
              fontWeight: FontWeight.w900,
              color: level == 2 ? const Color(0xFFDC2626) : const Color(0xFFEA580C),
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _FlamePainter extends CustomPainter {
  final double t; // 0..1, loops
  final int level; // 0..2
  const _FlamePainter({required this.t, required this.level});

  Path _flame(double w, double h, double sway, double inset) {
    final cx = w / 2;
    final left = w * inset;
    final right = w * (1 - inset);
    final top = h * (inset * 1.4);
    return Path()
      ..moveTo(cx, h)
      ..cubicTo(left - w * 0.15, h * 0.92, left, h * 0.45, cx + sway, top)
      ..cubicTo(right, h * 0.45, right + w * 0.15, h * 0.92, cx, h)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final bottom = h;
    final tau = math.pi * 2;
    final sway = math.sin(t * tau * 2) * w * 0.08;
    final flick = 1 + 0.07 * math.sin(t * tau * 3 + 1.3);

    // Soft glow behind the flame, stronger for longer streaks.
    canvas.drawCircle(
      Offset(w / 2, h * 0.62),
      w * (0.55 + 0.12 * level) * (1 + 0.08 * math.sin(t * tau * 2)),
      Paint()
        ..color = const Color(0xFFF97316).withValues(alpha: 0.16 + 0.1 * level)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 + 2.0 * level),
    );

    canvas.save();
    canvas.translate(0, bottom);
    canvas.scale(1, flick);
    canvas.translate(0, -bottom);

    final outer = _flame(w, h, sway, 0.06);
    canvas.drawPath(
      outer,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFDC2626), Color(0xFFF97316), Color(0xFFFBBF24)],
          stops: [0.0, 0.55, 1.0],
        ).createShader(Rect.fromLTWH(0, 0, w, h)),
    );

    // Inner core, a smaller flame that sways a little against the outer one.
    canvas.save();
    canvas.translate(w * 0.2, h * 0.34);
    canvas.scale(0.6, 0.64);
    canvas.drawPath(
      _flame(w, h, -sway * 0.8, 0.1),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [const Color(0xFFFDE68A), level == 2 ? Colors.white : const Color(0xFFFEF3C7)],
        ).createShader(Rect.fromLTWH(0, 0, w, h)),
    );
    canvas.restore();
    canvas.restore();

    // A few embers drifting up and fading.
    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1.0;
      final x = w * (0.35 + 0.3 * ((i * 0.37 + 0.13) % 1.0)) + math.sin((t + i) * tau) * 1.5;
      final y = h * (0.55 - 0.7 * p);
      canvas.drawCircle(
        Offset(x, y),
        1.1 + 0.4 * level,
        Paint()..color = const Color(0xFFFBBF24).withValues(alpha: (1 - p) * 0.9),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FlamePainter old) => old.t != t || old.level != level;
}

// =============================================================================
// PAYROLL
// =============================================================================

/// Payroll status: is the last completed pay week run yet, a button to run it, and the run history.
/// Commission totals on this page only count once a run is finalized, so this is where that happens.
class _PayrollRunsCard extends StatefulWidget {
  /// Called after a run is finalized or voided, so the dashboard numbers can reload.
  final VoidCallback onChanged;
  const _PayrollRunsCard({required this.onChanged});

  @override
  State<_PayrollRunsCard> createState() => _PayrollRunsCardState();
}

class _RunRow {
  final String weekStart;
  final String weekEnd;
  final String type;
  final String status;
  final String by;
  final double paid;

  _RunRow(Map<String, dynamic> j)
    : weekStart = '${j['week_start'] ?? ''}',
      weekEnd = '${j['week_end'] ?? ''}',
      type = '${j['run_type'] ?? ''}',
      status = '${j['status'] ?? ''}',
      by = '${j['run_by_name'] ?? ''}',
      paid = double.tryParse('${j['total_amount_paid'] ?? 0}') ?? 0;

  bool get voided => status == 'voided';
}

class _PayrollRunsCardState extends State<_PayrollRunsCard> {
  List<_RunRow> _runs = const [];
  bool _loading = true;
  String? _error;

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String _short(String ymd) {
    final p = ymd.split('-');
    if (p.length != 3) return ymd;
    return '${dashMonthNames[((int.tryParse(p[1]) ?? 1) - 1).clamp(0, 11)]} ${int.tryParse(p[2]) ?? 0}';
  }

  /// First pay week (commissions go live on this Monday, 2026-10-05).
  static final DateTime _firstWeek = DateTime(2026, 10, 5);

  /// Monday of the most recent pay week that is over, or the first pay week if none is over yet.
  DateTime get _lastWeek {
    final now = DashClock.now();
    final today = DateTime(now.year, now.month, now.day);
    final last = today.subtract(Duration(days: today.weekday - DateTime.monday + 7));
    return last.isBefore(_firstWeek) ? _firstWeek : last;
  }

  bool get _weekIsOver {
    final now = DashClock.now();
    final today = DateTime(now.year, now.month, now.day);
    return _lastWeek.add(const Duration(days: 7)).compareTo(today) <= 0;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await http
          .get(Uri.parse('$kApiBaseUrl/api/payroll/runs?limit=40'), headers: AuthSession.instance.headers())
          .timeout(const Duration(seconds: 30));
      if (res.statusCode == 401) {
        AuthSession.instance.logout();
        throw Exception('Your session ended. Sign in again to keep going.');
      }
      if (res.statusCode != 200) {
        throw Exception("Couldn't load the payroll runs (error ${res.statusCode}).");
      }
      final body = json.decode(res.body) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _runs = [for (final r in (body['runs'] as List? ?? const [])) _RunRow(Map<String, dynamic>.from(r as Map))];
        _loading = false;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _error = 'Loading the payroll runs took too long.';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is FormatException
            ? "Couldn't read the payroll runs."
            : e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  Future<void> _openRunDialog() async {
    await showPayrollRunDialog(
      context,
      initialDate: _lastWeek,
      onChanged: () {
        _load();
        widget.onChanged();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    final week = _lastWeek;
    final weekKey = _ymd(week);
    final weekEnd = _ymd(week.add(const Duration(days: 6)));
    final lastRuns = _runs.where((r) => r.weekStart == weekKey && !r.voided).toList();
    final paidLastWeek = lastRuns.fold<double>(0, (s, r) => s + r.paid);
    final done = lastRuns.isNotEmpty;
    final open = !_weekIsOver; // the first pay week is still running
    final latest = _runs.where((r) => !r.voided).firstOrNull;

    final header = DashPanelHeader(
      g: g,
      title: 'Payroll',
      tooltip: 'Commission on this page counts once a pay week has a finalized payroll run.',
      trailing: DashLink(
        text: 'Run history',
        label: 'Open the payroll run history',
        onTap: () => showPayrollHistoryDialog(context),
      ),
    );

    final Widget status;
    final Widget? action;
    if (_loading && _runs.isEmpty) {
      status = Align(
        alignment: Alignment.centerLeft,
        child: Text("Checking last week's payroll…", style: DashText.meta.copyWith(fontSize: 13)),
      );
      action = null;
    } else if (_error != null && _runs.isEmpty) {
      status = Align(
        alignment: Alignment.centerLeft,
        child: Text(_error!, maxLines: 2, overflow: TextOverflow.ellipsis, style: DashText.meta.copyWith(fontSize: 13)),
      );
      action = OutlinedButton(onPressed: _load, child: const Text('Try again'));
    } else {
      status = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Pay week ${_short(weekKey)} – ${_short(weekEnd)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: DashText.meta.copyWith(fontSize: 12.5),
          ),
          const SizedBox(height: 3),
          Tooltip(
            message: latest == null
                ? 'No payroll has been finalized yet.'
                : 'Latest run: ${_short(latest.weekStart)} – ${_short(latest.weekEnd)}, ${_money(latest.paid)}'
                      '${latest.by.isEmpty ? '' : ', run by ${latest.by}'}.',
            child: Text(
              done ? 'Paid ${_money(paidLastWeek)}' : (open ? 'Week in progress' : 'Not run yet'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                height: 1.2,
                fontWeight: FontWeight.w800,
                color: done ? DashUi.emeraldText : (open ? DashUi.slate : DashUi.amberText),
              ),
            ),
          ),
        ],
      );
      action = FilledButton.icon(
        onPressed: _openRunDialog,
        icon: const Icon(Icons.payments_outlined, size: 17),
        label: Text(done ? 'Review / adjust' : (open ? 'Preview payroll' : 'Run payroll')),
        style: FilledButton.styleFrom(
          backgroundColor: DashUi.ink,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }

    return DashPanel(
      header: header,
      child: SizedBox(
        height: _StripGeo.content(g),
        child: Row(
          children: [
            Expanded(child: status),
            if (action != null) ...[const SizedBox(width: 12), action],
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// NEXT RETAINAGE RELEASE (a countdown to the next quarter date)
// =============================================================================

class QuarterlyPayoutCountdownCard extends StatefulWidget {
  /// Retainage that will be released on the next quarter date, and how many techs receive it.
  final double amount;
  final int techCount;

  const QuarterlyPayoutCountdownCard({super.key, required this.amount, required this.techCount});

  @override
  State<QuarterlyPayoutCountdownCard> createState() => _QuarterlyPayoutCountdownCardState();
}

class _QuarterlyPayoutCountdownCardState extends State<QuarterlyPayoutCountdownCard> {
  late Timer _timer;
  late Duration _timeRemaining;
  late DateTime _previous;
  late DateTime _target;

  @override
  void initState() {
    super.initState();
    _calculateRemainingTime();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(_calculateRemainingTime);
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  /// Releases happen on Apr 1, Jul 1 and Oct 1. There is no January 1 release.
  void _calculateRemainingTime() {
    final now = DashClock.now();
    final dates = [
      for (final y in [now.year - 1, now.year, now.year + 1])
        for (final m in [4, 7, 10]) DateTime(y, m, 1),
    ];
    final next = dates.indexWhere((d) => d.isAfter(now));
    _target = dates[next];
    _previous = dates[next - 1];
    _timeRemaining = _target.difference(now);
  }

  /// How far through the stretch between the last quarter date and the next one we are, 0 to 1.
  double get _progress {
    final total = _target.difference(_previous).inSeconds;
    if (total <= 0) return 0;
    return (1 - _timeRemaining.inSeconds / total).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    final days = _timeRemaining.inDays;
    final hours = _timeRemaining.inHours % 24;
    final minutes = _timeRemaining.inMinutes % 60;
    final seconds = _timeRemaining.inSeconds % 60;
    final what = widget.amount > 0
        ? '${_money(widget.amount)} to ${widget.techCount} ${widget.techCount == 1 ? 'tech' : 'techs'}'
        : 'nothing scheduled';
    final date = '${dashMonthNames[_target.month - 1]} ${_target.day}';
    // Inside the last day the clock warms to amber: the release is about to happen.
    final accent = days == 0 ? DashUi.amber : DashUi.indigo;
    final calm = MediaQuery.disableAnimationsOf(context);

    return DashPanel(
      header: DashPanelHeader(
        g: g,
        title: 'Retainage release',
        note: date,
        tooltip: 'Locked retainage is released at the start of each quarter. Next: $date, $what.',
      ),
      // The clock's digits change every second. Kept out of text selection: a selectable whose text keeps changing
      // stops mouse selection from working elsewhere on the page (seen in Chrome).
      child: SelectionContainer.disabled(
        child: Semantics(
          label: 'Next retainage release $date, $what, in $days days and $hours hours',
          child: ExcludeSemantics(
            child: SizedBox(
              height: _StripGeo.content(g),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          flex: 2,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.amount > 0 ? _money(widget.amount) : 'Nothing scheduled',
                                  maxLines: 1,
                                  style: TextStyle(
                                    fontSize: widget.amount > 0 ? 17 : 13,
                                    height: 1.15,
                                    fontWeight: FontWeight.w800,
                                    color: widget.amount > 0 ? DashUi.ink : DashUi.subtle,
                                    fontFeatures: DashText.tabular,
                                  ),
                                ),
                                if (widget.amount > 0)
                                  Text(
                                    'to ${widget.techCount} ${widget.techCount == 1 ? 'tech' : 'techs'}',
                                    maxLines: 1,
                                    style: DashText.meta.copyWith(fontSize: 11.5, height: 1.2, color: DashUi.subtle),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          flex: 3,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _ClockChip(value: days, unit: 'd', color: accent, pad: false),
                                const SizedBox(width: 4),
                                _ClockChip(value: hours, unit: 'h', color: accent),
                                const SizedBox(width: 4),
                                _ClockChip(value: minutes, unit: 'm', color: accent),
                                const SizedBox(width: 4),
                                _ClockChip(value: seconds, unit: 's', color: accent, live: !calm),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  _QuarterBar(progress: _progress, color: accent, animate: !calm),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One unit of the countdown: a tinted tile with the digits big and the unit small. The seconds tile glows.
class _ClockChip extends StatelessWidget {
  final int value;
  final String unit;
  final Color color;
  final bool pad;
  final bool live;
  const _ClockChip({required this.value, required this.unit, required this.color, this.pad = true, this.live = false});

  @override
  Widget build(BuildContext context) {
    final digits = pad ? value.toString().padLeft(2, '0') : '$value';
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      constraints: const BoxConstraints(minWidth: 40),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: live ? 0.45 : 0.18)),
        boxShadow: live ? [BoxShadow(color: color.withValues(alpha: 0.22), blurRadius: 6)] : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, -0.35), end: Offset.zero).animate(anim),
                child: child,
              ),
            ),
            child: Text(
              digits,
              key: ValueKey(digits),
              style: TextStyle(
                fontSize: 17,
                height: 1.15,
                fontWeight: FontWeight.w800,
                color: color,
                fontFeatures: DashText.tabular,
              ),
            ),
          ),
          const SizedBox(width: 2),
          Text(
            unit,
            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color.withValues(alpha: 0.7)),
          ),
        ],
      ),
    );
  }
}

/// A thin track from the last quarter date to the next, filled to today, with a glowing head.
class _QuarterBar extends StatelessWidget {
  final double progress;
  final Color color;
  final bool animate;
  const _QuarterBar({required this.progress, required this.color, required this.animate});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: progress),
      duration: animate ? const Duration(milliseconds: 1200) : Duration.zero,
      curve: Curves.easeOutCubic,
      builder: (context, t, _) => SizedBox(
        height: 6,
        child: LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth * t;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: DashUi.line, borderRadius: BorderRadius.circular(3)),
                  ),
                ),
                Container(
                  width: w,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    gradient: LinearGradient(colors: [color.withValues(alpha: 0.35), color]),
                  ),
                ),
                Positioned(
                  left: math.max(0, w - 5),
                  top: -2,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      border: Border.all(color: color, width: 2),
                      boxShadow: [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 6)],
                    ),
                  ),
                ),
              ],
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

class _CommissionSkeleton extends StatelessWidget {
  const _CommissionSkeleton();

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    return Semantics(
      label: 'Loading commissions',
      child: ExcludeSemantics(
        child: SkeletonPulse(
          child: _Grid(
            tiles: List.generate(5, (_) => const DashSkeletonTile()),
            people: (layout) => DashSkeletonPanel(
              rows: math.min(5, layout.maxRows),
              rowH: layout.oneLine ? g.rowWide : _PeoplePanel.twoLineRow(g),
            ),
            peopleCount: 5,
            chart: const DashSkeletonPanel(fill: true),
            payroll: DashSkeletonPanel(rows: 1, rowH: _StripGeo.content(g) - 16),
            release: DashSkeletonPanel(rows: 1, rowH: _StripGeo.content(g) - 16),
            thisWeek: true,
          ),
        ),
      ),
    );
  }
}
