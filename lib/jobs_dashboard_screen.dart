import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'config/api_config.dart';
import 'widgets/dashboard_kit.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'widgets/dashboard_layout.dart';

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

class _JobsAxisScale {
  final double max;
  final double step;
  const _JobsAxisScale(this.max, this.step);
  int get ticks => (max / step).round();
}

_JobsAxisScale _jobsNiceScale(double maxV) {
  if (maxV <= 0) return const _JobsAxisScale(10, 2);
  final raw = maxV / 4;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  final nice = norm <= 1 ? 1.0 : (norm <= 2 ? 2.0 : (norm <= 5 ? 5.0 : 10.0));
  var step = nice * mag;
  if (step <= 0) step = 1;
  var top = (maxV / step).ceil() * step;
  if (top < maxV * 1.08) top += step;
  return _JobsAxisScale(top, step);
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

class _JobsDashboardContentState extends State<JobsDashboardContent> {
  bool _isLoading = true;
  String? _errorMessage;

  int _completedYtd = 0;
  int _activeOpenJobs = 0;
  double _avgProfitMargin = 0.0;
  double _avgJobRevenue = 0.0;
  int _newCustomersYtd = 0;

  List<_MonthlyJobData> _monthlyData = [];
  List<_PipelineStage>? _pipelineStages;
  List<_JobStatusCount>? _statusCounts;

  @override
  void initState() {
    super.initState();
    _fetchDashboardData();
  }

  @override
  void didUpdateWidget(covariant JobsDashboardContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedYear != widget.selectedYear) {
      _fetchDashboardData();
    }
  }

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

  Future<void> _fetchDashboardData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await http.get(
        Uri.parse('$kApiBaseUrl/api/dashboards/jobs?year=${widget.selectedYear}'),
        headers: {
          'Content-Type': 'application/json',
          if (kAuthToken.isNotEmpty) 'Authorization': 'Bearer $kAuthToken',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final Map<String, dynamic> body = json.decode(response.body);
        final scorecards = body['scorecards'] ?? {};

        _completedYtd = _parseInt(scorecards['completedYtd']);
        _activeOpenJobs = _parseInt(scorecards['activeOpenJobs']);
        _avgProfitMargin = _parseDouble(scorecards['avgProfitMargin']);
        _avgJobRevenue = _parseDouble(scorecards['avgJobRevenue']);
        _newCustomersYtd = _parseInt(scorecards['newCustomersYtd']);
        
        _pipelineStages = _parsePipelineStages(body['pipelineStages']);
        _statusCounts = _parseStatusCounts(body['statusCounts']);

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
        for (var item in rawWeekly) {
          int week = _parseInt(item['week_num']);
          int mNum = ((week - 1) / 4.33).floor() + 1;
          mNum = mNum.clamp(1, 12);

          monthlyRevSplit.putIfAbsent(mNum, () => {'res': 0.0, 'com': 0.0});
          monthlyRevSplit[mNum]!['res'] = (monthlyRevSplit[mNum]!['res'] ?? 0.0) + _parseDouble(item['residential_rev']);
          monthlyRevSplit[mNum]!['com'] = (monthlyRevSplit[mNum]!['com'] ?? 0.0) + _parseDouble(item['commercial_rev']);
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

        if (mounted) setState(() => _isLoading = false);
      } else {
        throw Exception('Status ${response.statusCode}');
      }
    } on TimeoutException {
      if (mounted) {
        setState(() {
          _errorMessage = 'The dashboard took too long to load. Check your connection and try again.';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
          _isLoading = false;
        });
      }
    }
  }

  static final _thousands = NumberFormat('#,##0');
  String _fmt(num v) => _thousands.format(v);
  String _money(double v) => '\$${_fmt(v)}';

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const _JobsSkeleton();
    if (_errorMessage != null) return DashErrorPanel(title: "Error loading jobs dashboard", message: _errorMessage!, onRetry: _fetchDashboardData);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 86,
          child: Row(
            children: [
              Expanded(child: AnimatedMetricCard(title: 'Completed YTD', value: _completedYtd.toDouble(), format: (v) => _fmt(v.toInt()), caption: '', valueColor: DashUi.emeraldDeep, index: 0)),
              const SizedBox(width: 8),
              Expanded(child: AnimatedMetricCard(title: 'Active Open Jobs', value: _activeOpenJobs.toDouble(), format: (v) => _fmt(v.toInt()), caption: '', valueColor: DashUi.sky, index: 1)),
              const SizedBox(width: 8),
              Expanded(child: AnimatedMetricCard(title: 'Avg Profit Margin', value: _avgProfitMargin, format: (v) => '${v.toStringAsFixed(1)}%', caption: '', valueColor: DashUi.indigo, index: 2)),
              const SizedBox(width: 8),
              Expanded(child: AnimatedMetricCard(title: 'Avg Job Revenue', value: _avgJobRevenue, format: (v) => _money(v), caption: '', valueColor: DashUi.amber, index: 3)),
              const SizedBox(width: 8),
              Expanded(child: AnimatedMetricCard(title: 'New Customers YTD', value: _newCustomersYtd.toDouble(), format: (v) => _fmt(v.toInt()), caption: '', valueColor: DashUi.blue, index: 4)),
            ],
          ),
        ),

        const SizedBox(height: 16),

        Expanded(
          flex: 10,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 7, 
                child: Column(
                  children: [
                    Expanded(flex: 11, child: _InteractiveJobsChart(data: _monthlyData, year: widget.selectedYear)),
                    const SizedBox(height: 16),
                    Expanded(flex: 9, child: _AvgJobValueChart(data: _monthlyData, year: widget.selectedYear)),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 5,
                child: _JobsStatusPanel(
                  statusCounts: _statusCounts,
                  loading: _isLoading,
                  monthly: _monthlyData,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// INTERACTIVE JOBS CHART
// =============================================================================

enum _JobsChartMetric { volume, mix, installEstimate }

extension _JobsChartMetricX on _JobsChartMetric {
  String get toggleLabel => switch (this) {
        _JobsChartMetric.volume => 'Volume',
        _JobsChartMetric.mix => 'Res vs Com',
        _JobsChartMetric.installEstimate => 'Install Split',
      };

  String get caption => switch (this) {
        _JobsChartMetric.volume => 'Monthly completed job volume',
        _JobsChartMetric.mix => 'Residential vs commercial revenue mix',
        _JobsChartMetric.installEstimate => 'Actual install vs service volume',
      };
}

class _InteractiveJobsChart extends StatefulWidget {
  final List<_MonthlyJobData> data;
  final int? year;
  const _InteractiveJobsChart({required this.data, this.year});

  @override
  State<_InteractiveJobsChart> createState() => _InteractiveJobsChartState();
}

class _InteractiveJobsChartState extends State<_InteractiveJobsChart> with TickerProviderStateMixin {
  late final AnimationController _intro;
  late final AnimationController _hover;

  _JobsChartMetric _metric = _JobsChartMetric.volume;
  int? _active;
  int? _paintedIndex;

  Timer? _cycleTimer;
  bool _chartHovering = false;

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..forward();
    _hover = AnimationController(vsync: this, duration: const Duration(milliseconds: 160));
    _restartCycleTimer();
  }

  @override
  void didUpdateWidget(covariant _InteractiveJobsChart old) {
    super.didUpdateWidget(old);
    if (!identical(old.data, widget.data)) {
      _active = null;
      _paintedIndex = null;
      _hover.value = 0;
      _intro.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _cycleTimer?.cancel();
    _intro.dispose();
    _hover.dispose();
    super.dispose();
  }

  void _restartCycleTimer() {
    _cycleTimer?.cancel();
    _cycleTimer = Timer.periodic(const Duration(seconds: 8), (_) => _autoCycle());
  }

  void _autoCycle() {
    if (!mounted || _chartHovering) return;
    final next = (_metric.index + 1) % _JobsChartMetric.values.length;
    _setMetric(_JobsChartMetric.values[next]);
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

  void _setMetric(_JobsChartMetric m) {
    if (m == _metric) return;
    setState(() => _metric = m);
    _resetAndReplay();
  }

  int? _indexFor(double dx, double width) {
    final n = widget.data.length;
    if (n == 0) return null;
    final plotW = width - _JobsChartPainter.leftGutter;
    if (plotW <= 0) return null;
    final i = ((dx - _JobsChartPainter.leftGutter) / (plotW / n)).floor();
    if (i < 0 || i >= n) return null;
    return i;
  }

  double _metricValue(_MonthlyJobData d) {
    switch (_metric) {
      case _JobsChartMetric.volume:
        return d.completedTotal.toDouble();
      case _JobsChartMetric.mix:
        return d.totalRevenue;
      case _JobsChartMetric.installEstimate:
        return (d.installCount + d.serviceCount).toDouble();
    }
  }

  double? _pct(double prev, double cur) => prev > 0 ? (cur - prev) / prev * 100 : null;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final yearText = widget.year?.toString() ?? 'this year';
    final activeData = data.where((d) => d.hasData).toList();

    if (activeData.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20.0),
        decoration: DashUi.panel(),
        child: Center(
          child: Text('No job data for $yearText yet.', style: const TextStyle(color: DashUi.muted, fontWeight: FontWeight.w500, fontSize: 14)),
        ),
      );
    }

    double headlineNum = 0;
    for (final d in activeData) {
      headlineNum += _metricValue(d);
    }

    String headlineValue;
    String headlineLabel;
    switch (_metric) {
      case _JobsChartMetric.volume:
        headlineValue = NumberFormat('#,##0').format(headlineNum);
        headlineLabel = 'Completed jobs in $yearText';
        break;
      case _JobsChartMetric.mix:
        headlineValue = _compactMoney(headlineNum);
        headlineLabel = 'Residential + commercial revenue';
        break;
      case _JobsChartMetric.installEstimate:
        headlineValue = NumberFormat('#,##0').format(headlineNum);
        headlineLabel = 'Install + service jobs completed';
        break;
    }

    int? peakIndex;
    var peakValue = 0.0;
    for (var i = 0; i < data.length; i++) {
      if (!data[i].hasData) continue;
      final v = _metricValue(data[i]);
      if (v > peakValue) {
        peakValue = v;
        peakIndex = i;
      }
    }

    var maxV = 0.0;
    for (final d in data) {
      if (!d.hasData) continue;
      if (_metric == _JobsChartMetric.mix) {
        maxV = math.max(maxV, d.totalRevenue);
      } else if (_metric == _JobsChartMetric.installEstimate) {
        maxV = math.max(maxV, (d.installCount + d.serviceCount).toDouble());
      } else {
        maxV = math.max(maxV, d.completedTotal.toDouble());
      }
    }
    final scale = _jobsNiceScale(maxV);

    double? trendPct;
    String? trendLabel;
    if (activeData.length >= 2) {
      final last = activeData.last;
      final prev = activeData[activeData.length - 2];
      trendPct = _pct(_metricValue(prev), _metricValue(last));
      trendLabel = '${last.month} vs ${prev.month}';
    }

    final avgForBenchmark = _metric == _JobsChartMetric.volume ? headlineNum / activeData.length : 0.0;

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
                  Text(_metric.caption, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: DashUi.slate)),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(headlineValue, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: DashUi.ink, height: 1.1)),
                      const SizedBox(width: 10),
                      Text(headlineLabel, style: const TextStyle(fontSize: 13, color: DashUi.muted, fontWeight: FontWeight.w500)),
                      if (trendPct != null) ...[
                        const SizedBox(width: 10),
                        _JobsTrendChip(pct: trendPct, label: trendLabel!),
                      ],
                    ],
                  ),
                ],
              ),
              _JobsMetricToggle(value: _metric, onChanged: _setMetric),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                return MouseRegion(
                  onEnter: (_) {
                    _chartHovering = true;
                    _cycleTimer?.cancel();
                  },
                  onHover: (e) => _setActive(_indexFor(e.localPosition.dx, c.maxWidth)),
                  onExit: (_) {
                    _setActive(null);
                    _chartHovering = false;
                    _restartCycleTimer();
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
                          painter: _JobsChartPainter(
                            data: data,
                            metric: _metric,
                            scale: scale,
                            avgBenchmark: avgForBenchmark,
                            peakIndex: peakIndex,
                            index: _paintedIndex,
                            intro: _intro.value,
                            hover: Curves.easeOutCubic.transform(_hover.value),
                          ),
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 18,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (_metric == _JobsChartMetric.volume) ...[
                _legendSwatch(Container(width: 12, height: 12, decoration: BoxDecoration(color: DashUi.indigo, borderRadius: BorderRadius.circular(3))), 'Completed jobs'),
                _legendSwatch(Container(width: 14, height: 2, color: DashUi.red), 'Monthly avg'),
              ],
              if (_metric == _JobsChartMetric.mix) ...[
                _legendSwatch(Container(width: 12, height: 12, color: DashUi.sky), 'Residential'),
                _legendSwatch(Container(width: 12, height: 12, color: DashUi.amber), 'Commercial'),
              ],
              if (_metric == _JobsChartMetric.installEstimate) ...[
                _legendSwatch(Container(width: 8, height: 8, decoration: const BoxDecoration(color: DashUi.indigo, shape: BoxShape.circle)), 'Install'),
                _legendSwatch(Container(width: 8, height: 8, decoration: const BoxDecoration(color: DashUi.sky, shape: BoxShape.circle)), 'Service'),
              ],
              if (peakIndex != null)
                _legendSwatch(
                  Transform.rotate(angle: math.pi / 4, child: Container(width: 8, height: 8, color: DashUi.amber)),
                  'Peak in ${data[peakIndex].month}',
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _legendSwatch(Widget swatch, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [swatch, const SizedBox(width: 8), Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: DashUi.slate))],
    );
  }
}

class _JobsTrendChip extends StatelessWidget {
  final double pct;
  final String label;
  const _JobsTrendChip({required this.pct, required this.label});

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
          Text('${pct.abs().toStringAsFixed(1)}% $label', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
        ],
      ),
    );
  }
}

class _JobsMetricToggle extends StatelessWidget {
  final _JobsChartMetric value;
  final ValueChanged<_JobsChartMetric> onChanged;
  const _JobsMetricToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: _JobsChartMetric.values.map((m) {
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

class _JobsChartPainter extends CustomPainter {
  static const double leftGutter = 46;
  static const double bottomGutter = 26;
  static const double topPad = 6;

  final List<_MonthlyJobData> data;
  final _JobsChartMetric metric;
  final _JobsAxisScale scale;
  final double avgBenchmark;
  final int? peakIndex;
  final int? index;
  final double intro;
  final double hover;

  const _JobsChartPainter({
    required this.data,
    required this.metric,
    required this.scale,
    required this.avgBenchmark,
    required this.peakIndex,
    required this.index,
    required this.intro,
    required this.hover,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(leftGutter, topPad, size.width, size.height - bottomGutter);
    if (plot.width <= 0 || plot.height <= 0 || data.isEmpty) return;

    final n = data.length;
    final slotW = plot.width / n;
    final focusing = index != null && hover > 0.001;

    double yFor(double v) => plot.bottom - (v / scale.max).clamp(0.0, 1.0) * plot.height;

    if (focusing) {
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(plot.left + index! * slotW + 2, plot.top, slotW - 4, plot.height),
        const Radius.circular(10),
      );
      canvas.drawRRect(r, Paint()..color = const Color(0xFFEFF6FF).withValues(alpha: hover));
    }

    for (var i = 0; i <= scale.ticks; i++) {
      final v = i * scale.step;
      final y = yFor(v);
      canvas.drawLine(
        Offset(plot.left, y),
        Offset(plot.right, y),
        Paint()
          ..color = i == 0 ? DashUi.line : DashUi.faint
          ..strokeWidth = 1,
      );
      final label = metric == _JobsChartMetric.mix ? _compactMoney(v) : v.round().toString();
      final tp = _layoutText(label, const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: DashUi.muted));
      tp.paint(canvas, Offset(leftGutter - 8 - tp.width, y - tp.height / 2));
    }

    if (metric == _JobsChartMetric.volume && avgBenchmark > 0) {
      final avgY = yFor(avgBenchmark);
      final dashPaint = Paint()
        ..color = DashUi.red
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      for (double dx = plot.left; dx < plot.right; dx += 8) {
        canvas.drawLine(Offset(dx, avgY), Offset(dx + 4, avgY), dashPaint);
      }
    }

    final stagger = 0.4 / n;

    for (var i = 0; i < n; i++) {
      final p = data[i];
      final has = p.hasData;
      final isFocus = focusing && index == i;
      final dim = (focusing && !isFocus) ? 1 - 0.5 * hover : 1.0;
      final cx = plot.left + slotW * (i + 0.5);
      final localT = Curves.easeOutCubic.transform(((intro - i * stagger) / 0.6).clamp(0.0, 1.0));

      final labelTp = _layoutText(
        p.month,
        TextStyle(
          fontSize: 12.5,
          fontWeight: isFocus ? FontWeight.w800 : FontWeight.w600,
          color: isFocus ? DashUi.ink : (has ? DashUi.slate : const Color(0xFFCBD5E1)),
        ),
        maxWidth: slotW,
        align: TextAlign.center,
      );
      labelTp.paint(canvas, Offset(cx - labelTp.width / 2, plot.bottom + 8));

      if (!has) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(cx, plot.bottom - 1.5), width: 16, height: 3), const Radius.circular(2)),
          Paint()..color = DashUi.line,
        );
        continue;
      }

      if (metric == _JobsChartMetric.volume) {
        final barW = math.min(slotW * 0.5, 26.0) + (isFocus ? 4 * hover : 0);
        final fullH = (p.completedTotal / scale.max).clamp(0.0, 1.0) * plot.height;
        final h = math.max(3.0, fullH * localT);
        final rect = Rect.fromLTWH(cx - barW / 2, plot.bottom - h, barW, h);
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(5)),
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [const Color(0xFF4338CA).withValues(alpha: dim), const Color(0xFF818CF8).withValues(alpha: dim)],
            ).createShader(rect),
        );
      } else if (metric == _JobsChartMetric.mix) {
        final barW = math.min(slotW * 0.5, 26.0) + (isFocus ? 4 * hover : 0);
        final comH = ((p.comRevenue / scale.max).clamp(0.0, 1.0) * plot.height) * localT;
        final resH = ((p.resRevenue / scale.max).clamp(0.0, 1.0) * plot.height) * localT;
        final yCom = plot.bottom - comH;
        final yRes = yCom - resH;
        if (comH > 0.5) {
          canvas.drawRect(Rect.fromLTWH(cx - barW / 2, yCom, barW, comH), Paint()..color = DashUi.amber.withValues(alpha: dim));
        }
        if (resH > 0.5) {
          canvas.drawRRect(
            RRect.fromRectAndCorners(Rect.fromLTWH(cx - barW / 2, yRes, barW, resH), topLeft: const Radius.circular(5), topRight: const Radius.circular(5)),
            Paint()..color = DashUi.sky.withValues(alpha: dim),
          );
        }
      } else {
        // Stacked Install Split: install volume on the bottom, service above.
        final barW = math.min(slotW * 0.56, 32.0) + (isFocus ? 4 * hover : 0);
        final installH = ((p.installCount / scale.max).clamp(0.0, 1.0) * plot.height) * localT;
        final serviceH = ((p.serviceCount / scale.max).clamp(0.0, 1.0) * plot.height) * localT;
        final totalH = installH + serviceH;
        final left = cx - barW / 2;
        final installRect = Rect.fromLTWH(left, plot.bottom - installH, barW, installH);
        final serviceRect = Rect.fromLTWH(left, plot.bottom - totalH, barW, serviceH);

        if (installH > 0.5) {
          canvas.drawRRect(
            RRect.fromRectAndCorners(
              installRect,
              bottomLeft: const Radius.circular(4),
              bottomRight: const Radius.circular(4),
              topLeft: serviceH <= 0.5 ? const Radius.circular(5) : Radius.zero,
              topRight: serviceH <= 0.5 ? const Radius.circular(5) : Radius.zero,
            ),
            Paint()..color = DashUi.indigo.withValues(alpha: dim),
          );
        }
        if (serviceH > 0.5) {
          canvas.drawRRect(
            RRect.fromRectAndCorners(
              serviceRect,
              topLeft: const Radius.circular(5),
              topRight: const Radius.circular(5),
            ),
            Paint()..color = DashUi.sky.withValues(alpha: dim),
          );
        }
      }

      if (peakIndex == i && localT > 0.98) {
        final val = metric == _JobsChartMetric.mix
            ? p.totalRevenue
            : (metric == _JobsChartMetric.installEstimate ? (p.installCount + p.serviceCount).toDouble() : p.completedTotal.toDouble());
        final topY = yFor(val) - 14;
        final c = Offset(cx, topY);
        final path = Path()
          ..moveTo(c.dx, c.dy - 4)
          ..lineTo(c.dx + 4, c.dy)
          ..lineTo(c.dx, c.dy + 4)
          ..lineTo(c.dx - 4, c.dy)
          ..close();
        canvas.drawPath(path, Paint()..color = DashUi.amber.withValues(alpha: dim));
      }
    }

    if (focusing) _paintTooltip(canvas, size, plot, slotW, yFor);
  }

  void _paintTooltip(Canvas canvas, Size size, Rect plot, double slotW, double Function(double) yFor) {
    final i = index!;
    final p = data[i];
    final has = p.hasData;

    final rows = <(String, String)>[];
    switch (metric) {
      case _JobsChartMetric.volume:
        rows.add(('Completed', has ? p.completedTotal.toString() : '—'));
        break;
      case _JobsChartMetric.mix:
        rows.add(('Residential', _compactMoney(p.resRevenue)));
        rows.add(('Commercial', _compactMoney(p.comRevenue)));
        rows.add(('Total', _compactMoney(p.totalRevenue)));
        break;
      case _JobsChartMetric.installEstimate:
        final total = p.installCount + p.serviceCount;
        final installPct = total > 0 ? (p.installCount / total * 100).round() : 0;
        final servicePct = total > 0 ? (p.serviceCount / total * 100).round() : 0;
        rows.add(('Install', '${NumberFormat('#,##0').format(p.installCount)}  ·  $installPct%'));
        rows.add(('Service', '${NumberFormat('#,##0').format(p.serviceCount)}  ·  $servicePct%'));
        rows.add(('Total jobs', NumberFormat('#,##0').format(total)));
        break;
    }

    final titleTp = _layoutText('${p.month} Detail', const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w800));
    final labelTps = <TextPainter>[];
    final valueTps = <TextPainter>[];
    for (final r in rows) {
      labelTps.add(_layoutText(r.$1, const TextStyle(color: Color(0xFF94A3B8), fontSize: 11.5, fontWeight: FontWeight.w500)));
      valueTps.add(_layoutText(r.$2, const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)));
    }

    final labelW = labelTps.map((t) => t.width).reduce(math.max);
    final valueW = valueTps.map((t) => t.width).reduce(math.max);
    final tipW = math.max(titleTp.width, labelW + 16 + valueW) + 28;
    final rowH = labelTps.first.height;
    final tipH = 12 + titleTp.height + 6 + rows.length * rowH + (rows.length - 1) * 3 + 12;

    final cx = plot.left + slotW * (i + 0.5);
    final val = metric == _JobsChartMetric.mix
        ? p.totalRevenue
        : (metric == _JobsChartMetric.installEstimate ? (p.installCount + p.serviceCount).toDouble() : p.completedTotal.toDouble());
    final barTop = has ? yFor(val) : plot.bottom - 3;

    double tx, ty;
    var caretAbove = false;
    final aboveY = barTop - tipH - 16;
    if (aboveY >= 0) {
      ty = aboveY;
      tx = cx - tipW / 2;
      caretAbove = true;
    } else {
      ty = math.max(plot.top, math.min(barTop - 8, plot.bottom - tipH));
      final rightX = cx + slotW * 0.3 + 12;
      tx = rightX + tipW <= size.width ? rightX : cx - slotW * 0.3 - 12 - tipW;
    }
    tx = math.max(0, math.min(tx, size.width - tipW));

    canvas.saveLayer(Rect.fromLTWH(tx - 24, ty - 24, tipW + 48, tipH + 60), Paint()..color = Colors.white.withValues(alpha: hover));

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

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _JobsChartPainter old) =>
      old.data != data ||
      old.metric != metric ||
      old.intro != intro ||
      old.index != index ||
      old.hover != hover ||
      old.peakIndex != peakIndex ||
      old.avgBenchmark != avgBenchmark;
}

// =============================================================================
// AVG JOB VALUE LINE CHART
// =============================================================================

class _AvgJobValueChart extends StatefulWidget {
  final List<_MonthlyJobData> data;
  final int? year;
  const _AvgJobValueChart({required this.data, this.year});

  @override
  State<_AvgJobValueChart> createState() => _AvgJobValueChartState();
}

class _AvgJobValueChartState extends State<_AvgJobValueChart> with SingleTickerProviderStateMixin {
  late final AnimationController _intro;
  late final AnimationController _hover;
  int? _paintedIndex;
  bool _chartHovering = false;

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..forward();
    _hover = AnimationController(vsync: this, duration: const Duration(milliseconds: 160));
  }

  @override
  void didUpdateWidget(covariant _AvgJobValueChart old) {
    super.didUpdateWidget(old);
    if (!identical(old.data, widget.data)) {
      _paintedIndex = null;
      _hover.value = 0;
      _intro.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    _hover.dispose();
    super.dispose();
  }

  void _setActive(int? i) {
    if (i == _paintedIndex) return;
    setState(() => _paintedIndex = i);
    if (i != null) {
      _hover.forward();
    } else {
      _hover.reverse();
    }
  }

  int? _indexFor(double dx, double width) {
    final n = widget.data.length;
    if (n == 0) return null;
    final plotW = width - _AvgValuePainter.leftGutter;
    if (plotW <= 0) return null;
    final i = ((dx - _AvgValuePainter.leftGutter) / (plotW / n)).floor();
    if (i < 0 || i >= n) return null;
    return i;
  }

  double _avgValue(_MonthlyJobData d) => d.completedTotal > 0 ? d.totalRevenue / d.completedTotal : 0.0;
  double? _pct(double prev, double cur) => prev > 0 ? (cur - prev) / prev * 100 : null;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final activeData = data.where((d) => d.hasData).toList();

    if (activeData.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20.0),
        decoration: DashUi.panel(),
        child: const Center(child: Text('No data for avg job value yet.', style: TextStyle(color: DashUi.muted))),
      );
    }

    double totalRev = 0;
    int totalJobs = 0;
    for (final d in activeData) {
      totalRev += d.totalRevenue;
      totalJobs += d.completedTotal;
    }
    final overallAvg = totalJobs > 0 ? totalRev / totalJobs : 0.0;

    var maxV = 0.0;
    int? peakIndex;
    var peakValue = 0.0;

    for (var i = 0; i < data.length; i++) {
      if (!data[i].hasData) continue;
      final val = _avgValue(data[i]);
      maxV = math.max(maxV, val);
      if (val > peakValue) {
        peakValue = val;
        peakIndex = i;
      }
    }
    final scale = _jobsNiceScale(maxV);

    double? trendPct;
    String? trendLabel;
    if (activeData.length >= 2) {
      final last = activeData.last;
      final prev = activeData[activeData.length - 2];
      trendPct = _pct(_avgValue(prev), _avgValue(last));
      trendLabel = '${last.month} vs ${prev.month}';
    }

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
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Average Job Value', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: DashUi.slate)),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text('\$${NumberFormat('#,##0').format(overallAvg)}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: DashUi.ink, height: 1.1)),
                      const SizedBox(width: 10),
                      const Text('YTD Average', style: TextStyle(fontSize: 12.5, color: DashUi.muted, fontWeight: FontWeight.w500)),
                      if (trendPct != null) ...[
                        const SizedBox(width: 10),
                        _JobsTrendChip(pct: trendPct, label: trendLabel!),
                      ],
                    ],
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 12, height: 3, color: DashUi.emeraldDeep),
                  const SizedBox(width: 6),
                  const Text('Avg Rev / Job', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: DashUi.slate)),
                ],
              )
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                return MouseRegion(
                  onEnter: (_) => _chartHovering = true,
                  onHover: (e) => _setActive(_indexFor(e.localPosition.dx, c.maxWidth)),
                  onExit: (_) {
                    _setActive(null);
                    _chartHovering = false;
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
                          painter: _AvgValuePainter(
                            data: data,
                            scale: scale,
                            peakIndex: peakIndex,
                            index: _paintedIndex,
                            intro: _intro.value,
                            hover: Curves.easeOutCubic.transform(_hover.value),
                          ),
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _AvgValuePainter extends CustomPainter {
  static const double leftGutter = 46;
  static const double bottomGutter = 26;
  static const double topPad = 6;

  final List<_MonthlyJobData> data;
  final _JobsAxisScale scale;
  final int? peakIndex;
  final int? index;
  final double intro;
  final double hover;

  const _AvgValuePainter({
    required this.data,
    required this.scale,
    required this.peakIndex,
    required this.index,
    required this.intro,
    required this.hover,
  });

  double _avgValue(_MonthlyJobData d) => d.completedTotal > 0 ? d.totalRevenue / d.completedTotal : 0.0;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(leftGutter, topPad, size.width, size.height - bottomGutter);
    if (plot.width <= 0 || plot.height <= 0 || data.isEmpty) return;

    final n = data.length;
    final slotW = plot.width / n;
    final focusing = index != null && hover > 0.001;

    double yFor(double v) => plot.bottom - (v / scale.max).clamp(0.0, 1.0) * plot.height;

    // Hover Highlight
    if (focusing) {
      final r = RRect.fromRectAndRadius(Rect.fromLTWH(plot.left + index! * slotW + 2, plot.top, slotW - 4, plot.height), const Radius.circular(10));
      canvas.drawRRect(r, Paint()..color = const Color(0xFFEFF6FF).withValues(alpha: hover));
    }

    // Grid lines
    for (var i = 0; i <= scale.ticks; i++) {
      final v = i * scale.step;
      final y = yFor(v);
      canvas.drawLine(
        Offset(plot.left, y), Offset(plot.right, y),
        Paint()..color = i == 0 ? DashUi.line : DashUi.faint..strokeWidth = 1,
      );
      final label = '\$${(v >= 1000 ? '${(v / 1000).toStringAsFixed(v % 1000 == 0 ? 0 : 1)}k' : v.round())}';
      final tp = _layoutText(label, const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: DashUi.muted));
      tp.paint(canvas, Offset(leftGutter - 8 - tp.width, y - tp.height / 2));
    }

    final validPts = <Offset>[];
    final stagger = 0.4 / n;

    // Labels & Points calculation
    for (var i = 0; i < n; i++) {
      final p = data[i];
      final isFocus = focusing && index == i;
      final cx = plot.left + slotW * (i + 0.5);
      final localT = Curves.easeOutCubic.transform(((intro - i * stagger) / 0.6).clamp(0.0, 1.0));

      final labelTp = _layoutText(
        p.month,
        TextStyle(fontSize: 12.5, fontWeight: isFocus ? FontWeight.w800 : FontWeight.w600, color: isFocus ? DashUi.ink : (p.hasData ? DashUi.slate : const Color(0xFFCBD5E1))),
        maxWidth: slotW, align: TextAlign.center,
      );
      labelTp.paint(canvas, Offset(cx - labelTp.width / 2, plot.bottom + 8));

      if (p.hasData) {
        final targetY = yFor(_avgValue(p));
        final animY = plot.bottom - (plot.bottom - targetY) * localT;
        validPts.add(Offset(cx, animY));
      } else {
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(cx, plot.bottom - 1.5), width: 16, height: 3), const Radius.circular(2)), Paint()..color = DashUi.line);
      }
    }

    // Draw Line and Gradient Fill
    if (validPts.isNotEmpty) {
      final path = Path()..moveTo(validPts.first.dx, validPts.first.dy);
      for (var i = 1; i < validPts.length; i++) {
        path.lineTo(validPts[i].dx, validPts[i].dy);
      }

      // Fill area under the line
      final areaPath = Path.from(path);
      areaPath.lineTo(validPts.last.dx, plot.bottom);
      areaPath.lineTo(validPts.first.dx, plot.bottom);
      areaPath.close();

      canvas.drawPath(
        areaPath,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [DashUi.emeraldDeep.withValues(alpha: 0.15), DashUi.emeraldDeep.withValues(alpha: 0.0)],
          ).createShader(Rect.fromLTRB(plot.left, plot.top, plot.right, plot.bottom)),
      );

      // Stroke Line
      canvas.drawPath(
        path,
        Paint()..color = DashUi.emeraldDeep..strokeWidth = 3..style = PaintingStyle.stroke..strokeJoin = StrokeJoin.round..strokeCap = StrokeCap.round,
      );

      // Dots
      for (final pt in validPts) {
        canvas.drawCircle(pt, 5, Paint()..color = Colors.white);
        canvas.drawCircle(pt, 3, Paint()..color = DashUi.emeraldDeep);
      }
    }

    if (focusing) _paintTooltip(canvas, size, plot, slotW, yFor);
  }

  void _paintTooltip(Canvas canvas, Size size, Rect plot, double slotW, double Function(double) yFor) {
    final i = index!;
    final p = data[i];
    if (!p.hasData) return;

    final avg = _avgValue(p);
    final rows = [
      ('Avg Value', '\$${NumberFormat('#,##0.00').format(avg)}'),
      ('Total Rev', '\$${NumberFormat('#,##0').format(p.totalRevenue)}'),
      ('Jobs', p.completedTotal.toString()),
    ];

    final titleTp = _layoutText('${p.month} Average', const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w800));
    final labelTps = rows.map((r) => _layoutText(r.$1, const TextStyle(color: Color(0xFF94A3B8), fontSize: 11.5, fontWeight: FontWeight.w500))).toList();
    final valueTps = rows.map((r) => _layoutText(r.$2, const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700))).toList();

    final labelW = labelTps.map((t) => t.width).reduce(math.max);
    final valueW = valueTps.map((t) => t.width).reduce(math.max);
    final tipW = math.max(titleTp.width, labelW + 16 + valueW) + 28;
    final rowH = labelTps.first.height;
    final tipH = 12 + titleTp.height + 6 + rows.length * rowH + (rows.length - 1) * 3 + 12;

    final cx = plot.left + slotW * (i + 0.5);
    final barTop = yFor(avg);

    double tx, ty;
    var caretAbove = false;
    final aboveY = barTop - tipH - 16;
    if (aboveY >= 0) {
      ty = aboveY;
      tx = cx - tipW / 2;
      caretAbove = true;
    } else {
      ty = math.max(plot.top, math.min(barTop - 8, plot.bottom - tipH));
      final rightX = cx + slotW * 0.3 + 12;
      tx = rightX + tipW <= size.width ? rightX : cx - slotW * 0.3 - 12 - tipW;
    }
    tx = math.max(0, math.min(tx, size.width - tipW));

    canvas.saveLayer(Rect.fromLTWH(tx - 24, ty - 24, tipW + 48, tipH + 60), Paint()..color = Colors.white.withValues(alpha: hover));
    final rrect = RRect.fromRectAndRadius(Rect.fromLTWH(tx, ty, tipW, tipH), const Radius.circular(10));
    canvas.drawRRect(rrect.shift(const Offset(0, 4)), Paint()..color = Colors.black.withValues(alpha: 0.22)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
    canvas.drawRRect(rrect, Paint()..color = DashUi.ink);

    if (caretAbove) {
      final ccx = math.max(tx + 16, math.min(cx, tx + tipW - 16));
      final caret = Path()..moveTo(ccx - 5, ty + tipH)..lineTo(ccx + 5, ty + tipH)..lineTo(ccx, ty + tipH + 5)..close();
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
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _AvgValuePainter old) => old.data != data || old.index != index || old.intro != intro || old.hover != hover;
}

// =============================================================================
// STATUS DONUT + QUICK INSIGHTS PANEL
// =============================================================================

class _JobSegSlice {
  final String name;
  final double amount;
  final Color color;
  const _JobSegSlice(this.name, this.amount, this.color);
}

class _JobsStatusPanel extends StatefulWidget {
  final List<_JobStatusCount>? statusCounts;
  final bool loading;
  final List<_MonthlyJobData> monthly;

  const _JobsStatusPanel({
    required this.statusCounts,
    required this.loading,
    required this.monthly,
  });

  @override
  State<_JobsStatusPanel> createState() => _JobsStatusPanelState();
}

class _JobsStatusPanelState extends State<_JobsStatusPanel> with SingleTickerProviderStateMixin {
  late final AnimationController _intro;
  int? _active;
  static const _topN = 5;

  List<_JobSegSlice> get _slices {
    final raw = widget.statusCounts;
    if (raw == null || raw.isEmpty) return const [];
    final sorted = [...raw]..sort((a, b) => b.count.compareTo(a.count));
    final top = sorted.take(_topN).toList();
    final restSum = sorted.skip(_topN).fold<int>(0, (s, c) => s + c.count);
    final slices = <_JobSegSlice>[
      for (var i = 0; i < top.length; i++)
        _JobSegSlice(top[i].status, top[i].count.toDouble(), _categoricalPalette[i % _categoricalPalette.length]),
    ];
    if (restSum > 0) slices.add(_JobSegSlice('Other', restSum.toDouble(), DashUi.slate));
    return slices;
  }

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..forward();
  }

  @override
  void didUpdateWidget(covariant _JobsStatusPanel old) {
    super.didUpdateWidget(old);
    if (!identical(old.statusCounts, widget.statusCounts)) {
      _active = null;
      _intro.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  void _setActive(int? i) {
    if (i == _active) return;
    setState(() => _active = i);
  }

  int? _hit(Offset p, double side, List<_JobSegSlice> slices, double total) {
    if (total <= 0) return null;
    final d = p - Offset(side / 2, side / 2);
    final r = _JobsDonutPainter.radiusFor(side);
    final half = _JobsDonutPainter.strokeFor(side) / 2 + 4;
    if (d.distance < r - half || d.distance > r + half) return null;
    var ang = math.atan2(d.dy, d.dx) + math.pi / 2;
    if (ang < 0) ang += 2 * math.pi;
    var acc = 0.0;
    for (var i = 0; i < slices.length; i++) {
      if (slices[i].amount <= 0) continue;
      acc += slices[i].amount / total * 2 * math.pi;
      if (ang <= acc) return i;
    }
    return null;
  }

  Widget _center(List<_JobSegSlice> slices, double total, double side) {
    Widget child;
    final i = _active;
    final fmt = NumberFormat('#,##0');
    if (total <= 0) {
      child = const Text('No jobs\nyet', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: DashUi.muted, fontWeight: FontWeight.w600));
    } else if (i != null) {
      final s = slices[i];
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${(s.amount / total * 100).toStringAsFixed(1)}%', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: s.color, height: 1.05)),
          const SizedBox(height: 2),
          Text(s.name, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: DashUi.slate), maxLines: 1, overflow: TextOverflow.ellipsis),
          Text('${fmt.format(s.amount)} jobs', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: DashUi.muted)),
        ],
      );
    } else {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(fmt.format(total), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: DashUi.ink, height: 1.05)),
          const SizedBox(height: 2),
          const Text('Total jobs', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: DashUi.slate)),
        ],
      );
    }
    return SizedBox(width: side * 0.56, child: FittedBox(fit: BoxFit.scaleDown, child: child));
  }

  Widget _legend(List<_JobSegSlice> slices, double total) {
    final fmt = NumberFormat('#,##0');
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(slices.length, (i) {
        final s = slices[i];
        final isActive = _active == i;
        final faded = _active != null && !isActive;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: MouseRegion(
            onEnter: (_) => _setActive(i),
            onExit: (_) => _setActive(null),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _setActive(isActive ? null : i),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 180),
                opacity: faded ? 0.35 : 1.0,
                child: Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: isActive ? 14 : 10,
                      height: isActive ? 14 : 10,
                      decoration: BoxDecoration(color: s.color, borderRadius: BorderRadius.circular(4)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, fontWeight: isActive ? FontWeight.w800 : FontWeight.w600, color: isActive ? DashUi.ink : DashUi.slate),
                      ),
                    ),
                    Text(fmt.format(s.amount), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: s.color)),
                  ],
                ),
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _statRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: DashUi.slate)),
          Text(value, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: valueColor ?? DashUi.ink)),
        ],
      ),
    );
  }

  Widget _splitBar({
    required String leftLabel,
    required Color leftColor,
    required double leftValue,
    required String rightLabel,
    required Color rightColor,
    required double rightValue,
  }) {
    final total = leftValue + rightValue;
    final leftPct = total > 0 ? leftValue / total : 0.5;
    final leftPctText = total > 0 ? '${(leftValue / total * 100).round()}%' : '—';
    final rightPctText = total > 0 ? '${(rightValue / total * 100).round()}%' : '—';
    final leftFlex = (leftPct * 1000).round().clamp(1, 999);
    final rightFlex = (1000 - leftFlex).clamp(1, 999);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: leftColor, borderRadius: BorderRadius.circular(2))),
                  const SizedBox(width: 5),
                  Text(leftLabel, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: DashUi.slate)),
                  const SizedBox(width: 4),
                  Text(leftPctText, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: leftColor)),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(rightPctText, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: rightColor)),
                  const SizedBox(width: 4),
                  Text(rightLabel, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: DashUi.slate)),
                  const SizedBox(width: 5),
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: rightColor, borderRadius: BorderRadius.circular(2))),
                ],
              ),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 8,
              child: Row(
                children: [
                  Expanded(flex: leftFlex, child: Container(color: leftColor)),
                  Expanded(flex: rightFlex, child: Container(color: rightColor)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _quickInsights() {
    final active = widget.monthly.where((m) => m.hasData).toList();
    if (active.isEmpty) {
      return const Text('Not enough job history yet for insights.', style: TextStyle(fontSize: 11.5, color: DashUi.muted, fontWeight: FontWeight.w600));
    }

    final totalCompleted = active.fold<int>(0, (s, m) => s + m.completedTotal);
    final avgPerMonth = totalCompleted / active.length;
    final busiest = active.reduce((a, b) => a.completedTotal >= b.completedTotal ? a : b);
    final totalInstall = active.fold<int>(0, (s, m) => s + m.installCount);
    final totalService = active.fold<int>(0, (s, m) => s + m.serviceCount);
    final totalRes = active.fold<double>(0, (s, m) => s + m.resRevenue);
    final totalCom = active.fold<double>(0, (s, m) => s + m.comRevenue);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _statRow('Busiest month', '${busiest.month} · ${NumberFormat('#,##0').format(busiest.completedTotal)} jobs', valueColor: DashUi.emeraldDeep),
        _statRow('Avg jobs / month', avgPerMonth.toStringAsFixed(1)),
        const SizedBox(height: 2),
        if (totalInstall + totalService > 0)
          _splitBar(
            leftLabel: 'Install',
            leftColor: DashUi.indigo,
            leftValue: totalInstall.toDouble(),
            rightLabel: 'Service',
            rightColor: DashUi.sky,
            rightValue: totalService.toDouble(),
          ),
        if (totalRes + totalCom > 0)
          _splitBar(
            leftLabel: 'Residential',
            leftColor: DashUi.sky,
            leftValue: totalRes,
            rightLabel: 'Commercial',
            rightColor: DashUi.amber,
            rightValue: totalCom,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final slices = _slices;
    final total = slices.fold<double>(0, (s, e) => s + e.amount);

    return Container(
      padding: const EdgeInsets.all(20.0),
      decoration: DashUi.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('ACTIVE JOBS BY STATUS', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: DashUi.ink, letterSpacing: 0.8)),
              Text('All-time', style: TextStyle(fontSize: 10.5, color: DashUi.muted, fontWeight: FontWeight.w600, fontStyle: FontStyle.italic)),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: widget.loading
                ? const Center(child: CircularProgressIndicator(color: DashUi.blue))
                : slices.isEmpty
                    ? const Center(
                        child: Text('Status breakdown not available.', style: TextStyle(color: DashUi.muted, fontSize: 12.5, fontWeight: FontWeight.w600)),
                      )
                    : LayoutBuilder(
                        builder: (context, c) {
                          final side = math.min(c.maxHeight, c.maxWidth * 0.5);
                          if (side <= 40) return const SizedBox.shrink();
                          return Row(
                            children: [
                              SizedBox(
                                width: side,
                                height: side,
                                child: MouseRegion(
                                  onHover: (e) => _setActive(_hit(e.localPosition, side, slices, total)),
                                  onExit: (_) => _setActive(null),
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTapDown: (d) => _setActive(_hit(d.localPosition, side, slices, total)),
                                    child: Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        AnimatedBuilder(
                                          animation: _intro,
                                          builder: (context, _) => CustomPaint(
                                            size: Size(side, side),
                                            painter: _JobsDonutPainter(slices: slices, total: total, active: _active, t: Curves.easeOutCubic.transform(_intro.value)),
                                          ),
                                        ),
                                        IgnorePointer(child: _center(slices, total, side)),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(child: _legend(slices, total)),
                            ],
                          );
                        },
                      ),
          ),
          const SizedBox(height: 14),
          Container(height: 1, color: DashUi.line),
          const SizedBox(height: 12),
          const Text('QUICK INSIGHTS', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: DashUi.ink, letterSpacing: 0.6)),
          const SizedBox(height: 10),
          _quickInsights(),
        ],
      ),
    );
  }
}

class _JobsDonutPainter extends CustomPainter {
  final List<_JobSegSlice> slices;
  final double total;
  final int? active;
  final double t;

  const _JobsDonutPainter({required this.slices, required this.total, required this.active, required this.t});

  static double strokeFor(double side) => side * 0.16;
  static double radiusFor(double side) => (side - strokeFor(side) - 10) / 2;

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    final center = Offset(size.width / 2, size.height / 2);
    final stroke = strokeFor(side);
    final rect = Rect.fromCircle(center: center, radius: radiusFor(side));

    canvas.drawCircle(
      center,
      radiusFor(side),
      Paint()
        ..color = DashUi.faint
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    if (total <= 0) return;

    final nonZero = slices.where((s) => s.amount > 0).length;
    final gap = nonZero > 1 ? 0.05 : 0.0;
    var start = -math.pi / 2;

    for (var i = 0; i < slices.length; i++) {
      final s = slices[i];
      if (s.amount <= 0) continue;
      final full = s.amount / total * 2 * math.pi;
      final sweep = math.max(0.0, full - gap) * t;
      final isActive = active == i;
      final dim = active != null && !isActive;

      canvas.drawArc(
        rect,
        start + gap / 2,
        sweep,
        false,
        Paint()
          ..color = s.color.withValues(alpha: dim ? 0.3 : 1.0)
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke + (isActive ? 6 : 0)
          ..strokeCap = StrokeCap.butt,
      );
      start += full;
    }
  }

  @override
  bool shouldRepaint(covariant _JobsDonutPainter old) => old.active != active || old.t != t || old.total != total || old.slices != slices;
}

// =============================================================================
// LOADING SKELETON
// =============================================================================

class _JobsSkeleton extends StatelessWidget {
  const _JobsSkeleton();

  Widget _metric() => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          decoration: DashUi.panel(radius: 12),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SkeletonBox(h: 12, w: 80),
              SizedBox(height: 12),
              SkeletonBox(h: 26, w: 90),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return SkeletonPulse(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 104,
            child: Row(children: [
              _metric(), const SizedBox(width: 8),
              _metric(), const SizedBox(width: 8),
              _metric(), const SizedBox(width: 8),
              _metric(), const SizedBox(width: 8),
              _metric(),
            ]),
          ),
          const SizedBox(height: 16),
          Expanded(
            flex: 10,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 7,
                  child: Column(
                    children: [
                      Expanded(
                        flex: 11,
                        child: Container(
                          padding: const EdgeInsets.all(20),
                          decoration: DashUi.panel(),
                          child: const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SkeletonBox(h: 16, w: 220),
                              SizedBox(height: 24),
                              Expanded(child: SkeletonBox(r: 8)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        flex: 9,
                        child: Container(
                          padding: const EdgeInsets.all(20),
                          decoration: DashUi.panel(),
                          child: const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SkeletonBox(h: 16, w: 180),
                              SizedBox(height: 24),
                              Expanded(child: SkeletonBox(r: 8)),
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
                        SkeletonBox(h: 16, w: 160),
                        SizedBox(height: 24),
                        Expanded(child: SkeletonBox(r: 8)),
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