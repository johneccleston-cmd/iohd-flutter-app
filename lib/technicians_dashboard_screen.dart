import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;
import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/dashboard_layout.dart';

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
  final double revenue;
  final int callbackCount;

  const _TechnicianProfile({
    required this.id,
    required this.name,
    required this.role,
    required this.imageUrl,
    required this.completedJobsYtd,
    required this.revenue,
    required this.callbackCount,
  });

  bool get hasJobs => completedJobsYtd > 0;
  double get callbackRate => hasJobs ? callbackCount / completedJobsYtd * 100 : 0.0;

  factory _TechnicianProfile.fromJson(Map<String, dynamic> json) {
    return _TechnicianProfile(
      id: json['id']?.toString() ?? '0',
      name: (json['name'] ?? 'Unknown tech').toString(),
      role: (json['jobTitle'] ?? json['role'] ?? 'Technician').toString(),
      imageUrl: (json['avatarUrl'] ?? json['avatar_url'] ?? '').toString(),
      completedJobsYtd: _toInt(json['completedJobsYtd']),
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
    if (a.hasJobs != b.hasJobs) return a.hasJobs ? -1 : 1;
    final cmp = a.callbackRate.compareTo(b.callbackRate);
    if (cmp != 0) return cmp;
    return b.completedJobsYtd.compareTo(a.completedJobsYtd);
  });
  return list;
}

// =============================================================================
// SCREEN STATE
// =============================================================================

class _TechniciansDashboardContentState extends State<TechniciansDashboardContent> {
  bool _isLoading = true;
  String? _errorMessage;
  int _requestId = 0;

  List<_TechnicianProfile> _techs = [];
  List<_TechnicianProfile> _ranked = [];
  List<_MonthlyChartPoint> _chartData = [];

  double _avgProfitYtd = 0;
  double _avgProfitPerDay = 0;
  double _callbackRatePct = 0;
  double? _avgRating;

  @override
  void initState() {
    super.initState();
    _fetchTechs();
  }

  @override
  void didUpdateWidget(covariant TechniciansDashboardContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedYear != widget.selectedYear) {
      _fetchTechs();
    }
  }

  Future<void> _fetchTechs() async {
    final requestId = ++_requestId;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await http.get(
        Uri.parse('$kApiBaseUrl/api/tech_stats?year=${widget.selectedYear}'),
        headers: AuthSession.instance.headers(),
      ).timeout(const Duration(seconds: 60)); // free-tier hosts can take ~30s+ to wake up

      if (!mounted || requestId != _requestId) return;

      if (response.statusCode != 200) {
        throw Exception('The server returned status ${response.statusCode}.');
      }

      final Map<String, dynamic> body = json.decode(response.body);
      final summary = (body['summary'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
      final metrics = (summary['metrics'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
      final List<dynamic> techsData = body['techs'] ?? [];
      final List<dynamic> chartRaw = summary['chartData'] ?? [];

      final techs = techsData.map((e) => _TechnicianProfile.fromJson(e as Map<String, dynamic>)).toList();

      setState(() {
        _avgProfitYtd = _parseMoney(metrics['avgProfitYtd'] ?? summary['avgProfitYtd']);
        _avgProfitPerDay = _parseMoney(metrics['avgProfitPerDay'] ?? summary['avgProfitPerDay']);
        _callbackRatePct = _parseMoney(metrics['callbackRatePct'] ?? summary['callbackRate']);
        _avgRating = (metrics['avgCustomerRating'] as num?)?.toDouble();

        _techs = techs;
        _ranked = _rankByCallbacks(techs);
        _chartData = chartRaw.map((e) => _MonthlyChartPoint.fromJson(e as Map<String, dynamic>)).toList();

        _isLoading = false;
      });
    } on TimeoutException {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _errorMessage = 'The dashboard took too long to load.';
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const _TechSkeleton();

    if (_errorMessage != null) {
      return DashErrorPanel(
        title: "Couldn't load technicians",
        message: _errorMessage!,
        onRetry: _fetchTechs,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 104,
          child: Row(
            children: [
              Expanded(
                child: AnimatedMetricCard(
                  title: 'Avg profit per tech YTD',
                  value: _avgProfitYtd,
                  caption: '',
                  valueColor: DashUi.blue,
                  index: 0,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AnimatedMetricCard(
                  title: 'Avg profit per tech per day',
                  value: _avgProfitPerDay,
                  caption: '',
                  valueColor: DashUi.blue,
                  index: 1,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AnimatedMetricCard(
                  title: 'Callback rate',
                  value: _callbackRatePct,
                  format: (v) => '${v.toStringAsFixed(1)}%',
                  caption: '',
                  valueColor: DashUi.amber,
                  index: 2,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AnimatedMetricCard(
                  title: 'Avg customer rating',
                  value: _avgRating,
                  format: (v) => '${v.toStringAsFixed(2)} ★',
                  caption: '',
                  valueColor: DashUi.ink,
                  index: 3,
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
              Expanded(flex: 7, child: _buildRosterAndChart()),
              const SizedBox(width: 16),
              Expanded(flex: 5, child: _buildCallbackLeaderboard()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRosterAndChart() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 4,
          child: _techs.isEmpty
              ? const Center(
                  child: Text(
                    'No active technicians found. Users with a tech role appear here.',
                    style: TextStyle(color: DashUi.muted, fontSize: 14),
                  ),
                )
              : Column(
                  children: [
                    for (int i = 0; i < _techs.length; i += 2) ...[
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: _TechCard(tech: _techs[i])),
                            const SizedBox(width: 12),
                            if (i + 1 < _techs.length)
                              Expanded(child: _TechCard(tech: _techs[i + 1]))
                            else
                              const Expanded(child: SizedBox.shrink()),
                          ],
                        ),
                      ),
                      if (i + 2 < _techs.length) const SizedBox(height: 12),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: 16),
        Expanded(
          flex: 5,
          child: _InteractiveProfitChart(
            data: _chartData, 
            year: widget.selectedYear,
            avgPerDayYtd: _avgProfitPerDay, // Passed directly to sync with scorecard
          ),
        ),
      ],
    );
  }

  Widget _buildCallbackLeaderboard() {
    if (_techs.isEmpty) return const SizedBox.shrink();

    final podium = _ranked.where((t) => t.hasJobs).take(3).toList();
    final first = podium.isNotEmpty ? podium[0] : null;
    final second = podium.length > 1 ? podium[1] : null;
    final third = podium.length > 2 ? podium[2] : null;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: DashUi.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Callback leaderboard', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: DashUi.ink)),
          const SizedBox(height: 2),
          const Text(
            'Fewest callbacks per completed job this year',
            style: TextStyle(fontSize: 12.5, color: DashUi.muted, fontWeight: FontWeight.w500),
          ),
          Expanded(
            child: podium.isEmpty
                ? const Center(
                    child: Text('No completed jobs yet this year.', style: TextStyle(color: DashUi.muted, fontSize: 14)),
                  )
                : LayoutBuilder(
                    builder: (context, c) {
                      // The tallest step (1st) is 254px of avatar + step at full scale, plus ~90px of fixed text,
                      // ring and spacing, plus 24px of padding. The old minimum of 0.45 overflowed on short windows.
                      final scaleH = (c.maxHeight - 24 - 90) / 254;
                      final scaleW = (c.maxWidth / 3) / 160;
                      final scale = math.min(scaleH, scaleW).clamp(0.2, 1.0).toDouble();
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (second != null) _PodiumStep(tech: second, rank: 2, scale: scale),
                            if (first != null) _PodiumStep(tech: first, rank: 1, scale: scale),
                            if (third != null) _PodiumStep(tech: third, rank: 3, scale: scale),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          const Divider(color: DashUi.faint, height: 1),
          const SizedBox(height: 12),
          _AutoHorizontalTechList(techs: _ranked),
        ],
      ),
    );
  }
}

// =============================================================================
// ORIGINAL RESTORED ROSTER CARD
// =============================================================================

class _TechCard extends StatelessWidget {
  final _TechnicianProfile tech;
  const _TechCard({required this.tech});

  @override
  Widget build(BuildContext context) {
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
              tech.imageUrl.isNotEmpty
                  ? tech.imageUrl
                  : 'https://ui-avatars.com/api/?name=${personNameKey(tech.name)}&background=random',
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Container(
                color: const Color(0xFFE2E8F0),
                child: const Icon(Icons.person, color: Color(0xFF94A3B8), size: 26),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tech.name,
                          style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1E293B),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        // The role line is dropped on short windows so the card's numbers keep their room.
                        if (tech.role.isNotEmpty && MediaQuery.sizeOf(context).height >= 700)
                          Text(
                            tech.role,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: Color(0xFF94A3B8),
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Color(0xFFE2E8F0)),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'COMPLETED JOBS',
                        style: TextStyle(fontSize: 10.5, color: Color(0xFF94A3B8), fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '${tech.completedJobsYtd}',
                        style: const TextStyle(
                          fontSize: 14.0,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF1E293B),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'REVENUE GENERATED',
                        style: TextStyle(fontSize: 10.5, color: Color(0xFF94A3B8), fontWeight: FontWeight.bold),
                      ),
                      Text(
                        dashMoney(tech.revenue),
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0284C7),
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

  String personNameKey(String name) => Uri.encodeComponent(name);
}

// =============================================================================
// PODIUM
// =============================================================================

class _PodiumStep extends StatelessWidget {
  final _TechnicianProfile tech;
  final int rank;
  final double scale;

  const _PodiumStep({required this.tech, required this.rank, required this.scale});

  @override
  Widget build(BuildContext context) {
    final isFirst = rank == 1;
    final color = rank == 1 ? const Color(0xFFF59E0B) : rank == 2 ? const Color(0xFF94A3B8) : const Color(0xFFB45309);
    final avatarSize = (isFirst ? 144.0 : 100.0) * scale;
    final stepHeight = (rank == 1 ? 110.0 : rank == 2 ? 75.0 : 50.0) * scale;
    final callbacks = tech.callbackCount;

    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          DashAvatar(
            name: tech.name,
            imageUrl: tech.imageUrl,
            size: avatarSize,
            ringColor: color,
            ringWidth: isFirst ? 5 : 4,
            glowColor: color.withValues(alpha: 0.45),
          ),
          const SizedBox(height: 12),
          Text(
            tech.name.split(' ').first,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: isFirst ? 20 : 17,
              fontWeight: isFirst ? FontWeight.w800 : FontWeight.w700,
              color: DashUi.ink,
            ),
          ),
          Text(
            '${tech.callbackRate.toStringAsFixed(1)}%, $callbacks ${callbacks == 1 ? 'callback' : 'callbacks'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: isFirst ? 14 : 12,
              color: DashUi.slate,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            height: stepHeight,
            width: double.infinity,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              border: Border(top: BorderSide(color: color, width: 3)),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
            ),
            child: Center(
              child: Text(
                rank == 1 ? '1st' : rank == 2 ? '2nd' : '3rd',
                style: TextStyle(
                  fontSize: isFirst ? 28 : 22,
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// LOADING SKELETON
// =============================================================================

class _TechSkeleton extends StatelessWidget {
  const _TechSkeleton();

  Widget _metric() => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: DashUi.panel(radius: 12),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SkeletonBox(h: 12, w: 120),
              SizedBox(height: 12),
              SkeletonBox(h: 26, w: 130),
              SizedBox(height: 10),
              SkeletonBox(h: 10, w: 90),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return SkeletonPulse(
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
                  flex: 7,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Expanded(
                        flex: 4,
                        child: Column(
                          children: [
                            Expanded(child: Row(children: [Expanded(child: SkeletonBox(r: 12)), SizedBox(width: 12), Expanded(child: SkeletonBox(r: 12))])),
                            SizedBox(height: 12),
                            Expanded(child: Row(children: [Expanded(child: SkeletonBox(r: 12)), SizedBox(width: 12), Expanded(child: SkeletonBox(r: 12))])),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        flex: 5,
                        child: Container(
                          padding: const EdgeInsets.all(20),
                          decoration: DashUi.panel(),
                          child: const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SkeletonBox(h: 12, w: 200),
                              SizedBox(height: 10),
                              SkeletonBox(h: 26, w: 120),
                              SizedBox(height: 20),
                              Expanded(child: SkeletonBox(r: 10)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 5,
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: DashUi.panel(),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonBox(h: 16, w: 170),
                        SizedBox(height: 8),
                        SkeletonBox(h: 12, w: 240),
                        SizedBox(height: 20),
                        Expanded(child: SkeletonBox(r: 12)),
                        SizedBox(height: 16),
                        SkeletonBox(h: 56, r: 10),
                      ],
                    ),
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

// =============================================================================
// PROFIT CHART
// =============================================================================

enum _ChartMetric { avgPerDay, totalProfit, jobs, profitPerJob }

String _groupInt(num v) => v.round().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');

extension _ChartMetricX on _ChartMetric {
  String get toggleLabel => switch (this) {
        _ChartMetric.avgPerDay => 'Avg / day',
        _ChartMetric.totalProfit => 'Total',
        _ChartMetric.jobs => 'Jobs',
        _ChartMetric.profitPerJob => 'Per job',
      };

  String get caption => switch (this) {
        _ChartMetric.avgPerDay => 'Average profit per tech per day',
        _ChartMetric.totalProfit => 'Total profit',
        _ChartMetric.jobs => 'Jobs completed',
        _ChartMetric.profitPerJob => 'Average profit per job',
      };

  String get rowLabel => switch (this) {
        _ChartMetric.avgPerDay => 'Avg / day',
        _ChartMetric.totalProfit => 'Total profit',
        _ChartMetric.jobs => 'Jobs',
        _ChartMetric.profitPerJob => 'Per job',
      };

  double valueOf(_MonthlyChartPoint p) => switch (this) {
        _ChartMetric.avgPerDay => p.avgProfitPerDay.toDouble(),
        _ChartMetric.totalProfit => p.totalProfit.toDouble(),
        _ChartMetric.jobs => p.jobCount.toDouble(),
        _ChartMetric.profitPerJob => p.jobCount > 0 ? p.totalProfit / p.jobCount : 0.0,
      };

  double priorValueOf(_MonthlyChartPoint p) => switch (this) {
        _ChartMetric.avgPerDay => p.priorAvgProfitPerDay.toDouble(),
        _ChartMetric.totalProfit => p.priorTotalProfit.toDouble(),
        _ChartMetric.jobs => p.priorJobCount.toDouble(),
        _ChartMetric.profitPerJob => p.priorJobCount > 0 ? p.priorTotalProfit / p.priorJobCount : 0.0,
      };

  String format(num v) => switch (this) {
        _ChartMetric.avgPerDay => '\$${_groupInt(v)}',
        _ChartMetric.totalProfit => _compactMoney(v),
        _ChartMetric.jobs => v.round().toString(),
        _ChartMetric.profitPerJob => _compactMoney(v),
      };

  String axisFormat(num v) => this == _ChartMetric.jobs ? v.round().toString() : _compactMoney(v);
}

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

class _AxisScale {
  final double max;
  final double step;
  const _AxisScale(this.max, this.step);
  int get ticks => (max / step).round();
}

_AxisScale _niceScale(double maxV, {bool integer = false}) {
  if (maxV <= 0) return const _AxisScale(4, 1);
  final raw = maxV / 4;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  final double nice = norm <= 1 ? 1 : (norm <= 2 ? 2 : (norm <= 5 ? 5 : 10));
  var step = nice * mag;
  if (integer && step < 1) step = 1;
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

class _InteractiveProfitChart extends StatefulWidget {
  final List<_MonthlyChartPoint> data;
  final int? year;
  final double? goalPerDay;
  final double avgPerDayYtd;

  const _InteractiveProfitChart({
    required this.data, 
    required this.avgPerDayYtd,
    this.year
  }) : goalPerDay = null;

  @override
  State<_InteractiveProfitChart> createState() => _InteractiveProfitChartState();
}

class _InteractiveProfitChartState extends State<_InteractiveProfitChart> with TickerProviderStateMixin {
  static const _amber = Color(0xFFF59E0B);

  late final AnimationController _intro;
  late final AnimationController _hover;

  _ChartMetric _metric = _ChartMetric.avgPerDay;
  bool _showPrior = true;
  int? _active;
  int? _paintedIndex;

  Timer? _metricCycleTimer;
  bool _chartHovering = false;

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..forward();
    _hover = AnimationController(vsync: this, duration: const Duration(milliseconds: 160));
    _restartMetricCycleTimer();
  }

  @override
  void didUpdateWidget(covariant _InteractiveProfitChart oldWidget) {
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
    _metricCycleTimer = Timer.periodic(const Duration(seconds: 8), (_) => _autoCycleMetric());
  }

  void _autoCycleMetric() {
    if (!mounted || _chartHovering) return;
    final nextIndex = (_metric.index + 1) % _ChartMetric.values.length;
    _setMetric(_ChartMetric.values[nextIndex]);
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

  void _resetAndReplay() {
    _active = null;
    _paintedIndex = null;
    _hover.value = 0;
    _intro.forward(from: 0);
  }

  void _setMetric(_ChartMetric m) {
    if (m == _metric) return;
    setState(() => _metric = m);
    _resetAndReplay();
  }

  void _togglePrior() {
    setState(() => _showPrior = !_showPrior);
    _resetAndReplay();
  }

  int? _indexFor(double dx, double width) {
    final n = widget.data.length;
    if (n == 0) return null;
    final plotW = width - _ProfitChartPainter.leftGutter;
    if (plotW <= 0) return null;
    final i = ((dx - _ProfitChartPainter.leftGutter) / (plotW / n)).floor();
    if (i < 0 || i >= n) return null;
    return i;
  }

  double? _pct(double prev, double cur) => prev > 0 ? (cur - prev) / prev * 100 : null;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final yearText = widget.year?.toString() ?? 'this year';

    if (data.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20.0),
        decoration: DashUi.panel(),
        child: Center(
          child: Text(
            'No chart data for $yearText yet.',
            style: const TextStyle(color: DashUi.muted, fontWeight: FontWeight.w500, fontSize: 14),
          ),
        ),
      );
    }

    final withData = [for (var i = 0; i < data.length; i++) if (_pointHasData(data[i])) i];
    final completed = withData.where((i) => !data[i].partial).toList();
    final meanIdx = completed.isNotEmpty ? completed : withData;

    final sum = withData.map((i) => _metric.valueOf(data[i])).fold<double>(0, (a, b) => a + b);

    double avg;
    if (_metric == _ChartMetric.profitPerJob) {
      var profit = 0;
      var jobs = 0;
      for (final i in withData) {
        profit += data[i].totalProfit;
        jobs += data[i].jobCount;
      }
      avg = jobs > 0 ? profit / jobs : 0.0;
    } else if (_metric == _ChartMetric.avgPerDay) {
      // FIX: Force the chart's average line to equal the exact YTD value passed from the scorecard
      avg = widget.avgPerDayYtd;
    } else {
      final vals = meanIdx.map((i) => _metric.valueOf(data[i])).toList();
      avg = vals.isEmpty ? 0.0 : vals.fold<double>(0, (a, b) => a + b) / vals.length;
    }

    final showsAverage = _metric == _ChartMetric.avgPerDay || _metric == _ChartMetric.profitPerJob;
    final headlineValue = showsAverage ? avg : sum;
    final headlineLabel = showsAverage ? 'Average' : 'Total';

    final hasPrior = data.any((p) => p.priorTotalProfit > 0 || p.priorJobCount > 0);
    final showPrior = hasPrior && _showPrior;

    final double? goal = (_metric == _ChartMetric.avgPerDay && widget.goalPerDay != null && widget.goalPerDay! > 0)
        ? widget.goalPerDay
        : null;
    final goalMet = goal == null ? 0 : completed.where((i) => _metric.valueOf(data[i]) >= goal).length;

    int? peakIndex;
    var peakValue = 0.0;
    for (final i in withData) {
      final v = _metric.valueOf(data[i]);
      if (v > peakValue) {
        peakValue = v;
        peakIndex = i;
      }
    }

    var maxV = 0.0;
    for (final p in data) {
      maxV = math.max(maxV, _metric.valueOf(p));
      if (showPrior) maxV = math.max(maxV, _metric.priorValueOf(p));
    }
    if (goal != null) maxV = math.max(maxV, goal);
    final scale = _niceScale(maxV, integer: _metric == _ChartMetric.jobs);

    double? trendPct;
    String? trendLabel;
    if (completed.length >= 2) {
      final last = completed.last;
      final prev = completed[completed.length - 2];
      trendPct = _pct(_metric.valueOf(data[prev]), _metric.valueOf(data[last]));
      trendLabel = '${data[last].month} vs ${data[prev].month}';
    }

    final partialIdx = data.indexWhere((p) => p.partial);

    final legend = <Widget>[
      _legendItem(
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3),
            gradient: const LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0xFF2563EB), Color(0xFF60A5FA)],
            ),
          ),
        ),
        'Monthly',
      ),
      if (partialIdx >= 0)
        _legendItem(
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              color: const Color(0xFF2563EB).withValues(alpha: 0.45),
            ),
          ),
          '${data[partialIdx].month} so far',
        ),
      if (goal != null)
        _legendItem(
          Container(width: 14, height: 2, color: DashUi.emeraldDeep),
          completed.isEmpty
              ? 'Goal ${_metric.format(goal)}'
              : 'Goal ${_metric.format(goal)}, met in $goalMet of ${completed.length} ${completed.length == 1 ? 'month' : 'months'}',
        ),
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
                color: _amber,
              ),
            ),
          ),
          'Average ${_metric.format(avg)}',
        ),
      if (showPrior)
        _legendItem(
          Container(
            width: 12,
            height: 2.5,
            decoration: BoxDecoration(
              color: DashUi.ink.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          'Same month last year',
        ),
      if (peakIndex != null)
        _legendItem(
          Transform.rotate(
            angle: math.pi / 4,
            child: Container(width: 8, height: 8, color: _amber),
          ),
          'Peak in ${data[peakIndex].month}, ${_metric.format(peakValue)}',
        ),
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      decoration: DashUi.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 10,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _metric.caption,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: DashUi.slate),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        _metric.format(headlineValue),
                        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: DashUi.ink, height: 1.1),
                      ),
                      // Dropped on short windows so the header fits on one line and the plot keeps its height.
                      if (MediaQuery.sizeOf(context).height >= 700) ...[
                        const SizedBox(width: 10),
                        Text(
                          '$headlineLabel for $yearText',
                          style: const TextStyle(fontSize: 13, color: DashUi.muted, fontWeight: FontWeight.w500),
                        ),
                      ],
                      if (trendPct != null) ...[
                        const SizedBox(width: 10),
                        _TrendChip(pct: trendPct, label: trendLabel!),
                      ],
                    ],
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasPrior) ...[
                    _LastYearChip(selected: _showPrior, onTap: _togglePrior),
                    const SizedBox(width: 8),
                  ],
                  _MetricToggle(value: _metric, onChanged: _setMetric),
                ],
              ),
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
                        onHover: (e) => _setActive(_indexFor(e.localPosition.dx, c.maxWidth)),
                        onExit: (_) {
                          _setActive(null);
                          _chartHovering = false;
                          _restartMetricCycleTimer();
                        },
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (d) => _setActive(_indexFor(d.localPosition.dx, c.maxWidth)),
                          onHorizontalDragStart: (d) => _setActive(_indexFor(d.localPosition.dx, c.maxWidth)),
                          onHorizontalDragUpdate: (d) => _setActive(_indexFor(d.localPosition.dx, c.maxWidth)),
                          child: AnimatedBuilder(
                            animation: Listenable.merge([_intro, _hover]),
                            builder: (context, _) {
                              return CustomPaint(
                                size: Size.infinite,
                                painter: _ProfitChartPainter(
                                  data: data,
                                  metric: _metric,
                                  scale: scale,
                                  average: avg,
                                  goal: goal,
                                  showPrior: showPrior,
                                  peakIndex: peakIndex,
                                  index: _paintedIndex,
                                  intro: _intro.value,
                                  hover: Curves.easeOutCubic.transform(_hover.value),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                    if (withData.isEmpty)
                      IgnorePointer(
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 28),
                            child: Text(
                              'Nothing recorded for $yearText yet.',
                              style: const TextStyle(fontSize: 14, color: DashUi.muted, fontWeight: FontWeight.w500),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          // On short windows the legend would take the height the plot needs.
          if (MediaQuery.sizeOf(context).height >= 700) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 18,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: legend,
            ),
          ],
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
        Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: DashUi.slate)),
      ],
    );
  }
}

class _TrendChip extends StatelessWidget {
  final double pct;
  final String label;
  const _TrendChip({required this.pct, required this.label});

  @override
  Widget build(BuildContext context) {
    final up = pct >= 0;
    final fg = up ? const Color(0xFF047857) : const Color(0xFFB91C1C);
    final bg = up ? const Color(0xFFECFDF5) : const Color(0xFFFEF2F2);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 14, color: fg),
          const SizedBox(width: 2),
          Text(
            '${pct.abs().toStringAsFixed(1)}% $label',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg),
          ),
        ],
      ),
    );
  }
}

class _LastYearChip extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;
  const _LastYearChip({required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: selected ? Colors.white : DashUi.faint,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: selected ? DashUi.ink.withValues(alpha: 0.35) : Colors.transparent),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 12,
                height: 2.5,
                decoration: BoxDecoration(
                  color: DashUi.ink.withValues(alpha: selected ? 0.6 : 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Last year',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: selected ? DashUi.ink : DashUi.slate,
                ),
              ),
            ],
          ),
        ),
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
      decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: _ChartMetric.values.map((m) {
          final selected = m == value;
          return MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => onChanged(m),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: selected ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: selected ? DashUi.line : Colors.transparent),
                ),
                child: Text(
                  m.toggleLabel,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    color: selected ? const Color(0xFF1D4ED8) : DashUi.slate,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _ProfitChartPainter extends CustomPainter {
  static const double leftGutter = 48;
  static const double bottomGutter = 38;
  static const double topPad = 6;

  final List<_MonthlyChartPoint> data;
  final _ChartMetric metric;
  final _AxisScale scale;
  final double average;
  final double? goal;
  final bool showPrior;
  final int? peakIndex;
  final int? index;
  final double intro;
  final double hover;

  const _ProfitChartPainter({
    required this.data,
    required this.metric,
    required this.scale,
    required this.average,
    required this.goal,
    required this.showPrior,
    required this.peakIndex,
    required this.index,
    required this.intro,
    required this.hover,
  });

  static const _amber = Color(0xFFF59E0B);

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(leftGutter, topPad, size.width, size.height - bottomGutter);
    if (plot.width <= 0 || plot.height <= 0 || data.isEmpty) return;

    final n = data.length;
    final slotW = plot.width / n;
    final focusing = index != null && hover > 0.001;
    final g = goal;

    double yFor(double v) => plot.bottom - (v / scale.max).clamp(0.0, 1.0) * plot.height;

    if (focusing) {
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(plot.left + index! * slotW + 2, plot.top, slotW - 4, plot.height),
        const Radius.circular(10),
      );
      canvas.drawRRect(r, Paint()..color = const Color(0xFFEFF6FF).withValues(alpha: hover));
    }

    final ticks = scale.ticks;
    for (var i = 0; i <= ticks; i++) {
      final v = i * scale.step;
      final y = yFor(v);
      canvas.drawLine(
        Offset(plot.left, y),
        Offset(plot.right, y),
        Paint()
          ..color = i == 0 ? DashUi.line : DashUi.faint
          ..strokeWidth = 1,
      );
      final tp = _layoutText(
        metric.axisFormat(v),
        const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: DashUi.muted),
      );
      tp.paint(canvas, Offset(leftGutter - 8 - tp.width, y - tp.height / 2));
    }

    final stagger = 0.4 / n;
    for (var i = 0; i < n; i++) {
      final p = data[i];
      final has = _pointHasData(p);
      final v = metric.valueOf(p);
      final prior = showPrior ? metric.priorValueOf(p) : 0.0;
      final partial = p.partial;
      final metGoal = g != null && !partial && v >= g;
      final isFocus = focusing && index == i;
      final dim = (focusing && !isFocus) ? 1 - 0.5 * hover : 1.0;

      final cx = plot.left + slotW * (i + 0.5);
      final baseW = math.min(slotW * 0.58, 36.0);
      final barW = baseW + (isFocus ? 4 * hover : 0);

      final localT = Curves.easeOutCubic.transform(((intro - i * stagger) / 0.6).clamp(0.0, 1.0));
      final fullH = (v / scale.max).clamp(0.0, 1.0) * plot.height;

      final labelTp = _layoutText(
        p.month,
        TextStyle(
          fontSize: 13,
          fontWeight: isFocus ? FontWeight.w800 : FontWeight.w600,
          color: isFocus ? DashUi.ink : (has ? DashUi.slate : const Color(0xFFCBD5E1)),
        ),
        maxWidth: slotW,
        align: TextAlign.center,
      );
      labelTp.paint(canvas, Offset(cx - labelTp.width / 2, plot.bottom + 8));

      if (partial) {
        final soFar = _layoutText(
          'so far',
          const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: DashUi.muted),
          maxWidth: slotW,
          align: TextAlign.center,
        );
        soFar.paint(canvas, Offset(cx - soFar.width / 2, plot.bottom + 8 + labelTp.height));
      }

      void drawPriorTick() {
        if (prior <= 0) return;
        final py = yFor(prior);
        canvas.drawLine(
          Offset(cx - baseW / 2 - 4, py),
          Offset(cx + baseW / 2 + 4, py),
          Paint()
            ..color = DashUi.ink.withValues(alpha: 0.6 * dim * localT)
            ..strokeWidth = 2
            ..strokeCap = StrokeCap.round,
        );
      }

      if (!has || v <= 0) {
        final stub = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(cx, plot.bottom - 1.5), width: baseW * 0.6, height: 3),
          const Radius.circular(2),
        );
        canvas.drawRRect(stub, Paint()..color = DashUi.line);
        drawPriorTick();
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
            ..color = (metGoal ? const Color(0xFF10B981) : const Color(0xFF3B82F6)).withValues(alpha: 0.35 * hover)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
        );
      }

      final List<Color> colors;
      if (metGoal) {
        colors = isFocus
            ? const [Color(0xFF047857), Color(0xFF34D399)]
            : const [Color(0xFF059669), Color(0xFF34D399)];
      } else {
        colors = isFocus
            ? const [Color(0xFF1D4ED8), Color(0xFF38BDF8)]
            : const [Color(0xFF2563EB), Color(0xFF60A5FA)];
      }
      final barAlpha = dim * (partial ? 0.5 : 1.0);
      canvas.drawRRect(
        rrect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: colors.map((c) => c.withValues(alpha: barAlpha)).toList(),
          ).createShader(rect),
      );

      drawPriorTick();

      if (peakIndex == i && localT > 0.98) {
        final c = Offset(cx, rect.top - 9);
        final path = Path()
          ..moveTo(c.dx, c.dy - 4)
          ..lineTo(c.dx + 4, c.dy)
          ..lineTo(c.dx, c.dy + 4)
          ..lineTo(c.dx - 4, c.dy)
          ..close();
        canvas.drawPath(path, Paint()..color = _amber.withValues(alpha: dim));
      }
    }

    if (average > 0 && average <= scale.max) {
      final y = yFor(average);
      final paint = Paint()
        ..color = _amber.withValues(alpha: 0.9 * intro)
        ..strokeWidth = 1.3
        ..strokeCap = StrokeCap.round;
      var x = plot.left;
      while (x < plot.right) {
        canvas.drawLine(Offset(x, y), Offset(math.min(x + 5, plot.right), y), paint);
        x += 9;
      }
    }

    if (g != null && g <= scale.max) {
      final y = yFor(g);
      canvas.drawLine(
        Offset(plot.left, y),
        Offset(plot.right, y),
        Paint()
          ..color = DashUi.emeraldDeep.withValues(alpha: intro)
          ..strokeWidth = 1.6,
      );
      final tp = _layoutText(
        'Goal ${metric.format(g)}',
        TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: DashUi.emeraldDeep.withValues(alpha: intro)),
      );
      final pill = RRect.fromRectAndRadius(
        Rect.fromLTWH(plot.right - tp.width - 16, y - tp.height - 8, tp.width + 12, tp.height + 4),
        const Radius.circular(6),
      );
      canvas.drawRRect(pill, Paint()..color = Colors.white.withValues(alpha: 0.92 * intro));
      tp.paint(canvas, Offset(pill.left + 6, pill.top + 2));
    }

    if (focusing) _paintTooltip(canvas, size, plot, slotW, yFor);
  }

  void _paintTooltip(Canvas canvas, Size size, Rect plot, double slotW, double Function(double) yFor) {
    final i = index!;
    final p = data[i];
    final has = _pointHasData(p);
    final cur = metric.valueOf(p);

    final rows = <(String, String, bool)>[
      for (final m in _ChartMetric.values) (m.rowLabel, m.format(m.valueOf(p)), m == metric),
    ];

    final deltas = <TextPainter>[];
    void addDelta(double base, String suffix) {
      if (base <= 0 || cur <= 0) return;
      final pct = (cur - base) / base * 100;
      final up = pct >= 0;
      deltas.add(_layoutText(
        '${up ? '▲' : '▼'} ${pct.abs().toStringAsFixed(1)}% $suffix',
        TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: up ? const Color(0xFF34D399) : const Color(0xFFF87171),
        ),
      ));
    }

    final skipMonthOverMonth = p.partial && (metric == _ChartMetric.totalProfit || metric == _ChartMetric.jobs);
    if (i > 0 && has && _pointHasData(data[i - 1]) && !skipMonthOverMonth) {
      addDelta(metric.valueOf(data[i - 1]), 'vs ${data[i - 1].month}');
    }
    if (showPrior) addDelta(metric.priorValueOf(p), 'vs ${p.month} last year');
    if (goal != null) addDelta(goal!, 'vs goal');

    final titleTp = _layoutText(
      p.partial ? '${p.month} so far' : p.month,
      const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w800),
    );
    final labelTps = <TextPainter>[];
    final valueTps = <TextPainter>[];
    for (final r in rows) {
      labelTps.add(_layoutText(
        r.$1,
        TextStyle(
          color: r.$3 ? Colors.white : const Color(0xFF94A3B8),
          fontSize: 11.5,
          fontWeight: r.$3 ? FontWeight.w700 : FontWeight.w500,
        ),
      ));
      valueTps.add(_layoutText(
        r.$2,
        TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: r.$3 ? FontWeight.w800 : FontWeight.w600,
        ),
      ));
    }

    final labelW = labelTps.map((t) => t.width).reduce(math.max);
    final valueW = valueTps.map((t) => t.width).reduce(math.max);
    final deltaW = deltas.isEmpty ? 0.0 : deltas.map((t) => t.width).reduce(math.max);
    final tipW = math.max(titleTp.width, math.max(labelW + 16 + valueW, deltaW)) + 28;
    final rowH = labelTps.first.height;
    var tipH = 12 + titleTp.height + 6 + rows.length * rowH + (rows.length - 1) * 3 + 12;
    if (deltas.isNotEmpty) {
      tipH += 6 + deltas.length * deltas.first.height + (deltas.length - 1) * 2;
    }

    final cx = plot.left + slotW * (i + 0.5);
    final barW = math.min(slotW * 0.58, 36.0);
    final barTop = has ? yFor(cur) : plot.bottom - 3;

    double tx, ty;
    var caretAbove = false;
    final aboveY = barTop - tipH - 16;
    if (aboveY >= 0) {
      ty = aboveY;
      tx = cx - tipW / 2;
      caretAbove = true;
    } else {
      ty = math.max(plot.top, math.min(barTop - 8, plot.bottom - tipH));
      final rightX = cx + barW / 2 + 12;
      tx = rightX + tipW <= size.width ? rightX : cx - barW / 2 - 12 - tipW;
    }
    tx = math.max(0, math.min(tx, size.width - tipW));

    canvas.saveLayer(
      Rect.fromLTWH(tx - 24, ty - 24, tipW + 48, tipH + 60),
      Paint()..color = Colors.white.withValues(alpha: hover),
    );

    final rrect = RRect.fromRectAndRadius(Rect.fromLTWH(tx, ty, tipW, tipH), const Radius.circular(10));
    canvas.drawRRect(
      rrect.shift(const Offset(0, 4)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    canvas.drawRRect(rrect, Paint()..color = DashUi.ink);

    if (caretAbove) {
      final ccx = math.max(tx + 16, math.min(cx, tx + tipW - 16));
      final caret = Path()
        ..moveTo(ccx - 5, ty + tipH)
        ..lineTo(ccx + 5, ty + tipH)
        ..lineTo(ccx, ty + tipH + 5)
        ..close();
      canvas.drawPath(caret, Paint()..color = DashUi.ink);
    }

    var y = ty + 12;
    titleTp.paint(canvas, Offset(tx + 14, y));
    y += titleTp.height + 6;
    for (var k = 0; k < rows.length; k++) {
      labelTps[k].paint(canvas, Offset(tx + 14, y));
      valueTps[k].paint(canvas, Offset(tx + tipW - 14 - valueTps[k].width, y));
      y += rowH + 3;
    }
    if (deltas.isNotEmpty) {
      y += 3;
      for (final d in deltas) {
        d.paint(canvas, Offset(tx + 14, y));
        y += d.height + 2;
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ProfitChartPainter old) =>
      old.data != data ||
      old.metric != metric ||
      old.intro != intro ||
      old.index != index ||
      old.hover != hover ||
      old.average != average ||
      old.goal != goal ||
      old.showPrior != showPrior ||
      old.peakIndex != peakIndex;
}

// =============================================================================
// AUTO-SCROLLING TECHNICIAN TICKER
// =============================================================================

class _AutoHorizontalTechList extends StatefulWidget {
  final List<_TechnicianProfile> techs;

  const _AutoHorizontalTechList({required this.techs});

  @override
  State<_AutoHorizontalTechList> createState() => _AutoHorizontalTechListState();
}

class _AutoHorizontalTechListState extends State<_AutoHorizontalTechList> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  final GlobalKey _rowKey = GlobalKey();
  final ValueNotifier<double> _offset = ValueNotifier<double>(0);

  static const double _speed = 45.0;
  static const double _cardGap = 12.0;

  double _rowWidth = 1.0;
  Duration? _lastElapsed;
  bool _isHovered = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _measureRow();
      _ticker.start();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.of(context).disableAnimations;
    if (_reduceMotion) _offset.value = 0;
  }

  void _onTick(Duration elapsed) {
    if (_isHovered || _reduceMotion) {
      _lastElapsed = elapsed;
      return;
    }

    if (_lastElapsed == null) {
      _lastElapsed = elapsed;
      return;
    }

    final double deltaSeconds = (elapsed - _lastElapsed!).inMicroseconds / 1000000.0;
    _lastElapsed = elapsed;
    final double dt = deltaSeconds.clamp(0.0, 0.05);

    if (_rowWidth <= 1.0 || dt <= 0) return;

    double nextOffset = _offset.value + (_speed * dt);
    if (nextOffset >= _rowWidth) {
      nextOffset %= _rowWidth;
    }
    _offset.value = nextOffset;
  }

  void _measureRow() {
    final BuildContext? context = _rowKey.currentContext;
    if (context == null) return;

    final RenderObject? renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;

    final double width = renderObject.size.width;
    if (width <= 0) return;

    _rowWidth = width + _cardGap;
    if (_offset.value >= _rowWidth) {
      _offset.value %= _rowWidth;
    }
  }

  @override
  void didUpdateWidget(covariant _AutoHorizontalTechList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.techs != widget.techs) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _measureRow();
      });
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _offset.dispose();
    super.dispose();
  }

  Widget _buildTechRow({Key? key}) {
    return Row(
      key: key,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < widget.techs.length; i++) ...[
          if (i > 0) const SizedBox(width: _cardGap),
          _buildTechCard(widget.techs[i], i),
        ],
      ],
    );
  }

  Widget _buildTechCard(_TechnicianProfile tech, int index) {
    final int rank = index + 1;
    final bool perfectRecord = tech.hasJobs && tech.callbackCount == 0;

    Color rankColor;
    if (rank == 1) {
      rankColor = const Color(0xFFD97706);
    } else if (rank == 2) {
      rankColor = const Color(0xFF475569);
    } else if (rank == 3) {
      rankColor = const Color(0xFF92400E);
    } else {
      rankColor = Colors.grey.shade600;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DashUi.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: rankColor, shape: BoxShape.circle),
            child: Text(
              '$rank',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ),
          const SizedBox(width: 8),
          DashAvatar(name: tech.name, imageUrl: tech.imageUrl, size: 28),
          const SizedBox(width: 8),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tech.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: DashUi.ink),
              ),
              Text(
                '${tech.completedJobsYtd} jobs, ${tech.callbackCount} ${tech.callbackCount == 1 ? 'callback' : 'callbacks'}',
                style: const TextStyle(fontSize: 10, color: DashUi.muted),
              ),
            ],
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: perfectRecord ? const Color(0xFFECFDF5) : Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: perfectRecord ? const Color(0xFF6EE7B7) : const Color(0xFFCBD5E1)),
            ),
            child: Text(
              tech.hasJobs ? '${tech.callbackRate.toStringAsFixed(1)}%' : 'No jobs',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: perfectRecord ? DashUi.emeraldDeep : DashUi.slate,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.techs.isEmpty) return const SizedBox.shrink();

    return MouseRegion(
      onEnter: (_) {
        _isHovered = true;
        _lastElapsed = null;
      },
      onExit: (_) {
        _isHovered = false;
        _lastElapsed = null;
      },
      child: SizedBox(
        height: 56,
        width: double.infinity,
        child: ClipRect(
          child: ValueListenableBuilder<double>(
            valueListenable: _offset,
            builder: (context, offset, child) {
              // OverflowBox lets the doubled row be wider than the viewport without a
              // RenderFlex overflow warning; ClipRect above trims what's off-screen.
              return Transform.translate(
                offset: Offset(-offset, 0),
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: 0,
                  maxWidth: double.infinity,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildTechRow(key: _rowKey),
                      const SizedBox(width: _cardGap),
                      _buildTechRow(),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}