import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'payroll_run_dialog.dart';
import 'widgets/dashboard_layout.dart';

// =============================================================================
// DESIGN TOKENS
// =============================================================================

class _Ui {
  static const ink = Color(0xFF0F172A);
  static const slate = Color(0xFF475569);
  static const muted = Color(0xFF94A3B8);
  static const line = Color(0xFFE2E8F0);
  static const faint = Color(0xFFF1F5F9);

  static const emerald = Color(0xFF10B981);
  static const emeraldDeep = Color(0xFF059669);
  static const indigo = Color(0xFF6366F1);
  static const sky = Color(0xFF0284C7);
  static const amber = Color(0xFFD97706);

  static BoxDecoration panel({double radius = 16}) => BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: line),
  );
}

String _money(double v) {
  final neg = v < 0;
  final s = v
      .abs()
      .toStringAsFixed(2)
      .replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+\.)'), (m) => '${m[1]},');
  return '${neg ? '-' : ''}\$$s';
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
  State<CommissionDashboardContent> createState() =>
      _CommissionDashboardContentState();
}

// =============================================================================
// MODELS
// =============================================================================

class _StaffCommissionProfile {
  final String id;
  final String name;
  final String jobTitle;
  final String imageUrl;
  final bool isSales;
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
    required this.commission,
    required this.lockedRetainage,
    required this.strikes,
    required this.penalties,
    this.weekGross = 0,
    this.hurdleStreak = 0,
    this.hurdleWeeksHit = 0,
  });

  String get initials {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
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

class _MonthlyPayoutPoint {
  final String month;
  final double payout;
  final double revenue;

  const _MonthlyPayoutPoint({
    required this.month,
    required this.payout,
    required this.revenue,
  });

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

class _CommissionDashboardContentState
    extends State<CommissionDashboardContent> {
  bool _isLoading = true;
  String? _errorMessage;

  List<_StaffCommissionProfile> _staff = [];
  List<_MonthlyPayoutPoint> _chartData = [];

  double _totalPayouts = 0;
  double _retainagePool = 0;

  /// Daily snapshots of the pool (oldest first) for its trend line; empty until there are a couple of days.
  List<double> _retainageHistory = [];
  double _avgPerTech = 0;
  double _weeklyHurdle = 750;

  /// Sales rep commission on estimates won this year (a percent of labor on each).
  double _salesCommission = 0;
  double _nextDisbursement = 0;
  int _nextDisbursementTechs = 0;

  @override
  void initState() {
    super.initState();
    _fetchLiveCommissionData();
  }

  @override
  void didUpdateWidget(covariant CommissionDashboardContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedYear != widget.selectedYear) {
      _fetchLiveCommissionData();
    }
  }

  Future<void> _fetchLiveCommissionData({bool fresh = false}) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await http
          .get(
            Uri.parse(
              '$kApiBaseUrl/api/commissions_stats?year=${widget.selectedYear}${fresh ? '&fresh=1' : ''}',
            ),
            headers: AuthSession.instance.headers(),
          )
          .timeout(
            const Duration(seconds: 60),
          ); // free-tier hosts can take ~30s+ to wake up

      if (response.statusCode == 200) {
        final Map<String, dynamic> body = json.decode(response.body);
        final summary =
            (body['summary'] as Map<String, dynamic>?) ??
            const <String, dynamic>{};
        final List<dynamic> techsData = body['technicians'] ?? [];
        final List<dynamic> chartRaw = body['monthlyData'] ?? [];

        if (mounted) {
          setState(() {
            _totalPayouts =
                (summary['totalPayoutsYtd'] as num?)?.toDouble() ?? 0.0;
            _retainagePool =
                (summary['commercialRetainagePool'] as num?)?.toDouble() ?? 0.0;
            final hist = body['history'];
            _retainageHistory = [
              for (final v
                  in (hist is Map
                      ? (hist['retainagePool'] as List<dynamic>? ?? const [])
                      : const <dynamic>[]))
                (v as num).toDouble(),
            ];
            _avgPerTech =
                (summary['avgCommissionPerTech'] as num?)?.toDouble() ?? 0.0;
            _weeklyHurdle =
                ((body['meta'] as Map?)?['weeklyThreshold'] as num?)
                    ?.toDouble() ??
                750;
            final sales =
                (summary['salesCommission'] as Map<String, dynamic>?) ??
                const <String, dynamic>{};
            _salesCommission = (sales['total'] as num?)?.toDouble() ?? 0.0;
            final next =
                (summary['nextDisbursement'] as Map<String, dynamic>?) ??
                const <String, dynamic>{};
            _nextDisbursement = (next['amount'] as num?)?.toDouble() ?? 0.0;
            _nextDisbursementTechs = (next['techCount'] as num?)?.toInt() ?? 0;

            _staff = techsData
                .map(
                  (e) => _StaffCommissionProfile.fromJson(
                    e as Map<String, dynamic>,
                  ),
                )
                .toList();
            _chartData = chartRaw
                .map(
                  (e) =>
                      _MonthlyPayoutPoint.fromJson(e as Map<String, dynamic>),
                )
                .toList();

            _isLoading = false;
          });
        }
      } else {
        throw Exception('The server returned status ${response.statusCode}.');
      }
    } on TimeoutException {
      if (mounted) {
        setState(() {
          _errorMessage = 'The dashboard took too long to load.';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  /// Commission as a % of revenue, month by month, trimmed the same way as the payout trend.
  List<double>? _rateTrend() {
    if (_chartData.isEmpty) return null;
    final now = DateTime.now();
    final upTo = widget.selectedYear == now.year
        ? now.month
        : _chartData.length;
    final pts = _chartData
        .take(upTo)
        .map((p) => p.revenue > 0 ? p.payout / p.revenue * 100 : 0.0)
        .toList();
    final first = pts.indexWhere((v) => v > 0);
    final trimmed = first < 0 ? pts : pts.sublist(math.max(0, first - 1));
    return trimmed.length >= 2 ? trimmed : null;
  }

  List<double> _payoutTrend() {
    if (_chartData.isEmpty) return const [];
    final now = DateTime.now();
    final upTo = widget.selectedYear == now.year
        ? now.month
        : _chartData.length;
    final pts = _chartData.take(upTo).map((p) => p.payout).toList();
    final first = pts.indexWhere((v) => v > 0);
    if (first < 0) return pts;
    return pts.sublist(math.max(0, first - 1));
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const _DashboardSkeleton();

    if (_errorMessage != null) {
      return _ErrorPanel(
        message: _errorMessage!,
        onRetry: _fetchLiveCommissionData,
      );
    }

    // Effective rate uses the same monthly series as the chart so the two always agree.
    final chartPayout = _chartData.fold<double>(0, (s, p) => s + p.payout);
    final chartRevenue = _chartData.fold<double>(0, (s, p) => s + p.revenue);
    final commissionRate = chartRevenue > 0
        ? chartPayout / chartRevenue * 100
        : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 86,
          child: Row(
            children: [
              Expanded(
                child: _MetricCard(
                  title: 'Total payouts YTD',
                  amount: _totalPayouts,
                  index: 0,
                  trend: _payoutTrend(),
                  valueColor: _Ui.emeraldDeep,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _MetricCard(
                  title: 'Sales commission YTD',
                  amount: _salesCommission,
                  index: 1,
                  valueColor: _Ui.amber,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _MetricCard(
                  title: 'Commercial retainage pool',
                  amount: _retainagePool,
                  index: 2,
                  trend: _retainageHistory.length >= 2
                      ? _retainageHistory
                      : null,
                  valueColor: _Ui.indigo,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _MetricCard(
                  title: 'Average commission per tech',
                  amount: _avgPerTech,
                  index: 3,
                  valueColor: _Ui.ink,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _MetricCard(
                  title: 'Commission % of revenue',
                  amount: commissionRate,
                  index: 4,
                  valueColor: _Ui.sky,
                  trend: _rateTrend(),
                  format: (v) => '${v.toStringAsFixed(1)}%',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // --- ORIGINAL LEFT COLUMN: Stacked Staff Cards ---
              Expanded(
                flex: 3,
                child: Container(
                  padding: const EdgeInsets.all(12.0),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF0F172A).withValues(alpha: 0.03),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: _staff.isEmpty
                      ? const Center(
                          child: Text(
                            'No staff data available.',
                            style: TextStyle(color: Colors.grey, fontSize: 14),
                          ),
                        )
                      : Column(
                          children: [
                            for (int i = 0; i < _staff.length; i++) ...[
                              Expanded(
                                child: _buildStaffCard(_staff[i], i + 1),
                              ),
                              if (i < _staff.length - 1)
                                const SizedBox(height: 6),
                            ],
                          ],
                        ),
                ),
              ),

              const SizedBox(width: 16),

              // --- RIGHT COLUMN: Countdown + Interactive Chart ---
              Expanded(
                flex: 7,
                child: Column(
                  children: [
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            flex: 6,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  flex: 5,
                                  child: _InteractivePayoutChart(
                                    data: _chartData,
                                    staff: _staff,
                                    year: widget.selectedYear,
                                  ),
                                ),
                                // The meters are for the CURRENT pay week, so they only show for the current year.
                                if (widget.selectedYear ==
                                    DateTime.now().year) ...[
                                  const SizedBox(height: 12),
                                  Expanded(
                                    flex: 4,
                                    child: _HurdleMetersCard(
                                      staff: _staff,
                                      hurdle: _weeklyHurdle,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 4,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                QuarterlyPayoutCountdownCard(
                                  amount: _nextDisbursement,
                                  techCount: _nextDisbursementTechs,
                                ),
                                const SizedBox(height: 12),
                                Expanded(
                                  child: _PayrollRunsCard(
                                    onChanged: () =>
                                        _fetchLiveCommissionData(fresh: true),
                                  ),
                                ),
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
          ),
        ),
      ],
    );
  }

  // --- ORIGINAL STAFF CARD UI ---
  Widget _buildStaffCard(_StaffCommissionProfile person, int rank) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE2E8F0), width: 1),
      ),
      clipBehavior: Clip.hardEdge,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 72,
            child: Image.network(
              person.imageUrl.isNotEmpty
                  ? person.imageUrl
                  : 'https://ui-avatars.com/api/?name=${Uri.encodeQueryComponent(person.name)}&background=random',
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Container(
                color: const Color(0xFFE2E8F0),
                child: const Icon(
                  Icons.person,
                  color: Color(0xFF94A3B8),
                  size: 26,
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 12.0,
                vertical: 3.0,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          person.name,
                          style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1E293B),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (person.strikes > 0 || person.penalties != 0) ...[
                        const SizedBox(width: 8),
                        _StrikeChip(
                          strikes: person.strikes,
                          penalties: person.penalties,
                        ),
                      ],
                    ],
                  ),
                  const Divider(height: 1, color: Color(0xFFE2E8F0)),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'PAID YTD',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: Color(0xFF94A3B8),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        person.isSales ? 'Sales' : _money(person.commission),
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w900,
                          color: person.isSales
                              ? const Color(0xFF94A3B8)
                              : const Color(0xFF059669),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'LOCKED RETAINAGE',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: Color(0xFF94A3B8),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        _money(person.lockedRetainage),
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF6366F1),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StrikeChip extends StatelessWidget {
  final int strikes;
  final double penalties;
  const _StrikeChip({required this.strikes, required this.penalties});

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      if (strikes > 0) '$strikes ${strikes == 1 ? 'strike' : 'strikes'}',
      // The ledger stores callback deductions as negative amounts.
      if (penalties != 0) '-${_money(penalties.abs())}',
    ];
    return Tooltip(
      message: 'Callback strikes and retainage penalties this year',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF2F2),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFFECACA)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              size: 12,
              color: Color(0xFFDC2626),
            ),
            const SizedBox(width: 4),
            Text(
              parts.join(' · '),
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: Color(0xFFB91C1C),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// SCORECARD (Helper text removed)
// =============================================================================

class _MetricCard extends StatefulWidget {
  final String title;
  final double amount;
  final Color valueColor;
  final int index;
  final List<double>? trend;
  final String Function(double)? format;

  const _MetricCard({
    required this.title,
    required this.amount,
    required this.valueColor,
    required this.index,
    this.trend,
    this.format,
  });

  @override
  State<_MetricCard> createState() => _MetricCardState();
}

class _MetricCardState extends State<_MetricCard>
    with SingleTickerProviderStateMixin {
  static const _baseMs = 520;
  static const _staggerMs = 110;
  static const _countUpMs = 1100;
  static const _sparkDrawMs = 600;

  late final AnimationController _enter;
  late final Animation<double> _t;
  bool _hovering = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    final totalMs = _baseMs + widget.index * _staggerMs;
    _enter = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: totalMs),
    );
    _t = CurvedAnimation(
      parent: _enter,
      curve: Interval(
        widget.index * _staggerMs / totalMs,
        1.0,
        curve: Curves.easeOutCubic,
      ),
    );
    _enter.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.of(context).disableAnimations;
    if (_reduceMotion) _enter.value = 1;
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;

    final textColumn = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          w.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: _Ui.slate,
          ),
        ),
        const SizedBox(height: 6),
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: w.amount),
          duration: _reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: _countUpMs),
          curve: Curves.easeOutCubic,
          builder: (context, v, _) => FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              (w.format ?? _money)(v),
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                height: 1.1,
                color: w.valueColor,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ],
    );

    return FadeTransition(
      opacity: _t,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.12),
          end: Offset.zero,
        ).animate(_t),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            transform: Matrix4.translationValues(0, _hovering ? -2 : 0, 0),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _hovering
                    ? w.valueColor.withValues(alpha: 0.55)
                    : _Ui.line,
              ),
            ),
            child: LayoutBuilder(
              builder: (context, c) {
                final showSpark = w.trend != null && c.maxWidth > 250;
                return Row(
                  children: [
                    Expanded(child: textColumn),
                    if (showSpark) ...[
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 84,
                        height: 48,
                        child: TweenAnimationBuilder<double>(
                          tween: Tween<double>(begin: 0, end: 1),
                          duration: _reduceMotion
                              ? Duration.zero
                              : const Duration(
                                  milliseconds: _countUpMs + _sparkDrawMs,
                                ),
                          builder: (context, t, _) {
                            final progress =
                                ((t * (_countUpMs + _sparkDrawMs) -
                                            _countUpMs) /
                                        _sparkDrawMs)
                                    .clamp(0.0, 1.0);
                            return CustomPaint(
                              painter: _SparklinePainter(
                                values: w.trend!,
                                color: w.valueColor,
                                progress: progress,
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> values;
  final Color color;
  final double progress;

  const _SparklinePainter({
    required this.values,
    required this.color,
    required this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 5.0;
    final w = size.width - pad * 2;
    final h = size.height - pad * 2;
    final maxV = values.fold<double>(0, math.max);

    if (values.length < 2 || maxV <= 0) {
      final base = Paint()
        ..color = _Ui.line
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round;
      final y = size.height / 2;
      var x = pad;
      while (x < size.width - pad) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(x + 4, size.width - pad), y),
          base,
        );
        x += 8;
      }
      return;
    }

    final pts = <Offset>[
      for (var i = 0; i < values.length; i++)
        Offset(
          pad + w * i / (values.length - 1),
          pad + h * (1 - values[i] / maxV),
        ),
    ];

    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      final cx = (pts[i - 1].dx + pts[i].dx) / 2;
      path.cubicTo(cx, pts[i - 1].dy, cx, pts[i].dy, pts[i].dx, pts[i].dy);
    }

    final metric = path.computeMetrics().first;
    final len = metric.length;

    if (progress > 0) {
      canvas.drawPath(
        metric.extractPath(0, len * progress),
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );

      final head = metric.getTangentForOffset(len * progress);
      if (head != null) {
        if (progress >= 1) {
          canvas.drawCircle(
            head.position,
            6,
            Paint()..color = color.withValues(alpha: 0.18),
          );
        }
        canvas.drawCircle(head.position, 3.2, Paint()..color = color);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.values != values || old.color != color || old.progress != progress;
}

// =============================================================================
// LOADING + ERROR STATES
// =============================================================================

class _DashboardSkeleton extends StatefulWidget {
  const _DashboardSkeleton();

  @override
  State<_DashboardSkeleton> createState() => _DashboardSkeletonState();
}

class _DashboardSkeletonState extends State<_DashboardSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Widget _box({double? h, double? w, double r = 8}) => Container(
    height: h,
    width: w,
    decoration: BoxDecoration(
      color: _Ui.line,
      borderRadius: BorderRadius.circular(r),
    ),
  );

  Widget _metric() => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: _Ui.panel(radius: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _box(h: 12, w: 120),
          const SizedBox(height: 12),
          _box(h: 26, w: 170),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(
        begin: 0.45,
        end: 1,
      ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
      child: Column(
        children: [
          SizedBox(
            height: 104,
            child: Row(
              children: [
                _metric(),
                const SizedBox(width: 12),
                _metric(),
                const SizedBox(width: 12),
                _metric(),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 5,
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: _Ui.panel(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _box(h: 16, w: 110),
                        const SizedBox(height: 16),
                        Expanded(
                          child: ListView(
                            physics: const NeverScrollableScrollPhysics(),
                            children: [
                              for (var i = 0; i < 5; i++) ...[
                                _box(h: 96, r: 12),
                                const SizedBox(height: 8),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 7,
                  child: Column(
                    children: [
                      _box(h: 104, r: 16),
                      const SizedBox(height: 16),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(20),
                          decoration: _Ui.panel(),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _box(h: 12, w: 160),
                              const SizedBox(height: 10),
                              _box(h: 26, w: 120),
                              const SizedBox(height: 20),
                              Expanded(child: _box(r: 10)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorPanel({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 420,
        padding: const EdgeInsets.all(28),
        decoration: _Ui.panel(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 34, color: _Ui.muted),
            const SizedBox(height: 14),
            const Text(
              "Couldn't load commissions",
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: _Ui.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message.replaceFirst('Exception: ', ''),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13.5, color: _Ui.slate),
            ),
            const SizedBox(height: 4),
            const Text(
              'Check your connection, then try again.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: _Ui.muted),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Try again'),
              style: FilledButton.styleFrom(backgroundColor: _Ui.emeraldDeep),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// QUARTERLY PAYOUT COUNTDOWN CARD
// =============================================================================

class QuarterlyPayoutCountdownCard extends StatefulWidget {
  /// Retainage that will be released on the next quarter date, and how many techs receive it.
  final double amount;
  final int techCount;

  const QuarterlyPayoutCountdownCard({
    super.key,
    required this.amount,
    required this.techCount,
  });

  @override
  State<QuarterlyPayoutCountdownCard> createState() =>
      _QuarterlyPayoutCountdownCardState();
}

class _QuarterlyPayoutCountdownCardState
    extends State<QuarterlyPayoutCountdownCard> {
  late Timer _timer;
  late Duration _timeRemaining;
  late String _nextQuarterName;

  @override
  void initState() {
    super.initState();
    _calculateRemainingTime();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) _calculateRemainingTime();
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  void _calculateRemainingTime() {
    final now = DateTime.now();
    final year = now.year;

    final q1 = DateTime(year, 4, 1);
    final q2 = DateTime(year, 7, 1);
    final q3 = DateTime(year, 10, 1);
    final q4 = DateTime(year + 1, 1, 1);

    DateTime target;
    if (now.isBefore(q1)) {
      target = q1;
      _nextQuarterName = 'Q1 DISBURSEMENT';
    } else if (now.isBefore(q2)) {
      target = q2;
      _nextQuarterName = 'Q2 DISBURSEMENT';
    } else if (now.isBefore(q3)) {
      target = q3;
      _nextQuarterName = 'Q3 DISBURSEMENT';
    } else {
      target = q4;
      _nextQuarterName = 'Q4 DISBURSEMENT';
    }

    setState(() {
      _timeRemaining = target.difference(now);
    });
  }

  @override
  Widget build(BuildContext context) {
    final days = _timeRemaining.inDays;
    final hours = _timeRemaining.inHours % 24;
    final minutes = _timeRemaining.inMinutes % 60;
    final seconds = _timeRemaining.inSeconds % 60;

    // The next release on top, the clock underneath. Sits above the paid-by-technician card.
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0F172A), Color(0xFF1E293B)],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Color(0xFF10B981),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _nextQuarterName,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF10B981),
                  letterSpacing: 1.0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            widget.amount > 0
                ? 'Retainage release: ${_money(widget.amount)} to ${widget.techCount} ${widget.techCount == 1 ? 'tech' : 'techs'}'
                : 'Retainage release: nothing scheduled',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          // The clock's digits change every second. Kept out of text selection: a selectable whose text keeps
          // changing stops mouse selection from working elsewhere on the page (seen in Chrome).
          SelectionContainer.disabled(
            child: Row(
              children: [
                Expanded(
                  child: _clockUnit(days.toString().padLeft(2, '0'), 'd'),
                ),
                Expanded(
                  child: _clockUnit(hours.toString().padLeft(2, '0'), 'h'),
                ),
                Expanded(
                  child: _clockUnit(minutes.toString().padLeft(2, '0'), 'm'),
                ),
                Expanded(
                  child: _clockUnit(
                    seconds.toString().padLeft(2, '0'),
                    's',
                    isAccent: true,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _clockUnit(String val, String unit, {bool isAccent = false}) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        decoration: BoxDecoration(
          color: isAccent
              ? const Color(0xFF059669).withValues(alpha: 0.2)
              : const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: isAccent ? const Color(0xFF059669) : const Color(0xFF334155),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              val,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w900,
                color: isAccent ? const Color(0xFF34D399) : Colors.white,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 2),
            Text(
              unit,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Color(0xFF94A3B8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// INTERACTIVE PAYOUT CHART
// =============================================================================

enum _ChartMetric { payouts, revenue }

extension _ChartMetricX on _ChartMetric {
  bool get _isPayouts => this == _ChartMetric.payouts;

  String get toggleLabel => _isPayouts ? 'Commissions' : 'Revenue';
  String get caption => _isPayouts ? 'Paid by month' : 'Revenue by month';
  String get rowLabel => _isPayouts ? 'Disbursed' : 'Revenue';
  String get legendLabel => _isPayouts ? 'Monthly payout' : 'Monthly revenue';

  Color get accent => _isPayouts ? _Ui.emerald : _Ui.sky;
  Color get accentDeep =>
      _isPayouts ? _Ui.emeraldDeep : const Color(0xFF075985);
  Color get tint =>
      _isPayouts ? const Color(0xFFECFDF5) : const Color(0xFFF0F9FF);
  List<Color> get barColors => _isPayouts
      ? const [Color(0xFF059669), Color(0xFF10B981)]
      : const [Color(0xFF0369A1), Color(0xFF0284C7)];
  List<Color> get focusColors => _isPayouts
      ? const [Color(0xFF047857), Color(0xFF34D399)]
      : const [Color(0xFF075985), Color(0xFF38BDF8)];

  double valueOf(_MonthlyPayoutPoint p) => _isPayouts ? p.payout : p.revenue;

  String format(num v) {
    final a = v.abs();
    if (a >= 1000000) {
      return '\$${(v / 1000000).toStringAsFixed(1).replaceAll('.0', '')}M';
    }
    if (a >= 1000) {
      return '\$${(v / 1000).toStringAsFixed(1).replaceAll('.0', '')}k';
    }
    return '\$${v.round()}';
  }

  String axisFormat(num v) => format(v);
}

class _AxisScale {
  final double max;
  final double step;
  const _AxisScale(this.max, this.step);
  int get ticks => (max / step).round();
}

_AxisScale _niceScale(double maxV) {
  if (maxV <= 0) return const _AxisScale(10000, 2500);
  final raw = maxV / 4;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  final double nice = norm <= 1 ? 1 : (norm <= 2 ? 2 : (norm <= 5 ? 5 : 10));
  var step = nice * mag;
  var top = (maxV / step).ceil() * step;
  if (top < maxV * 1.08) top += step;
  return _AxisScale(top, step);
}

TextPainter _layoutText(
  String text,
  TextStyle style, {
  double maxWidth = double.infinity,
  TextAlign align = TextAlign.left,
}) {
  return TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textAlign: align,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: maxWidth);
}

class _InteractivePayoutChart extends StatefulWidget {
  final List<_MonthlyPayoutPoint> data;
  final List<_StaffCommissionProfile> staff;
  final int? year;

  const _InteractivePayoutChart({
    required this.data,
    required this.staff,
    this.year,
  });

  @override
  State<_InteractivePayoutChart> createState() =>
      _InteractivePayoutChartState();
}

class _InteractivePayoutChartState extends State<_InteractivePayoutChart>
    with TickerProviderStateMixin {
  late final AnimationController _intro;
  late final AnimationController _hover;

  _ChartMetric _metric = _ChartMetric.payouts;
  int? _active;
  int? _paintedIndex;

  Timer? _metricCycleTimer;
  bool _chartHovering = false;

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..forward();
    _hover = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
    );
    _restartMetricCycleTimer();
  }

  @override
  void didUpdateWidget(covariant _InteractivePayoutChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.data, widget.data)) {
      _active = null;
      _paintedIndex = null;
      _hover.value = 0;
      _intro.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _metricCycleTimer?.cancel();
    _intro.dispose();
    _hover.dispose();
    super.dispose();
  }

  void _restartMetricCycleTimer() {
    _metricCycleTimer?.cancel();
    _metricCycleTimer = Timer.periodic(
      const Duration(seconds: 9),
      (_) => _autoCycleMetric(),
    );
  }

  void _autoCycleMetric() {
    if (!mounted || _chartHovering) return;
    _setMetric(
      _metric == _ChartMetric.payouts
          ? _ChartMetric.revenue
          : _ChartMetric.payouts,
    );
  }

  void _setActive(int? i) {
    if (i == _active) return;
    setState(() {
      if (i != null) _paintedIndex = i;
      _active = i;
    });
    if (i != null) {
      _hover.forward();
    } else {
      _hover.reverse();
    }
  }

  void _setMetric(_ChartMetric m) {
    if (m == _metric) return;
    setState(() {
      _metric = m;
      _active = null;
      _paintedIndex = null;
    });
    _hover.value = 0;
    _intro.forward(from: 0);
  }

  int? _indexFor(double dx, double width) {
    final n = widget.data.length;
    if (n == 0) return null;
    final plotW = width - _PayoutChartPainter.leftGutter;
    if (plotW <= 0) return null;
    final i = ((dx - _PayoutChartPainter.leftGutter) / (plotW / n)).floor();
    if (i < 0 || i >= n) return null;
    return i;
  }

  double? _pct(double prev, double cur) =>
      prev > 0 ? (cur - prev) / prev * 100 : null;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;

    if (data.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20.0),
        decoration: _Ui.panel(),
        child: const Center(
          child: Text(
            'No chart data for this year yet.',
            style: TextStyle(
              color: _Ui.muted,
              fontWeight: FontWeight.w500,
              fontSize: 14,
            ),
          ),
        ),
      );
    }

    final withData = [
      for (var i = 0; i < data.length; i++)
        if (_metric.valueOf(data[i]) > 0) i,
    ];
    final values = withData.map((i) => _metric.valueOf(data[i])).toList();
    final sum = values.fold<double>(0, (a, b) => a + b);
    final avg = values.isEmpty ? 0.0 : sum / values.length;

    int? peakIndex;
    var peakValue = 0.0;
    for (final i in withData) {
      final v = _metric.valueOf(data[i]);
      if (v > peakValue) {
        peakValue = v;
        peakIndex = i;
      }
    }

    final maxV = data
        .map(_metric.valueOf)
        .fold<double>(0, (a, b) => math.max(a, b));
    final scale = _niceScale(maxV);

    double? trendPct;
    String? trendVs;
    if (withData.length >= 2) {
      final last = withData.last;
      final prev = withData[withData.length - 2];
      trendPct = _pct(_metric.valueOf(data[prev]), _metric.valueOf(data[last]));
      trendVs = data[prev].month;
    }

    final now = DateTime.now();
    final int? currentMonth = widget.year == now.year ? now.month - 1 : null;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      decoration: _Ui.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  _metric.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _Ui.slate,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _MetricToggle(value: _metric, onChanged: _setMetric),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 4,
            children: [
              Text(
                _metric.format(sum),
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: _Ui.ink,
                  height: 1.1,
                ),
              ),
              Text(
                'Total for ${widget.year}',
                style: const TextStyle(
                  fontSize: 13,
                  color: _Ui.muted,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (trendPct != null) _TrendChip(pct: trendPct, vs: trendVs!),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                return Stack(
                  children: [
                    Positioned.fill(
                      child: MouseRegion(
                        onEnter: (_) {
                          _chartHovering = true;
                          _metricCycleTimer?.cancel();
                        },
                        onHover: (e) => _setActive(
                          _indexFor(e.localPosition.dx, c.maxWidth),
                        ),
                        onExit: (_) {
                          _setActive(null);
                          _chartHovering = false;
                          _restartMetricCycleTimer();
                        },
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (d) => _setActive(
                            _indexFor(d.localPosition.dx, c.maxWidth),
                          ),
                          onHorizontalDragStart: (d) => _setActive(
                            _indexFor(d.localPosition.dx, c.maxWidth),
                          ),
                          onHorizontalDragUpdate: (d) => _setActive(
                            _indexFor(d.localPosition.dx, c.maxWidth),
                          ),
                          child: AnimatedBuilder(
                            animation: Listenable.merge([_intro, _hover]),
                            builder: (context, _) {
                              return CustomPaint(
                                size: Size.infinite,
                                painter: _PayoutChartPainter(
                                  data: data,
                                  metric: _metric,
                                  scale: scale,
                                  average: avg,
                                  total: sum,
                                  peakIndex: peakIndex,
                                  currentMonth: currentMonth,
                                  index: _paintedIndex,
                                  intro: _intro.value,
                                  hover: Curves.easeOutCubic.transform(
                                    _hover.value,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                    if (sum <= 0)
                      IgnorePointer(
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 28),
                            child: Text(
                              'Nothing recorded for ${widget.year} yet.',
                              style: const TextStyle(
                                fontSize: 14,
                                color: _Ui.muted,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _legendItem(
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: _metric.barColors,
                    ),
                  ),
                ),
                _metric.legendLabel,
              ),
              const SizedBox(width: 20),
              if (avg > 0)
                _legendItem(
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(
                      3,
                      (i) => Container(
                        width: 4,
                        height: 2.5,
                        margin: EdgeInsets.only(right: i == 2 ? 0 : 2),
                        color: _metric.accent,
                      ),
                    ),
                  ),
                  'Monthly average (${_metric.format(avg)})',
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _legendItem(Widget swatch, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        swatch,
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: _Ui.slate,
          ),
        ),
      ],
    );
  }
}

/// Hurdle meters: each technician's gross for the current pay week against the weekly hurdle. Bars fill in one after
/// another, the numbers count up, and a bar that has cleared the hurdle turns green, glows and gets a light sweep.
/// Gross includes the commercial retainage held that week (it counts toward the hurdle but is not paid).
class _HurdleMetersCard extends StatefulWidget {
  final List<_StaffCommissionProfile> staff;
  final double hurdle;
  const _HurdleMetersCard({required this.staff, required this.hurdle});

  @override
  State<_HurdleMetersCard> createState() => _HurdleMetersCardState();
}

class _HurdleMetersCardState extends State<_HurdleMetersCard>
    with TickerProviderStateMixin {
  late final AnimationController _intro;
  late final AnimationController _sweep;
  String _sig = '';

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    _sweep = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3400),
    );
    _sig = _signature();
    _intro.forward();
    _sweep.repeat();
  }

  String _signature() => widget.staff
      .where((p) => !p.isSales)
      .map((p) => '${p.id}:${p.weekGross.toStringAsFixed(2)}')
      .join('|');

  @override
  void didUpdateWidget(covariant _HurdleMetersCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final now = _signature();
    if (now != _sig) {
      _sig = now;
      _intro.forward(from: 0); // new numbers: play the fill again
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    _sweep.dispose();
    super.dispose();
  }

  static const double _rowH = 34;

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduce) {
      _intro.value = 1;
      _sweep.stop();
    }
    final techs = widget.staff.where((p) => !p.isSales).toList()
      ..sort((a, b) => b.weekGross.compareTo(a.weekGross));
    final cleared = techs.where((p) => p.weekGross >= widget.hurdle).length;

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
      decoration: _Ui.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Weekly hurdle',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _Ui.slate,
                  ),
                ),
              ),
              Text(
                techs.isEmpty ? '' : '$cleared of ${techs.length} cleared',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: _Ui.emeraldDeep,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: techs.isEmpty
                ? const Center(
                    child: Text(
                      'No technicians to show.',
                      style: TextStyle(color: _Ui.muted, fontSize: 13),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, box) {
                      final fit = (box.maxHeight / _rowH).floor().clamp(1, 99);
                      final needMore = techs.length > fit;
                      final visible = needMore
                          ? math.max(1, fit - 1)
                          : techs.length;
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (var i = 0; i < visible; i++)
                            SizedBox(
                              height: _rowH,
                              child: _meterRow(techs[i], i, techs.length),
                            ),
                          if (needMore)
                            SizedBox(
                              height: _rowH,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  '+${techs.length - visible} more',
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    color: _Ui.muted,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _meterRow(_StaffCommissionProfile p, int index, int count) {
    final hurdle = widget.hurdle <= 0 ? 1.0 : widget.hurdle;
    final target = (p.weekGross / hurdle).clamp(0.0, 1.0);
    final isCleared = p.weekGross >= hurdle;
    // Rows start one after another: each gets its own slice of the intro animation.
    final start = (index * 0.09).clamp(0.0, 0.5);
    final curve = CurvedAnimation(
      parent: _intro,
      curve: Interval(
        start,
        math.min(1.0, start + 0.55),
        curve: Curves.easeOutCubic,
      ),
    );

    return AnimatedBuilder(
      // Only the intro drives the row. The light sweep has its own builder below, so the text is not rebuilt
      // every frame (that would keep clearing a mouse selection of the names and amounts).
      animation: curve,
      builder: (context, _) {
        final t = curve.value;
        final fill = target * t;
        final shown = p.weekGross * t;
        final accent = isCleared ? _Ui.emeraldDeep : _Ui.amber;
        return Row(
          children: [
            SizedBox(
              width: 116,
              child: Text(
                p.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: _Ui.ink,
                ),
              ),
            ),
            // A fixed slot so the bars line up whether or not someone has a streak.
            SizedBox(
              width: 48,
              child: p.hurdleStreak > 0
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: _StreakFlame(
                        streak: p.hurdleStreak,
                        weeksHit: p.hurdleWeeksHit,
                      ),
                    )
                  : null,
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) {
                  final w = c.maxWidth;
                  return SizedBox(
                    height: 16,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            color: _Ui.faint,
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        if (fill > 0)
                          Container(
                            width: math.max(10.0, w * fill),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              gradient: LinearGradient(
                                colors: isCleared
                                    ? const [
                                        Color(0xFF059669),
                                        Color(0xFF34D399),
                                      ]
                                    : const [
                                        Color(0xFFF59E0B),
                                        Color(0xFFD97706),
                                      ],
                              ),
                              boxShadow: isCleared && t >= 1
                                  ? [
                                      BoxShadow(
                                        color: _Ui.emerald.withValues(
                                          alpha: 0.35,
                                        ),
                                        blurRadius: 8,
                                        spreadRadius: 0.5,
                                      ),
                                    ]
                                  : null,
                            ),
                            child: isCleared && t >= 1
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: AnimatedBuilder(
                                      animation: _sweep,
                                      builder: (context, _) =>
                                          FractionallySizedBox(
                                            alignment: Alignment(
                                              -1.6 + 3.2 * _sweep.value,
                                              0,
                                            ),
                                            widthFactor: 0.28,
                                            child: Container(
                                              decoration: BoxDecoration(
                                                gradient: LinearGradient(
                                                  colors: [
                                                    Colors.white.withValues(
                                                      alpha: 0,
                                                    ),
                                                    Colors.white.withValues(
                                                      alpha: 0.45,
                                                    ),
                                                    Colors.white.withValues(
                                                      alpha: 0,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                    ),
                                  )
                                : null,
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
            SizedBox(
              width: 128,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (isCleared) ...[
                    Icon(Icons.check_circle_rounded, size: 15, color: accent),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    _money(shown).replaceAll('.00', ''),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: isCleared ? _Ui.emeraldDeep : _Ui.ink,
                    ),
                  ),
                  Text(
                    isCleared
                        ? '  +${_money(math.max(0, (p.weekGross - hurdle) * t)).replaceAll('.00', '')}'
                        : ' / ${_money(hurdle).replaceAll('.00', '')}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isCleared ? _Ui.emeraldDeep : _Ui.muted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
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

class _StreakFlameState extends State<_StreakFlame>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
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
                painter: _FlamePainter(
                  t: reduce ? 0.25 : _c.value,
                  level: level,
                ),
              ),
            ),
          ),
          const SizedBox(width: 2),
          Text(
            '$s',
            style: TextStyle(
              fontSize: 14 + level.toDouble(),
              fontWeight: FontWeight.w900,
              color: level == 2
                  ? const Color(0xFFDC2626)
                  : const Color(0xFFEA580C),
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
          colors: [
            const Color(0xFFFDE68A),
            level == 2 ? Colors.white : const Color(0xFFFEF3C7),
          ],
        ).createShader(Rect.fromLTWH(0, 0, w, h)),
    );
    canvas.restore();
    canvas.restore();

    // A few embers drifting up and fading.
    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1.0;
      final x =
          w * (0.35 + 0.3 * ((i * 0.37 + 0.13) % 1.0)) +
          math.sin((t + i) * tau) * 1.5;
      final y = h * (0.55 - 0.7 * p);
      canvas.drawCircle(
        Offset(x, y),
        1.1 + 0.4 * level,
        Paint()
          ..color = const Color(0xFFFBBF24).withValues(alpha: (1 - p) * 0.9),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FlamePainter old) =>
      old.t != t || old.level != level;
}

/// Payroll status: is the last completed pay week run yet, a button to run it, and the recent runs.
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
  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  static String _short(String ymd) {
    final p = ymd.split('-');
    if (p.length != 3) return ymd;
    return '${_months[(int.tryParse(p[1]) ?? 1) - 1]} ${int.tryParse(p[2]) ?? 0}';
  }

  /// First pay week (commissions go live on this Monday, 2026-10-05).
  static final DateTime _firstWeek = DateTime(2026, 10, 5);

  /// Monday of the most recent pay week that is over, or the first pay week if none is over yet.
  DateTime get _lastWeek {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final last = today.subtract(
      Duration(days: today.weekday - DateTime.monday + 7),
    );
    return last.isBefore(_firstWeek) ? _firstWeek : last;
  }

  bool get _weekIsOver {
    final now = DateTime.now();
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
          .get(
            Uri.parse('$kApiBaseUrl/api/payroll/runs?limit=40'),
            headers: AuthSession.instance.headers(),
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode == 401) {
        AuthSession.instance.logout();
        throw Exception('Your session expired. Please sign in again.');
      }
      if (res.statusCode != 200) {
        throw Exception('The server returned status ${res.statusCode}.');
      }
      final body = json.decode(res.body) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _runs = [
          for (final r in (body['runs'] as List? ?? const []))
            _RunRow(Map<String, dynamic>.from(r as Map)),
        ];
        _loading = false;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _error = 'Took too long to load.';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
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
    final week = _lastWeek;
    final weekKey = _ymd(week);
    final weekEnd = _ymd(week.add(const Duration(days: 6)));
    final lastRuns = _runs
        .where((r) => r.weekStart == weekKey && !r.voided)
        .toList();
    final paidLastWeek = lastRuns.fold<double>(0, (s, r) => s + r.paid);
    final done = lastRuns.isNotEmpty;
    final open = !_weekIsOver; // the first pay week is still running

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
      decoration: _Ui.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Payroll',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: _Ui.slate,
            ),
          ),
          const SizedBox(height: 10),
          if (_loading && _runs.isEmpty)
            const Expanded(
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (_error != null && _runs.isEmpty)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: _Ui.muted, fontSize: 13),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: _load,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: done
                    ? const Color(0xFFECFDF5)
                    : (open ? _Ui.faint : const Color(0xFFFFFBEB)),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: done
                      ? const Color(0xFFA7F3D0)
                      : (open ? _Ui.line : const Color(0xFFFDE68A)),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Pay week ${_short(weekKey)} – ${_short(weekEnd)}',
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: _Ui.slate,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    done
                        ? 'Paid ${_money(paidLastWeek)}'
                        : (open ? 'Week in progress' : 'Not run yet'),
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: done
                          ? _Ui.emeraldDeep
                          : (open ? _Ui.slate : _Ui.amber),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _openRunDialog,
                      icon: const Icon(Icons.payments_outlined, size: 18),
                      label: Text(
                        done
                            ? 'Review / adjust'
                            : (open ? 'Preview payroll' : 'Run payroll'),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: _Ui.ink,
                        minimumSize: const Size(0, 40),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Recent runs',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: _Ui.slate,
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: _runs.isEmpty
                  ? const Align(
                      alignment: Alignment.topLeft,
                      child: Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text(
                          'No payroll has been finalized yet.',
                          style: TextStyle(color: _Ui.muted, fontSize: 13),
                        ),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, box) {
                        const rowH = 34.0;
                        final fit = (box.maxHeight / rowH).floor().clamp(1, 99);
                        final shown = math.min(_runs.length, fit);
                        return Column(
                          children: [
                            for (var i = 0; i < shown; i++)
                              SizedBox(height: rowH, child: _runLine(_runs[i])),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _runLine(_RunRow r) {
    final muted = r.voided;
    return Row(
      children: [
        Expanded(
          child: Text(
            '${_short(r.weekStart)} – ${_short(r.weekEnd)}'
            '${r.type == 'adjustment' ? '  ·  adjustment' : ''}'
            '${r.voided ? '  ·  voided' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: muted ? _Ui.muted : _Ui.ink,
              decoration: muted ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
        Text(
          _money(r.paid),
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: muted ? _Ui.muted : _Ui.ink,
          ),
        ),
      ],
    );
  }
}

class _TrendChip extends StatelessWidget {
  final double pct;
  final String vs;
  const _TrendChip({required this.pct, required this.vs});

  @override
  Widget build(BuildContext context) {
    final up = pct >= 0;
    final fg = up ? const Color(0xFF047857) : const Color(0xFFB91C1C);
    final bg = up ? const Color(0xFFECFDF5) : const Color(0xFFFEF2F2);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
            size: 14,
            color: fg,
          ),
          const SizedBox(width: 2),
          Text(
            '${pct.abs().toStringAsFixed(1)}% vs $vs',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricToggle extends StatelessWidget {
  final _ChartMetric value;
  final ValueChanged<_ChartMetric> onChanged;
  const _MetricToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _Ui.faint,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: _ChartMetric.values.map((m) {
          final selected = m == value;
          return GestureDetector(
            onTap: () => onChanged(m),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: selected ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected ? _Ui.line : Colors.transparent,
                ),
              ),
              child: Text(
                m.toggleLabel,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: selected ? m.accentDeep : _Ui.slate,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _TipRow {
  final String label;
  final String value;
  final Color valueColor;
  const _TipRow(this.label, this.value, this.valueColor);
}

class _PayoutChartPainter extends CustomPainter {
  static const double leftGutter = 52;
  static const double bottomGutter = 32;
  static const double topPad = 6;

  final List<_MonthlyPayoutPoint> data;
  final _ChartMetric metric;
  final _AxisScale scale;
  final double average;
  final double total;
  final int? peakIndex;
  final int? currentMonth;
  final int? index;
  final double intro;
  final double hover;

  const _PayoutChartPainter({
    required this.data,
    required this.metric,
    required this.scale,
    required this.average,
    required this.total,
    required this.peakIndex,
    required this.currentMonth,
    required this.index,
    required this.intro,
    required this.hover,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(
      leftGutter,
      topPad,
      size.width,
      size.height - bottomGutter,
    );
    if (plot.width <= 0 || plot.height <= 0 || data.isEmpty) return;

    final n = data.length;
    final slotW = plot.width / n;
    final focusing = index != null && hover > 0.001;

    double yFor(double v) =>
        plot.bottom - (v / scale.max).clamp(0.0, 1.0) * plot.height;

    if (focusing) {
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          plot.left + index! * slotW + 2,
          plot.top,
          slotW - 4,
          plot.height,
        ),
        const Radius.circular(10),
      );
      canvas.drawRRect(
        r,
        Paint()..color = metric.tint.withValues(alpha: hover),
      );
    }

    final ticks = scale.ticks;
    for (var i = 0; i <= ticks; i++) {
      final v = i * scale.step;
      final y = yFor(v);
      canvas.drawLine(
        Offset(plot.left, y),
        Offset(plot.right, y),
        Paint()
          ..color = i == 0 ? _Ui.line : _Ui.faint
          ..strokeWidth = 1,
      );
      final tp = _layoutText(
        metric.axisFormat(v),
        const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: _Ui.muted,
        ),
      );
      tp.paint(canvas, Offset(leftGutter - 8 - tp.width, y - tp.height / 2));
    }

    final stagger = 0.4 / n;
    for (var i = 0; i < n; i++) {
      final p = data[i];
      final v = metric.valueOf(p);
      final isFocus = focusing && index == i;
      final isCurrent = currentMonth == i;
      final dim = (focusing && !isFocus) ? 1 - 0.5 * hover : 1.0;

      final cx = plot.left + slotW * (i + 0.5);
      final baseW = math.min(slotW * 0.58, 36.0);
      final barW = baseW + (isFocus ? 4 * hover : 0);

      final localT = Curves.easeOutCubic.transform(
        ((intro - i * stagger) / 0.6).clamp(0.0, 1.0),
      );
      final fullH = (v / scale.max).clamp(0.0, 1.0) * plot.height;

      final emphasized = isFocus || isCurrent;
      final labelTp = _layoutText(
        p.month,
        TextStyle(
          fontSize: 13,
          fontWeight: emphasized ? FontWeight.w800 : FontWeight.w600,
          color: emphasized
              ? _Ui.ink
              : (v > 0 ? _Ui.slate : const Color(0xFFCBD5E1)),
        ),
        maxWidth: slotW,
        align: TextAlign.center,
      );
      labelTp.paint(canvas, Offset(cx - labelTp.width / 2, plot.bottom + 8));

      // A short underline marks the current month.
      if (isCurrent) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(cx, plot.bottom + 8 + labelTp.height + 4),
              width: 14,
              height: 3,
            ),
            const Radius.circular(2),
          ),
          Paint()..color = metric.accent,
        );
      }

      if (v <= 0) {
        final stub = RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(cx, plot.bottom - 1.5),
            width: baseW * 0.6,
            height: 3,
          ),
          const Radius.circular(2),
        );
        canvas.drawRRect(stub, Paint()..color = _Ui.line);
        continue;
      }

      final h = math.max(3.0, fullH * localT);
      final rect = Rect.fromLTWH(cx - barW / 2, plot.bottom - h, barW, h);
      final topR = Radius.circular(math.min(8, barW / 2));
      final rrect = RRect.fromRectAndCorners(
        rect,
        topLeft: topR,
        topRight: topR,
        bottomLeft: const Radius.circular(2),
        bottomRight: const Radius.circular(2),
      );

      if (isFocus) {
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = metric.accent.withValues(alpha: 0.35 * hover)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
        );
      }

      final colors = isFocus ? metric.focusColors : metric.barColors;
      canvas.drawRRect(
        rrect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: colors.map((c) => c.withValues(alpha: dim)).toList(),
          ).createShader(rect),
      );

      // Label the tallest bar so the best month reads without hovering.
      if (peakIndex == i && !isFocus && localT >= 1) {
        final tp = _layoutText(
          metric.format(v),
          TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w800,
            color: metric.accentDeep.withValues(alpha: dim),
          ),
        );
        final ly = rect.top - tp.height - 4;
        if (ly >= 0) tp.paint(canvas, Offset(cx - tp.width / 2, ly));
      }
    }

    if (average > 0 && average <= scale.max) {
      final y = yFor(average);
      final paint = Paint()
        ..color = metric.accent.withValues(alpha: 0.9 * intro)
        ..strokeWidth = 1.3
        ..strokeCap = StrokeCap.round;
      var x = plot.left;
      while (x < plot.right) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(x + 5, plot.right), y),
          paint,
        );
        x += 9;
      }

      final avgTp = _layoutText(
        'avg ${metric.format(average)}',
        TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: metric.accentDeep.withValues(alpha: intro),
        ),
      );
      avgTp.paint(
        canvas,
        Offset(plot.right - avgTp.width - 4, y - avgTp.height - 3),
      );
    }

    if (focusing) _paintTooltip(canvas, size, plot, slotW, yFor);
  }

  void _paintTooltip(
    Canvas canvas,
    Size size,
    Rect plot,
    double slotW,
    double Function(double) yFor,
  ) {
    final i = index!;
    final p = data[i];
    final v = metric.valueOf(p);

    final rows = <_TipRow>[
      _TipRow(metric.rowLabel, metric.format(v), Colors.white),
    ];
    if (v > 0 && total > 0) {
      rows.add(
        _TipRow(
          'Share of year',
          '${(v / total * 100).toStringAsFixed(0)}%',
          Colors.white,
        ),
      );
    }
    if (v > 0 && average > 0) {
      final d = (v - average) / average * 100;
      rows.add(
        _TipRow(
          'Vs average',
          '${d >= 0 ? '+' : '-'}${d.abs().toStringAsFixed(0)}%',
          d >= 0 ? const Color(0xFF34D399) : const Color(0xFFF87171),
        ),
      );
    }

    final titleTp = _layoutText(
      p.month,
      const TextStyle(
        color: Colors.white,
        fontSize: 13.5,
        fontWeight: FontWeight.w800,
      ),
    );
    final labelTps = rows
        .map(
          (r) => _layoutText(
            r.label,
            const TextStyle(
              color: Color(0xFF94A3B8),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        )
        .toList();
    final valueTps = rows
        .map(
          (r) => _layoutText(
            r.value,
            TextStyle(
              color: r.valueColor,
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        )
        .toList();

    var contentW = titleTp.width;
    for (var k = 0; k < rows.length; k++) {
      contentW = math.max(contentW, labelTps[k].width + 16 + valueTps[k].width);
    }
    final rowH = labelTps.first.height;
    final tipW = contentW + 28;
    final tipH =
        10 +
        titleTp.height +
        6 +
        rows.length * rowH +
        (rows.length - 1) * 4 +
        12;

    final cx = plot.left + slotW * (i + 0.5);
    final barTop = yFor(v);

    double tx = cx - tipW / 2;
    double ty = barTop - tipH - 12;
    if (ty < 0) ty = barTop + 12;
    tx = math.max(0, math.min(tx, size.width - tipW));

    canvas.saveLayer(
      Rect.fromLTWH(tx - 24, ty - 24, tipW + 48, tipH + 60),
      Paint()..color = Colors.white.withValues(alpha: hover),
    );

    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(tx, ty, tipW, tipH),
      const Radius.circular(10),
    );
    canvas.drawRRect(
      rrect.shift(const Offset(0, 4)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    canvas.drawRRect(rrect, Paint()..color = _Ui.ink);

    var y = ty + 10;
    titleTp.paint(canvas, Offset(tx + 14, y));
    y += titleTp.height + 6;
    for (var k = 0; k < rows.length; k++) {
      labelTps[k].paint(canvas, Offset(tx + 14, y));
      valueTps[k].paint(canvas, Offset(tx + tipW - 14 - valueTps[k].width, y));
      y += rowH + 4;
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PayoutChartPainter old) =>
      old.data != data ||
      old.metric != metric ||
      old.intro != intro ||
      old.index != index ||
      old.hover != hover ||
      old.average != average ||
      old.total != total ||
      old.peakIndex != peakIndex ||
      old.currentMonth != currentMonth;
}
