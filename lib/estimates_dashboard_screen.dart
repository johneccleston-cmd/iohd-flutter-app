import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;
import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'widgets/dashboard_kit.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'widgets/dashboard_layout.dart';
import 'widgets/estimate_list_dialog.dart';

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

class _ChartScale {
  final double max;
  final double step;
  const _ChartScale(this.max, this.step);
  int get ticks => (max / step).round();
}

_ChartScale _niceScale(double maxV, {bool isCount = false}) {
  if (maxV <= 0) return const _ChartScale(4, 1);
  final raw = maxV / 4;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  final nice = norm <= 1 ? 1.0 : (norm <= 2 ? 2.0 : (norm <= 5 ? 5.0 : 10.0));
  var step = nice * mag;
  if (isCount && step < 1) step = 1;
  var top = (maxV / step).ceil() * step;
  if (top < maxV * 1.08) top += step;
  return _ChartScale(top, step);
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

class _EstimatesDashboardContentState extends State<EstimatesDashboardContent> {
  bool _isLoading = true;
  String? _errorMessage;

  double _openValue = 0.0;
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
    _fetchDashboardData();
  }

  @override
  void didUpdateWidget(covariant EstimatesDashboardContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedYear != widget.selectedYear) {
      _fetchDashboardData();
    }
  }

  int _parseInt(dynamic v) => v == null ? 0 : (v is num ? v.toInt() : int.tryParse(v.toString()) ?? 0);
  double _parseDouble(dynamic v) => v == null ? 0.0 : (v is num ? v.toDouble() : double.tryParse(v.toString()) ?? 0.0);

  Future<void> _fetchDashboardData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await http.get(
        Uri.parse('$kApiBaseUrl/api/dashboards/estimates?year=${widget.selectedYear}'),
        headers: AuthSession.instance.headers(),
      ).timeout(const Duration(seconds: 60));

      if (response.statusCode == 200) {
        final Map<String, dynamic> body = json.decode(response.body);
        final scorecards = body['scorecards'] ?? {};

        _openValue = _parseDouble(scorecards['openValue']);
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

        if (mounted) setState(() => _isLoading = false);
      } else {
        throw Exception('Status ${response.statusCode}');
      }
    } on TimeoutException {
      if (mounted) {
        setState(() {
          _errorMessage = 'The dashboard took too long to load. Check your connection.';
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
    if (_isLoading) return const _EstimatesSkeleton();
    if (_errorMessage != null) return DashErrorPanel(title: "Error loading estimates dashboard", message: _errorMessage!, onRetry: _fetchDashboardData);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Top 4 Scorecards (Compact Height, Empty Captions)
        SizedBox(
          height: 86,
          child: Row(
            children: [
              Expanded(child: AnimatedMetricCard(title: 'Open Value', value: _openValue, format: (v) => _money(v), caption: '', valueColor: DashUi.indigo, index: 0, trend: _openHistory.length >= 2 ? _openHistory : null)),
              const SizedBox(width: 8),
              Expanded(child: AnimatedMetricCard(title: 'Lost Value', value: _lostValue, format: (v) => _money(v), caption: '', valueColor: DashUi.red, index: 1, trend: dashTrend([for (final m in _valueData) m.lostValue], widget.selectedYear))),
              const SizedBox(width: 8),
              Expanded(child: AnimatedMetricCard(title: 'Avg Win Rate', value: _winRate, format: (v) => '${v.toStringAsFixed(1)}%', caption: '', valueColor: DashUi.emeraldDeep, index: 2, trend: dashTrend([for (final m in _valueData) m.winRate], widget.selectedYear))),
              const SizedBox(width: 8),
              Expanded(child: AnimatedMetricCard(title: 'Estimates Sent YTD', value: _sentYtd.toDouble(), format: (v) => _fmt(v.toInt()), caption: '', valueColor: DashUi.sky, index: 3, trend: dashTrend([for (final m in _valueData) m.sentCount.toDouble()], widget.selectedYear))),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Main Charts Section
        Expanded(
          flex: 10,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 7,
                child: Column(
                  children: [
                    Expanded(flex: 12, child: _InteractiveSentWonChart(data: _valueData, year: widget.selectedYear)),
                    const SizedBox(height: 16),
                    Expanded(flex: 8, child: _AvgEstimateValueChart(data: _valueData, year: widget.selectedYear)),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 5,
                child: Column(
                  children: [
                    Expanded(flex: 9, child: _PipelineAgingPanel(buckets: _agingBuckets, year: widget.selectedYear)),
                    const SizedBox(height: 16),
                    Expanded(flex: 11, child: _LostReasonsPanel(reasons: _lostReasons, loading: _isLoading, year: widget.selectedYear)),
                  ],
                ),
              ),
            ],
          ),
        ),

        // Auto-Scrolling Stale Pipeline Ticker
        if (_staleEstimates.isNotEmpty) ...[
          const SizedBox(height: 16),
          _AutoHorizontalStaleList(estimates: _staleEstimates),
        ],
      ],
    );
  }
}

// =============================================================================
// INTERACTIVE SENT VS WON CHART (COMBO SUPPORT + AUTO CYCLE)
// =============================================================================

enum _EstChartMetric { value, volume }

class _InteractiveSentWonChart extends StatefulWidget {
  final List<_MonthlyValueData> data;
  final int? year;
  const _InteractiveSentWonChart({required this.data, this.year});

  @override
  State<_InteractiveSentWonChart> createState() => _InteractiveSentWonChartState();
}

class _InteractiveSentWonChartState extends State<_InteractiveSentWonChart> with TickerProviderStateMixin {
  late final AnimationController _intro;
  late final AnimationController _hover;

  _EstChartMetric _metric = _EstChartMetric.value;
  int? _paintedIndex;
  bool _chartHovering = false;
  Timer? _metricCycleTimer;

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..forward();
    _hover = AnimationController(vsync: this, duration: const Duration(milliseconds: 160));
    _restartMetricCycleTimer();
  }

  @override
  void didUpdateWidget(covariant _InteractiveSentWonChart old) {
    super.didUpdateWidget(old);
    if (!identical(old.data, widget.data)) {
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
    final nextIndex = (_metric.index + 1) % _EstChartMetric.values.length;
    _setMetric(_EstChartMetric.values[nextIndex]);
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

  void _setMetric(_EstChartMetric m) {
    if (m == _metric) return;
    setState(() => _metric = m);
    _paintedIndex = null;
    _hover.value = 0;
    _intro.forward(from: 0);
    _restartMetricCycleTimer();
  }

  int? _indexFor(double dx, double width) {
    final n = widget.data.length;
    if (n == 0) return null;
    final plotW = width - _SentWonChartPainter.leftGutter - (_metric == _EstChartMetric.volume ? 30 : 0);
    if (plotW <= 0) return null;
    final i = ((dx - _SentWonChartPainter.leftGutter) / (plotW / n)).floor();
    if (i < 0 || i >= n) return null;
    return i;
  }

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
          child: Text('No estimate data for $yearText yet.', style: const TextStyle(color: DashUi.muted, fontWeight: FontWeight.w500, fontSize: 14)),
        ),
      );
    }

    double headlineValue = 0;
    for (final d in activeData) {
      headlineValue += _metric == _EstChartMetric.value ? d.sentValue : d.sentCount.toDouble();
    }

    var maxV = 0.0;
    for (final d in data) {
      if (!d.hasData) continue;
      maxV = math.max(maxV, _metric == _EstChartMetric.value ? d.sentValue : d.sentCount.toDouble());
    }
    final scale = _niceScale(maxV, isCount: _metric == _EstChartMetric.volume);

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
                  const Text('Estimate Pipeline', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: DashUi.slate)),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        _metric == _EstChartMetric.value ? _compactMoney(headlineValue) : NumberFormat('#,##0').format(headlineValue), 
                        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: DashUi.ink, height: 1.1)
                      ),
                      const SizedBox(width: 10),
                      Text('Total Sent in $yearText', style: const TextStyle(fontSize: 13, color: DashUi.muted, fontWeight: FontWeight.w500)),
                    ],
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _legendSwatch(Container(width: 12, height: 12, decoration: BoxDecoration(color: DashUi.slate, borderRadius: BorderRadius.circular(3))), 'Sent'),
                  const SizedBox(width: 12),
                  _legendSwatch(Container(width: 12, height: 12, decoration: BoxDecoration(color: DashUi.emeraldDeep, borderRadius: BorderRadius.circular(3))), 'Won'),
                  if (_metric == _EstChartMetric.volume) ...[
                    const SizedBox(width: 12),
                    _legendSwatch(Container(width: 14, height: 2, color: DashUi.blue), 'Win Rate'),
                  ],
                  const SizedBox(width: 24),
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(10)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _ToggleBtn(label: 'Value \$', selected: _metric == _EstChartMetric.value, onTap: () => _setMetric(_EstChartMetric.value)),
                        _ToggleBtn(label: 'Volume', selected: _metric == _EstChartMetric.volume, onTap: () => _setMetric(_EstChartMetric.volume)),
                      ],
                    ),
                  )
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                return MouseRegion(
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
                          painter: _SentWonChartPainter(
                            data: data,
                            metric: _metric,
                            scale: scale,
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

  Widget _legendSwatch(Widget swatch, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [swatch, const SizedBox(width: 6), Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: DashUi.slate))],
    );
  }
}

class _ToggleBtn extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ToggleBtn({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: selected ? DashUi.line : Colors.transparent),
          ),
          child: Text(
            label,
            style: TextStyle(fontSize: 12.5, fontWeight: selected ? FontWeight.w800 : FontWeight.w600, color: selected ? DashUi.blue : DashUi.slate),
          ),
        ),
      ),
    );
  }
}

class _SentWonChartPainter extends CustomPainter {
  static const double leftGutter = 46;
  static const double bottomGutter = 26;
  static const double topPad = 6;

  final List<_MonthlyValueData> data;
  final _EstChartMetric metric;
  final _ChartScale scale;
  final int? index;
  final double intro;
  final double hover;

  const _SentWonChartPainter({
    required this.data,
    required this.metric,
    required this.scale,
    required this.index,
    required this.intro,
    required this.hover,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rightGutter = metric == _EstChartMetric.volume ? 30.0 : 0.0;
    final plot = Rect.fromLTRB(leftGutter, topPad, size.width - rightGutter, size.height - bottomGutter);
    if (plot.width <= 0 || plot.height <= 0 || data.isEmpty) return;

    final n = data.length;
    final slotW = plot.width / n;
    final focusing = index != null && hover > 0.001;

    double yFor(double v) => plot.bottom - (v / scale.max).clamp(0.0, 1.0) * plot.height;
    double winRateY(double pct) => plot.bottom - (pct / 100.0).clamp(0.0, 1.0) * plot.height;

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
      final label = metric == _EstChartMetric.value ? _compactMoney(v) : v.round().toString();
      final tp = _layoutText(label, const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: DashUi.muted));
      tp.paint(canvas, Offset(leftGutter - 8 - tp.width, y - tp.height / 2));
    }

    // Right Y-axis for Win Rate %
    if (metric == _EstChartMetric.volume) {
      for (var i = 0; i <= 4; i++) {
        final pct = i * 25.0;
        final y = winRateY(pct);
        final tp = _layoutText('${pct.round()}%', const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: DashUi.blue));
        tp.paint(canvas, Offset(plot.right + 6, y - tp.height / 2));
      }
    }

    final sentPts = <Offset>[];
    final wonPts = <Offset>[];
    final ratePts = <Offset>[];
    final stagger = 0.4 / n;

    // Drawing calculations
    for (var i = 0; i < n; i++) {
      final p = data[i];
      final isFocus = focusing && index == i;
      final cx = plot.left + slotW * (i + 0.5);
      final localT = Curves.easeOutCubic.transform(((intro - i * stagger) / 0.6).clamp(0.0, 1.0));
      final dim = (focusing && !isFocus) ? 1 - 0.4 * hover : 1.0;

      final labelTp = _layoutText(
        p.month,
        TextStyle(fontSize: 12.5, fontWeight: isFocus ? FontWeight.w800 : FontWeight.w600, color: isFocus ? DashUi.ink : (p.hasData ? DashUi.slate : const Color(0xFFCBD5E1))),
        maxWidth: slotW, align: TextAlign.center,
      );
      labelTp.paint(canvas, Offset(cx - labelTp.width / 2, plot.bottom + 8));

      if (p.hasData) {
        if (metric == _EstChartMetric.value) {
          sentPts.add(Offset(cx, plot.bottom - (plot.bottom - yFor(p.sentValue)) * localT));
          wonPts.add(Offset(cx, plot.bottom - (plot.bottom - yFor(p.wonValue)) * localT));
        } else {
          // Volume Combo Chart: Grouped Bars + Line
          final barW = math.min(slotW * 0.35, 20.0);
          final spacing = 2.0;
          final sentH = (p.sentCount / scale.max) * plot.height * localT;
          final wonH = (p.wonCount / scale.max) * plot.height * localT;

          canvas.drawRRect(
            RRect.fromRectAndCorners(Rect.fromLTWH(cx - barW - spacing/2, plot.bottom - sentH, barW, math.max(2, sentH)), topLeft: const Radius.circular(4), topRight: const Radius.circular(4)),
            Paint()..color = DashUi.slate.withValues(alpha: dim * 0.7),
          );
          canvas.drawRRect(
            RRect.fromRectAndCorners(Rect.fromLTWH(cx + spacing/2, plot.bottom - wonH, barW, math.max(2, wonH)), topLeft: const Radius.circular(4), topRight: const Radius.circular(4)),
            Paint()..color = DashUi.emeraldDeep.withValues(alpha: dim),
          );
          
          ratePts.add(Offset(cx, plot.bottom - (plot.bottom - winRateY(p.winRate)) * localT));
        }
      } else {
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(cx, plot.bottom - 1.5), width: 16, height: 3), const Radius.circular(2)), Paint()..color = DashUi.line);
      }
    }

    void drawLine(List<Offset> pts, Color color, {bool fillUnder = false}) {
      if (pts.isEmpty) return;
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (var i = 1; i < pts.length; i++) path.lineTo(pts[i].dx, pts[i].dy);

      if (fillUnder) {
        final areaPath = Path.from(path)..lineTo(pts.last.dx, plot.bottom)..lineTo(pts.first.dx, plot.bottom)..close();
        canvas.drawPath(areaPath, Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [color.withValues(alpha: 0.15), color.withValues(alpha: 0.0)]).createShader(plot));
      }
      canvas.drawPath(path, Paint()..color = color..strokeWidth = 3..style = PaintingStyle.stroke..strokeJoin = StrokeJoin.round..strokeCap = StrokeCap.round);
      for (final pt in pts) {
        canvas.drawCircle(pt, 4, Paint()..color = Colors.white);
        canvas.drawCircle(pt, 2.5, Paint()..color = color);
      }
    }

    if (metric == _EstChartMetric.value) {
      drawLine(sentPts, DashUi.slate, fillUnder: true);
      drawLine(wonPts, DashUi.emeraldDeep, fillUnder: true);
    } else {
      drawLine(ratePts, DashUi.blue);
    }

    if (focusing) _paintTooltip(canvas, size, plot, slotW, yFor);
  }

  void _paintTooltip(Canvas canvas, Size size, Rect plot, double slotW, double Function(double) yFor) {
    final i = index!;
    final p = data[i];
    if (!p.hasData) return;

    final rows = <(String, String, Color)>[];
    if (metric == _EstChartMetric.value) {
      rows.add(('Sent', '\$${NumberFormat('#,##0').format(p.sentValue)}', DashUi.slate));
      rows.add(('Won', '\$${NumberFormat('#,##0').format(p.wonValue)}', DashUi.emeraldDeep));
    } else {
      rows.add(('Sent', p.sentCount.toString(), DashUi.slate));
      rows.add(('Won', p.wonCount.toString(), DashUi.emeraldDeep));
      rows.add(('Win Rate', '${p.winRate.toStringAsFixed(1)}%', DashUi.blue));
    }

    final titleTp = _layoutText('${p.month} Detail', const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w800));
    final labelTps = rows.map((r) => _layoutText(r.$1, const TextStyle(color: Color(0xFF94A3B8), fontSize: 11.5, fontWeight: FontWeight.w500))).toList();
    final valueTps = rows.map((r) => _layoutText(r.$2, TextStyle(color: r.$3 == DashUi.slate ? Colors.white : r.$3, fontSize: 12, fontWeight: FontWeight.w800))).toList();

    final labelW = labelTps.map((t) => t.width).reduce(math.max);
    final valueW = valueTps.map((t) => t.width).reduce(math.max);
    final tipW = math.max(titleTp.width, labelW + 16 + valueW) + 28;
    final rowH = labelTps.first.height;
    final tipH = 12 + titleTp.height + 6 + rows.length * rowH + (rows.length - 1) * 3 + 12;

    final cx = plot.left + slotW * (i + 0.5);
    final barTop = yFor(metric == _EstChartMetric.value ? p.sentValue : p.sentCount.toDouble());

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
  bool shouldRepaint(covariant _SentWonChartPainter old) => old.data != data || old.metric != metric || old.index != index || old.intro != intro || old.hover != hover;
}

// =============================================================================
// AVG ESTIMATE VALUE CHART
// =============================================================================

class _AvgEstimateValueChart extends StatefulWidget {
  final List<_MonthlyValueData> data;
  final int? year;
  const _AvgEstimateValueChart({required this.data, this.year});

  @override
  State<_AvgEstimateValueChart> createState() => _AvgEstimateValueChartState();
}

class _AvgEstimateValueChartState extends State<_AvgEstimateValueChart> with TickerProviderStateMixin {
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
  void didUpdateWidget(covariant _AvgEstimateValueChart old) {
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
    final plotW = width - 46; 
    if (plotW <= 0) return null;
    final i = ((dx - 46) / (plotW / n)).floor();
    if (i < 0 || i >= n) return null;
    return i;
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final activeData = data.where((d) => d.hasData).toList();

    if (activeData.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20.0),
        decoration: DashUi.panel(),
        child: const Center(child: Text('No data for avg estimate value yet.', style: TextStyle(color: DashUi.muted))),
      );
    }

    double totalRev = 0;
    int totalEsts = 0;
    var maxV = 0.0;

    for (final d in activeData) {
      totalRev += d.sentValue;
      totalEsts += d.sentCount;
      maxV = math.max(maxV, d.avgSentValue);
    }
    final overallAvg = totalEsts > 0 ? totalRev / totalEsts : 0.0;
    final scale = _niceScale(maxV);

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
                  const Text('Average Estimate Value', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: DashUi.slate)),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text('\$${NumberFormat('#,##0').format(overallAvg)}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: DashUi.ink, height: 1.1)),
                      const SizedBox(width: 10),
                      const Text('YTD Average (Sent)', style: TextStyle(fontSize: 12.5, color: DashUi.muted, fontWeight: FontWeight.w500)),
                    ],
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 12, height: 3, color: DashUi.amber),
                  const SizedBox(width: 6),
                  const Text('Avg Value / Est', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: DashUi.slate)),
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
                          painter: _AvgEstValuePainter(
                            data: data,
                            scale: scale,
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

class _AvgEstValuePainter extends CustomPainter {
  static const double leftGutter = 46;
  static const double bottomGutter = 26;
  static const double topPad = 6;

  final List<_MonthlyValueData> data;
  final _ChartScale scale;
  final int? index;
  final double intro;
  final double hover;

  const _AvgEstValuePainter({required this.data, required this.scale, required this.index, required this.intro, required this.hover});

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(leftGutter, topPad, size.width, size.height - bottomGutter);
    if (plot.width <= 0 || plot.height <= 0 || data.isEmpty) return;

    final n = data.length;
    final slotW = plot.width / n;
    final focusing = index != null && hover > 0.001;

    double yFor(double v) => plot.bottom - (v / scale.max).clamp(0.0, 1.0) * plot.height;

    if (focusing) {
      final r = RRect.fromRectAndRadius(Rect.fromLTWH(plot.left + index! * slotW + 2, plot.top, slotW - 4, plot.height), const Radius.circular(10));
      canvas.drawRRect(r, Paint()..color = const Color(0xFFEFF6FF).withValues(alpha: hover));
    }

    for (var i = 0; i <= scale.ticks; i++) {
      final v = i * scale.step;
      final y = yFor(v);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), Paint()..color = i == 0 ? DashUi.line : DashUi.faint..strokeWidth = 1);
      final tp = _layoutText(_compactMoney(v), const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: DashUi.muted));
      tp.paint(canvas, Offset(leftGutter - 8 - tp.width, y - tp.height / 2));
    }

    final validPts = <Offset>[];
    final stagger = 0.4 / n;

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
        final animY = plot.bottom - (plot.bottom - yFor(p.avgSentValue)) * localT;
        validPts.add(Offset(cx, animY));
      } else {
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(cx, plot.bottom - 1.5), width: 16, height: 3), const Radius.circular(2)), Paint()..color = DashUi.line);
      }
    }

    if (validPts.isNotEmpty) {
      final path = Path()..moveTo(validPts.first.dx, validPts.first.dy);
      for (var i = 1; i < validPts.length; i++) path.lineTo(validPts[i].dx, validPts[i].dy);

      final areaPath = Path.from(path)..lineTo(validPts.last.dx, plot.bottom)..lineTo(validPts.first.dx, plot.bottom)..close();
      canvas.drawPath(areaPath, Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [DashUi.amber.withValues(alpha: 0.15), DashUi.amber.withValues(alpha: 0.0)]).createShader(plot));
      canvas.drawPath(path, Paint()..color = DashUi.amber..strokeWidth = 3..style = PaintingStyle.stroke..strokeJoin = StrokeJoin.round..strokeCap = StrokeCap.round);
      
      for (final pt in validPts) {
        canvas.drawCircle(pt, 5, Paint()..color = Colors.white);
        canvas.drawCircle(pt, 3, Paint()..color = DashUi.amber);
      }
    }

    if (focusing) {
      final p = data[index!];
      if (!p.hasData) return;
      final rows = [('Avg Value', '\$${NumberFormat('#,##0').format(p.avgSentValue)}'), ('Sent Ests', p.sentCount.toString())];
      final titleTp = _layoutText('${p.month} Average', const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w800));
      final labelTps = rows.map((r) => _layoutText(r.$1, const TextStyle(color: Color(0xFF94A3B8), fontSize: 11.5, fontWeight: FontWeight.w500))).toList();
      final valueTps = rows.map((r) => _layoutText(r.$2, const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700))).toList();

      final tipW = math.max(titleTp.width, labelTps.map((t) => t.width).reduce(math.max) + 16 + valueTps.map((t) => t.width).reduce(math.max)) + 28;
      final tipH = 12 + titleTp.height + 6 + rows.length * labelTps.first.height + (rows.length - 1) * 3 + 12;

      final cx = plot.left + slotW * (index! + 0.5);
      final barTop = yFor(p.avgSentValue);
      double ty = math.max(plot.top, math.min(barTop - tipH - 16 >= 0 ? barTop - tipH - 16 : barTop - 8, plot.bottom - tipH));
      double tx = math.max(0, math.min(barTop - tipH - 16 >= 0 ? cx - tipW / 2 : cx + slotW * 0.3 + 12, size.width - tipW));

      canvas.saveLayer(Rect.fromLTWH(tx - 24, ty - 24, tipW + 48, tipH + 60), Paint()..color = Colors.white.withValues(alpha: hover));
      final rrect = RRect.fromRectAndRadius(Rect.fromLTWH(tx, ty, tipW, tipH), const Radius.circular(10));
      canvas.drawRRect(rrect.shift(const Offset(0, 4)), Paint()..color = Colors.black.withValues(alpha: 0.22)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
      canvas.drawRRect(rrect, Paint()..color = DashUi.ink);

      var y = ty + 12;
      titleTp.paint(canvas, Offset(tx + 14, y));
      y += titleTp.height + 6;
      for (var k = 0; k < rows.length; k++) {
        labelTps[k].paint(canvas, Offset(tx + 14, y));
        valueTps[k].paint(canvas, Offset(tx + tipW - 14 - valueTps[k].width, y));
        y += labelTps.first.height + 3;
      }
      canvas.restore();
    }
  }
  @override bool shouldRepaint(covariant _AvgEstValuePainter old) => old.data != data || old.index != index || old.intro != intro || old.hover != hover;
}

// =============================================================================
// OPEN PIPELINE AGING PANEL
// =============================================================================

class _PipelineAgingPanel extends StatefulWidget {
  final List<_AgingBucket> buckets;
  final int year;
  const _PipelineAgingPanel({required this.buckets, required this.year});

  @override
  State<_PipelineAgingPanel> createState() => _PipelineAgingPanelState();
}

class _PipelineAgingPanelState extends State<_PipelineAgingPanel> with SingleTickerProviderStateMixin {
  late final AnimationController _intro;
  int? _hovered;

  /// Opens the list of open estimates in this age bucket.
  void _open(_AgingBucket b, Color color) {
    showDialog(
      context: context,
      builder: (_) => EstimateListDialog(
        year: widget.year,
        heading: 'Open estimates · ${b.label}',
        totalLabel: 'open',
        color: color,
        icon: Icons.hourglass_bottom_rounded,
        uri: Uri.parse(
          '$kApiBaseUrl/api/dashboards/estimates/drill'
          '?year=${widget.year}&kind=aging&bucket=${Uri.encodeQueryComponent(b.label)}',
        ),
        initialSort: EstimateListSort.oldest,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..forward();
  }

  @override
  void didUpdateWidget(covariant _PipelineAgingPanel old) {
    super.didUpdateWidget(old);
    if (!identical(old.buckets, widget.buckets)) _intro.forward(from: 0);
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20.0),
      decoration: DashUi.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('OPEN PIPELINE AGING', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: DashUi.ink, letterSpacing: 0.8)),
          const SizedBox(height: 16),
          Expanded(
            child: widget.buckets.isEmpty
              ? const Center(child: Text('No open estimates.', style: TextStyle(color: DashUi.muted, fontSize: 13, fontWeight: FontWeight.w600)))
              : LayoutBuilder(
                  builder: (context, c) {
                    double maxVal = 0.0;
                    for (var b in widget.buckets) { if (b.value > maxVal) maxVal = b.value; }
                    if (maxVal == 0) maxVal = 1;

                    return Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: widget.buckets.asMap().entries.map((entry) {
                        final i = entry.key;
                        final b = entry.value;
                        final double hRatio = (b.value / maxVal).clamp(0.05, 1.0);
                        final isRed = b.label.contains('31');
                        final color = isRed ? DashUi.red : DashUi.blue;
                        final hovered = _hovered == i;
                        final dim = _hovered != null && !hovered;
                        final clickable = b.count > 0;

                        return Expanded(
                          child: MouseRegion(
                            cursor: clickable ? SystemMouseCursors.click : MouseCursor.defer,
                            onEnter: (_) => setState(() => _hovered = i),
                            onExit: (_) => setState(() => _hovered = null),
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: clickable ? () => _open(b, color) : null,
                              child: AnimatedOpacity(
                                duration: const Duration(milliseconds: 150),
                                opacity: dim ? 0.4 : 1,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      Text('\$${NumberFormat('#,##0').format(b.value)}', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: color)),
                                      const SizedBox(height: 4),
                                      Expanded(
                                        child: Stack(
                                          alignment: Alignment.bottomCenter,
                                          children: [
                                            Container(width: 32, decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(6))),
                                            AnimatedBuilder(
                                              animation: _intro,
                                              builder: (context, child) => FractionallySizedBox(
                                                heightFactor: hRatio * Curves.easeOutCubic.transform(_intro.value),
                                                child: AnimatedContainer(
                                                  duration: const Duration(milliseconds: 150),
                                                  width: hovered ? 38 : 32,
                                                  decoration: BoxDecoration(
                                                    color: color,
                                                    borderRadius: BorderRadius.circular(6),
                                                    boxShadow: hovered ? [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 8, offset: const Offset(0, 2))] : null,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(b.label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: hovered ? color : DashUi.slate)),
                                      Text(
                                        hovered && clickable ? 'View list ›' : '${b.count} ests',
                                        style: TextStyle(fontSize: 10, color: hovered && clickable ? color : DashUi.muted, fontWeight: hovered ? FontWeight.w700 : FontWeight.w400),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// INTERACTIVE LOST REASONS PANEL
// =============================================================================

class _LostReasonsPanel extends StatefulWidget {
  final List<_LostReason> reasons;
  final bool loading;
  final int year;
  const _LostReasonsPanel({required this.reasons, required this.loading, required this.year});

  @override
  State<_LostReasonsPanel> createState() => _LostReasonsPanelState();
}

class _LostReasonsPanelState extends State<_LostReasonsPanel> with SingleTickerProviderStateMixin {
  late final AnimationController _intro;
  int? _hoveredIndex;

  /// Opens the list of lost estimates with this reason.
  void _open(_LostReason r) {
    showDialog(
      context: context,
      builder: (_) => EstimateListDialog(
        year: widget.year,
        heading: 'Lost estimates · ${r.reason}',
        totalLabel: 'lost',
        color: r.color,
        icon: Icons.highlight_off_rounded,
        uri: Uri.parse(
          '$kApiBaseUrl/api/dashboards/estimates/drill'
          '?year=${widget.year}&kind=lost&reason=${Uri.encodeQueryComponent(r.reason)}',
        ),
        initialSort: EstimateListSort.value,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..forward();
  }

  @override
  void didUpdateWidget(covariant _LostReasonsPanel old) {
    super.didUpdateWidget(old);
    if (!identical(old.reasons, widget.reasons)) _intro.forward(from: 0);
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20.0),
      decoration: DashUi.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('TOP LOST REASONS', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: DashUi.ink, letterSpacing: 0.8)),
          const SizedBox(height: 12),
          Expanded(
            child: widget.loading
                ? const Center(child: CircularProgressIndicator(color: DashUi.blue))
                : widget.reasons.isEmpty
                    ? const Center(child: Text('No lost estimates recorded yet.', style: TextStyle(color: DashUi.muted, fontSize: 12.5, fontWeight: FontWeight.w600)))
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final double maxLostValue = widget.reasons.fold(0.0, (max, item) => item.lostValue > max ? item.lostValue : max) * 1.1;
                          final double totalLost = widget.reasons.fold(0.0, (sum, item) => sum + item.lostValue);

                          return Column(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: widget.reasons.asMap().entries.map((entry) {
                              final int index = entry.key;
                              final _LostReason reason = entry.value;
                              final bool isHovered = _hoveredIndex == index;
                              final bool dim = _hoveredIndex != null && !isHovered;

                              final double ratio = maxLostValue > 0 ? (reason.lostValue / maxLostValue).clamp(0.05, 1.0) : 0.05;
                              final double pct = totalLost > 0 ? (reason.lostValue / totalLost * 100) : 0.0;

                              return MouseRegion(
                                cursor: reason.count > 0 ? SystemMouseCursors.click : MouseCursor.defer,
                                onEnter: (_) => setState(() => _hoveredIndex = index),
                                onExit: (_) => setState(() => _hoveredIndex = null),
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: reason.count == 0 ? null : () => _open(reason),
                                  child: AnimatedOpacity(
                                  duration: const Duration(milliseconds: 150),
                                  opacity: dim ? 0.35 : 1.0,
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 100,
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Text(reason.reason, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: DashUi.ink), maxLines: 1, overflow: TextOverflow.ellipsis),
                                            const SizedBox(height: 2),
                                            Text('${reason.count} Estimates', style: const TextStyle(fontSize: 11, color: DashUi.muted, fontWeight: FontWeight.w600)),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Stack(
                                          alignment: Alignment.centerLeft,
                                          children: [
                                            Container(height: 28, decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(6))),
                                            AnimatedBuilder(
                                              animation: _intro,
                                              builder: (context, child) => FractionallySizedBox(
                                                widthFactor: ratio * Curves.easeOutCubic.transform(_intro.value),
                                                child: AnimatedContainer(
                                                  duration: const Duration(milliseconds: 150),
                                                  height: 28, 
                                                  decoration: BoxDecoration(
                                                    color: reason.color, 
                                                    borderRadius: BorderRadius.circular(6),
                                                    boxShadow: isHovered ? [BoxShadow(color: reason.color.withValues(alpha: 0.35), blurRadius: 8, offset: const Offset(0, 2))] : null,
                                                  )
                                                ),
                                              )
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      SizedBox(
                                        width: 100,
                                        child: Text(
                                          isHovered ? '${pct.toStringAsFixed(1)}% of Lost' : '\$${NumberFormat('#,##0').format(reason.lostValue)}',
                                          textAlign: TextAlign.end,
                                          style: TextStyle(
                                            fontSize: 13, 
                                            fontWeight: FontWeight.bold, 
                                            color: isHovered ? reason.color : DashUi.ink
                                          ),
                                        ),
                                      ),
                                      SizedBox(
                                        width: 18,
                                        child: Icon(Icons.chevron_right_rounded, size: 18, color: isHovered && reason.count > 0 ? reason.color : Colors.transparent),
                                      ),
                                    ],
                                  ),
                                ),
                                ),
                              );
                            }).toList(),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// AUTO-SCROLLING STALE TICKER (USER'S EXACT BASE COPY)
// =============================================================================

class _AutoHorizontalStaleList extends StatefulWidget {
  final List<_StaleEstimate> estimates;

  const _AutoHorizontalStaleList({required this.estimates});

  @override
  State<_AutoHorizontalStaleList> createState() =>
      _AutoHorizontalStaleListState();
}

class _AutoHorizontalStaleListState
    extends State<_AutoHorizontalStaleList>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  final GlobalKey _rowKey = GlobalKey();
  final ValueNotifier<double> _offset = ValueNotifier<double>(0.0);

  static const double _speed = 45.0; // px/sec
  static const double _cardGap = 12.0;
  static const double _tickerHeight = 56.0;

  double _cycleWidth = 1.0;
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
      if (!_reduceMotion) {
        _ticker.start();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final reduceMotion = MediaQuery.of(context).disableAnimations;
    if (reduceMotion == _reduceMotion) return;

    _reduceMotion = reduceMotion;

    if (_reduceMotion) {
      _ticker.stop();
      _lastElapsed = null;
      _offset.value = 0.0;
    } else if (!_ticker.isActive) {
      _lastElapsed = null;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    if (_isHovered || _reduceMotion || _cycleWidth <= 1.0) {
      _lastElapsed = elapsed;
      return;
    }

    final previous = _lastElapsed;
    _lastElapsed = elapsed;
    if (previous == null) return;

    final dt = (elapsed - previous).inMicroseconds /
        Duration.microsecondsPerSecond;
    if (dt <= 0) return;

    final frameSeconds = math.min(dt, 0.05);
    final next = _offset.value + (_speed * frameSeconds);
    _offset.value = next >= _cycleWidth ? next % _cycleWidth : next;
  }

  void _measureRow() {
    if (!mounted) return;

    final context = _rowKey.currentContext;
    final renderObject = context?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;

    final width = renderObject.size.width;
    if (width <= 0) return;

    final newCycleWidth = width + _cardGap;
    _cycleWidth = newCycleWidth;

    if (_offset.value >= newCycleWidth) {
      _offset.value %= newCycleWidth;
    }
  }

  @override
  void didUpdateWidget(covariant _AutoHorizontalStaleList oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (!identical(oldWidget.estimates, widget.estimates)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _measureRow();
      });
    }
  }

  void _pauseTicker() {
    _isHovered = true;
    _lastElapsed = null;
  }

  void _resumeTicker() {
    _isHovered = false;
    _lastElapsed = null;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _offset.dispose();
    super.dispose();
  }

  Widget _buildStaleRow({Key? key}) {
    return Row(
      key: key,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < widget.estimates.length; i++) ...[
          if (i > 0) const SizedBox(width: _cardGap),
          _buildStaleCard(widget.estimates[i]),
        ],
      ],
    );
  }

  String _fmt(num value) {
    return value.toStringAsFixed(0).replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (Match m) => '${m[1]},',
    );
  }

  Widget _buildStaleCard(_StaleEstimate est) {
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
            decoration: const BoxDecoration(
              color: Color(0xFFFEF2F2),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.warning_amber_rounded,
              color: Color(0xFFDC2626),
              size: 14,
            ),
          ),
          const SizedBox(width: 8),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                est.customerName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: DashUi.ink,
                ),
              ),
              Text(
                '${est.daysOld} days old',
                style: const TextStyle(fontSize: 10, color: DashUi.muted),
              ),
            ],
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFBEB),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFDE68A)),
            ),
            child: Text(
              '\$${_fmt(est.value)}',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Color(0xFFD97706),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.estimates.isEmpty) return const SizedBox.shrink();

    return MouseRegion(
      onEnter: (_) => _pauseTicker(),
      onExit: (_) => _resumeTicker(),
      child: SizedBox(
        height: _tickerHeight,
        width: double.infinity,
        child: ClipRect(
          child: ValueListenableBuilder<double>(
            valueListenable: _offset,
            child: RepaintBoundary(
              // OverflowBox lets the doubled row be wider than the viewport without a
              // RenderFlex overflow warning; ClipRect above trims what's off-screen.
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                minWidth: 0,
                maxWidth: double.infinity,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildStaleRow(key: _rowKey),
                    const SizedBox(width: _cardGap),
                    _buildStaleRow(),
                  ],
                ),
              ),
            ),
            builder: (context, offset, child) {
              return Transform.translate(
                offset: Offset(-offset, 0.0),
                child: child,
              );
            },
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// LOADING SKELETON
// =============================================================================

class _EstimatesSkeleton extends StatelessWidget {
  const _EstimatesSkeleton();

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
            height: 86,
            child: Row(children: [
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
                        flex: 12,
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
                        flex: 8,
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
                  child: Column(
                    children: [
                      Expanded(
                        flex: 9,
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
                      const SizedBox(height: 16),
                      Expanded(
                        flex: 11,
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
          ),
        ],
      ),
    );
  }
}