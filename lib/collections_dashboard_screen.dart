import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart' hide TextDirection;

import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/dashboard_layout.dart';
import 'widgets/estimate_list_dialog.dart';

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

const _monthNames = [
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
final _whole = NumberFormat('#,##0');

/// Height of the scorecards. Kept short so the panels below and to the right get the room.
const double _kCardHeight = 86;

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

double _d(dynamic v) => v == null
    ? 0.0
    : (v is num ? v.toDouble() : double.tryParse(v.toString()) ?? 0.0);
int _i(dynamic v) =>
    v == null ? 0 : (v is num ? v.toInt() : int.tryParse(v.toString()) ?? 0);

String _age(int days) {
  if (days < 60) return '$days days';
  if (days < 730) return '${(days / 30.4).round()} months';
  return '${(days / 365).floor()} years';
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

/// Monthly series trimmed to what's happened so far, starting just before the first non-zero month.
List<double> _trendOf(List<double> monthly, int year) {
  final now = DateTime.now();
  final upTo = year == now.year ? now.month : monthly.length;
  final pts = monthly.take(upTo).toList();
  final first = pts.indexWhere((v) => v > 0);
  if (first < 0) return pts;
  return pts.sublist(math.max(0, first - 1));
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

class _Overdue {
  final String jobId;
  final String customer;
  final double amount;
  final int days;
  const _Overdue(this.jobId, this.customer, this.amount, this.days);
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

// =============================================================================
// SCREEN STATE
// =============================================================================

class _CollectionsDashboardContentState
    extends State<CollectionsDashboardContent> {
  bool _isLoading = true;
  String? _errorMessage;
  int _requestId = 0;

  double _collected = 0;
  double _priorCollected = 0;
  double _outstanding = 0;
  double _over90 = 0;
  int _writeOffJobs = 0;
  double _writeOffBalance = 0;

  /// Write-offs by month for the selected year (12 entries, January first).
  List<double> _writeOffJobsMonthly = List.filled(12, 0);
  List<double> _writeOffBalanceMonthly = List.filled(12, 0);

  /// Always 12 entries, January first.
  List<double> _months = List.filled(12, 0);
  List<double> _priorMonths = List.filled(12, 0);
  List<_Method> _methods = [];
  List<_Stage> _stages = [];
  List<_Overdue> _overdue = [];
  List<double> _outstandingTrend = [];
  List<double> _over90Trend = [];
  List<_Owing> _owing = [];

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(covariant CollectionsDashboardContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedYear != widget.selectedYear) _fetch();
  }

  List<double> _monthly(dynamic raw) {
    final out = List<double>.filled(12, 0);
    for (final e in (raw as List<dynamic>? ?? const [])) {
      final m = _i(e['month_num']);
      if (m >= 1 && m <= 12) out[m - 1] = _d(e['collected']);
    }
    return out;
  }

  Future<void> _fetch() async {
    final id =
        ++_requestId; // a slower, older request must not overwrite a newer year
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await http
          .get(
            Uri.parse(
              '$kApiBaseUrl/api/dashboards/collections?year=${widget.selectedYear}',
            ),
            headers: AuthSession.instance.headers(),
          )
          .timeout(
            const Duration(seconds: 60),
          ); // free-tier hosts can take ~30s+ to wake up

      if (id != _requestId || !mounted) return;
      if (response.statusCode != 200) {
        throw Exception('The server returned status ${response.statusCode}.');
      }

      final body = json.decode(response.body) as Map<String, dynamic>;
      final s =
          (body['summary'] as Map<String, dynamic>?) ??
          const <String, dynamic>{};

      setState(() {
        _collected = _d(s['collected']);
        _priorCollected = _d(s['priorCollected']);
        _outstanding = _d(s['outstanding']);
        _over90 = _d(s['over90']);
        _writeOffJobs = _i(s['writeOffJobs']);
        _writeOffBalance = _d(s['writeOffBalance']);
        _writeOffJobsMonthly = List<double>.filled(12, 0);
        _writeOffBalanceMonthly = List<double>.filled(12, 0);
        for (final e
            in (body['writeOffMonthly'] as List<dynamic>? ?? const [])) {
          final m = _i(e['month_num']);
          if (m >= 1 && m <= 12) {
            _writeOffJobsMonthly[m - 1] = _d(e['job_count']);
            _writeOffBalanceMonthly[m - 1] = _d(e['balance']);
          }
        }
        _months = _monthly(body['monthly']);
        _priorMonths = _monthly(body['priorMonthly']);
        _methods = [
          for (final e in (body['methods'] as List<dynamic>? ?? const []))
            _Method(
              (e['method'] ?? 'Other').toString(),
              _d(e['amount']),
              _i(e['paymentCount']),
            ),
        ].where((m) => m.amount > 0).toList();
        _stages = [
          for (final e in (body['stages'] as List<dynamic>? ?? const []))
            _Stage(
              (e['stage'] ?? '').toString(),
              (e['label'] ?? '').toString(),
              _d(e['amount']),
              _i(e['jobCount']),
            ),
        ];
        final history = (body['history'] as List<dynamic>? ?? const []);
        _outstandingTrend = [for (final h in history) _d(h['outstanding'])];
        _over90Trend = [for (final h in history) _d(h['over90'])];
        _overdue = [
          for (final e in (body['overdue'] as List<dynamic>? ?? const []))
            _Overdue(
              (e['jobId'] ?? '').toString(),
              (e['customer'] ?? 'Unknown').toString(),
              _d(e['amount']),
              _i(e['daysOverdue']),
            ),
        ];
        _owing = [
          for (final e in (body['topOwing'] as List<dynamic>? ?? const []))
            _Owing(
              (e['customer'] ?? 'Unknown').toString(),
              _d(e['amount']),
              _i(e['jobCount']),
              e['oldestDays'] == null ? null : _i(e['oldestDays']),
            ),
        ];
        _isLoading = false;
      });
    } on TimeoutException {
      if (id == _requestId && mounted) {
        setState(() {
          _errorMessage = 'The dashboard took too long to load.';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (id == _requestId && mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const _CollectionsSkeleton();
    if (_errorMessage != null) {
      return DashErrorPanel(
        title: "Couldn't load collections",
        message: _errorMessage!,
        onRetry: _fetch,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Left: the scorecards, then the cash charts.
              Expanded(
                flex: 7,
                child: Column(
                  children: [
                    SizedBox(
                      height: _kCardHeight,
                      child: Row(
                        children: [
                          Expanded(
                            child: AnimatedMetricCard(
                              title: 'Collected ${widget.selectedYear}',
                              value: _collected,
                              format: _money,
                              valueColor: DashUi.emeraldDeep,
                              index: 0,
                              trend: _trendOf(_months, widget.selectedYear),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: AnimatedMetricCard(
                              title: 'Outstanding balance',
                              value: _outstanding,
                              format: _money,
                              valueColor: DashUi.amber,
                              index: 1,
                              trend: _outstandingTrend.length >= 2
                                  ? _outstandingTrend
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: AnimatedMetricCard(
                              title: 'Over 90 days',
                              value: _over90,
                              format: _money,
                              valueColor: DashUi.red,
                              index: 2,
                              trend: _over90Trend.length >= 2
                                  ? _over90Trend
                                  : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: _kCardHeight,
                      child: Row(
                        children: [
                          Expanded(
                            child: AnimatedMetricCard(
                              title: 'Write-offs ${widget.selectedYear} (jobs)',
                              value: _writeOffJobs.toDouble(),
                              format: (v) => _whole.format(v.round()),
                              valueColor: DashUi.ink,
                              index: 3,
                              trend: dashTrend(
                                _writeOffJobsMonthly,
                                widget.selectedYear,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: AnimatedMetricCard(
                              title:
                                  'Written-off balance ${widget.selectedYear}',
                              value: _writeOffBalance,
                              format: _money,
                              valueColor: DashUi.red,
                              index: 4,
                              trend: dashTrend(
                                _writeOffBalanceMonthly,
                                widget.selectedYear,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      flex: 11,
                      child: _MonthlyCollectedChart(
                        data: _months,
                        prior: _priorMonths,
                        year: widget.selectedYear,
                        total: _collected,
                        priorTotal: _priorCollected,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      flex: 7,
                      child: _MethodsPanel(
                        methods: _methods,
                        year: widget.selectedYear,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // Right: starts at the very top so the balance panels get the full height of the page.
              Expanded(
                flex: 4,
                child: Column(
                  children: [
                    Expanded(
                      flex: 9,
                      child: _StagePanel(stages: _stages, total: _outstanding),
                    ),
                    const SizedBox(height: 16),
                    Expanded(flex: 11, child: _OwingPanel(rows: _owing)),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_overdue.isNotEmpty) ...[
          const SizedBox(height: 16),
          AutoScrollTicker(items: [for (final o in _overdue) _OverdueCard(o)]),
        ],
      ],
    );
  }
}

// =============================================================================
// FIT ROWS (rows that share the panel height and shrink to fit; never scroll)
// =============================================================================

/// Lays out [count] rows so they fill the available height. If the panel is too short for rows of
/// [naturalRowHeight], the whole block is scaled down instead of scrolling or overflowing.
class _FitRows extends StatelessWidget {
  final int count;
  final double naturalRowHeight;
  final Widget Function(int index) rowBuilder;
  const _FitRows({
    required this.count,
    required this.naturalRowHeight,
    required this.rowBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final naturalTotal = naturalRowHeight * count;
        final scale = naturalTotal <= c.maxHeight
            ? 1.0
            : c.maxHeight / naturalTotal;
        final rowH = math.max(naturalRowHeight, c.maxHeight / count);
        return FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.topLeft,
          child: SizedBox(
            // Widened by 1/scale so that, once scaled down, the rows still span the full panel width.
            width: c.maxWidth / scale,
            height: rowH * count,
            child: Column(
              children: [
                for (var i = 0; i < count; i++)
                  SizedBox(height: rowH, child: rowBuilder(i)),
              ],
            ),
          ),
        );
      },
    );
  }
}

// =============================================================================
// PANEL HEADER
// =============================================================================

class _PanelTitle extends StatelessWidget {
  final String title;
  final String subtitle;
  const _PanelTitle(this.title, this.subtitle);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: DashUi.slate,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: const TextStyle(
            fontSize: 12,
            color: DashUi.muted,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _EmptyNote extends StatelessWidget {
  final String text;
  const _EmptyNote(this.text);

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 14,
        color: DashUi.muted,
        fontWeight: FontWeight.w500,
      ),
    ),
  );
}

// =============================================================================
// MONTHLY CHART (bars = this year, tick = same month last year)
// =============================================================================

class _MonthlyCollectedChart extends StatefulWidget {
  final List<double> data;
  final List<double> prior;
  final int year;
  final double total;
  final double priorTotal;
  const _MonthlyCollectedChart({
    required this.data,
    required this.prior,
    required this.year,
    required this.total,
    required this.priorTotal,
  });

  @override
  State<_MonthlyCollectedChart> createState() => _MonthlyCollectedChartState();
}

class _MonthlyCollectedChartState extends State<_MonthlyCollectedChart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _intro;
  int? _index;

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..forward();
  }

  @override
  void didUpdateWidget(covariant _MonthlyCollectedChart old) {
    super.didUpdateWidget(old);
    if (!identical(old.data, widget.data)) {
      _index = null;
      _intro.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  int? _indexFor(double dx, double width) {
    final plotW = width - _CollectedPainter.leftGutter;
    if (plotW <= 0) return null;
    final i = ((dx - _CollectedPainter.leftGutter) / (plotW / 12)).floor();
    return (i < 0 || i >= 12) ? null : i;
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final maxV = [...w.data, ...w.prior].fold<double>(0, math.max);
    final scale = _niceScale(maxV);
    final now = DateTime.now();
    final currentMonth = w.year == now.year ? now.month - 1 : null;
    final empty = maxV <= 0;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      decoration: DashUi.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 6,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const _PanelTitle(
                    'Cash collected by month',
                    'Payments received, net of refunds',
                  ),
                  const SizedBox(width: 14),
                  Text(
                    _compactMoney(w.total),
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: DashUi.ink,
                      height: 1.1,
                    ),
                  ),
                  if (w.priorTotal > 0) ...[
                    const SizedBox(width: 8),
                    _vsPriorChip(
                      (w.total - w.priorTotal) / w.priorTotal * 100,
                      w.year - 1,
                    ),
                  ],
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _legendDot(DashUi.emeraldDeep, '${w.year}'),
                  const SizedBox(width: 14),
                  _legendDot(DashUi.slate, '${w.year - 1}', tick: true),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: empty
                ? _EmptyNote('No payments recorded in ${w.year}.')
                : LayoutBuilder(
                    builder: (context, c) {
                      return MouseRegion(
                        onHover: (e) {
                          final i = _indexFor(e.localPosition.dx, c.maxWidth);
                          if (i != _index) setState(() => _index = i);
                        },
                        onExit: (_) => setState(() => _index = null),
                        child: Stack(
                          children: [
                            AnimatedBuilder(
                              animation: _intro,
                              builder: (context, _) => CustomPaint(
                                size: Size(c.maxWidth, c.maxHeight),
                                painter: _CollectedPainter(
                                  data: w.data,
                                  prior: w.prior,
                                  scale: scale,
                                  hover: _index,
                                  currentMonth: currentMonth,
                                  intro: Curves.easeOutCubic.transform(
                                    _intro.value,
                                  ),
                                ),
                              ),
                            ),
                            if (_index != null) _tooltip(c),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _tooltip(BoxConstraints c) {
    final i = _index!;
    final plotW = c.maxWidth - _CollectedPainter.leftGutter;
    final slot = plotW / 12;
    final cx = _CollectedPainter.leftGutter + slot * i + slot / 2;
    const tipW = 150.0;
    final left = (cx - tipW / 2)
        .clamp(
          _CollectedPainter.leftGutter,
          math.max(_CollectedPainter.leftGutter, c.maxWidth - tipW),
        )
        .toDouble();
    final cur = widget.data[i];
    final pri = widget.prior[i];
    return Positioned(
      left: left,
      top: 0,
      width: tipW,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: DashUi.ink,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_monthNames[i]} ${widget.year}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: DashUi.muted,
                ),
              ),
              Text(
                _money(cur),
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              Text(
                '${widget.year - 1}: ${_money(pri)}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: DashUi.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _legendDot(Color color, String text, {bool tick = false}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: tick ? 14 : 11,
        height: tick ? 3 : 11,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(tick ? 1.5 : 3),
        ),
      ),
      const SizedBox(width: 6),
      Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: DashUi.slate,
        ),
      ),
    ],
  );

  Widget _vsPriorChip(double pct, int priorYear) {
    final up = pct >= 0;
    final color = up ? DashUi.emeraldDeep : DashUi.red;
    return Tooltip(
      message: 'Same stretch of $priorYear',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
              size: 13,
              color: color,
            ),
            const SizedBox(width: 2),
            Text(
              '${pct.abs().toStringAsFixed(0)}% vs $priorYear',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CollectedPainter extends CustomPainter {
  static const leftGutter = 46.0;
  static const bottomGutter = 22.0;

  final List<double> data;
  final List<double> prior;
  final _Scale scale;
  final int? hover;
  final int? currentMonth;
  final double intro;

  const _CollectedPainter({
    required this.data,
    required this.prior,
    required this.scale,
    required this.hover,
    required this.currentMonth,
    required this.intro,
  });

  void _text(
    Canvas canvas,
    String s,
    Offset at,
    TextStyle style, {
    TextAlign align = TextAlign.left,
  }) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout();
    final dx = align == TextAlign.right
        ? at.dx - tp.width
        : (align == TextAlign.center ? at.dx - tp.width / 2 : at.dx);
    tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTWH(
      leftGutter,
      14,
      size.width - leftGutter,
      size.height - bottomGutter - 14,
    );
    if (plot.width <= 0 || plot.height <= 0) return;
    const axis = TextStyle(
      fontSize: 11,
      color: DashUi.muted,
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
      _text(
        canvas,
        _compactMoney(t * scale.step),
        Offset(plot.left - 8, y),
        axis,
        align: TextAlign.right,
      );
    }

    final slot = plot.width / 12;
    final barW = math.min(slot * 0.56, 46.0);
    for (var i = 0; i < 12; i++) {
      final cx = plot.left + slot * i + slot / 2;
      final label = TextStyle(
        fontSize: 11,
        fontWeight: hover == i ? FontWeight.w800 : FontWeight.w600,
        color: hover == i ? DashUi.ink : DashUi.muted,
      );
      _text(
        canvas,
        _monthNames[i],
        Offset(cx, plot.bottom + 12),
        label,
        align: TextAlign.center,
      );

      // Months that haven't happened yet draw nothing, not a zero-height bar.
      final cm = currentMonth;
      final future = cm != null && i > cm;
      if (!future && data[i] > 0) {
        final h = plot.height * (data[i] / scale.max) * intro;
        final dim = hover != null && hover != i;
        final rect = RRect.fromRectAndCorners(
          Rect.fromLTWH(cx - barW / 2, plot.bottom - h, barW, h),
          topLeft: const Radius.circular(5),
          topRight: const Radius.circular(5),
        );
        canvas.drawRRect(
          rect,
          Paint()..color = DashUi.emeraldDeep.withValues(alpha: dim ? 0.35 : 1),
        );
      }

      if (prior[i] > 0) {
        final y = plot.bottom - plot.height * (prior[i] / scale.max);
        canvas.drawLine(
          Offset(cx - barW / 2 - 3, y),
          Offset(cx + barW / 2 + 3, y),
          Paint()
            ..color = DashUi.slate.withValues(
              alpha: hover != null && hover != i ? 0.3 : 0.9,
            )
            ..strokeWidth = 2.5
            ..strokeCap = StrokeCap.round,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CollectedPainter old) =>
      old.data != data ||
      old.prior != prior ||
      old.hover != hover ||
      old.intro != intro ||
      old.scale.max != scale.max;
}

// =============================================================================
// PAYMENT METHODS
// =============================================================================

class _MethodsPanel extends StatelessWidget {
  final List<_Method> methods;
  final int year;
  const _MethodsPanel({required this.methods, required this.year});

  @override
  Widget build(BuildContext context) {
    final total = methods.fold<double>(0, (s, m) => s + m.amount);

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
      decoration: DashUi.panel(),
      // On a short window the whole panel scales down to fit instead of overflowing.
      child: LayoutBuilder(
        builder: (context, c) {
          const natural = 78.0;
          final scale = c.maxHeight >= natural ? 1.0 : c.maxHeight / natural;
          return FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: c.maxWidth / scale,
              height: scale < 1 ? natural : c.maxHeight,
              child: _body(total),
            ),
          );
        },
      ),
    );
  }

  Widget _body(double total) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title and subtitle share one line: this panel is the shortest on the page.
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            const Text(
              'How customers paid',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: DashUi.slate,
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                'Share of cash collected · $year',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: DashUi.muted,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: total <= 0
              ? _EmptyNote('No payments recorded in $year.')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        height: 14,
                        child: Row(
                          children: [
                            for (final m in methods)
                              Expanded(
                                flex: math.max(
                                  1,
                                  (m.amount / total * 1000).round(),
                                ),
                                child: Tooltip(
                                  message: '${m.method}: ${_money(m.amount)}',
                                  child: Container(color: m.color),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 28,
                      runSpacing: 8,
                      children: [for (final m in methods) _chip(m, total)],
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _chip(_Method m, double total) => Tooltip(
    message: '${_whole.format(m.count)} payments',
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: m.color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          m.method,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: DashUi.ink,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          _compactMoney(m.amount),
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: DashUi.emeraldDeep,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '${(m.amount / total * 100).toStringAsFixed(0)}%',
          style: const TextStyle(
            fontSize: 12,
            color: DashUi.muted,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

// =============================================================================
// UNPAID BALANCES BY STAGE (sub-status of Final Invoice Sent)
// =============================================================================

class _StagePanel extends StatelessWidget {
  final List<_Stage> stages;
  final double total;
  const _StagePanel({required this.stages, required this.total});

  @override
  Widget build(BuildContext context) {
    final maxV = stages.fold<double>(0, (m, b) => math.max(m, b.amount));

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      decoration: DashUi.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _PanelTitle(
            'Unpaid balances by stage',
            'Final Invoice Sent jobs, split by notice',
          ),
          const SizedBox(height: 8),
          Expanded(
            child: total <= 0
                ? const _EmptyNote('Nothing outstanding.')
                : _FitRows(
                    count: stages.length,
                    naturalRowHeight: 24,
                    rowBuilder: (i) => _row(stages[i], maxV),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _row(_Stage b, double maxV) => _StageRowTap(
    stage: b,
    child: Row(
      children: [
        SizedBox(
          width: 118,
          child: Text(
            b.label,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: DashUi.slate,
            ),
          ),
        ),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: LayoutBuilder(
              builder: (context, c) => TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: maxV > 0 ? b.amount / maxV : 0),
                duration: const Duration(milliseconds: 700),
                curve: Curves.easeOutCubic,
                builder: (context, t, _) => Container(
                  width: math.max(b.amount > 0 ? 3.0 : 0.0, c.maxWidth * t),
                  height: 14,
                  decoration: BoxDecoration(
                    color: b.color,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 64,
          child: Text(
            _compactMoney(b.amount),
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: b.amount > 0 ? b.color : DashUi.muted,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(
            '${b.jobCount} ${b.jobCount == 1 ? 'job' : 'jobs'}',
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontSize: 11.5,
              color: DashUi.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Makes a stage row clickable: pointer cursor, a hover highlight, and the list of jobs behind it.
class _StageRowTap extends StatefulWidget {
  final _Stage stage;
  final Widget child;
  const _StageRowTap({required this.stage, required this.child});

  @override
  State<_StageRowTap> createState() => _StageRowTapState();
}

class _StageRowTapState extends State<_StageRowTap> {
  bool _hovering = false;

  void _open() {
    final s = widget.stage;
    showDialog(
      context: context,
      builder: (_) => EstimateListDialog(
        year: DateTime.now().year,
        periodLabel: 'As of today',
        heading: '${s.label} · unpaid balances',
        totalLabel: 'unpaid',
        noun: 'job',
        ageLabel: 'overdue',
        color: s.color,
        icon: Icons.schedule_rounded,
        uri: Uri.parse(
          '$kApiBaseUrl/api/dashboards/collections/jobs?stage=${Uri.encodeQueryComponent(s.stage)}',
        ),
        initialSort:
            EstimateListSort.oldest, // oldest date = most overdue first
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.stage;
    return Tooltip(
      message: s.jobCount == 0
          ? 'No jobs in ${s.label}'
          : 'See the ${s.jobCount} ${s.jobCount == 1 ? 'job' : 'jobs'}',
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: s.jobCount == 0 ? null : _open,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: _hovering
                  ? s.color.withValues(alpha: 0.08)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// TICKER CARD (one overdue job)
// =============================================================================

class _OverdueCard extends StatelessWidget {
  final _Overdue o;
  const _OverdueCard(this.o);

  @override
  Widget build(BuildContext context) {
    final old = o.days > 90;
    final tone = old ? DashUi.red : DashUi.amber;
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
            decoration: BoxDecoration(
              color: tone.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.schedule_rounded, color: tone, size: 14),
          ),
          const SizedBox(width: 8),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  o.customer,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: DashUi.ink,
                  ),
                ),
              ),
              Text(
                '${o.jobId.isEmpty ? '' : '#${o.jobId} · '}${_age(o.days)} overdue',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: old ? FontWeight.w700 : FontWeight.w500,
                  color: old ? DashUi.red : DashUi.muted,
                ),
              ),
            ],
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: tone.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: tone.withValues(alpha: 0.3)),
            ),
            child: Text(
              _money(o.amount),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: tone,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// BIGGEST BALANCES
// =============================================================================

class _OwingPanel extends StatelessWidget {
  final List<_Owing> rows;
  const _OwingPanel({required this.rows});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
      decoration: DashUi.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _PanelTitle(
            'Biggest open balances',
            'Top 5 customers · oldest unpaid job',
          ),
          const SizedBox(height: 8),
          Expanded(
            child: rows.isEmpty
                ? const _EmptyNote('No customers owe a balance.')
                : _FitRows(
                    count: rows.length,
                    naturalRowHeight: 42,
                    rowBuilder: (i) =>
                        _row(rows[i], i, last: i == rows.length - 1),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _row(_Owing r, int i, {required bool last}) {
    final old = (r.oldestDays ?? 0) > 90;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: last
            ? null
            : const Border(bottom: BorderSide(color: DashUi.faint)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '${i + 1}',
              style: const TextStyle(
                fontSize: 12,
                color: DashUi.muted,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.customer,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: DashUi.ink,
                  ),
                ),
                Text(
                  '${r.jobCount} ${r.jobCount == 1 ? 'job' : 'jobs'}'
                  '${r.oldestDays == null ? '' : ' · oldest ${_age(r.oldestDays!)}'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: old ? DashUi.red : DashUi.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            _money(r.amount),
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: DashUi.amber,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// SKELETON
// =============================================================================

class _CollectionsSkeleton extends StatelessWidget {
  const _CollectionsSkeleton();

  Widget _metric() => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: DashUi.panel(radius: 12),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SkeletonBox(h: 12, w: 120),
          SizedBox(height: 12),
          SkeletonBox(h: 26, w: 170),
        ],
      ),
    ),
  );

  Widget _panel(int flex) => Expanded(
    flex: flex,
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: DashUi.panel(),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBox(h: 12, w: 180),
          SizedBox(height: 10),
          Expanded(child: SkeletonBox(r: 10)),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return SkeletonPulse(
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(
                  flex: 7,
                  child: Column(
                    children: [
                      SizedBox(
                        height: _kCardHeight,
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
                      const SizedBox(height: 12),
                      SizedBox(
                        height: _kCardHeight,
                        child: Row(
                          children: [
                            _metric(),
                            const SizedBox(width: 12),
                            _metric(),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _panel(11),
                      const SizedBox(height: 16),
                      _panel(6),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 4,
                  child: Column(
                    children: [
                      _panel(11),
                      const SizedBox(height: 16),
                      _panel(9),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const SkeletonBox(h: 56, r: 10),
        ],
      ),
    );
  }
}
