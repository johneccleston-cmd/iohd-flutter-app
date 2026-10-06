import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'widgets/dashboard_kit.dart';
import 'widgets/dashboard_layout.dart';
import 'config/api_config.dart';
import 'config/auth_session.dart';

class InventoryDashboardScreen extends StatelessWidget {
  const InventoryDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      title: 'Inventory',
      builder: (context, selectedYear) {
        return InventoryDashboardContent(selectedYear: selectedYear);
      },
    );
  }
}

class InventoryDashboardContent extends StatefulWidget {
  final int selectedYear;
  const InventoryDashboardContent({super.key, required this.selectedYear});

  @override
  State<InventoryDashboardContent> createState() => _InventoryDashboardContentState();
}

// =============================================================================
// GLOBAL HELPERS
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
// MODELS & DESERIALIZATION
// =============================================================================

class _InventoryStrikeTech {
  final String name;
  final String imageUrl;
  final int strikeCount;

  const _InventoryStrikeTech({
    required this.name,
    required this.imageUrl,
    required this.strikeCount,
  });
}

class _CategoryData {
  final String name;
  final double activeValue;
  final double lowStockValue;
  final double deadValue;
  final Color color;

  const _CategoryData(this.name, this.activeValue, this.lowStockValue, this.deadValue, this.color);

  double get total => activeValue + lowStockValue + deadValue;
}

class _InventoryMonth {
  final String month;
  final double received;
  final double used;
  final double onHand;
  final bool hasData;

  const _InventoryMonth(this.month, this.received, this.used, this.onHand, this.hasData);
}

class _InventorySummary {
  final double totalValuation;

  /// Null when not tracked yet (needs a stock movement history the system doesn't record yet).
  final double? deadStockValue;
  final int lowStockCount;

  /// Null when not tracked yet (needs completed cycle counts with expected vs counted quantities).
  final double? accuracyPct;
  final DateTime? lastCycleCount;
  final List<_CategoryData> categories;
  final List<_InventoryMonth> monthly;
  final List<_InventoryStrikeTech> topStrikeTechs;

  /// False when the server says stock received/used by month isn't recorded yet.
  final bool movementTracked;

  /// Daily snapshots of the total valuation (oldest first) for its trend line.
  final List<double> valuationHistory;

  const _InventorySummary({
    this.totalValuation = 0,
    this.deadStockValue,
    this.lowStockCount = 0,
    this.accuracyPct,
    this.lastCycleCount,
    this.categories = const [],
    this.monthly = const [],
    this.topStrikeTechs = const [],
    this.movementTracked = true,
    this.valuationHistory = const [],
  });

  factory _InventorySummary.fromJson(Map<String, dynamic> json) {
    double num_(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0.0;
    int int_(dynamic v) => v is int ? v : int.tryParse('$v') ?? 0;

    // A malformed colorHex from the API falls back to blue instead of failing the whole screen.
    Color parseColor(String? hex) {
      if (hex == null || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) return DashUi.blue;
      return Color(int.parse('FF${hex.substring(1)}', radix: 16));
    }

    final catList = (json['categories'] as List? ?? [])
        .map((c) => _CategoryData(
              c['category']?.toString() ?? 'Unknown',
              num_(c['activeValue']),
              num_(c['lowStockValue']),
              num_(c['deadValue']),
              parseColor(c['colorHex']?.toString()),
            ))
        .toList();

    final techList = (json['topStrikeTechs'] as List? ?? [])
        .map((t) => _InventoryStrikeTech(
              name: t['name']?.toString() ?? 'Tech',
              imageUrl: t['imageUrl']?.toString() ?? '',
              strikeCount: int_(t['strikeCount']),
            ))
        .toList();

    final monthList = (json['monthly'] as List? ?? [])
        .map((m) => _InventoryMonth(
              m['month']?.toString() ?? '',
              num_(m['received']),
              num_(m['used']),
              num_(m['onHand']),
              m['hasData'] == true,
            ))
        .toList();

    return _InventorySummary(
      totalValuation: num_(json['totalValuation']),
      deadStockValue: json['deadStockValue'] == null ? null : num_(json['deadStockValue']),
      lowStockCount: int_(json['lowStockCount']),
      accuracyPct: json['accuracyPct'] == null ? null : num_(json['accuracyPct']),
      lastCycleCount: json['lastCycleCount'] != null ? DateTime.tryParse(json['lastCycleCount'].toString()) : null,
      categories: catList,
      topStrikeTechs: techList,
      monthly: monthList,
      movementTracked: json['movementTracked'] != false,
      valuationHistory: [
        for (final v in ((json['history'] is Map ? (json['history'] as Map)['valuation'] : null) as List? ?? const []))
          num_(v),
      ],
    );
  }
}

// =============================================================================
// SCREEN STATE
// =============================================================================

class _InventoryDashboardContentState extends State<InventoryDashboardContent> {
  _InventorySummary? _data;
  bool _isLoading = true;
  String? _errorMessage;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _fetchInventoryData();
  }

  @override
  void didUpdateWidget(covariant InventoryDashboardContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedYear != widget.selectedYear) {
      _fetchInventoryData();
    }
  }

  Future<void> _fetchInventoryData() async {
    final requestId = ++_requestId;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final urlString = '$kApiBaseUrl/api/dashboards/inventory?year=${widget.selectedYear}';

      final response = await http.get(
        Uri.parse(urlString),
        headers: AuthSession.instance.headers(),
      ).timeout(const Duration(seconds: 60)); // free-tier hosts can take ~30s+ to wake up

      if (!mounted || requestId != _requestId) return;

      if (response.statusCode == 200) {
        final Map<String, dynamic> jsonBody = json.decode(response.body);
        setState(() {
          _data = _InventorySummary.fromJson(jsonBody);
          _isLoading = false;
        });
      } else {
        throw Exception('The server returned status ${response.statusCode}.');
      }
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

  String _dateLabel(DateTime? d) {
    if (d == null) return '—';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(40.0),
          child: CircularProgressIndicator(color: DashUi.blue),
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline_rounded, color: DashUi.red, size: 36),
            const SizedBox(height: 8),
            Text(_errorMessage!, style: const TextStyle(color: DashUi.ink, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _fetchInventoryData,
              style: ElevatedButton.styleFrom(
                backgroundColor: DashUi.blue,
                foregroundColor: Colors.white,
              ),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final data = _data!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
      // 1. Top scorecards
        SizedBox(
          height: 104,
          child: Row(
            children: [
              Expanded(
                child: AnimatedMetricCard(
                  title: 'Total Valuation',
                  value: data.totalValuation,
                  format: _moneyFull,
                  caption: '', // Pass empty string to hide it
                  valueColor: DashUi.blue,
                  index: 0,
                  trend: data.valuationHistory.length >= 2 ? data.valuationHistory : null,
                  sparkMinWidth: 215,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AnimatedMetricCard(
                  // Shows "—" until stock movement is recorded (it used to always say $0).
                  title: data.deadStockValue == null ? 'Dead stock (not tracked yet)' : 'Dead Stock (90+ Days)',
                  value: data.deadStockValue,
                  format: _moneyFull,
                  caption: '', // Pass empty string to hide it
                  valueColor: DashUi.red,
                  index: 1,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AnimatedMetricCard(
                  // Items at or below a reorder point that has been set.
                  title: 'At or below reorder point',
                  value: data.lowStockCount.toDouble(),
                  format: (v) => v.round().toString(),
                  caption: '', // Pass empty string to hide it
                  valueColor: DashUi.amber,
                  index: 2,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AnimatedMetricCard(
                  // Shows "—" until cycle counts record expected vs counted (it used to be a fixed 98.4%).
                  title: data.accuracyPct == null ? 'Accuracy (not tracked yet)' : 'Inventory Accuracy',
                  value: data.accuracyPct,
                  format: (v) => '${v.toStringAsFixed(1)}%',
                  caption: '', // Pass empty string to hide it
                  valueColor: DashUi.emeraldDeep,
                  index: 3,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StaticInfoCard(
                  title: 'Last Cycle Count',
                  value: data.lastCycleCount == null ? 'Not yet' : _dateLabel(data.lastCycleCount),
                  icon: Icons.fact_check_outlined,
                  iconColor: DashUi.slate,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // 2. Middle row: Category Breakdown + Inventory Strike Podium
        Expanded(
          flex: 6,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 6,
                child: _CategoryBreakdownPanel(categories: data.categories, total: data.totalValuation),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 5,
                child: _InventoryStrikePodiumPanel(techs: data.topStrikeTechs),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // 3. Bottom row: Received/Used/On-Hand trend
        Expanded(
          flex: data.movementTracked ? 4 : 2,
          child: data.movementTracked
              ? _InventoryTrendChart(data: data.monthly, year: widget.selectedYear)
              : const _NotTrackedPanel(
                  title: 'Stock received, used and on hand by month',
                  message: 'Not tracked yet. Stock movement (receiving and parts used on jobs) is not recorded in the '
                      'system yet, so there is nothing real to chart. This fills in once it is.',
                ),
        ),
      ],
    );
  }
}

// =============================================================================
// NOT-TRACKED-YET PANEL (instead of charting made-up numbers)
// =============================================================================

class _NotTrackedPanel extends StatelessWidget {
  final String title;
  final String message;
  const _NotTrackedPanel({required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: DashUi.panel(),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.hourglass_empty_rounded, color: DashUi.muted, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: DashUi.ink)),
                const SizedBox(height: 4),
                Text(
                  message,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: DashUi.slate, height: 1.35),
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
// STATIC INFO CARD
// =============================================================================

class _StaticInfoCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color iconColor;

  const _StaticInfoCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: DashUi.panel(radius: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  title,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: DashUi.slate),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(icon, color: iconColor, size: 18),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: DashUi.ink),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// INVENTORY STRIKE PODIUM PANEL
// =============================================================================

class _InventoryStrikePodiumPanel extends StatelessWidget {
  final List<_InventoryStrikeTech> techs;
  const _InventoryStrikePodiumPanel({required this.techs});

  @override
  Widget build(BuildContext context) {
    // Simplified rank logic
    final rank1 = techs.isNotEmpty ? techs[0] : null;
    final rank2 = techs.length > 1 ? techs[1] : null;
    final rank3 = techs.length > 2 ? techs[2] : null;

    return Container(
      padding: const EdgeInsets.all(20.0),
      decoration: DashUi.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              Text(
                'INVENTORY STRIKES PODIUM',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: DashUi.ink, letterSpacing: 0.8),
              ),
              Icon(Icons.inventory_2_outlined, color: DashUi.amber, size: 18),
            ],
          ),
          const SizedBox(height: 2),
          // Strikes are a running total per tech (users.inventory_strikes), not per year.
          const Text(
            'Fewest strikes ranks first · all-time',
            style: TextStyle(fontSize: 12, color: DashUi.muted, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: (rank1 == null)
                ? const Center(child: Text('No inventory strike data recorded.', style: TextStyle(color: DashUi.muted)))
                : LayoutBuilder(
                    builder: (context, constraints) {
                      // 1st place is 167px of avatar + step at full size plus ~66px of fixed text, ring and
                      // spacing. The old 0.65 minimum overflowed on short windows.
                      final scale = ((constraints.maxHeight - 66) / 167.0).clamp(0.3, 1.0);
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (rank2 != null) _PodiumStep(tech: rank2, rank: 2, scale: scale) else const Spacer(),
                          _PodiumStep(tech: rank1, rank: 1, scale: scale),
                          if (rank3 != null) _PodiumStep(tech: rank3, rank: 3, scale: scale) else const Spacer(),
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

class _PodiumStep extends StatelessWidget {
  final _InventoryStrikeTech tech;
  final int rank;
  final double scale;

  const _PodiumStep({required this.tech, required this.rank, required this.scale});

  @override
  Widget build(BuildContext context) {
    final isFirst = rank == 1;
    final color = rank == 1 ? const Color(0xFFF59E0B) : rank == 2 ? const Color(0xFF94A3B8) : const Color(0xFFB45309);
    final avatarSize = (isFirst ? 82.0 : 64.0) * scale;
    final stepHeight = (rank == 1 ? 85.0 : rank == 2 ? 60.0 : 40.0) * scale;
    final strikes = tech.strikeCount;

    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          DashAvatar(
            name: tech.name,
            imageUrl: tech.imageUrl,
            size: avatarSize,
            ringColor: color,
            ringWidth: isFirst ? 4 : 3,
            glowColor: color.withValues(alpha: 0.35),
          ),
          const SizedBox(height: 8),
          Text(
            tech.name.split(' ').first,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: isFirst ? 15 : 13,
              fontWeight: isFirst ? FontWeight.w800 : FontWeight.w700,
              color: DashUi.ink,
            ),
          ),
          Text(
            '$strikes ${strikes == 1 ? 'strike' : 'strikes'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: isFirst ? 12 : 11,
              color: DashUi.slate,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            height: stepHeight,
            width: double.infinity,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              border: Border(top: BorderSide(color: color, width: 3)),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Center(
              child: Text(
                rank == 1 ? '1st' : rank == 2 ? '2nd' : '3rd',
                style: TextStyle(
                  fontSize: isFirst ? 22 : 18,
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
// CATEGORY BREAKDOWN PANEL
// =============================================================================

class _CategoryBreakdownPanel extends StatefulWidget {
  final List<_CategoryData> categories;
  final double total;
  const _CategoryBreakdownPanel({required this.categories, required this.total});

  @override
  State<_CategoryBreakdownPanel> createState() => _CategoryBreakdownPanelState();
}

class _CategoryBreakdownPanelState extends State<_CategoryBreakdownPanel> {
  bool _showHealthView = false;

  Widget _tab(String text, bool active, VoidCallback onTap) {
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

  @override
  Widget build(BuildContext context) {
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
                  _showHealthView ? 'STOCK HEALTH BY CATEGORY' : 'VALUATION BY CATEGORY',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: DashUi.ink, letterSpacing: 0.8),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(8)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _tab('By Value', !_showHealthView, () => setState(() => _showHealthView = false)),
                    _tab('Stock Health', _showHealthView, () => setState(() => _showHealthView = true)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: widget.categories.isEmpty
                ? const Center(child: Text('No categories recorded yet.', style: TextStyle(color: DashUi.muted)))
                : _showHealthView
                    ? _StockHealthList(categories: widget.categories)
                    : _ValueList(categories: widget.categories, total: widget.total),
          ),
        ],
      ),
    );
  }
}

class _ValueList extends StatefulWidget {
  final List<_CategoryData> categories;
  final double total;
  const _ValueList({required this.categories, required this.total});

  @override
  State<_ValueList> createState() => _ValueListState();
}

class _ValueListState extends State<_ValueList> {
  int? _hovered;

  @override
  Widget build(BuildContext context) {
    final maxVal = widget.categories.fold<double>(0, (m, c) => math.max(m, c.total)) * 1.05;

    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: List.generate(widget.categories.length, (i) {
        final cat = widget.categories[i];
        final ratio = maxVal > 0 ? (cat.total / maxVal).clamp(0.02, 1.0) : 0.0;
        final pct = widget.total > 0 ? cat.total / widget.total * 100 : 0.0;
        final isHovered = _hovered == i;
        final isFaded = _hovered != null && !isHovered;

        return MouseRegion(
          onEnter: (_) => setState(() => _hovered = i),
          onExit: (_) => setState(() => _hovered = null),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: isFaded ? 0.35 : 1.0,
            child: Row(
              children: [
                SizedBox(
                  width: 140,
                  child: Text(
                    cat.name,
                    style: TextStyle(
                      fontSize: 13,
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
                        height: isHovered ? 24 : 20,
                        decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(6)),
                      ),
                      FractionallySizedBox(
                        widthFactor: ratio,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 400),
                          curve: Curves.easeOutCubic,
                          height: isHovered ? 24 : 20,
                          decoration: BoxDecoration(color: cat.color, borderRadius: BorderRadius.circular(6)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 88,
                  child: Text(
                    isHovered ? '${pct.toStringAsFixed(1)}%' : _compactMoney(cat.total),
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: isHovered ? FontWeight.w900 : FontWeight.bold,
                      color: isHovered ? cat.color : DashUi.ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }
}

class _StockHealthList extends StatefulWidget {
  final List<_CategoryData> categories;
  const _StockHealthList({required this.categories});

  @override
  State<_StockHealthList> createState() => _StockHealthListState();
}

class _StockHealthListState extends State<_StockHealthList> {
  int? _hovered;

  Widget _legendDot(Color c, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: DashUi.slate)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final maxVal = widget.categories.fold<double>(0, (m, c) => math.max(m, c.total)) * 1.05;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 14,
          children: [
            _legendDot(DashUi.emeraldDeep, 'Active'),
            _legendDot(DashUi.amber, 'Low stock'),
            _legendDot(DashUi.red, 'Dead stock'),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: List.generate(widget.categories.length, (i) {
              final cat = widget.categories[i];
              final ratio = maxVal > 0 ? (cat.total / maxVal).clamp(0.02, 1.0) : 0.0;
              final isHovered = _hovered == i;
              final isFaded = _hovered != null && !isHovered;
              final deadShare = cat.total > 0 ? cat.deadValue / cat.total * 100 : 0.0;

              return MouseRegion(
                onEnter: (_) => setState(() => _hovered = i),
                onExit: (_) => setState(() => _hovered = null),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: isFaded ? 0.35 : 1.0,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 140,
                        child: Text(
                          cat.name,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: isHovered ? FontWeight.w800 : FontWeight.w600,
                            color: isHovered ? DashUi.ink : DashUi.slate,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FractionallySizedBox(
                          widthFactor: ratio,
                          alignment: Alignment.centerLeft,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: SizedBox(
                              height: isHovered ? 24 : 20,
                              child: Row(
                                children: [
                                  if (cat.activeValue > 0)
                                    Expanded(flex: (cat.activeValue * 1000).round(), child: Container(color: DashUi.emeraldDeep)),
                                  if (cat.lowStockValue > 0)
                                    Expanded(flex: (cat.lowStockValue * 1000).round(), child: Container(color: DashUi.amber)),
                                  if (cat.deadValue > 0)
                                    Expanded(flex: (cat.deadValue * 1000).round(), child: Container(color: DashUi.red)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      SizedBox(
                        width: 88,
                        child: Text(
                          isHovered ? '${deadShare.toStringAsFixed(0)}% dead' : _compactMoney(cat.total),
                          textAlign: TextAlign.end,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: isHovered ? FontWeight.w900 : FontWeight.bold,
                            color: isHovered ? DashUi.red : DashUi.ink,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// INVENTORY TREND CHART
// =============================================================================

enum _TrendMetric { received, used, onHand }

extension _TrendMetricX on _TrendMetric {
  String get toggleLabel => switch (this) {
        _TrendMetric.received => 'Received',
        _TrendMetric.used => 'Used',
        _TrendMetric.onHand => 'On Hand',
      };

  String get caption => switch (this) {
        _TrendMetric.received => 'Monthly stock received',
        _TrendMetric.used => 'Monthly stock used',
        _TrendMetric.onHand => 'On-hand valuation trend',
      };
}

class _AxisScale {
  final double max;
  final double step;
  const _AxisScale(this.max, this.step);
  int get ticks => (max / step).round();
}

_AxisScale _niceScale(double maxV) {
  if (maxV <= 0) return const _AxisScale(50000, 10000);
  final raw = maxV / 4;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  final double nice = norm <= 1 ? 1 : (norm <= 2 ? 2 : (norm <= 5 ? 5 : 10));
  var step = nice * mag;
  var top = (maxV / step).ceil() * step;
  if (top < maxV * 1.08) top += step;
  return _AxisScale(top, step);
}

class _InventoryTrendChart extends StatefulWidget {
  final List<_InventoryMonth> data;
  final int? year;
  const _InventoryTrendChart({required this.data, this.year});

  @override
  State<_InventoryTrendChart> createState() => _InventoryTrendChartState();
}

class _InventoryTrendChartState extends State<_InventoryTrendChart> with TickerProviderStateMixin {
  late final AnimationController _intro;
  late final AnimationController _hover;

  _TrendMetric _metric = _TrendMetric.received;
  int? _active;
  int? _paintedIndex;

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..forward();
    _hover = AnimationController(vsync: this, duration: const Duration(milliseconds: 160));
  }

  @override
  void dispose() {
    _intro.dispose();
    _hover.dispose();
    super.dispose();
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

  void _setMetric(_TrendMetric m) {
    if (m == _metric) return;
    setState(() => _metric = m);
    _resetAndReplay();
  }

  int? _indexFor(double dx, double width) {
    final n = widget.data.length;
    if (n == 0) return null;
    final plotW = width - _TrendChartPainter.leftGutter;
    if (plotW <= 0) return null;
    final i = ((dx - _TrendChartPainter.leftGutter) / (plotW / n)).floor();
    if (i < 0 || i >= n) return null;
    return i;
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final yearText = widget.year?.toString() ?? 'this year';

    if (data.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20.0),
        decoration: DashUi.panel(),
        child: Center(
          child: Text('No inventory activity for $yearText yet.',
              style: const TextStyle(color: DashUi.muted, fontWeight: FontWeight.w500, fontSize: 14)),
        ),
      );
    }

    final activeData = data.where((d) => d.hasData).toList();
    final totalReceived = activeData.fold<double>(0, (a, b) => a + b.received);
    final totalUsed = activeData.fold<double>(0, (a, b) => a + b.used);
    final latestOnHand = activeData.isNotEmpty ? activeData.last.onHand : 0.0;

    String headlineValue;
    String headlineLabel;
    if (_metric == _TrendMetric.received) {
      headlineValue = _compactMoney(totalReceived);
      headlineLabel = 'Total received in $yearText';
    } else if (_metric == _TrendMetric.used) {
      headlineValue = _compactMoney(totalUsed);
      headlineLabel = 'Total used in $yearText';
    } else {
      headlineValue = _compactMoney(latestOnHand);
      headlineLabel = 'Latest on-hand value';
    }

    var maxV = 0.0;
    for (final p in data) {
      if (!p.hasData) continue;
      if (_metric == _TrendMetric.onHand) {
        maxV = math.max(maxV, p.onHand);
      } else if (_metric == _TrendMetric.received) {
        maxV = math.max(maxV, p.received);
      } else {
        maxV = math.max(maxV, p.used);
      }
    }
    final scale = _niceScale(maxV);

    double? trendPct;
    String? trendLabel;
    if (activeData.length >= 2) {
      final last = activeData.last;
      final prev = activeData[activeData.length - 2];
      double valFor(_InventoryMonth m) => switch (_metric) {
            _TrendMetric.received => m.received,
            _TrendMetric.used => m.used,
            _TrendMetric.onHand => m.onHand,
          };
      final valLast = valFor(last);
      final valPrev = valFor(prev);
      if (valPrev > 0) {
        trendPct = (valLast - valPrev) / valPrev * 100;
        trendLabel = '${last.month} vs ${prev.month}';
      }
    }

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
            runSpacing: 10,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_metric.caption, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.slate)),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(headlineValue, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: DashUi.ink, height: 1.1)),
                      const SizedBox(width: 8),
                      Text(headlineLabel, style: const TextStyle(fontSize: 12, color: DashUi.muted, fontWeight: FontWeight.w500)),
                      if (trendPct != null) ...[
                        const SizedBox(width: 8),
                        _TrendChip(pct: trendPct, label: trendLabel!),
                      ],
                    ],
                  ),
                ],
              ),
              _TrendMetricToggle(value: _metric, onChanged: _setMetric),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                return Stack(
                  children: [
                    Positioned.fill(
                      child: MouseRegion(
                        onHover: (e) => _setActive(_indexFor(e.localPosition.dx, c.maxWidth)),
                        onExit: (_) => _setActive(null),
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
                                painter: _TrendChartPainter(
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
                      ),
                    ),
                    if (activeData.isEmpty)
                      IgnorePointer(
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 20),
                            child: Text('Nothing recorded for $yearText yet.',
                                style: const TextStyle(fontSize: 13, color: DashUi.muted, fontWeight: FontWeight.w500)),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 12, color: fg),
          const SizedBox(width: 2),
          Text('${pct.abs().toStringAsFixed(1)}% $label', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg)),
        ],
      ),
    );
  }
}

class _TrendMetricToggle extends StatelessWidget {
  final _TrendMetric value;
  final ValueChanged<_TrendMetric> onChanged;
  const _TrendMetricToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: _TrendMetric.values.map((m) {
          final selected = m == value;
          return MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => onChanged(m),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: selected ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: selected ? DashUi.line : Colors.transparent),
                ),
                child: Text(
                  m.toggleLabel,
                  style: TextStyle(
                    fontSize: 12,
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

class _TrendChartPainter extends CustomPainter {
  static const double leftGutter = 52;
  static const double bottomGutter = 24;
  static const double topPad = 6;

  final List<_InventoryMonth> data;
  final _TrendMetric metric;
  final _AxisScale scale;
  final int? index;
  final double intro;
  final double hover;

  const _TrendChartPainter({
    required this.data,
    required this.metric,
    required this.scale,
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

    double yFor(double v) => plot.bottom - (v / scale.max).clamp(0.0, 1.0) * plot.height;

    if (focusing) {
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(plot.left + index! * slotW + 2, plot.top, slotW - 4, plot.height),
        const Radius.circular(8),
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
      final tp = _layoutText(_compactMoney(v), const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: DashUi.muted));
      tp.paint(canvas, Offset(leftGutter - 8 - tp.width, y - tp.height / 2));
    }

    final stagger = 0.4 / n;
    final onHandPts = <Offset>[];

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
          fontSize: 12,
          fontWeight: isFocus ? FontWeight.w800 : FontWeight.w600,
          color: isFocus ? DashUi.ink : (has ? DashUi.slate : const Color(0xFFCBD5E1)),
        ),
        maxWidth: slotW,
        align: TextAlign.center,
      );
      labelTp.paint(canvas, Offset(cx - labelTp.width / 2, plot.bottom + 6));

      if (!has) {
        final stub = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(cx, plot.bottom - 1.5), width: 16, height: 3),
          const Radius.circular(2),
        );
        canvas.drawRRect(stub, Paint()..color = DashUi.line);
        continue;
      }

      if (metric == _TrendMetric.onHand) {
        onHandPts.add(Offset(cx, yFor(p.onHand)));
      } else {
        final barW = math.min(slotW * 0.5, 28.0) + (isFocus ? 4 * hover : 0);
        final val = metric == _TrendMetric.received ? p.received : p.used;
        final h = math.max(3.0, (val / scale.max).clamp(0.0, 1.0) * plot.height * localT);
        final rect = Rect.fromLTWH(cx - barW / 2, plot.bottom - h, barW, h);
        final r = Radius.circular(math.min(6, barW / 2));
        final colors = metric == _TrendMetric.received
            ? const [Color(0xFF0284C7), Color(0xFF38BDF8)]
            : const [Color(0xFFD97706), Color(0xFFFBBF24)];

        canvas.drawRRect(
          RRect.fromRectAndCorners(rect, topLeft: r, topRight: r),
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: colors.map((c) => c.withValues(alpha: dim)).toList(),
            ).createShader(rect),
        );
      }
    }

    if (metric == _TrendMetric.onHand && onHandPts.length > 1) {
      final path = Path()..moveTo(onHandPts.first.dx, onHandPts.first.dy);
      for (var i = 1; i < onHandPts.length; i++) {
        path.lineTo(onHandPts[i].dx, onHandPts[i].dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF6366F1).withValues(alpha: intro)
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
      for (final pt in onHandPts) {
        canvas.drawCircle(pt, 5, Paint()..color = Colors.white.withValues(alpha: intro));
        canvas.drawCircle(pt, 3, Paint()..color = const Color(0xFF6366F1).withValues(alpha: intro));
      }
    }

    if (focusing) _paintTooltip(canvas, size, plot, slotW, yFor);
  }

  void _paintTooltip(Canvas canvas, Size size, Rect plot, double slotW, double Function(double) yFor) {
    final i = index!;
    final p = data[i];
    final has = p.hasData;

    final val = metric == _TrendMetric.received
        ? p.received
        : (metric == _TrendMetric.used ? p.used : p.onHand);
    final metricName = metric == _TrendMetric.received
        ? 'Received'
        : (metric == _TrendMetric.used ? 'Used' : 'On Hand');

    final titleTp = _layoutText('${p.month} Inventory', const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800));
    final labelTp = _layoutText(metricName, const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700));
    final valueTp = _layoutText(_compactMoney(val), const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800));

    final tipW = math.max(titleTp.width, labelTp.width + 16 + valueTp.width) + 24;
    final tipH = 10 + titleTp.height + 4 + labelTp.height + 10;

    final cx = plot.left + slotW * (i + 0.5);
    final barTop = has ? yFor(val) : plot.bottom - 3;

    double tx, ty;
    var caretAbove = false;
    final aboveY = barTop - tipH - 12;
    if (aboveY >= 0) {
      ty = aboveY;
      tx = cx - tipW / 2;
      caretAbove = true;
    } else {
      ty = math.max(plot.top, math.min(barTop - 8, plot.bottom - tipH));
      final rightX = cx + 16;
      tx = rightX + tipW <= size.width ? rightX : cx - 16 - tipW;
    }
    tx = math.max(0, math.min(tx, size.width - tipW));

    canvas.saveLayer(Rect.fromLTWH(tx - 20, ty - 20, tipW + 40, tipH + 40), Paint()..color = Colors.white.withValues(alpha: hover));

    final rrect = RRect.fromRectAndRadius(Rect.fromLTWH(tx, ty, tipW, tipH), const Radius.circular(8));
    canvas.drawRRect(
      rrect.shift(const Offset(0, 3)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawRRect(rrect, Paint()..color = DashUi.ink);

    if (caretAbove) {
      final ccx = math.max(tx + 12, math.min(cx, tx + tipW - 12));
      final caret = Path()
        ..moveTo(ccx - 4, ty + tipH)
        ..lineTo(ccx + 4, ty + tipH)
        ..lineTo(ccx, ty + tipH + 4)
        ..close();
      canvas.drawPath(caret, Paint()..color = DashUi.ink);
    }

    var y = ty + 10;
    titleTp.paint(canvas, Offset(tx + 12, y));
    y += titleTp.height + 4;
    labelTp.paint(canvas, Offset(tx + 12, y));
    valueTp.paint(canvas, Offset(tx + tipW - 12 - valueTp.width, y));

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TrendChartPainter old) =>
      old.data != data || old.metric != metric || old.intro != intro || old.index != index || old.hover != hover;
}