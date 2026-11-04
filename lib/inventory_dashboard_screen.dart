import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'config/access.dart';
import 'widgets/dash_hover_card.dart';
import 'widgets/dashboard_data.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/dashboard_layout.dart';
import 'widgets/dashboard_panels.dart';

// The Inventory dashboard. There is no year to pick: stock is as of today, strikes are all time, count accuracy is this
// year so far, and the stock movement chart appears once stock received and used is recorded.
//   scorecards  stock value, dead stock, items at or below their reorder point, count accuracy, last cycle count
//   left        stock value by category, or each category's stock health
//   right       inventory strikes (fewest first) over stock movement by month
// The page fits the window without scrolling and without shrinking text (see _Grid).

class InventoryDashboardScreen extends StatelessWidget {
  const InventoryDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // No year selector: stock, strikes and cycle counts are all "as of now" (the server ignores a year).
    return DashboardLayout(
      title: 'Inventory',
      icon: accessIcon('dash_inventory'),
      showYearSelector: false,
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

  /// This year's counted items whose shelf count matched the system (0-100), the same figure as the warehouse KPI page.
  /// Null before any count with quantities has been recorded this year.
  final double? accuracyPct;

  /// The items behind [accuracyPct]: counted this year, and the ones that matched. Null from a server that doesn't send them.
  final int? accuracyCounted;
  final int? accuracyMatched;
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
    this.accuracyCounted,
    this.accuracyMatched,
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
      accuracyCounted: json['accuracy'] is Map && (json['accuracy'] as Map)['counted'] != null ? int_((json['accuracy'] as Map)['counted']) : null,
      accuracyMatched: json['accuracy'] is Map && (json['accuracy'] as Map)['matched'] != null ? int_((json['accuracy'] as Map)['matched']) : null,
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

class _InventoryDashboardContentState extends State<InventoryDashboardContent> with DashboardLoading {
  _InventorySummary? _data;

  @override
  void initState() {
    super.initState();
    dashReload();
  }

  // Everything here is "as of now", so there is no year to send.
  @override
  Future<void> dashReload({bool fresh = false}) => dashLoad(
        '/api/dashboards/inventory',
        fresh: fresh,
        apply: (body) => _data = _InventorySummary.fromJson(body),
      );

  String _dateLabel(DateTime? d) {
    if (d == null) return '—';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    if (dashLoading) return const _InventorySkeleton();
    if (dashFailure != null) {
      return DashErrorPanel.failure(dashFailure!, what: 'inventory', onRetry: dashReload);
    }

    final data = _data!;
    final g = DashGeo.of(context);
    final last = data.lastCycleCount;
    final now = DashClock.now();
    final daysAgo = last == null
        ? null
        : DateTime(now.year, now.month, now.day).difference(DateTime(last.year, last.month, last.day)).inDays;

    // Stock is as of today and accuracy is this year so far; each caption says which. Dead stock says "Not tracked yet"
    // instead of showing a made-up figure, and fills in once the system records stock movement.
    final valueCaption = 'Active items at cost · today';
    final tiles = <Widget>[
      AnimatedMetricCard(
        title: 'Stock value',
        value: data.totalValuation,
        format: _moneyFull,
        caption: valueCaption,
        definition: 'On-hand quantity times unit cost for every active item, as of now. The line is one '
            'reading a day.',
        valueColor: DashUi.blue,
        index: 0,
        trend: data.valuationHistory.length >= 2 ? data.valuationHistory : null,
        sparkMinWidth: dashSparkRoom(context, title: 'Stock value', value: _moneyFull(data.totalValuation), caption: valueCaption),
      ),
      AnimatedMetricCard(
        // Shows "—" until stock movement is recorded (it used to always say $0).
        title: 'Dead stock',
        value: data.deadStockValue,
        format: _moneyFull,
        caption: data.deadStockValue == null ? 'Not tracked yet' : 'No movement in 90+ days · today',
        definition: data.deadStockValue == null
            ? 'Needs a record of stock received and used, which the system does not keep yet.'
            : 'The value of active items with no stock movement in the last 90 days.',
        valueColor: DashUi.red,
        index: 1,
      ),
      AnimatedMetricCard(
        // Items at or below a reorder point that has been set. Amber only when there are some (none is not a problem).
        title: 'At or below reorder point',
        value: data.lowStockCount.toDouble(),
        format: (v) => v.round().toString(),
        caption: 'Items with a reorder point · today',
        definition: 'Active items whose on-hand quantity is at or below their reorder point. Items with '
            'no reorder point are not counted.',
        valueColor: data.lowStockCount > 0 ? DashUi.amber : DashUi.ink,
        index: 2,
      ),
      AnimatedMetricCard(
        // This year's cycle counts against the system quantity: the same figure, title and wording as the warehouse
        // KPI page (an item counted twice is two counts). Shows "—" until a count with quantities has been recorded
        // this year (it used to be a fixed 98.4%).
        title: 'Inventory accuracy',
        value: data.accuracyPct,
        format: (v) => '${v.toStringAsFixed(1)}%',
        caption: data.accuracyPct == null
            ? 'Starts with the next count'
            : (data.accuracyCounted != null && data.accuracyMatched != null
                ? '${data.accuracyMatched} of ${dashCount(data.accuracyCounted!, 'count')} matched · ${now.year}'
                : 'Counts that matched · ${now.year}'),
        definition: data.accuracyPct == null
            ? 'The share of item counts whose shelf count matched the system quantity. No cycle count with quantities '
                'has been recorded in ${now.year} yet, so it starts with the next one.'
            : 'The share of the item counts recorded in ${now.year}'
                '${data.accuracyCounted == null ? '' : ' (${data.accuracyMatched} of ${data.accuracyCounted})'} whose '
                'shelf count matched the system quantity. An item counted twice counts twice, and zones still in '
                "progress are included. The target is 95%. The warehouse team's KPI page shows it week by week.",
        valueColor: data.accuracyPct == null
            ? DashUi.muted
            : (data.accuracyPct! >= 95 ? DashUi.emeraldDeep : (data.accuracyPct! >= 90 ? DashUi.amber : DashUi.red)),
        index: 3,
      ),
      _DateCard(
        title: 'Last cycle count',
        value: last == null ? 'Not yet' : _dateLabel(last),
        caption: daysAgo == null
            ? 'No zone counted yet'
            : daysAgo <= 0
                ? 'Zone finished today'
                : 'Zone finished ${dashCount(daysAgo, 'day')} ago',
        definition: 'When the most recent cycle-count zone was finished.',
        index: 4,
      ),
    ];

    return _Grid(
      tiles: tiles,
      categories: (tall, fill) => _CategoryPanel(
        g: g,
        categories: data.categories,
        total: data.totalValuation,
        tall: tall,
        fill: fill,
      ),
      categoryRows: data.categories.length,
      strikes: _StrikesPanel(g: g, techs: data.topStrikeTechs),
      strikeRows: data.topStrikeTechs.length,
      movement: data.movementTracked
          ? _MovementChart(months: data.monthly, year: widget.selectedYear)
          : _NotTrackedPanel(
              g: g,
              title: 'Not tracked yet',
              message: 'Stock received and parts used on jobs aren\'t recorded in the system yet.',
            ),
      movementTracked: data.movementTracked,
    );
  }
}

// =============================================================================
// GRID (shared by the page and its skeleton)
// =============================================================================

/// Lays the page out to fit the window:
///   two columns   scorecards; categories | strike ranking over stock movement   (1280x600 and up)
///   one column    a window narrower than a desktop one: everything in one column that scrolls
class _Grid extends StatelessWidget {
  final List<Widget> tiles;

  /// `tall`: two-line rows for a narrow column. `fill`: the panel is given a height to fill.
  final Widget Function(bool tall, bool fill) categories;
  final int categoryRows;
  final Widget strikes;
  final int strikeRows;
  final Widget movement;
  final bool movementTracked;

  const _Grid({
    required this.tiles,
    required this.categories,
    required this.categoryRows,
    required this.strikes,
    required this.strikeRows,
    required this.movement,
    required this.movementTracked,
  });

  static const _twoColumnsFrom = 1000.0;

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final bodyH = c.maxHeight - g.tile - dashGap;
        final strikesH = _StrikesPanel.height(g, strikeRows);
        // The movement panel below the ranking: a short note while movement isn't tracked, a chart once it is.
        final movementMin = movementTracked ? 180.0 : _NotTrackedPanel.minHeight(g);
        final leftInner = (w - dashGap) * 13 / 23 - 40;
        final tall = leftInner < _CategoryPanel.oneLineWidth(g);
        final categoriesH = g.rows(categoryRows, tall ? g.rowTall : g.rowWide) + g.line(12.5) + 6;
        final Widget content;
        if (w >= _twoColumnsFrom && bodyH >= categoriesH && bodyH >= strikesH + dashGap + movementMin) {
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: g.tile, child: _tileRow(tiles)),
              const SizedBox(height: dashGap),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 13, child: categories(tall, true)),
                    const SizedBox(width: dashGap),
                    Expanded(
                      flex: 10,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(height: strikesH, child: strikes),
                          const SizedBox(height: dashGap),
                          Expanded(child: movement),
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
                categories(true, false),
                const SizedBox(height: dashGap),
                SizedBox(height: strikesH, child: strikes),
                const SizedBox(height: dashGap),
                SizedBox(height: movementTracked ? 300 : _NotTrackedPanel.minHeight(g), child: movement),
              ],
            ),
          );
        }
        return SizedBox(width: w, height: c.maxHeight, child: content);
      },
    );
  }

  /// The scorecards side by side, the row shared by what each card's words need, so a long title or caption ("At or
  /// below reorder point", "6 days ago") isn't cut short at larger text while a "—" card has room to spare. The stock
  /// value's trend line only claims its room when the whole row can give it; placeholders share the row evenly.
  Widget _tileRow(List<Widget> row) => LayoutBuilder(
    builder: (context, c) {
      double? need(Widget w, {required bool line}) => switch (w) {
        AnimatedMetricCard m => dashTileWidth(
            (line && m.trend != null ? dashSparkRoom : dashTileTextWidth)(
              context,
              title: m.title,
              value: m.value == null ? '—' : m.format(m.value!),
              caption: m.caption,
            ),
          ),
        // Its date is drawn at 22 px, not the 28 px dashTileTextWidth measures a value at.
        _DateCard d => dashTileWidth(
            math.max(
              dashTileTextWidth(context, title: d.title, value: '', caption: d.caption),
              dashTileTextWidth(context, title: '', value: d.value) * 22 / 28,
            ),
          ),
        _ => null,
      };
      final withLines = [for (final w in row) need(w, line: true)];
      final fits = withLines.every((n) => n != null) &&
          withLines.fold<double>(0, (a, n) => a + n!) + 12 * (row.length - 1) <= c.maxWidth;
      final needs = fits ? withLines : [for (final w in row) need(w, line: false)];
      final even = needs.any((n) => n == null);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < row.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(flex: even ? 1 : needs[i]!.round(), child: row[i]),
          ],
        ],
      );
    },
  );
}

// =============================================================================
// SCORECARD WITH A DATE (same frame and type as AnimatedMetricCard)
// =============================================================================

class _DateCard extends StatefulWidget {
  final String title;
  final String value;
  final String caption;
  final String definition;
  final int index;
  const _DateCard({
    required this.title,
    required this.value,
    required this.caption,
    required this.definition,
    required this.index,
  });

  @override
  State<_DateCard> createState() => _DateCardState();
}

class _DateCardState extends State<_DateCard> with SingleTickerProviderStateMixin {
  // The same staggered entrance as the scorecards beside it.
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 520 + widget.index * 110),
  )..forward();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) _enter.value = 1;
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final t = CurvedAnimation(
      parent: _enter,
      curve: Interval(w.index * 110 / (520 + w.index * 110), 1, curve: Curves.easeOutCubic),
    );
    return Semantics(
      container: true,
      label: '${w.title}: ${w.value}. ${w.definition}',
      child: ExcludeSemantics(
        child: FadeTransition(
          opacity: t,
          child: DashHoverCard(
            title: w.title,
            value: w.value,
            body: w.definition,
            color: DashUi.ink,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: DashUi.panel(radius: 12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    w.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.3, color: DashUi.slate),
                  ),
                  const SizedBox(height: 4),
                  // The date at the scorecards' line height, so the card is the same height as theirs.
                  SizedBox(
                    height: MediaQuery.textScalerOf(context).scale(28) * 1.1,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        w.value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, height: 1.1, color: DashUi.ink),
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    w.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, height: 1.3, color: DashUi.subtle),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// CATEGORIES (by value, or split into active, low-stock and dead stock)
// =============================================================================

class _CategoryPanel extends StatefulWidget {
  final DashGeo g;
  final List<_CategoryData> categories;
  final double total;
  final bool tall;
  final bool fill;
  const _CategoryPanel({
    required this.g,
    required this.categories,
    required this.total,
    required this.tall,
    required this.fill,
  });

  // Column widths at 100% text.
  static const labelWidth = 150.0;
  static const amountWidth = 76.0;
  static const detailWidth = 64.0;

  /// The inner width one-line rows need (the three text columns, padding, and a bar of at least 70 px).
  static double oneLineWidth(DashGeo g) => (labelWidth + amountWidth + detailWidth) * g.k + 106;

  @override
  State<_CategoryPanel> createState() => _CategoryPanelState();
}

class _CategoryPanelState extends State<_CategoryPanel> {
  bool _health = false;

  static const _active = DashUi.emeraldDeep;
  static const _low = DashUi.amber;
  static const _dead = DashUi.red;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final g = w.g;
    // Biggest first, in both views (the server sends them by name), so the finding names the top row.
    final cats = [...w.categories]..sort((a, b) => b.total.compareTo(a.total));
    final maxV = cats.fold<double>(0, (m, c) => math.max(m, c.total));
    // Dead stock needs a movement history the system doesn't keep yet, so every category's dead value is 0: the key
    // and the hover text leave it out instead of saying "Dead $0" as if it were measured.
    final deadTracked = cats.any((c) => c.deadValue > 0);
    final base = w.tall ? g.rowTall : g.rowWide;

    final header = DashPanelHeader(
      g: g,
      title: _health ? 'Stock health by category' : 'Value by category',
      note: 'today',
      tooltip: _health
          ? 'Each category by value: stock that is not low (above its reorder point, or no reorder point set) and '
              'stock at or below its reorder point.'
          : 'On-hand value of each category, as of now, and its share of the stock value, biggest first.',
      trailing: cats.isEmpty
          ? null
          : DashSegmented<bool>(
              value: _health,
              label: 'Category view',
              options: const [(false, 'By value'), (true, 'Stock health')],
              onChanged: (v) => setState(() => _health = v),
            ),
    );

    if (cats.isEmpty) {
      return DashPanel(
        fill: w.fill,
        header: header,
        child: SizedBox(height: 2 * base, child: const DashEmptyNote('No categories recorded yet.')),
      );
    }

    // The legend has its own line so every row keeps its width (and is there in both views so nothing moves); by value
    // it names the finding instead.
    final top = cats.reduce((a, b) => b.total > a.total ? b : a);
    final legend = SizedBox(
      height: g.line(12.5) + 6,
      child: Align(
        alignment: Alignment.centerLeft,
        child: ExcludeSemantics(
          child: _health
              ? Wrap(
                  spacing: 14,
                  children: [
                    const DashLegendSwatch(color: _active, text: 'Not low'),
                    const DashLegendSwatch(color: _low, text: 'At or below reorder point'),
                    if (deadTracked) const DashLegendSwatch(color: _dead, text: 'Dead'),
                  ],
                )
              : Text(
                  '${top.name} holds ${dashShare(top.total, w.total)} of the stock value · ${dashCount(cats.length, 'category')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DashText.meta.copyWith(fontWeight: FontWeight.w700, color: DashUi.slate),
                ),
        ),
      ),
    );

    // Filling a panel, the rows share its whole height evenly (so a tall window has no blank half-panel under six rows),
    // and their bars thicken with them, 8 px up to 14.
    Widget rows(double h) => DashRows(
      count: cats.length,
      base: base,
      give: w.fill ? double.infinity : 24,
      row: (i) {
        final c = cats[i];
        final barH = 8 + 6 * ((h - base) / 48).clamp(0.0, 1.0);
        final share = dashShare(c.total, w.total);
        final lowShare = dashShare(c.lowStockValue, c.total);
        final health = 'not low ${_moneyFull(c.activeValue)}, at or below reorder point '
            '${_moneyFull(c.lowStockValue)}${deadTracked ? ', dead ${_moneyFull(c.deadValue)}' : ''}';
        return DashBarRow(
          g: g,
          label: c.name,
          fraction: maxV > 0 ? c.total / maxV : 0,
          // One colour by value (a category is not a meaning); the health view's parts carry the colours.
          color: DashUi.blue,
          amount: _moneyFull(c.total),
          detail: _health ? '$lowShare low' : share,
          tall: w.tall,
          labelWidth: _CategoryPanel.labelWidth,
          amountWidth: _CategoryPanel.amountWidth,
          detailWidth: _CategoryPanel.detailWidth,
          bar: _health
              ? DashStackBar(
                  parts: [(c.activeValue, _active), (c.lowStockValue, _low), (c.deadValue, _dead)],
                  height: barH,
                )
              : DashBar(fraction: maxV > 0 ? c.total / maxV : 0, color: DashUi.blue, height: barH),
          tooltip: _health
              ? 'Not low ${_moneyFull(c.activeValue)}\nAt or below reorder point ${_moneyFull(c.lowStockValue)}'
                  '${deadTracked ? '\nDead ${_moneyFull(c.deadValue)}' : ''}'
              : (c.name.length > 20 ? c.name : null),
          semanticsLabel: '${c.name}: ${_moneyFull(c.total)}, $share of stock value. ${health[0].toUpperCase()}${health.substring(1)}',
        );
      },
    );

    return DashPanel(
      fill: w.fill,
      header: header,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          legend,
          if (w.fill)
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) => rows(math.max(base, c.maxHeight / cats.length)),
              ),
            )
          else
            rows(base),
        ],
      ),
    );
  }
}

// =============================================================================
// INVENTORY STRIKES (the three with the fewest, all time)
// =============================================================================

class _StrikesPanel extends StatelessWidget {
  final DashGeo g;
  final List<_InventoryStrikeTech> techs;
  const _StrikesPanel({required this.g, required this.techs});

  /// One line per technician, so a stock movement chart below keeps its height.
  static double rowH(DashGeo g) => math.max(g.rowWide, 34.0);
  static double height(DashGeo g, int rows) => g.rows(rows, rowH(g));

  @override
  Widget build(BuildContext context) {
    return DashPanel(
      fill: true,
      // The server sends the best three only (fewest strikes), so the title says it is a "fewest" list, not everyone.
      header: DashPanelHeader(
        g: g,
        title: 'Fewest inventory strikes',
        note: 'all time',
        // Strikes are a running total per tech (users.inventory_strikes), not per year.
        tooltip: 'The three technicians with the fewest strikes for inventory mistakes, fewest first. Strikes are a '
            'running total per technician, not per year.',
      ),
      child: techs.isEmpty
          ? const DashEmptyNote('No active technicians to rank.')
          : DashRows(
              count: techs.length,
              base: rowH(g),
              give: 14,
              row: (i) {
                final t = techs[i];
                final s = t.strikeCount;
                return DashPressable(
                  onTap: null,
                  label: 'Number ${i + 1}. ${t.name}: ${dashCount(s, 'strike')}',
                  radius: BorderRadius.circular(8),
                  builder: (_) => Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      border: i == techs.length - 1 ? null : const Border(bottom: BorderSide(color: DashUi.faint)),
                    ),
                    child: Row(
                      children: [
                        DashRankBadge(rank: i + 1, size: 24),
                        const SizedBox(width: 8),
                        DashAvatar(name: t.name, imageUrl: t.imageUrl, size: 26, accent: DashUi.amber),
                        const SizedBox(width: 10),
                        Expanded(child: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.name)),
                        const SizedBox(width: 10),
                        Text(
                          dashCount(s, 'strike'),
                          style: DashText.money.copyWith(color: s == 0 ? DashUi.emeraldText : DashUi.ink),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

// =============================================================================
// STOCK MOVEMENT (not recorded yet: a note in its place; a chart once it is)
// =============================================================================

class _NotTrackedPanel extends StatelessWidget {
  final DashGeo g;
  final String title;
  final String message;
  const _NotTrackedPanel({required this.g, required this.title, required this.message});

  /// The title and three lines of the message.
  static double minHeight(DashGeo g) => g.panelTop + 3 * g.line(13, 1.4) + 6;

  @override
  Widget build(BuildContext context) {
    return DashPanel(
      fill: true,
      header: DashPanelHeader(
        g: g,
        title: 'Stock movement',
        note: 'by month',
        tooltip: 'Stock received, used on jobs and on hand, month by month, once the system records it.',
      ),
      child: Semantics(
        label: '$title. $message',
        child: ExcludeSemantics(
          child: LayoutBuilder(
            builder: (context, c) {
              final note = Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(9)),
                    child: const Icon(Icons.hourglass_empty_rounded, size: 18, color: DashUi.slate),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: '$title. ', style: const TextStyle(fontWeight: FontWeight.w700, color: DashUi.ink)),
                          TextSpan(text: message),
                        ],
                      ),
                      style: const TextStyle(fontSize: 13, height: 1.4, color: DashUi.slate),
                    ),
                  ),
                ],
              );
              // With height to spare (a tall window), the note sits in the middle of the card as an empty state, with
              // a faint baseline of the twelve months the chart will fill, instead of three lines over a blank card.
              if (!c.maxHeight.isFinite || c.maxHeight < 200) return note;
              return Column(
                children: [
                  const Spacer(),
                  ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460), child: note),
                  const SizedBox(height: 18),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: Row(
                      children: [
                        for (final m in dashMonthNames)
                          Expanded(
                            child: Column(
                              children: [
                                Container(
                                  height: 3,
                                  margin: const EdgeInsets.symmetric(horizontal: 3),
                                  decoration: BoxDecoration(color: DashUi.line, borderRadius: BorderRadius.circular(2)),
                                ),
                                const SizedBox(height: 4),
                                Text(m, style: DashText.meta.copyWith(fontSize: 10.5, color: DashUi.muted)),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  const Spacer(flex: 2),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _MovementChart extends StatelessWidget {
  final List<_InventoryMonth> months;
  final int year;
  const _MovementChart({required this.months, required this.year});

  @override
  Widget build(BuildContext context) {
    List<double> pick(double Function(_InventoryMonth) f) =>
        [for (var i = 0; i < 12; i++) i < months.length && months[i].hasData ? f(months[i]) : 0.0];
    DashChartView view(String tab, String title, String row, List<double> values, Color color, {bool line = false}) {
      final total = values.fold<double>(0, (a, b) => a + b);
      return DashChartView(
        tab: tab,
        title: title,
        note: line ? null : '${_compactMoney(total)} in $year',
        series: [DashSeries(row, values, color, kind: line ? DashSeriesKind.line : DashSeriesKind.bar)],
        axis: _compactMoney,
        barLabel: line ? null : _compactMoney,
        tip: (i) => [DashTipRow(row, _moneyFull(values[i]), color: color)],
        summary: (last) => '$title: ${[for (var i = 0; i <= last; i++) '${dashMonthNames[i]} ${_compactMoney(values[i])}'].join(', ')}',
        emptyText: 'No stock movement recorded for $year yet.',
        semanticsLabel: '$title by month, $year',
      );
    }

    return DashMonthChart(
      year: year,
      views: [
        view('Received', 'Stock received', 'Received', pick((m) => m.received), DashUi.sky),
        view('Used', 'Stock used on jobs', 'Used', pick((m) => m.used), DashUi.amber),
        view('On hand', 'Stock on hand', 'On hand', pick((m) => m.onHand), DashUi.blue, line: true),
      ],
    );
  }
}

// =============================================================================
// SKELETON (the same grid, with placeholders)
// =============================================================================

class _InventorySkeleton extends StatelessWidget {
  const _InventorySkeleton();

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    return Semantics(
      label: 'Loading inventory',
      child: ExcludeSemantics(
        child: SkeletonPulse(
          child: _Grid(
            tiles: List.generate(5, (_) => const DashSkeletonTile()),
            categories: (tall, fill) => DashSkeletonPanel(rows: 6, rowH: tall ? g.rowTall : g.rowWide),
            categoryRows: 6,
            strikes: DashSkeletonPanel(rows: 3, rowH: _StrikesPanel.rowH(g) - 4),
            strikeRows: 3,
            movement: const DashSkeletonPanel(rows: 2, rowH: 20),
            movementTracked: false,
          ),
        ),
      ),
    );
  }
}
