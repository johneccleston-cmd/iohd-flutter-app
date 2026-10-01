import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'config/api_config.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/dashboard_layout.dart';

class ReportsScreen extends StatelessWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      title: 'Financial Reports',
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
// SCREEN STATE
// =============================================================================

class _FinancialDashboardContentState extends State<FinancialDashboardContent> {
  bool _isLoading = true;
  String? _errorMessage;
  int _requestId = 0;

  bool _showNetIncomeView = false;

  _FinancialSummary _data = const _FinancialSummary();
  
  double get _opexTotal => _data.expenses.fold<double>(0, (s, e) => s + e.amount);

  final List<_MonthlyFinancials> _fallbackChartData = const [
    _MonthlyFinancials('Jan', 0, 0, 0, 0, false),
    _MonthlyFinancials('Feb', 0, 0, 0, 0, false),
    _MonthlyFinancials('Mar', 0, 0, 0, 0, false),
    _MonthlyFinancials('Apr', 0, 0, 0, 0, false),
    _MonthlyFinancials('May', 0, 0, 0, 0, false),
    _MonthlyFinancials('Jun', 0, 0, 0, 0, false),
    _MonthlyFinancials('Jul', 0, 0, 0, 0, false),
    _MonthlyFinancials('Aug', 0, 0, 0, 0, false),
    _MonthlyFinancials('Sep', 0, 0, 0, 0, false),
    _MonthlyFinancials('Oct', 0, 0, 0, 0, false),
    _MonthlyFinancials('Nov', 0, 0, 0, 0, false),
    _MonthlyFinancials('Dec', 0, 0, 0, 0, false),
  ];

  @override
  void initState() {
    super.initState();
    _fetchSummary();
  }

  @override
  void didUpdateWidget(covariant FinancialDashboardContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedYear != widget.selectedYear) {
      _fetchSummary();
    }
  }

  Future<void> _fetchSummary() async {
    final requestId = ++_requestId;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final urlString = '$kApiBaseUrl/api/financial_dashboard?year=${widget.selectedYear}';

      final response = await http.get(
        Uri.parse(urlString),
        headers: {
          'Content-Type': 'application/json',
          if (kAuthToken.isNotEmpty) 'Authorization': 'Bearer $kAuthToken',
        },
      );

      if (!mounted || requestId != _requestId) return;

      if (response.statusCode == 200) {
        final Map<String, dynamic> jsonBody = json.decode(response.body);
        setState(() {
          _data = _FinancialSummary.fromJson(jsonBody);
          _isLoading = false;
        });
      } else {
        throw Exception('The server returned status ${response.statusCode}.');
      }
    } catch (e) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  String _moneyNoDecimals(double v) {
    final neg = v < 0;
    final s = v.abs().toStringAsFixed(0).replaceAllMapped(
          RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
          (m) => '${m[1]},',
        );
    return '${neg ? '-' : ''}\$$s';
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const _FinancialSkeleton();

    if (_errorMessage != null) {
      return DashErrorPanel(
        title: "Couldn't load financials",
        message: _errorMessage!,
        onRetry: _fetchSummary,
      );
    }

    final chartData = _data.chartData.isNotEmpty ? _data.chartData : _fallbackChartData;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Top 6 Financial Scorecards
        SizedBox(
          height: 86,
          child: Row(
            children: [
              Expanded(
                child: AnimatedMetricCard(
                  title: 'Revenue YTD',
                  value: _data.revenueYtd,
                  format: _moneyNoDecimals,
                  caption: '',
                  valueColor: DashUi.sky,
                  index: 0,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AnimatedMetricCard(
                  title: 'Outstanding',
                  value: _data.outstandingMoney,
                  format: _moneyNoDecimals,
                  caption: '',
                  valueColor: DashUi.amber,
                  index: 1,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AnimatedMetricCard(
                  title: 'Gross Profit YTD',
                  value: _data.grossProfitYtd,
                  format: _moneyNoDecimals,
                  caption: '',
                  valueColor: DashUi.emeraldDeep,
                  index: 2,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AnimatedMetricCard(
                  title: 'Yearly Projected',
                  value: _data.yearlyProjected,
                  format: _moneyNoDecimals,
                  caption: '',
                  valueColor: DashUi.blue,
                  index: 3,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AnimatedMetricCard(
                  title: 'Company Pool',
                  value: _data.companyPool,
                  format: _moneyNoDecimals,
                  caption: '',
                  valueColor: DashUi.indigo,
                  index: 4,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AnimatedMetricCard(
                  title: 'Commercial Pool',
                  value: _data.commercialPool,
                  format: _moneyNoDecimals,
                  caption: '',
                  valueColor: DashUi.ink,
                  index: 5,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // 2. Middle Row: OpEx/Net Toggle (Left) + Revenue Segment Split (Right)
        //    OpEx gets more of the horizontal room (was 7:5, now 8:4) so the
        //    donut panel is narrower instead of stretching wide with empty
        //    space around the circle.
        Expanded(
          flex: 11,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 8,
                child: _buildToggleableExpenseContainer(chartData),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 4,
                child: _RevenueSegmentPanel(
                  residential: _data.residentialRevenue,
                  commercial: _data.commercialRevenue,
                  highVolume: _data.highVolumeRevenue,
                  other: _data.otherRevenue,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 14),

        // 3. Bottom Row: Interactive Dynamic Revenue vs Profit Chart
        Expanded(
          flex: 9,
          child: _InteractiveFinancialChart(
            data: chartData,
            year: widget.selectedYear,
          ),
        ),
      ],
    );
  }

  // ---- MIDDLE ROW COMPONENT A: EXPENSE / NET INCOME TOGGLE ----
  Widget _buildToggleableExpenseContainer(List<_MonthlyFinancials> chartData) {
    return Container(
      padding: const EdgeInsets.all(20.0),
      decoration: DashUi.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  _showNetIncomeView ? 'NET INCOME TREND (AFTER OPEX)' : 'OPERATING EXPENSES · ${_moneyNoDecimals(_opexTotal)} YTD',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: DashUi.ink,
                    letterSpacing: 0.8,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(8)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildToggleTab('OpEx', !_showNetIncomeView, () => setState(() => _showNetIncomeView = false)),
                    _buildToggleTab('Net Income', _showNetIncomeView, () => setState(() => _showNetIncomeView = true)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _showNetIncomeView
                ? _NetIncomePanel(data: chartData, expenses: _data.expenses)
                : _InteractiveOpExList(expenses: _data.expenses),
          ),
        ],
      ),
    );
  }

  Widget _buildToggleTab(String text, bool active, VoidCallback onTap) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: active ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: active ? DashUi.line : Colors.transparent),
          ),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: active ? FontWeight.bold : FontWeight.w600,
              color: active ? DashUi.ink : DashUi.slate,
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// REVENUE BY SEGMENT PANEL (animated donut + linked legend)
// =============================================================================

class _SegSlice {
  final String name;
  final double amount;
  final Color color;
  const _SegSlice(this.name, this.amount, this.color);
}

class _RevenueSegmentPanel extends StatefulWidget {
  final double residential;
  final double commercial;
  final double highVolume;
  final double other;

  const _RevenueSegmentPanel({
    required this.residential,
    required this.commercial,
    required this.highVolume,
    required this.other,
  });

  @override
  State<_RevenueSegmentPanel> createState() => _RevenueSegmentPanelState();
}

class _RevenueSegmentPanelState extends State<_RevenueSegmentPanel> with SingleTickerProviderStateMixin {
  late final AnimationController _intro;
  int? _active;

  List<_SegSlice> get _slices => [
        _SegSlice('Residential', math.max(0, widget.residential), DashUi.sky),
        _SegSlice('Commercial', math.max(0, widget.commercial), DashUi.indigo),
        _SegSlice('High Volume', math.max(0, widget.highVolume), DashUi.emeraldDeep),
        _SegSlice('Other', math.max(0, widget.other), DashUi.amber),
      ];

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..forward();
  }

  @override
  void didUpdateWidget(covariant _RevenueSegmentPanel old) {
    super.didUpdateWidget(old);
    if (old.residential != widget.residential ||
        old.commercial != widget.commercial ||
        old.highVolume != widget.highVolume ||
        old.other != widget.other) {
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

  int? _hit(Offset p, double side, List<_SegSlice> slices, double total) {
    if (total <= 0) return null;
    final d = p - Offset(side / 2, side / 2);
    final r = _DonutPainter.radiusFor(side);
    final half = _DonutPainter.strokeFor(side) / 2 + 4;
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

  Widget _center(List<_SegSlice> slices, double total, double side) {
    Widget child;
    final i = _active;
    if (total <= 0) {
      child = const Text('No revenue\nyet',
          textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: DashUi.muted, fontWeight: FontWeight.w600));
    } else if (i != null) {
      final s = slices[i];
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${(s.amount / total * 100).toStringAsFixed(1)}%',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: s.color, height: 1.05)),
          const SizedBox(height: 2),
          Text(s.name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.slate)),
          Text(_compactMoney(s.amount),
              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: DashUi.muted)),
        ],
      );
    } else {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_compactMoney(total),
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: DashUi.ink, height: 1.05)),
          const SizedBox(height: 2),
          const Text('Total revenue',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: DashUi.slate)),
        ],
      );
    }
    return SizedBox(
      width: side * 0.56,
      child: FittedBox(fit: BoxFit.scaleDown, child: child),
    );
  }

  Widget _legend(List<_SegSlice> slices, double total) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: List.generate(slices.length, (i) {
        final s = slices[i];
        final pct = total > 0 ? s.amount / total * 100 : 0.0;
        final isActive = _active == i;
        final faded = _active != null && !isActive;
        return MouseRegion(
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          s.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: isActive ? FontWeight.w800 : FontWeight.w600,
                            color: isActive ? DashUi.ink : DashUi.slate,
                          ),
                        ),
                        Text(_moneyFull(s.amount),
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: DashUi.muted)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('${pct.toStringAsFixed(1)}%',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: s.color)),
                ],
              ),
            ),
          ),
        );
      }),
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
          const Text(
            'REVENUE BY SEGMENT',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: DashUi.ink, letterSpacing: 0.8),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                final side = math.min(c.maxHeight, c.maxWidth * 0.46);
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
                                  painter: _DonutPainter(
                                    slices: slices,
                                    total: total,
                                    active: _active,
                                    t: Curves.easeOutCubic.transform(_intro.value),
                                  ),
                                ),
                              ),
                              IgnorePointer(child: _center(slices, total, side)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 24),
                    Expanded(child: _legend(slices, total)),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  final List<_SegSlice> slices;
  final double total;
  final int? active;
  final double t;

  const _DonutPainter({required this.slices, required this.total, required this.active, required this.t});

  static double strokeFor(double side) => side * 0.15;
  static double radiusFor(double side) => (side - strokeFor(side) - 10) / 2;

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    final center = Offset(size.width / 2, size.height / 2);
    final stroke = strokeFor(side);
    final rect = Rect.fromCircle(center: center, radius: radiusFor(side));

    // Track
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
    final gap = nonZero > 1 ? 0.045 : 0.0;
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
      start += full * 1.0;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.active != active || old.t != t || old.total != total || old.slices != slices;
}

// =============================================================================
// INTERACTIVE OP-EX LIST
// =============================================================================

class _InteractiveOpExList extends StatefulWidget {
  final List<_ExpenseCategory> expenses;
  const _InteractiveOpExList({required this.expenses});

  @override
  State<_InteractiveOpExList> createState() => _InteractiveOpExListState();
}

class _InteractiveOpExListState extends State<_InteractiveOpExList> {
  int? _hoveredIndex;

  String _fmt(num value) {
    return value.toStringAsFixed(0).replaceAllMapped(
        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]},');
  }

  @override
  Widget build(BuildContext context) {
    if (widget.expenses.isEmpty) {
      return const Center(
        child: Text('No operating expenses recorded yet.', style: TextStyle(color: DashUi.muted)),
      );
    }

    final double totalExpense = widget.expenses.fold(0.0, (max, item) => max + item.amount);
    final double maxExpense = widget.expenses.fold(0.0, (max, item) => item.amount > max ? item.amount : max) * 1.05;

    return LayoutBuilder(
      builder: (context, constraints) {
        return Column(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: List.generate(widget.expenses.length, (index) {
            final exp = widget.expenses[index];
            final double ratio = maxExpense > 0 ? (exp.amount / maxExpense).clamp(0.02, 1.0) : 0.0;
            final double pctOfTotal = totalExpense > 0 ? (exp.amount / totalExpense) * 100 : 0.0;
            
            final isHovered = _hoveredIndex == index;
            final isFaded = _hoveredIndex != null && _hoveredIndex != index;

            return MouseRegion(
              onEnter: (_) => setState(() => _hoveredIndex = index),
              onExit: (_) => setState(() => _hoveredIndex = null),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: isFaded ? 0.35 : 1.0,
                child: Row(
                  children: [
                    SizedBox(
                      width: 150,
                      child: Text(
                        exp.category,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: isHovered ? FontWeight.w800 : FontWeight.w600,
                          color: isHovered ? DashUi.ink : DashUi.slate,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          Container(
                            height: isHovered ? 28 : 24, 
                            decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(7))
                          ),
                          FractionallySizedBox(
                            widthFactor: ratio,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 400),
                              curve: Curves.easeOutCubic,
                              height: isHovered ? 28 : 24,
                              decoration: BoxDecoration(color: exp.color, borderRadius: BorderRadius.circular(7)),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    SizedBox(
                      width: 84,
                      child: Text(
                        isHovered ? '${pctOfTotal.toStringAsFixed(1)}%' : '\$${_fmt(exp.amount)}',
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          fontSize: 14.5, 
                          fontWeight: isHovered ? FontWeight.w900 : FontWeight.bold, 
                          color: isHovered ? exp.color : DashUi.ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

// =============================================================================
// NET INCOME PANEL
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

class _NiceRange {
  final double min;
  final double max;
  final double step;
  const _NiceRange(this.min, this.max, this.step);
}

_NiceRange _niceRange(double minV, double maxV) {
  final span = maxV - minV;
  if (span <= 0) return const _NiceRange(0, 40000, 10000);
  final raw = span / 4;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  final step = (norm <= 1 ? 1 : (norm <= 2 ? 2 : (norm <= 5 ? 5 : 10))) * mag;
  var top = (maxV / step).ceil() * step;
  var bottom = (minV / step).floor() * step;
  if (maxV > 0 && top < maxV * 1.08) top += step;
  if (minV < 0 && bottom > minV * 1.08) bottom -= step;
  if (top == bottom) top += step;
  return _NiceRange(bottom, top, step);
}

double _niceFactor(double f) {
  if (f <= 1) return 1;
  for (final s in const [1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0, 12.0, 15.0, 20.0, 25.0, 30.0, 40.0, 50.0]) {
    if (f <= s) return s;
  }
  return f.ceilToDouble();
}

class _NetIncomePanel extends StatefulWidget {
  final List<_MonthlyFinancials> data;
  final List<_ExpenseCategory> expenses;
  const _NetIncomePanel({required this.data, required this.expenses});

  @override
  State<_NetIncomePanel> createState() => _NetIncomePanelState();
}

class _NetIncomePanelState extends State<_NetIncomePanel> {
  int? _hover; // hovered / tapped month; null = show latest month

  void _setHover(int? i) {
    if (i == _hover) return;
    setState(() => _hover = i);
  }

  int? _indexFor(double dx, double width) {
    final plotW = width - _NetChartPainter.leftGutter - _NetChartPainter.rightGutter;
    if (plotW <= 0) return null;
    final i = ((dx - _NetChartPainter.leftGutter) / (plotW / 12)).floor();
    return (i < 0 || i > 11) ? null : i;
  }

  Widget _stat(String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: DashUi.muted)),
        const SizedBox(height: 1),
        Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: color)),
      ],
    );
  }

  Widget _legend(Widget swatch, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        swatch,
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: DashUi.slate)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalOpEx = widget.expenses.fold<double>(0, (s, e) => s + e.amount);
    final series = _buildNetSeries(widget.data, totalOpEx);
    final lastActive = series.lastIndexWhere((p) => p.hasData);

    if (lastActive < 0) {
      return const Center(child: Text('No data recorded yet.', style: TextStyle(color: DashUi.muted)));
    }

    final hover = _hover;
    final sel = (hover != null && hover < series.length && series[hover].hasData) ? hover : lastActive;
    final p = series[sel];
    final showingLatest = sel == lastActive && hover == null;

    final netYtd = series.last.cumulative;
    final profitYtd = series.fold<double>(0, (s, x) => s + x.profit);
    final expenseYtd = series.fold<double>(0, (s, x) => s + x.expense);
    final opexShare = profitYtd > 0 ? expenseYtd / profitYtd * 100 : null;
    final netColor = netYtd >= 0 ? DashUi.emeraldDeep : DashUi.red;
    final pNetColor = p.net >= 0 ? DashUi.emeraldDeep : DashUi.red;

    final estimated = !widget.data.any((m) => m.hasData && m.expense > 0) && totalOpEx > 0;
    final noExpenses = expenseYtd <= 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Headline + selected-month readout
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Net income YTD',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: DashUi.slate)),
                Text(_moneyFull(netYtd),
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: netColor, height: 1.15)),
                if (opexShare != null)
                  Text('OpEx = ${opexShare.toStringAsFixed(0)}% of gross profit',
                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: DashUi.muted)),
              ],
            ),
            const SizedBox(width: 24),
            Container(width: 1, height: 46, color: DashUi.line),
            const SizedBox(width: 24),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    showingLatest ? '${p.month} · latest' : p.month,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: DashUi.ink, letterSpacing: 0.4),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 22,
                    runSpacing: 4,
                    children: [
                      _stat('Gross profit', _moneyFull(p.profit), DashUi.emeraldDeep),
                      _stat('OpEx', p.expense > 0 ? '-${_moneyFull(p.expense)}' : '\$0', DashUi.amber),
                      _stat('Net', _moneyFull(p.net), pNetColor),
                      _stat('Cumulative', _moneyFull(p.cumulative), DashUi.indigo),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // Chart
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) {
              return MouseRegion(
                onHover: (e) => _setHover(_indexFor(e.localPosition.dx, c.maxWidth)),
                onExit: (_) => _setHover(null),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _setHover(_indexFor(d.localPosition.dx, c.maxWidth)),
                  onHorizontalDragUpdate: (d) => _setHover(_indexFor(d.localPosition.dx, c.maxWidth)),
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: _NetChartPainter(series: series, selected: sel),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 6),

        // Legend + data-quality note
        Wrap(
          spacing: 16,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _legend(
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: DashUi.emeraldDeep, borderRadius: BorderRadius.circular(2)),
              ),
              'Monthly net',
            ),
            _legend(
              Container(
                width: 14,
                height: 3,
                decoration: BoxDecoration(color: DashUi.indigo, borderRadius: BorderRadius.circular(2)),
              ),
              'Cumulative (right axis)',
            ),
            if (estimated)
              const Text('OpEx spread evenly across months (no monthly expense data)',
                  style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: DashUi.muted))
            else if (noExpenses)
              const Text('No expenses recorded, so net = gross profit',
                  style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: DashUi.muted)),
          ],
        ),
      ],
    );
  }
}

class _NetChartPainter extends CustomPainter {
  static const double leftGutter = 46;
  static const double rightGutter = 46;
  static const double bottomGutter = 22;
  static const double topPad = 8;

  final List<_NetPoint> series;
  final int selected;

  const _NetChartPainter({required this.series, required this.selected});

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(leftGutter, topPad, size.width - rightGutter, size.height - bottomGutter);
    if (plot.width <= 0 || plot.height <= 0 || series.isEmpty) return;

    final n = series.length;
    final slotW = plot.width / n;

    var maxNet = 0.0, minNet = 0.0, maxCum = 0.0, minCum = 0.0;
    for (final p in series) {
      if (!p.hasData) continue;
      maxNet = math.max(maxNet, p.net);
      minNet = math.min(minNet, p.net);
      maxCum = math.max(maxCum, p.cumulative);
      minCum = math.min(minCum, p.cumulative);
    }

    final axis = _niceRange(minNet, maxNet);
    double yFor(double v) => plot.bottom - (v - axis.min) / (axis.max - axis.min) * plot.height;
    final zeroY = yFor(0);

    // The cumulative line rides a right-hand axis that is the left axis times [f],
    // so both zero lines coincide and the line never leaves the plot.
    var f = 1.0;
    if (axis.max > 0 && maxCum > 0) f = math.max(f, maxCum / axis.max);
    if (axis.min < 0 && minCum < 0) f = math.max(f, minCum / axis.min);
    f = _niceFactor(f);
    double yCum(double v) => yFor(v / f);

    // Selected column highlight
    if (selected >= 0 && selected < n) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(plot.left + selected * slotW + 2, plot.top, slotW - 4, plot.height),
          const Radius.circular(10),
        ),
        Paint()..color = const Color(0xFFEFF6FF),
      );
    }

    // Grid + both axes
    final ticks = ((axis.max - axis.min) / axis.step).round();
    for (var i = 0; i <= ticks; i++) {
      final v = axis.min + i * axis.step;
      final y = yFor(v);
      final isZero = (v).abs() < axis.step * 1e-6;
      canvas.drawLine(
        Offset(plot.left, y),
        Offset(plot.right, y),
        Paint()
          ..color = isZero ? DashUi.slate.withValues(alpha: 0.45) : DashUi.faint
          ..strokeWidth = isZero ? 1.5 : 1,
      );
      final left = _layoutText(
        _compactMoney(v),
        const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: DashUi.muted),
      );
      left.paint(canvas, Offset(leftGutter - 8 - left.width, y - left.height / 2));

      if (f > 1.01) {
        final right = _layoutText(
          _compactMoney(v * f),
          TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: DashUi.indigo.withValues(alpha: 0.8)),
        );
        right.paint(canvas, Offset(plot.right + 8, y - right.height / 2));
      }
    }

    // Bars + month labels
    final linePts = <Offset>[];
    for (var i = 0; i < n; i++) {
      final p = series[i];
      final cx = plot.left + slotW * (i + 0.5);
      final isSel = i == selected;

      final label = _layoutText(
        p.month,
        TextStyle(
          fontSize: 11.5,
          fontWeight: isSel ? FontWeight.w800 : FontWeight.w600,
          color: isSel ? DashUi.ink : (p.hasData ? DashUi.slate : const Color(0xFFCBD5E1)),
        ),
        maxWidth: slotW,
        align: TextAlign.center,
      );
      label.paint(canvas, Offset(cx - label.width / 2, plot.bottom + 6));

      if (!p.hasData) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(cx, zeroY), width: 14, height: 3), const Radius.circular(2)),
          Paint()..color = DashUi.line,
        );
        continue;
      }

      final barW = math.min(slotW * 0.5, 28.0);
      final y = yFor(p.net);
      final top = math.min(zeroY, y);
      final bottom = math.max(zeroY, y);
      final rect = Rect.fromLTRB(cx - barW / 2, top, cx + barW / 2, math.max(bottom, top + 2));
      final pos = p.net >= 0;
      final color = pos ? DashUi.emeraldDeep : DashUi.red;
      final r = Radius.circular(math.min(6, barW / 2));

      canvas.drawRRect(
        RRect.fromRectAndCorners(
          rect,
          topLeft: pos ? r : Radius.zero,
          topRight: pos ? r : Radius.zero,
          bottomLeft: pos ? Radius.zero : r,
          bottomRight: pos ? Radius.zero : r,
        ),
        Paint()..color = color.withValues(alpha: isSel ? 1.0 : 0.6),
      );

      linePts.add(Offset(cx, yCum(p.cumulative)));
    }

    // Cumulative line
    if (linePts.isNotEmpty) {
      if (linePts.length > 1) {
        final path = Path()..moveTo(linePts.first.dx, linePts.first.dy);
        for (var i = 1; i < linePts.length; i++) {
          path.lineTo(linePts[i].dx, linePts[i].dy);
        }
        canvas.drawPath(
          path,
          Paint()
            ..color = DashUi.indigo
            ..strokeWidth = 2.5
            ..style = PaintingStyle.stroke
            ..strokeJoin = StrokeJoin.round
            ..strokeCap = StrokeCap.round,
        );
      }

      // Dots line up with the active months in order; find the selected one by x.
      final selX = plot.left + slotW * (selected + 0.5);
      for (final pt in linePts) {
        final isSel = (pt.dx - selX).abs() < 0.5;
        canvas.drawCircle(pt, isSel ? 6 : 3.5, Paint()..color = Colors.white);
        canvas.drawCircle(pt, isSel ? 4 : 2.2, Paint()..color = DashUi.indigo);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _NetChartPainter old) => old.selected != selected || old.series != series;
}

// =============================================================================
// INTERACTIVE FINANCIAL CHART (BOTTOM)
// =============================================================================

enum _FinancialChartMetric { both, revenue, profit, margin }

extension _FinancialChartMetricX on _FinancialChartMetric {
  String get toggleLabel => switch (this) {
        _FinancialChartMetric.both => 'Both',
        _FinancialChartMetric.revenue => 'Revenue',
        _FinancialChartMetric.profit => 'Profit',
        _FinancialChartMetric.margin => 'Margin %',
      };

  // Updated captions to clarify completed jobs scope
  String get caption => switch (this) {
        _FinancialChartMetric.both => 'Completed Revenue vs. Completed Profit',
        _FinancialChartMetric.revenue => 'Monthly Completed Revenue trajectory',
        _FinancialChartMetric.profit => 'Monthly Completed Profit performance',
        _FinancialChartMetric.margin => 'Monthly Completed Profit Margin trend',
      };
}

class _AxisScale {
  final double max;
  final double step;
  const _AxisScale(this.max, this.step);
  int get ticks => (max / step).round();
}

_AxisScale _niceScale(double maxV, {bool isPercent = false}) {
  if (maxV <= 0) return isPercent ? const _AxisScale(100, 25) : const _AxisScale(50000, 10000);
  final raw = maxV / 4;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  final double nice = norm <= 1 ? 1 : (norm <= 2 ? 2 : (norm <= 5 ? 5 : 10));
  var step = nice * mag;
  var top = (maxV / step).ceil() * step;
  if (top < maxV * 1.08) top += step;
  return _AxisScale(top, step);
}

class _InteractiveFinancialChart extends StatefulWidget {
  final List<_MonthlyFinancials> data;
  final int? year;

  const _InteractiveFinancialChart({required this.data, this.year});

  @override
  State<_InteractiveFinancialChart> createState() => _InteractiveFinancialChartState();
}

class _InteractiveFinancialChartState extends State<_InteractiveFinancialChart> with TickerProviderStateMixin {
  late final AnimationController _intro;
  late final AnimationController _hover;

  _FinancialChartMetric _metric = _FinancialChartMetric.both;
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
  void didUpdateWidget(covariant _InteractiveFinancialChart oldWidget) {
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
    final nextIndex = (_metric.index + 1) % _FinancialChartMetric.values.length;
    _setMetric(_FinancialChartMetric.values[nextIndex]);
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

  void _setMetric(_FinancialChartMetric m) {
    if (m == _metric) return;
    setState(() => _metric = m);
    _resetAndReplay();
  }

  int? _indexFor(double dx, double width) {
    final n = widget.data.length;
    if (n == 0) return null;
    final plotW = width - _FinancialChartPainter.leftGutter;
    if (plotW <= 0) return null;
    final i = ((dx - _FinancialChartPainter.leftGutter) / (plotW / n)).floor();
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

    final activeData = data.where((d) => d.hasData).toList();
    final totalRev = activeData.fold<double>(0, (a, b) => a + b.revenue);
    final totalProfit = activeData.fold<double>(0, (a, b) => a + b.profit);
    final avgMargin = totalRev > 0 ? (totalProfit / totalRev) * 100 : 0.0;

    String headlineValue;
    String headlineLabel;
    
    // Updated headline labels for explicit completed branding
    if (_metric == _FinancialChartMetric.margin) {
      headlineValue = '${avgMargin.toStringAsFixed(1)}%';
      headlineLabel = 'Avg Completed Margin for $yearText';
    } else if (_metric == _FinancialChartMetric.profit) {
      headlineValue = _compactMoney(totalProfit);
      headlineLabel = 'Total Completed Profit for $yearText';
    } else {
      headlineValue = _compactMoney(totalRev);
      headlineLabel = 'Completed Revenue for $yearText';
    }

    int? peakIndex;
    var peakValue = 0.0;
    for (var i = 0; i < data.length; i++) {
      if (!data[i].hasData) continue;
      final val = _metric == _FinancialChartMetric.profit
          ? data[i].profit
          : _metric == _FinancialChartMetric.margin
              ? data[i].marginPct
              : data[i].revenue;
      if (val > peakValue) {
        peakValue = val;
        peakIndex = i;
      }
    }

    var maxV = 0.0;
    for (final p in data) {
      if (!p.hasData) continue;
      if (_metric == _FinancialChartMetric.margin) {
        maxV = math.max(maxV, p.marginPct);
      } else if (_metric == _FinancialChartMetric.profit) {
        maxV = math.max(maxV, p.profit);
      } else {
        maxV = math.max(maxV, p.revenue);
      }
    }
    final scale = _niceScale(maxV, isPercent: _metric == _FinancialChartMetric.margin);

    double? trendPct;
    String? trendLabel;
    if (activeData.length >= 2) {
      final last = activeData.last;
      final prev = activeData[activeData.length - 2];
      final valLast = _metric == _FinancialChartMetric.profit
          ? last.profit
          : _metric == _FinancialChartMetric.margin
              ? last.marginPct
              : last.revenue;
      final valPrev = _metric == _FinancialChartMetric.profit
          ? prev.profit
          : _metric == _FinancialChartMetric.margin
              ? prev.marginPct
              : prev.revenue;
      trendPct = _pct(valPrev, valLast);
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
                        headlineValue,
                        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: DashUi.ink, height: 1.1),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        headlineLabel,
                        style: const TextStyle(fontSize: 13, color: DashUi.muted, fontWeight: FontWeight.w500),
                      ),
                      if (trendPct != null) ...[
                        const SizedBox(width: 10),
                        _TrendChip(pct: trendPct, label: trendLabel!),
                      ],
                    ],
                  ),
                ],
              ),
              _MetricToggle(value: _metric, onChanged: _setMetric),
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
                                painter: _FinancialChartPainter(
                                  data: data,
                                  metric: _metric,
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
                      ),
                    ),
                    if (activeData.isEmpty)
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
          const SizedBox(height: 12),
          Wrap(
            spacing: 18,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (_metric == _FinancialChartMetric.both || _metric == _FinancialChartMetric.revenue)
                _legendItem(
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      gradient: const LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Color(0xFF0284C7), Color(0xFF38BDF8)],
                      ),
                    ),
                  ),
                  'Completed Revenue', // Updated Legend
                ),
              if (_metric == _FinancialChartMetric.both || _metric == _FinancialChartMetric.profit)
                _legendItem(
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      gradient: const LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Color(0xFF059669), Color(0xFF34D399)],
                      ),
                    ),
                  ),
                  'Completed Profit', // Updated Legend
                ),
              if (_metric == _FinancialChartMetric.margin)
                _legendItem(
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(width: 8, height: 3, color: const Color(0xFF6366F1)),
                      const SizedBox(width: 2),
                      const Icon(Icons.arrow_upward_rounded, size: 12, color: Color(0xFF10B981)),
                    ],
                  ),
                  'Completed Margin %', // Updated Legend
                ),
              if (peakIndex != null)
                _legendItem(
                  Transform.rotate(
                    angle: math.pi / 4,
                    child: Container(width: 8, height: 8, color: DashUi.amber),
                  ),
                  'Peak in ${data[peakIndex].month}',
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

class _MetricToggle extends StatelessWidget {
  final _FinancialChartMetric value;
  final ValueChanged<_FinancialChartMetric> onChanged;
  const _MetricToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: _FinancialChartMetric.values.map((m) {
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

class _FinancialChartPainter extends CustomPainter {
  static const double leftGutter = 52;
  static const double bottomGutter = 28;
  static const double topPad = 6;

  final List<_MonthlyFinancials> data;
  final _FinancialChartMetric metric;
  final _AxisScale scale;
  final int? peakIndex;
  final int? index;
  final double intro;
  final double hover;

  const _FinancialChartPainter({
    required this.data,
    required this.metric,
    required this.scale,
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
      final label = metric == _FinancialChartMetric.margin ? '${v.round()}%' : _compactMoney(v);
      final tp = _layoutText(
        label,
        const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: DashUi.muted),
      );
      tp.paint(canvas, Offset(leftGutter - 8 - tp.width, y - tp.height / 2));
    }

    final stagger = 0.4 / n;

    final marginPoints = <Offset>[];
    final marginTrends = <int>[];
    final bothProfitPoints = <Offset>[];

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
          fontSize: 13,
          fontWeight: isFocus ? FontWeight.w800 : FontWeight.w600,
          color: isFocus ? DashUi.ink : (has ? DashUi.slate : const Color(0xFFCBD5E1)),
        ),
        maxWidth: slotW,
        align: TextAlign.center,
      );
      labelTp.paint(canvas, Offset(cx - labelTp.width / 2, plot.bottom + 8));

      if (!has) {
        final stub = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(cx, plot.bottom - 1.5), width: 18, height: 3),
          const Radius.circular(2),
        );
        canvas.drawRRect(stub, Paint()..color = DashUi.line);
        continue;
      }

      if (metric == _FinancialChartMetric.margin) {
        final fullH = (p.marginPct / scale.max).clamp(0.0, 1.0) * plot.height;
        final h = fullH * localT;
        final y = plot.bottom - h;
        marginPoints.add(Offset(cx, y));

        if (i == 0) {
          marginTrends.add(0);
        } else {
          final prevP = data[i - 1];
          if (prevP.hasData) {
            if (p.marginPct > prevP.marginPct) {
              marginTrends.add(1);
            } else if (p.marginPct < prevP.marginPct) marginTrends.add(-1);
            else marginTrends.add(0);
          } else {
            marginTrends.add(0);
          }
        }
      

} else if (metric == _FinancialChartMetric.both) {
  // Revenue bars + gross profit line.
  final groupW = math.min(slotW * 0.72, 40.0);
  final barW = groupW;

  final revH =
      (p.revenue / scale.max).clamp(0.0, 1.0) *
      plot.height *
      localT;

  final profitY = plot.bottom -
      (p.profit / scale.max).clamp(0.0, 1.0) *
          plot.height *
          localT;

  final revRect = Rect.fromLTWH(
    cx - barW / 2,
    plot.bottom - math.max(3.0, revH),
    barW,
    math.max(3.0, revH),
  );

  final revRRect = RRect.fromRectAndRadius(
    revRect,
    const Radius.circular(6),
  );

  // Revenue bar.
  canvas.drawRRect(
    revRRect,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          const Color(0xFF0369A1).withValues(alpha: dim),
          const Color(0xFF38BDF8).withValues(alpha: dim),
        ],
      ).createShader(revRect),
  );

  // Collect profit points for the line drawn after the bars.
  bothProfitPoints.add(
    Offset(cx, profitY),
  );


      } else {
        final baseW = math.min(slotW * 0.58, 36.0);
        final barW = baseW + (isFocus ? 4 * hover : 0);
        final val = metric == _FinancialChartMetric.profit ? p.profit : p.revenue;

        final fullH = (val / scale.max).clamp(0.0, 1.0) * plot.height;
        final h = math.max(3.0, fullH * localT);
        final rect = Rect.fromLTWH(cx - barW / 2, plot.bottom - h, barW, h);
        final topR = Radius.circular(math.min(8, barW / 2));
        final rrect = RRect.fromRectAndCorners(rect, topLeft: topR, topRight: topR, bottomLeft: const Radius.circular(2), bottomRight: const Radius.circular(2));

        final List<Color> colors = metric == _FinancialChartMetric.profit
            ? const [Color(0xFF059669), Color(0xFF34D399)]
            : const [Color(0xFF0284C7), Color(0xFF38BDF8)];

        canvas.drawRRect(
          rrect,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: colors.map((c) => c.withValues(alpha: dim)).toList(),
            ).createShader(rect),
        );
      }

      if (peakIndex == i && localT > 0.98) {
        final val = metric == _FinancialChartMetric.profit ? p.profit : (metric == _FinancialChartMetric.margin ? p.marginPct : p.revenue);
        final topY = plot.bottom - ((val / scale.max).clamp(0.0, 1.0) * plot.height) - 14; 
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
    
if (metric == _FinancialChartMetric.both &&
    bothProfitPoints.isNotEmpty) {
  final profitPath = Path()
    ..moveTo(
      bothProfitPoints.first.dx,
      bothProfitPoints.first.dy,
    );

  for (var i = 1; i < bothProfitPoints.length; i++) {
    profitPath.lineTo(
      bothProfitPoints[i].dx,
      bothProfitPoints[i].dy,
    );
  }

  // Draw the green gross profit line.
  canvas.drawPath(
    profitPath,
    Paint()
      ..color = const Color(0xFF059669).withValues(alpha: intro)
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round,
  );

  // Draw circular markers.
  for (final pt in bothProfitPoints) {
    canvas.drawCircle(
      pt,
      5.5,
      Paint()..color = Colors.white.withValues(alpha: intro),
    );

    canvas.drawCircle(
      pt,
      3.5,
      Paint()
        ..color = const Color(0xFF059669).withValues(alpha: intro),
    );
  }
}


    if (metric == _FinancialChartMetric.margin && marginPoints.isNotEmpty) {
      final path = Path();
      path.moveTo(marginPoints.first.dx, marginPoints.first.dy);
      for (var i = 1; i < marginPoints.length; i++) {
        path.lineTo(marginPoints[i].dx, marginPoints[i].dy);
      }

      final areaPath = Path.from(path)
        ..lineTo(marginPoints.last.dx, plot.bottom)
        ..lineTo(marginPoints.first.dx, plot.bottom)
        ..close();

      canvas.drawPath(
        areaPath,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              const Color(0xFF6366F1).withValues(alpha: 0.2 * intro),
              const Color(0xFF6366F1).withValues(alpha: 0.0),
            ],
          ).createShader(Rect.fromLTWH(0, 0, plot.width, plot.height)),
      );

      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF6366F1).withValues(alpha: intro)
          ..strokeWidth = 3.0
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round,
      );

      for (var i = 0; i < marginPoints.length; i++) {
        final pt = marginPoints[i];
        final trend = marginTrends[i];

        canvas.drawCircle(pt, 8, Paint()..color = Colors.white.withValues(alpha: intro));

        if (trend > 0) {
          final arrow = Path()
            ..moveTo(pt.dx, pt.dy - 5)
            ..lineTo(pt.dx + 5, pt.dy + 4)
            ..lineTo(pt.dx - 5, pt.dy + 4)
            ..close();
          canvas.drawPath(arrow, Paint()..color = const Color(0xFF10B981).withValues(alpha: intro)..style = PaintingStyle.fill);
        } else if (trend < 0) {
          final arrow = Path()
            ..moveTo(pt.dx, pt.dy + 5)
            ..lineTo(pt.dx + 5, pt.dy - 4)
            ..lineTo(pt.dx - 5, pt.dy - 4)
            ..close();
          canvas.drawPath(arrow, Paint()..color = const Color(0xFFEF4444).withValues(alpha: intro)..style = PaintingStyle.fill);
        } else {
          canvas.drawCircle(pt, 4, Paint()..color = const Color(0xFF6366F1).withValues(alpha: intro));
        }
      }
    }

    if (focusing) _paintTooltip(canvas, size, plot, slotW, yFor);
  }

  void _paintTooltip(Canvas canvas, Size size, Rect plot, double slotW, double Function(double) yFor) {
    final i = index!;
    final p = data[i];
    final has = p.hasData;

    final rows = <(String, String, bool)>[
      ('Revenue', _compactMoney(p.revenue), metric == _FinancialChartMetric.both || metric == _FinancialChartMetric.revenue),
      ('Gross Profit', _compactMoney(p.profit), metric == _FinancialChartMetric.both || metric == _FinancialChartMetric.profit),
      ('Profit Margin', '${p.marginPct.toStringAsFixed(1)}%', metric == _FinancialChartMetric.margin),
    ];

    TextPainter? deltaTp;
    if (i > 0 && has && data[i - 1].hasData) {
      final prevVal = metric == _FinancialChartMetric.profit
          ? data[i - 1].profit
          : metric == _FinancialChartMetric.margin
              ? data[i - 1].marginPct
              : data[i - 1].revenue;
      final curVal = metric == _FinancialChartMetric.profit
          ? p.profit
          : metric == _FinancialChartMetric.margin
              ? p.marginPct
              : p.revenue;

      if (prevVal > 0) {
        final pct = (curVal - prevVal) / prevVal * 100;
        final up = pct >= 0;
        deltaTp = _layoutText(
          '${up ? '▲' : '▼'} ${pct.abs().toStringAsFixed(1)}% vs ${data[i - 1].month}',
          TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: up ? const Color(0xFF34D399) : const Color(0xFFF87171),
          ),
        );
      }
    }

    final titleTp = _layoutText(
      '${p.month} Financials',
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
    final deltaW = deltaTp?.width ?? 0.0;
    
    final tipW = math.max(titleTp.width, math.max(labelW + 16 + valueW, deltaW)) + 28;
    final rowH = labelTps.first.height;
    var tipH = 12 + titleTp.height + 6 + rows.length * rowH + (rows.length - 1) * 3 + 12;
    if (deltaTp != null) tipH += 6 + deltaTp.height;

    final cx = plot.left + slotW * (i + 0.5);
    final barW = math.min(slotW * 0.58, 36.0);
    
    final val = metric == _FinancialChartMetric.profit ? p.profit : (metric == _FinancialChartMetric.margin ? p.marginPct : p.revenue);
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
    if (deltaTp != null) {
      y += 3;
      deltaTp.paint(canvas, Offset(tx + 14, y));
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FinancialChartPainter old) =>
      old.data != data ||
      old.metric != metric ||
      old.intro != intro ||
      old.index != index ||
      old.hover != hover ||
      old.peakIndex != peakIndex;
}

// =============================================================================
// LOADING SKELETON
// =============================================================================

class _FinancialSkeleton extends StatelessWidget {
  const _FinancialSkeleton();

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
              SkeletonBox(h: 26, w: 100),
              SizedBox(height: 10),
              SkeletonBox(h: 10, w: 60),
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
            height: 92,
            child: Row(
              children: [
                _metric(), const SizedBox(width: 8),
                _metric(), const SizedBox(width: 8),
                _metric(), const SizedBox(width: 8),
                _metric(), const SizedBox(width: 8),
                _metric(), const SizedBox(width: 8),
                _metric(),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            flex: 11,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 8,
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: DashUi.panel(),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonBox(h: 16, w: 200),
                        SizedBox(height: 24),
                        Expanded(child: SkeletonBox(r: 8)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 4,
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
          const SizedBox(height: 14),
          Expanded(
            flex: 9,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: DashUi.panel(),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(h: 16, w: 250),
                  SizedBox(height: 24),
                  Expanded(child: SkeletonBox(r: 8)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}