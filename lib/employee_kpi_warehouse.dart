part of 'kpi_dashboard_screen.dart';

// =============================================================================
// WAREHOUSE KPI PAGE (/hr/kpis/:username for a role that says "warehouse": Dennis)
// =============================================================================
//
// Built like the technician page (employee_kpi_tech.dart) from the dashboards' kit: the dark title bar with a year
// picker and Refresh, a row of scorecards, and the chart beside the zones under it, all on one screen without
// scrolling at desktop sizes (one scrolling column below 1000 px wide, like the dashboards). Every figure and
// animation the page had before is still here: rank, milestone and integrity score; peer rating and morale with its
// heartbeat and Preview (both in the title bar, as on the tech page); jobs completed, low stock items and cycle counts
// done with their trend lines; callback strikes (which opens the visits); the team's inventory strikes, Dennis's own
// counted in, as the dark team card with the techs' trend line; inventory accuracy and its weekly line against the 95%
// target; the stock gaps, stock levels and cycle history views (the chart steps through its views every 8 seconds); open purchase
// orders; and the cycle count zones.
//
// Where each figure comes from (GET /api/employees/:username/kpis?year=Y, `warehouse`, the year picked unless it says
// otherwise): cycle counts, accuracy, stock gaps, jobs and callback strikes are for the year. Low stock, stock value,
// open POs, the zones and the inventory strikes are how things stand today (nothing keeps their past), which the cards
// say when an earlier year is picked. The zones, counts and stock are company-wide: nothing records who counted what.

/// Everything the page shows for one year.
class _WhPage {
  final int year;

  /// Null from a server that doesn't send the warehouse figures yet.
  final _WarehouseKpis? warehouse;

  /// The person's own inventory strikes, all time.
  final int inventoryStrikes;
  final _Rating? morale;
  const _WhPage({required this.year, required this.warehouse, required this.inventoryStrikes, required this.morale});

  factory _WhPage.parse(Map<String, dynamic> kpis, int year) {
    final emp = kpis['employee'] is Map ? kpis['employee'] as Map : const {};
    final bundle = _bundleFrom(kpis);
    return _WhPage(
      year: year,
      warehouse: bundle.warehouse,
      inventoryStrikes: int.tryParse(_str(emp['inventoryStrikes'])) ?? 0,
      morale: bundle.morale,
    );
  }

  bool get isCurrentYear => year == DashClock.now().year;
}

/// "1,299".
String _whCount(int n) => '${n < 0 ? '-' : ''}${n.abs().toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},')}';

/// Strike counts: green at none, amber at one, red past that.
Color _strikeColor(int n) => n == 0 ? DashUi.emeraldDeep : (n == 1 ? DashUi.amber : DashUi.red);

// =============================================================================
// THE PAGE
// =============================================================================

/// The title bar (back button, photo, name, title, time with the company, rank, milestone, integrity score, peer
/// rating and morale) and the year picker; the content below loads the year picked.
class _WarehouseKpiPage extends StatefulWidget {
  final _EmployeeKpiArgs args;
  final String employeeId;
  const _WarehouseKpiPage({super.key, required this.args, required this.employeeId});

  @override
  State<_WarehouseKpiPage> createState() => _WarehouseKpiPageState();
}

class _WarehouseKpiPageState extends State<_WarehouseKpiPage> {
  final _ratings = _TechRatings();

  _EmployeeUser get user => widget.args.entry.user;

  @override
  void dispose() {
    _ratings.dispose();
    super.dispose();
  }

  /// The years the picker offers: from the year this person was hired (as far as yearsWorked says) to now, at most
  /// four; the dashboards' three when the hire date isn't known.
  List<int> _years() {
    final now = DashClock.now();
    final y = user.yearsWorked;
    if (y == null) return [now.year, now.year - 1, now.year - 2];
    final hired = now.subtract(Duration(days: (y * 365.25).round())).year;
    return [for (var yr = now.year; yr >= math.max(hired, now.year - 3); yr--) yr];
  }

  @override
  Widget build(BuildContext context) {
    final tenure = user.yearsWorked == null ? null : '${_fmtTenure(user.yearsWorked)} at IOHD';
    return DashboardLayout(
      title: user.name,
      heading: user.name.toUpperCase(),
      subtitle: [user.displayTitle, ?tenure].join(' · '),
      leading: _HeaderLead(user: user, rank: widget.args.entry.rank),
      titleTrailing: _HeaderBadges(args: widget.args, ratings: _ratings),
      years: _years(),
      builder: (context, year) => _WarehouseKpiContent(user: user, employeeId: widget.employeeId, year: year, ratings: _ratings),
    );
  }
}

class _WarehouseKpiContent extends StatefulWidget {
  final _EmployeeUser user;
  final String employeeId;
  final int year;
  final _TechRatings ratings;
  const _WarehouseKpiContent({required this.user, required this.employeeId, required this.year, required this.ratings});

  @override
  State<_WarehouseKpiContent> createState() => _WarehouseKpiContentState();
}

/// Loads the figures the way the dashboards do (DashboardLoading): a skeleton on the first load, a refresh keeps the
/// figures on screen and the header says if it failed, an answer for an older request is ignored.
class _WarehouseKpiContentState extends State<_WarehouseKpiContent> {
  final _requests = DashRequests();
  _WhPage? _data;
  DashLoadException? _failure;
  bool _loading = true;
  bool _busy = false;
  DashFreshness? _freshness;
  DateTime? _updatedAt;
  bool _computedTime = false;

  String get _first {
    final n = widget.user.name.trim();
    return n.isEmpty ? 'This person' : n.split(RegExp(r'\s+')).first;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _freshness = DashFreshnessScope.maybeOf(context);
  }

  @override
  void dispose() {
    _requests.cancel();
    _freshness?.release(this);
    super.dispose();
  }

  Future<void> _load({bool fresh = false}) async {
    final keep = fresh && _data != null && _failure == null;
    setState(() {
      if (!keep) _loading = true;
      _failure = null;
      _busy = true;
    });
    _report();
    try {
      final kpis = await _requests.get('/api/employees/${Uri.encodeComponent(widget.employeeId)}/kpis', query: {'year': '${widget.year}'}, fresh: fresh);
      if (kpis == null || !mounted) return; // a newer request took over, or the page is gone
      final _WhPage data;
      try {
        data = _WhPage.parse(kpis.body, widget.year);
      } catch (_) {
        throw const DashLoadException(DashFailure.badData);
      }
      setState(() {
        _data = data;
        _loading = false;
        _busy = false;
        _updatedAt = kpis.generatedAt ?? kpis.receivedAt;
        _computedTime = kpis.generatedAt != null;
      });
      widget.ratings.set(null, data.morale); // nothing records a peer rating for the warehouse yet
      _report();
    } on DashLoadException catch (e) {
      if (!mounted) return;
      if (keep) {
        setState(() => _busy = false);
        _report(refreshFailure: e); // the figures on screen are still the last good ones
        return;
      }
      setState(() {
        _failure = e;
        _loading = false;
        _busy = false;
        _data = null;
        _updatedAt = null;
      });
      _report();
    }
  }

  void _report({DashLoadException? refreshFailure}) {
    _freshness?.report(
      this,
      updatedAt: _data == null ? null : _updatedAt,
      computedTime: _computedTime,
      busy: _busy,
      refreshFailure: refreshFailure,
      onRefresh: _busy ? null : () => _load(fresh: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const _WhSkeleton();
    final failure = _failure;
    if (failure != null) {
      return DashErrorPanel.failure(failure, what: "$_first's figures", onRetry: _load);
    }
    final data = _data!;
    if (data.warehouse == null) {
      return DashErrorPanel(
        title: "Warehouse figures aren't available yet",
        message: 'The server has not been updated to send them. Try again once it has.',
        hint: null,
        onRetry: () => _load(fresh: true),
      );
    }
    return _WhBody(data: data, w: data.warehouse!, user: widget.user, first: _first, employeeId: widget.employeeId);
  }
}

// =============================================================================
// SCORECARDS
// =============================================================================

class _WhBody extends StatelessWidget {
  final _WhPage data;
  final _WarehouseKpis w;
  final _EmployeeUser user;
  final String first;
  final String employeeId;
  const _WhBody({required this.data, required this.w, required this.user, required this.first, required this.employeeId});

  @override
  Widget build(BuildContext context) {
    final year = data.year;
    final period = dashPeriodLabel(year);
    final now = data.isCurrentYear;
    // Stock, purchase orders, zones and strikes are how things stand today; an earlier year says so.
    final today = now ? '' : ' · as of today';
    List<double>? monthly(List<double> v) {
      final t = dashTrend(v, year);
      return t != null && t.any((x) => x > 0) ? t : null;
    }
    List<double>? daily(List<double> v) => v.length >= 2 ? v : null;
    final last = w.lastCycleCount;
    final lastDay = last == null ? null : _shortDay(last.toIso8601String());

    // --- Inventory accuracy: the headline, against the 95% target. ---
    final acc = w.accuracyPct;
    final accColor = acc == null ? DashUi.muted : (acc >= 95 ? DashUi.emeraldDeep : (acc >= 90 ? DashUi.amber : DashUi.red));
    final verdict = acc != null && acc >= 95 ? 'meets the 95% target' : 'under the 95% target';
    final accuracy = _TileSpec(
      title: 'Inventory accuracy',
      value: acc,
      format: (v) => '${_fmtNum(v)}%',
      captions: acc == null
          ? [if (now) ...['Starts with the next cycle count', 'No counts yet'] else 'None in $year']
          : ['${dashCount(w.accuracyCounted, 'item count')} · $verdict', '${w.accuracyCounted} counts · ${verdict.replaceFirst('the ', '')}', '${verdict[0].toUpperCase()}${verdict.substring(1)}', 'Target 95%'],
      definition: acc == null
          ? 'The share of counted items whose shelf count matched the system quantity. No count with quantities has been recorded in $year yet.'
          : 'The share of the item counts recorded in $year (${w.accuracyCounted}) whose shelf count matched the system quantity. An item '
              'counted in two weeks counts twice, and zones still in progress are included. The target is 95%. The Accuracy chart '
              'shows the last 12 weeks.',
      color: accColor,
      trend: daily([for (final t in w.accuracyTrend) t.$2]),
    );

    final cycles = _TileSpec(
      title: 'Cycle counts done',
      value: w.cycleDone.toDouble(),
      format: (v) => '${v.round()}',
      captions: last == null
          ? [now ? 'None completed yet' : 'None in $year']
          : ['${dashCount(w.itemsCounted, 'item count')} in finished zones · last $lastDay', '${dashCount(w.itemsCounted, 'item count')} · last $lastDay', 'Last $lastDay', period],
      definition: 'Zone counts finished in $year (a zone is one cycle count of part of the warehouse), and the item counts in them: '
          '${w.itemsCounted}, an item counted in two zones or weeks counting twice. Nothing records who did a count, so this is the '
          'whole warehouse team.',
      color: DashUi.ink,
      trend: monthly(w.cycleMonthly),
    );

    final lowColor = w.lowStockCount == 0 ? DashUi.emeraldDeep : DashUi.ink;
    final health = w.stockHealth;
    final lowStock = _TileSpec(
      // The Inventory dashboard's "At or below reorder point", in words that fit the card.
      title: 'Needs reorder',
      value: w.lowStockCount.toDouble(),
      format: (v) => '${v.round()}',
      // An earlier year keeps "as of today" in every caption, however short the card makes it.
      captions: health == null
          ? [
              'of ${dashCount(w.itemCount, 'item')} · ${_wholeMoney(w.stockValue)} in stock$today',
              'of ${dashCount(w.itemCount, 'item')}$today',
              now ? 'Reorder point set' : 'As of today',
            ]
          : now
              ? [
                  '${health.empty} empty · ${health.low} low · ${_wholeMoney(w.stockValue)} in stock',
                  '${health.empty} empty · ${_wholeMoney(w.stockValue)} in stock',
                  '${health.empty} empty · ${health.low} low',
                  '${health.empty} empty',
                ]
              : [
                  '${health.empty} empty · ${_wholeMoney(w.stockValue)} in stock$today',
                  '${health.empty} empty$today',
                  'As of today',
                ],
      definition: health == null
          ? 'Active inventory items whose quantity is at or below the reorder point set for them, out of ${dashCount(w.itemCount, 'active item')} '
              'worth ${_wholeMoney(w.stockValue)} at cost. Today\'s count: the line fills in with a snapshot each day.'
          : 'Items at or below their reorder point today: ${health.empty} with none on hand and ${health.low} running low, out of the '
              '${health.tracked} items that have a reorder point. ${health.noReorder} items with stock on hand have no reorder point, so they '
              "can't show as low. All the stock is worth ${_wholeMoney(w.stockValue)} at cost. The same count as the Inventory dashboard's At or below reorder point. "
              'The Stock levels chart breaks it down; the line fills in with a snapshot each day.',
      color: lowColor,
      trend: daily(w.lowStockHistory),
    );

    final po = w.openPos;
    final oldest = po?.oldest == null ? null : _shortDay(po!.oldest!.toIso8601String());
    final aging = po == null || po.aging.isEmpty
        ? ''
        : ' Open for: ${po.aging.map((a) => '${a.$1} ${a.$2}').join(', ')}.';
    final openPos = _TileSpec(
      title: 'Open POs',
      value: po?.count.toDouble(),
      format: (v) => '${v.round()}',
      captions: po == null
          ? ['Not available yet']
          : po.count == 0
              ? [now ? 'Nothing waiting on a vendor' : 'None open$today']
              : now
                  ? (po.overdue > 0
                      ? ['${po.overdue} past due · ${_wholeMoney(po.value)} open', '${po.overdue} past due · ${_wholeMoney(po.value)}', '${po.overdue} past due']
                      : ['${_wholeMoney(po.value)} open · none past due', '${_wholeMoney(po.value)} · none past due', '${_wholeMoney(po.value)} open'])
                  : (po.overdue > 0
                      ? ['${po.overdue} past due · ${_wholeMoney(po.value)} open$today', '${po.overdue} past due$today', 'As of today']
                      : ['${_wholeMoney(po.value)} open · none past due$today', '${_wholeMoney(po.value)} open$today', 'As of today']),
      definition: po == null
          ? 'Purchase orders ordered but not yet received. The server did not send them.'
          : 'Purchase orders ordered but not yet received: ${po.count} worth ${_wholeMoney(po.value)}, ${po.overdue} past their expected date'
              '${oldest == null ? '' : ', the oldest ordered $oldest'}.$aging',
      color: po == null ? DashUi.muted : (po.overdue > 0 ? DashUi.red : DashUi.ink),
    );

    final jobs = _TileSpec(
      title: 'Jobs completed',
      value: w.jobsCompleted?.toDouble(),
      format: (v) => '${v.round()}',
      captions: w.jobsCompleted == null ? ['Not available yet'] : ['Installs and service · $period', period],
      definition: 'Completed jobs that started in $year where $first has a credited work day (warehouse staff install too). Callback visits '
          'and visits with no day weight are not counted. The line counts each job in the month $first worked it, like the technicians\' pages.',
      color: w.jobsCompleted == null ? DashUi.muted : DashUi.indigo,
      trend: w.jobsCompleted == null ? null : monthly(w.jobsMonthly),
    );

    // --- Strikes: callbacks on the person's own jobs, and the team's inventory strikes (theirs included) as the
    // page's one dark "team" card, like the field supervisor's team callback rate. ---
    // Callback strikes are counted from Oct 5, 2026 (callback tracking's go-live, like the technicians' pages).
    final callbackTracked = year >= 2026;
    final callbacks = callbackTracked ? w.callbackStrikes : null;
    final techStrikes = w.teamInventoryStrikes;
    final mine = data.inventoryStrikes;
    final teamStrikes = techStrikes == null ? null : techStrikes + mine;
    final strikes = <_TileSpec>[
      _TileSpec(
        title: 'Callback strikes',
        value: callbacks?.toDouble(),
        format: (v) => '${v.round()}',
        captions: !callbackTracked
            ? ['Tracking began Oct 5, 2026']
            : callbacks == null
                ? ['Not available yet']
                : year == 2026
                    ? ["Callbacks on $first's jobs since Oct 5", 'Since Oct 5, 2026', 'Since Oct 5']
                    : ["Callbacks on $first's jobs · $period", period],
        definition: !callbackTracked
            ? 'Callback strikes are counted from Oct 5, 2026, when callback tracking began, so $year has none to show.'
            : 'Verified callback visits in $year${year == 2026 ? ' (counted from Oct 5, 2026, when callback tracking began)' : ''} '
                'on jobs where $first did the original work. Select to open the visits.',
        color: callbacks == null ? DashUi.muted : _strikeColor(callbacks),
        count: callbacks ?? 0,
        noun: 'callback visit',
        onOpen: () => showDialog<void>(
          context: context,
          builder: (_) => _CallbackStrikesDialog(employeeId: employeeId, name: user.name, year: year),
        ),
      ),
      _TileSpec(
        title: 'Team inv. strikes',
        value: teamStrikes?.toDouble(),
        format: (v) => '${v.round()}',
        captions: teamStrikes == null
            ? ['Not available yet']
            : ['$first $mine + techs $techStrikes, all time', '$first $mine + techs $techStrikes', 'All time'],
        definition: 'Days a tech had checked out none of the day\'s job materials by 4 PM (8:30 AM before November 2026), all time '
            '(the counters keep no dates), for the whole team: '
            '$first\'s own $mine and every current tech\'s ${techStrikes ?? '—'} added up. The line is this total, snapshotted each '
            'day, so it fills in as days pass.',
        color: teamStrikes == null ? DashUi.muted : DashUi.red,
        trend: daily(w.teamStrikesWithMeHistory),
        featured: true,
      ),
    ];

    return _WhGrid(
      tiles: [accuracy, cycles, lowStock, openPos, jobs, ...strikes],
      chart: _WhChartPanel(w: w, year: year, now: now),
      zones: _ZonesPanel(
        zones: w.zones,
        today: today,
        coverage: w.coverageItems == null
            ? null
            : _Coverage(items: w.coverageItems!, of: w.itemCount, value: w.coverageValue ?? 0, stockValue: w.stockValue, year: year),
      ),
      rows: w.zones.length,
    );
  }
}

// =============================================================================
// THE CHART: accuracy by week, stock gaps and cycle history, stepping through itself
// =============================================================================

/// One panel with three views of the warehouse's counting, behind a switch in the title row. It steps to the next
/// view every 8 seconds, holds while the pointer or the keyboard is on it, never moves with reduced motion, and a view
/// picked by hand restarts the wait.
class _WhChartPanel extends StatefulWidget {
  final _WarehouseKpis w;
  final int year;

  /// Whether [year] is this one: the weekly accuracy and the cycle history are always the latest weeks, so an earlier
  /// year says they are today's.
  final bool now;
  const _WhChartPanel({required this.w, required this.year, required this.now});

  @override
  State<_WhChartPanel> createState() => _WhChartPanelState();
}

class _WhChartPanelState extends State<_WhChartPanel> with SingleTickerProviderStateMixin {
  static const _views = [(0, 'Accuracy'), (1, 'Stock gaps'), (2, 'Stock levels'), (3, 'Cycles')];
  late final _cycler = _ViewCycler(vsync: this, count: _views.length, onStep: () => setState(() {}));
  bool _pointerIn = false;
  bool _focused = false;

  int get _view => _cycler.view;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cycler.still(MediaQuery.disableAnimationsOf(context));
  }

  @override
  void dispose() {
    _cycler.dispose();
    super.dispose();
  }

  void _hold() => _cycler.hold(_pointerIn || _focused);

  void _pick(int v) => setState(() => _cycler.pick(v));

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    final w = widget.w;
    final (title, note, tip) = switch (_view) {
      0 => (
          'Inventory accuracy',
          widget.now ? 'last 12 weeks' : 'last 12 weeks · as of today',
          'The headline is ${widget.year}\'s share of item counts that matched the system quantity. The line is each week\'s share '
              '(weeks start Monday), for the weeks with counts in the last 12 weeks whatever year is picked, against the 95% target. '
              'Hover a week to read it.'
        ),
      1 => (
          'Stock gaps',
          'shelf vs system',
          'What the cycle counts in ${widget.year} found against what the system said, at cost. The headline adds up every item that '
              "didn't match; the rows are the biggest gaps. A bar going left (red) is stock that should have been on the shelf and "
              "wasn't, often material taken without being checked out. A bar going right (amber) is stock on the shelf the system "
              "didn't know about, often a delivery or a return that was never entered."
        ),
      2 => (
          'Stock levels',
          'today',
          'Items with a reorder point, today: empty (none on hand), low (some, at or below the reorder point) or stocked above it, '
              'then the categories with the most empty or low items. Items with no reorder point are not in the bar: they can never '
              'show as low, which is why they are listed under Records to fix.'
        ),
      _ => (
          'Cycle counts',
          widget.now ? 'last 6 months' : 'last 6 months · as of today',
          "Each zone's last six scheduled count weeks (one a month), oldest on the left: done, missed, still open, or from before counts "
              'were recorded. A zone is counted in its own week (Wednesday to Friday). Done means the count for that week was finished; '
              "the record doesn't say whether it was finished on time."
        ),
    };
    final Widget content = switch (_view) {
      0 => _AccuracyStoryView(pct: w.accuracyPct, counted: w.accuracyCounted, weeks: w.accuracyTrend, year: widget.year),
      1 => _StockGapsView(misses: w.topMisses, totals: w.stockGaps, counted: w.accuracyCounted),
      2 => _StockLevelsView(health: w.stockHealth, itemCount: w.itemCount),
      _ => _CycleStoryView(history: w.cycleHistory),
    };
    return MouseRegion(
      onEnter: (_) {
        _pointerIn = true;
        _hold();
      },
      onExit: (_) {
        _pointerIn = false;
        _hold();
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (f) {
          _focused = f;
          _hold();
        },
        child: DashPanel(
          fill: true,
          header: SizedBox(
            height: g.panelHeader,
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    label: '$title, $note',
                    child: ExcludeSemantics(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Tooltip(
                          message: tip,
                          waitDuration: const Duration(milliseconds: 500),
                          child: Text.rich(
                            TextSpan(children: [
                              TextSpan(text: title, style: DashText.panelTitle),
                              TextSpan(text: ' · $note', style: DashText.panelNote),
                            ]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: DashSegmented<int>(value: _view, options: _views, onChanged: _pick, label: 'Chart view'),
                    ),
                  ),
                ),
              ],
            ),
          ),
          child: _ViewSwitcher(view: _view, forward: _cycler.forward, child: content),
        ),
      ),
    );
  }
}

// =============================================================================
// THE CHART'S STORIES: stock gaps and cycle counts
// =============================================================================

/// A headline figure that counts up, with a word or two after it ("−13 units short").
class _StoryStat extends StatelessWidget {
  final double value;
  final String Function(double) format;
  final String label;
  final Color color;
  const _StoryStat(this.value, this.format, this.label, this.color);

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(begin: still ? value : 0, end: value),
          duration: still ? Duration.zero : const Duration(milliseconds: 900),
          curve: Curves.easeOutCubic,
          builder: (context, x, _) => Text(
            format(x),
            maxLines: 1,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, height: 1.1, color: color, fontFeatures: DashText.tabular),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, maxLines: 1, style: DashText.meta.copyWith(fontSize: 12.5, color: DashUi.slate)),
      ],
    );
  }
}

/// Accuracy as an answer before the line: the year's share of item counts that matched ("94.4% of 160 item counts
/// matched"), and a callout that says how often the weeks reached the 95% target and how the latest week did, so the
/// chart under it only has to show the shape.
class _AccuracyStoryView extends StatelessWidget {
  final double? pct;
  final int counted;
  final List<(String, double, int)> weeks;
  final int year;
  const _AccuracyStoryView({required this.pct, required this.counted, required this.weeks, required this.year});

  static const _target = 95.0;

  @override
  Widget build(BuildContext context) {
    final p = pct;
    if (p == null) return DashEmptyNote('No count with quantities recorded in $year yet');
    final g = DashGeo.of(context);
    final color = p >= _target ? DashUi.emeraldText : (p >= 90 ? DashUi.amberText : DashUi.redText);
    final onTarget = weeks.where((w) => w.$2 >= _target).length;
    final latest = weeks.isEmpty ? null : weeks.last;
    String day(String iso) {
      final d = DateTime.tryParse(iso);
      return d == null ? iso : '${_monthLetters[d.month - 1]} ${d.day}';
    }

    final String callout;
    final Color calloutColor;
    if (latest == null) {
      (callout, calloutColor) = ('No weekly counts in the last 12 weeks', DashUi.subtle);
    } else {
      // The headline gives the target and the chart labels the latest week, so this only has to say how they compare.
      final met = latest.$2 >= _target;
      final gap = (latest.$2 - _target).abs();
      final under = '${_fmtNum(gap)} points under target';
      if (weeks.length < 2) {
        callout = 'Week of ${day(latest.$1)}: ${_fmtNum(latest.$2)}%, ${met ? 'on target' : under}';
      } else if (onTarget == weeks.length) {
        callout = 'On target in all ${weeks.length} weeks';
      } else if (onTarget == 0) {
        callout = 'Under target in all ${weeks.length} weeks · latest week $under';
      } else {
        callout = 'On target in $onTarget of ${weeks.length} weeks${met ? ', including the latest' : ' · latest week $under'}';
      }
      calloutColor = met ? DashUi.emeraldText : DashUi.amberText;
    }
    final headH = g.line(22, 1.1) + g.line(12) + 2;
    return Semantics(
      label: '${_fmtNum(p)}% of $counted item counts matched the system in $year. $callout.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: headH,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: _StoryStat(p, (v) => '${_fmtNum(v)}%', 'of ${_whCount(counted)} item counts matched the system · target ${_target.round()}%', color),
                  ),
                ),
                Text(callout, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.meta.copyWith(fontWeight: FontWeight.w700, color: calloutColor)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: weeks.length < 2
                ? const DashEmptyNote('The week-by-week line appears after two weeks of counts')
                : _AccuracyTrendChart(points: weeks),
          ),
        ],
      ),
    );
  }
}

/// A key entry under a view: a swatch (or the record tick) and what it means.
Widget _keyItem(Widget swatch, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [swatch, const SizedBox(width: 6), Text(text, maxLines: 1, style: DashText.meta)],
    );

Widget _keyBox(Color fill, {Color? border}) => Container(
      width: 14,
      height: 9,
      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(3), border: border == null ? null : Border.all(color: border, width: 1.2)),
    );

/// Stock gaps as "what the system said against what was on the shelf". The headline puts every gap of the year in
/// dollars and says which way they lean; the callout says what that usually means (extra stock: deliveries or returns
/// not entered; missing stock: material taken without being checked out). Under it the biggest gaps, an item a row:
/// "System 11 → shelf 42" in words, and a bar growing out of a zero line (the shelf matched the system) to the left in
/// red for stock that wasn't there, to the right in amber for stock the system didn't know about. The rows share one
/// scale, and the zero line sits only as far in as the biggest shortfall needs (at the left edge when nothing was
/// short), so a one-sided year doesn't waste half the panel.
class _StockGapsView extends StatelessWidget {
  final List<(String, int, int, double?)> misses; // name, system qty, counted qty, cost each
  /// Every gap of the year added up; worked out from [misses] for a server that doesn't send it.
  final _GapTotals? totals;

  /// Item counts recorded this year ("8 of 59 item counts off"); 0 when not known.
  final int counted;
  const _StockGapsView({required this.misses, required this.totals, required this.counted});

  static const _rightW = 92.0;

  /// [totals], or the same figures from the rows shown (an older server).
  _GapTotals get _sum {
    if (totals != null) return totals!;
    var si = 0, ei = 0, su = 0, eu = 0;
    var sv = 0.0, ev = 0.0;
    for (final m in misses) {
      final d = m.$3 - m.$2;
      if (d < 0) {
        si++;
        su -= d;
        sv -= d * (m.$4 ?? 0);
      } else {
        ei++;
        eu += d;
        ev += d * (m.$4 ?? 0);
      }
    }
    return _GapTotals(shortItems: si, extraItems: ei, shortUnits: su, extraUnits: eu, shortValue: sv, extraValue: ev);
  }

  @override
  Widget build(BuildContext context) {
    if (misses.isEmpty) {
      return DashEmptyNote(counted > 0 ? 'Every item counted matched the system' : 'No counts with quantities recorded yet');
    }
    final g = DashGeo.of(context);
    final t = _sum;
    // Dollars when there is a cost to put on the gaps, units otherwise.
    final money = t.shortValue + t.extraValue > 0;
    final extraLeads = money ? t.extraValue >= t.shortValue : t.extraUnits >= t.shortUnits;
    String amount(double v) => money ? _wholeMoney(v) : '${v.round()}';
    String units(int n) => n == 1 ? 'unit' : 'units';
    final extraAmt = money ? t.extraValue : t.extraUnits.toDouble();
    final shortAmt = money ? t.shortValue : t.shortUnits.toDouble();

    final lead = extraLeads
        ? _StoryStat(extraAmt, (v) => '+${amount(v)}', money ? "of stock the system didn't know about" : "${units(t.extraUnits)} the system didn't know about", DashUi.amberText)
        : _StoryStat(shortAmt, (v) => '−${amount(v)}', money ? 'of stock missing from the shelves' : '${units(t.shortUnits)} missing from the shelves', DashUi.redText);
    final otherAmt = extraLeads ? shortAmt : extraAmt;
    final other = otherAmt <= 0
        ? null
        : (extraLeads
            ? _StoryStat(otherAmt, (v) => '−${amount(v)}', 'missing', DashUi.redText)
            : _StoryStat(otherAmt, (v) => '+${amount(v)}', 'unrecorded extra', DashUi.amberText));
    final off = counted >= t.items && counted > 0
        ? _StoryStat(t.items.toDouble(), (v) => '${v.round()} of $counted', 'item counts off', DashUi.ink)
        : _StoryStat(t.items.toDouble(), (v) => '${v.round()}', t.items == 1 ? 'item off' : 'items off', DashUi.ink);
    final headline = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [lead, if (other != null) ...[const SizedBox(width: 22), other], const SizedBox(width: 22), off],
      ),
    );

    // What the gaps usually mean, in words.
    final (callout, calloutColor) = t.shortItems == 0
        ? ('${t.items == 1 ? 'The gap was' : 'All ${t.items} gaps were'} extra stock: usually deliveries or returns not entered in the system', DashUi.amberText)
        : t.extraItems == 0
            ? ('${t.items == 1 ? 'The gap was' : 'All ${t.items} gaps were'} missing stock: usually material taken without being checked out', DashUi.redText)
            : extraLeads
                ? ('${t.extraItems} of ${t.items} gaps were extra stock: check deliveries are being entered', DashUi.amberText)
                : ('${t.shortItems} of ${t.items} gaps were missing stock: check material is being checked out', DashUi.redText);

    var maxShort = 0, maxExtra = 0;
    for (final m in misses) {
      final d = m.$3 - m.$2;
      if (d < 0) maxShort = math.max(maxShort, -d);
      if (d > 0) maxExtra = math.max(maxExtra, d);
    }
    final span = math.max(1, maxShort + maxExtra);
    final zero = maxShort / span; // where the zero line sits across the bar area, 0..1

    final key = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (maxShort > 0) ...[_keyItem(_keyBox(DashUi.red), 'Missing from the shelf'), const SizedBox(width: 16)],
          if (maxExtra > 0) ...[_keyItem(_keyBox(DashUi.amber), 'On the shelf, not in the system'), const SizedBox(width: 16)],
          _keyItem(Container(width: 2, height: 14, color: DashUi.ink), 'Shelf matches the system'),
        ],
      ),
    );

    final headH = g.line(22, 1.1) + g.line(12) + 2;
    final colH = g.line(11.5) + 2;
    final keyH = g.line(12) + 2;
    final minRow = math.max(38.0, g.line(13) + g.line(12) + 6);
    return Semantics(
      label: '${t.extraItems} items had extra stock, ${amount(extraAmt)}${money ? '' : ' units'}; '
          '${t.shortItems} were short, ${amount(shortAmt)}${money ? '' : ' units'}. $callout.',
      child: LayoutBuilder(
        builder: (context, c) {
          final avail = math.max(0.0, c.maxHeight - headH - 10 - colH - 4 - keyH - 8);
          final n = math.max(1, math.min(misses.length, (avail / minRow).floor()));
          final rowH = math.min(avail / n, 58.0);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: headH,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: headline),
                    Text(callout, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.meta.copyWith(fontWeight: FontWeight.w700, color: calloutColor)),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: colH,
                // The rows' hover wash pads them by 6 a side; the labels match so they sit over the bars.
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: _GapAxisLabels(zero: zero, short: maxShort > 0, extra: maxExtra > 0, money: money)),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < n; i++)
                        SizedBox(
                          height: rowH,
                          child: _GapRow(item: misses[i], zero: zero, span: span, index: i, divider: i > 0),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(height: keyH, child: key),
            ],
          );
        },
      ),
    );
  }
}

/// The three columns of the gap rows: the item and its two counts in words, the bar, and the gap with its value.
Widget _gapColumns({required Widget item, required Widget bar, required Widget figure}) => Row(
      children: [
        Expanded(flex: 5, child: item),
        const SizedBox(width: 14),
        Expanded(flex: 6, child: bar),
        const SizedBox(width: 12),
        SizedBox(width: _StockGapsView._rightW, child: figure),
      ],
    );

/// Over the bars: which way is missing and which is extra, on either side of the zero line.
class _GapAxisLabels extends StatelessWidget {
  final double zero;
  final bool short;
  final bool extra;
  final bool money;
  const _GapAxisLabels({required this.zero, required this.short, required this.extra, required this.money});

  @override
  Widget build(BuildContext context) {
    final style = DashText.column.copyWith(fontSize: 11.5);
    return ExcludeSemantics(
      child: _gapColumns(
        item: Text('Item · system count → shelf count', maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
        bar: LayoutBuilder(
          builder: (context, c) {
            final x = c.maxWidth * zero;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                if (short)
                  Positioned(
                    left: 0,
                    width: math.max(0.0, x - 6),
                    top: 0,
                    bottom: 0,
                    child: Text('← missing', maxLines: 1, overflow: TextOverflow.clip, textAlign: TextAlign.right, style: style.copyWith(color: DashUi.redText)),
                  ),
                if (extra)
                  Positioned(
                    left: x + 6,
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: Text('extra →', maxLines: 1, overflow: TextOverflow.clip, style: style.copyWith(color: DashUi.amberText)),
                  ),
              ],
            );
          },
        ),
        figure: Text(money ? 'Gap · at cost' : 'Gap', maxLines: 1, textAlign: TextAlign.right, style: style),
      ),
    );
  }
}

class _GapRow extends StatelessWidget {
  final (String, int, int, double?) item;

  /// Where the zero line sits across the bar area (0..1), and the units the whole bar area stands for.
  final double zero;
  final int span;
  final int index;
  final bool divider;
  const _GapRow({required this.item, required this.zero, required this.span, required this.index, required this.divider});

  @override
  Widget build(BuildContext context) {
    final (name, system, counted, cost) = item;
    final diff = counted - system;
    final short = diff < 0;
    final color = short ? DashUi.redText : DashUi.amberText;
    final value = cost == null ? null : diff.abs() * cost;
    final words = short ? 'missing' : 'extra';
    final still = MediaQuery.disableAnimationsOf(context);
    const growMs = 800;
    final ms = growMs + index * 110;
    final tip = '$name: the system said $system, the shelf had $counted, so ${diff.abs()} $words'
        '${value == null ? ' (no cost on record)' : ' (${dashMoney(value)} at ${dashMoney(cost!)} each)'}';
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 400),
      child: Semantics(
        container: true,
        label: tip,
        child: ExcludeSemantics(
          child: DecoratedBox(
            decoration: BoxDecoration(border: divider ? const Border(top: BorderSide(color: DashUi.faint)) : null),
            child: _HoverTint(
              child: TweenAnimationBuilder<double>(
              tween: Tween(begin: still ? 1 : 0, end: 1),
              duration: still ? Duration.zero : Duration(milliseconds: ms),
              builder: (context, t, _) {
                final p = still ? 1.0 : Curves.easeOutCubic.transform(((t * ms - index * 110) / growMs).clamp(0.0, 1.0));
                return _gapColumns(
                  item: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.name.copyWith(fontSize: 13)),
                      Text.rich(
                        TextSpan(children: [
                          TextSpan(text: 'System $system'),
                          const TextSpan(text: '  →  '),
                          TextSpan(text: 'shelf $counted', style: TextStyle(color: color, fontWeight: FontWeight.w700)),
                        ]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DashText.meta.copyWith(fontFeatures: DashText.tabular),
                      ),
                    ],
                  ),
                  bar: SizedBox(
                    height: 14,
                    child: CustomPaint(painter: _GapBarPainter(diff: diff, zero: zero, span: span, t: p)),
                  ),
                  figure: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${short ? '−' : '+'}${(diff.abs() * p).round()}',
                        maxLines: 1,
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, height: 1.2, color: color, fontFeatures: DashText.tabular),
                      ),
                      Text(value == null ? 'no cost' : _wholeMoney(value * p), maxLines: 1, style: DashText.meta.copyWith(fontFeatures: DashText.tabular)),
                    ],
                  ),
                );
              },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One item's gap: a faint track, the zero line where the shelf would match the system, and a bar growing out of it,
/// left in red for stock that was missing, right in amber for stock the system didn't have.
class _GapBarPainter extends CustomPainter {
  final int diff;
  final double zero;
  final int span;
  final double t;
  const _GapBarPainter({required this.diff, required this.zero, required this.span, required this.t});

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final r = Radius.circular(h / 2);
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, r), Paint()..color = DashUi.faint);
    final x0 = size.width * zero;
    final len = math.max(h * 0.6, size.width * diff.abs() / span) * t;
    if (len > 0) {
      final rect = diff < 0 ? RRect.fromLTRBR(x0 - len, 0, x0, h, r) : RRect.fromLTRBR(x0, 0, x0 + len, h, r);
      canvas.drawRRect(rect, Paint()..color = diff < 0 ? DashUi.red : DashUi.amber);
    }
    final zx = x0.clamp(1.0, size.width - 1.0);
    canvas.drawLine(
      Offset(zx, -4),
      Offset(zx, h + 4),
      Paint()
        ..color = DashUi.ink
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _GapBarPainter old) => old.t != t || old.diff != diff || old.zero != zero || old.span != span;
}

// =============================================================================
// THE CHART'S STOCK VIEW: how the items with a reorder point stand today
// =============================================================================

/// Stock levels as one question: of the items that have a reorder point, how many are empty, low or stocked? The
/// headline answers it ("86 of 194 are empty") and names the category with the most empty; a bar split three ways
/// (empty, low, stocked) grows in under it with its key; then the categories with the most empty or low items, each a
/// bar of its own on one shared scale; and last the records that keep the counts and reorder alerts blind (no reorder
/// point, no shelf location, no cost), because an item without a reorder point can never show as low.
class _StockLevelsView extends StatelessWidget {
  final _StockHealth? health;

  /// Active items in all.
  final int itemCount;
  const _StockLevelsView({required this.health, required this.itemCount});

  static const _emptyC = DashUi.red;
  static const _lowC = DashUi.amber;
  static final _okC = DashUi.emerald.withValues(alpha: 0.55);

  @override
  Widget build(BuildContext context) {
    final h = health;
    if (h == null) return const DashEmptyNote('Stock levels appear once the server is updated');
    if (h.tracked == 0) return const DashEmptyNote('No item has a reorder point set yet, so none can show as low');
    final g = DashGeo.of(context);
    final still = MediaQuery.disableAnimationsOf(context);
    final worst = h.byCategory.where((c) => c.$2 > 0).fold<(String, int, int, int)?>(null, (b, c) => b == null || c.$2 > b.$2 ? c : b);
    final (callout, calloutColor) = h.empty == 0
        ? (h.low == 0 ? ('Everything with a reorder point is stocked above it', DashUi.emeraldText) : ('Nothing is empty; ${h.low} ${h.low == 1 ? 'item is' : 'items are'} low', DashUi.amberText))
        : worst == null
            ? ('${h.low} more ${h.low == 1 ? 'is' : 'are'} low', DashUi.amberText)
            : (
                'Most empty: ${worst.$1}, ${worst.$2 == worst.$2 + worst.$3 + worst.$4 ? 'all ${worst.$2} of its items with a reorder point' : '${worst.$2} of ${worst.$2 + worst.$3 + worst.$4}'}'
                    '${h.low > 0 ? ' · ${h.low} more items are low' : ''}',
                DashUi.redText
              );
    final headline = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: _StoryStat(
        h.empty.toDouble(),
        (v) => '${v.round()} of ${h.tracked}',
        'items with a reorder point are empty',
        h.empty == 0 ? DashUi.emeraldText : DashUi.redText,
      ),
    );
    final key = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _keyItem(_keyBox(_emptyC), 'Empty ${h.empty}'),
          const SizedBox(width: 16),
          _keyItem(_keyBox(_lowC), 'Low ${h.low}'),
          const SizedBox(width: 16),
          _keyItem(_keyBox(_okC), 'Stocked ${h.ok}'),
          const SizedBox(width: 16),
          Text('Low = some on hand, at or below the reorder point', maxLines: 1, style: DashText.meta),
        ],
      ),
    );
    // Items with stock on hand only (the server leaves out catalog items nobody keeps in stock, which need none of these).
    // (count, icon, what is missing, what that does in the tooltip, what that does on the card)
    final fixes = [
      (h.noReorder, Icons.notifications_off_outlined, 'no reorder point', 'can never show as low, so nobody is told to reorder them', "Can't show as low"),
      (h.noLocation, Icons.wrong_location_outlined, 'no shelf location', 'are harder to find and to put on a zone count', 'Harder to find and count'),
      (h.noCost, Icons.money_off_rounded, 'no cost', 'leave the stock value and the gaps in dollars short', 'Missing from the stock value'),
    ].where((f) => f.$1 > 0).toList();
    String fixTip(int n, String what, String does) =>
        '$n ${n == 1 ? 'item' : 'items'} with stock on hand ${n == 1 ? 'has' : 'have'} $what. Stocked items with $what $does. '
        "Catalog items nobody keeps in stock aren't counted here.";
    final footer = fixes.isEmpty
        ? Text('Every stocked item has a reorder point, a shelf location and a cost', maxLines: 1, style: DashText.meta.copyWith(color: DashUi.emeraldText, fontWeight: FontWeight.w600))
        : FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Stocked items to fix', style: DashText.meta.copyWith(color: DashUi.ink, fontWeight: FontWeight.w700)),
                for (final f in fixes) ...[
                  const SizedBox(width: 14),
                  Tooltip(
                    message: fixTip(f.$1, f.$3, f.$4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(f.$2, size: 15, color: DashUi.amberText),
                        const SizedBox(width: 4),
                        Text.rich(
                          TextSpan(children: [
                            TextSpan(text: '${f.$1}', style: const TextStyle(color: DashUi.ink, fontWeight: FontWeight.w800)),
                            TextSpan(text: ' ${f.$3}'),
                          ]),
                          style: DashText.meta.copyWith(fontFeatures: DashText.tabular),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          );

    final headH = g.line(22, 1.1) + g.line(12) + 2;
    final keyH = g.line(12) + 2;
    final colH = g.line(11.5) + 2;
    final footH = g.line(12) + 6;
    final minRow = math.max(26.0, g.line(13) + 8);
    final scale = h.byCategory.fold<int>(1, (m, c) => math.max(m, c.$2 + c.$3 + c.$4));
    return Semantics(
      label: '${h.empty} of ${h.tracked} items with a reorder point are empty, ${h.low} are low and ${h.ok} are stocked. $callout.',
      child: LayoutBuilder(
        builder: (context, c) {
          final fixed = headH + 10 + 16 + 6 + keyH + 12 + colH + 8;
          // The records to fix as three cards when every category row still fits beside them at a comfortable height;
          // in a short window, one line.
          final cardsH = _FixCard.height(g);
          final rows = h.byCategory.length;
          final cards = fixes.isNotEmpty && c.maxHeight - fixed - cardsH >= rows * 34;
          final avail = math.max(0.0, c.maxHeight - fixed - (cards ? cardsH : footH));
          final n = math.min(rows, (avail / minRow).floor());
          final rowH = n == 0 ? 0.0 : math.min(avail / n, 40.0);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: headH,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: headline),
                    Text(callout, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.meta.copyWith(fontWeight: FontWeight.w700, color: calloutColor)),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 16,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: still ? 1 : 0, end: 1),
                  duration: still ? Duration.zero : const Duration(milliseconds: 1100),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, _) => CustomPaint(
                    painter: _LevelsBarPainter(parts: [(h.empty, _emptyC), (h.low, _lowC), (h.ok, _okC)], total: h.tracked, t: t, gap: 3),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(height: keyH, child: key),
              const SizedBox(height: 12),
              if (n > 0) ...[
                SizedBox(
                  height: colH,
                  child: Row(
                    children: [
                      const SizedBox(width: 6),
                      Expanded(child: Text('Categories with the most empty or low', maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.column.copyWith(fontSize: 11.5))),
                      Text('Empty · low', maxLines: 1, style: DashText.column.copyWith(fontSize: 11.5)),
                      const SizedBox(width: 6),
                    ],
                  ),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < n; i++) SizedBox(height: rowH, child: _CategoryLevelRow(cat: h.byCategory[i], scale: scale, index: i)),
                      ],
                    ),
                  ),
                ),
              ] else
                const Spacer(),
              const SizedBox(height: 8),
              if (cards)
                SizedBox(
                  height: cardsH,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < fixes.length; i++) ...[
                        if (i > 0) const SizedBox(width: 10),
                        Expanded(
                          child: _FixCard(
                            count: fixes[i].$1,
                            icon: fixes[i].$2,
                            what: 'stocked ${fixes[i].$1 == 1 ? 'item' : 'items'} with ${fixes[i].$3}',
                            why: fixes[i].$5,
                            tip: fixTip(fixes[i].$1, fixes[i].$3, fixes[i].$4),
                            index: i,
                          ),
                        ),
                      ],
                    ],
                  ),
                )
              else
                SizedBox(height: footH, child: Align(alignment: Alignment.centerLeft, child: footer)),
            ],
          );
        },
      ),
    );
  }
}

class _CategoryLevelRow extends StatelessWidget {
  final (String, int, int, int) cat; // category, empty, low, ok
  final int scale;
  final int index;
  const _CategoryLevelRow({required this.cat, required this.scale, required this.index});

  @override
  Widget build(BuildContext context) {
    final (name, empty, low, ok) = cat;
    final total = empty + low + ok;
    final still = MediaQuery.disableAnimationsOf(context);
    const growMs = 800;
    final ms = growMs + index * 100;
    final words = [if (empty > 0) '$empty empty', if (low > 0) '$low low'].join(' · ');
    return Tooltip(
      message: '$name: $total ${total == 1 ? 'item has' : 'items have'} a reorder point: $empty empty, $low low, $ok stocked',
      waitDuration: const Duration(milliseconds: 400),
      child: Semantics(
        container: true,
        label: '$name: $empty empty, $low low, $ok stocked',
        child: ExcludeSemantics(
          child: _HoverTint(
            child: Row(
            children: [
              Expanded(flex: 4, child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.name.copyWith(fontSize: 13))),
              const SizedBox(width: 12),
              Expanded(
                flex: 6,
                child: SizedBox(
                  height: 10,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: still ? 1 : 0, end: 1),
                    duration: still ? Duration.zero : Duration(milliseconds: ms),
                    builder: (context, t, _) => CustomPaint(
                      painter: _LevelsBarPainter(
                        parts: [(empty, _StockLevelsView._emptyC), (low, _StockLevelsView._lowC), (ok, _StockLevelsView._okC)],
                        total: scale,
                        t: still ? 1 : Curves.easeOutCubic.transform(((t * ms - index * 100) / growMs).clamp(0.0, 1.0)),
                        gap: 2,
                        track: false,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 112,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    words,
                    maxLines: 1,
                    style: DashText.meta.copyWith(color: empty > 0 ? DashUi.redText : DashUi.amberText, fontWeight: FontWeight.w700, fontFeatures: DashText.tabular),
                  ),
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

/// One kind of record to fix: how many items lack it, in big figures that count up, what is missing, and what that
/// costs the warehouse, on a faint amber card that rises in after the bars.
class _FixCard extends StatelessWidget {
  final int count;
  final IconData icon;
  final String what;
  final String why;
  final String tip;
  final int index;
  const _FixCard({required this.count, required this.icon, required this.what, required this.why, required this.tip, required this.index});

  static double height(DashGeo g) => math.max(64.0, g.line(20, 1.1) + g.line(12) * 2 + 16);

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final delay = 500 + index * 120;
    final ms = delay + 700;
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 400),
      child: Semantics(
        container: true,
        label: '$count items have $what. $why.',
        child: ExcludeSemantics(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: still ? 1 : 0, end: 1),
            duration: still ? Duration.zero : Duration(milliseconds: ms),
            builder: (context, t, child) {
              final p = still ? 1.0 : Curves.easeOutCubic.transform(((t * ms - delay) / 700).clamp(0.0, 1.0));
              return Opacity(opacity: p, child: Transform.translate(offset: Offset(0, (1 - p) * 10), child: child));
            },
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              decoration: BoxDecoration(
                color: DashUi.amber.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: DashUi.amber.withValues(alpha: 0.22)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Icon(icon, size: 16, color: DashUi.amberText),
                        const SizedBox(width: 6),
                        TweenAnimationBuilder<double>(
                          tween: Tween(begin: still ? count.toDouble() : 0, end: count.toDouble()),
                          duration: still ? Duration.zero : const Duration(milliseconds: 1000),
                          curve: Curves.easeOutCubic,
                          builder: (context, v, _) => Text(
                            '${v.round()}',
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, height: 1.1, color: DashUi.ink, fontFeatures: DashText.tabular),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(what, maxLines: 1, style: DashText.label),
                      ],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(why, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.meta.copyWith(color: DashUi.amberText, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A bar split into coloured parts out of [total], growing in from the left with [t] (a faint track behind it unless
/// [track] is off). Parts keep a small [gap] between them so each reads as its own piece.
class _LevelsBarPainter extends CustomPainter {
  final List<(int, Color)> parts;
  final int total;
  final double t;
  final double gap;
  final bool track;
  const _LevelsBarPainter({required this.parts, required this.total, required this.t, this.gap = 2, this.track = true});

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final r = Radius.circular(math.min(h / 2, 5));
    if (track) canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, r), Paint()..color = DashUi.faint);
    if (total <= 0) return;
    final end = size.width * t;
    var x = 0.0;
    for (final (n, color) in parts) {
      if (n <= 0) continue;
      final w = size.width * n / total;
      final right = math.min(x + w - gap, end);
      if (right > x) canvas.drawRRect(RRect.fromLTRBR(x, 0, math.max(right, x + 2), h, r), Paint()..color = color);
      x += w;
    }
  }

  @override
  bool shouldRepaint(covariant _LevelsBarPainter old) => old.t != t || old.total != total || old.parts.length != parts.length || !_sameParts(old.parts);

  bool _sameParts(List<(int, Color)> o) {
    for (var i = 0; i < parts.length; i++) {
      if (parts[i] != o[i]) return false;
    }
    return true;
  }
}

/// One zone's record over its last scheduled weeks.
class _ZoneRecord {
  final String zone;
  final List<(String, String)> weeks; // period start, Complete / Missed / Pending / Untracked
  const _ZoneRecord(this.zone, this.weeks);

  int count(String status) => weeks.where((w) => w.$2 == status).length;
  int get done => count('Complete');
  int get missed => count('Missed');

  /// Weeks that have come due since counts were recorded (done or missed).
  int get scored => done + missed;

  /// Completed counts in a row, back from the latest week that has come due.
  int get streak {
    var n = 0;
    for (final w in weeks.reversed) {
      if (w.$2 == 'Pending') continue;
      if (w.$2 != 'Complete') break;
      n++;
    }
    return n;
  }

  /// Whether the latest week that has come due was missed.
  bool get missedLast => weeks.reversed.where((w) => w.$2 != 'Pending').firstOrNull?.$2 == 'Missed';
}

/// Cycle counts as a question: are the zones being counted each scheduled week? The headline answers it (a ring and "17 of
/// 22 scheduled counts done") and names the zone furthest behind; under it each zone is a timeline of its scheduled weeks,
/// oldest on the left, a dot per week (done, missed, still open, or before counts were recorded) that pops in along the
/// line, with the zone's score and its current run at the end of the row.
class _CycleStoryView extends StatelessWidget {
  final List<(String, List<(String, String)>)> history;
  const _CycleStoryView({required this.history});

  static const _rightW = 104.0;
  static const _zoneW = 64.0;

  @override
  Widget build(BuildContext context) {
    if (history.isEmpty) return const DashEmptyNote('No cycle counts scheduled yet');
    final g = DashGeo.of(context);
    final zones = [for (final h in history) _ZoneRecord(h.$1, h.$2)];
    final done = zones.fold<int>(0, (s, z) => s + z.done);
    final scored = zones.fold<int>(0, (s, z) => s + z.scored);
    final rate = scored == 0 ? null : done / scored;
    final behind = zones.where((z) => z.missed > 0).fold<_ZoneRecord?>(null, (b, z) => b == null || z.missed > b.missed ? z : b);
    final cols = zones.fold<int>(0, (m, z) => math.max(m, z.weeks.length));
    final longest = zones.firstWhere((z) => z.weeks.length == cols);
    final still = MediaQuery.disableAnimationsOf(context);
    final ringColor = rate == null ? DashUi.muted : (rate >= 0.9 ? DashUi.emerald : (rate >= 0.7 ? DashUi.amber : DashUi.red));

    final callout = behind == null
        ? (scored == 0 ? ('Nothing has come due since counts were recorded', DashUi.slate) : ('No zone has missed a count', DashUi.emeraldText))
        : ('${behind.zone} is furthest behind: ${behind.missed} missed', DashUi.redText);
    final headline = Row(
      children: [
        SizedBox(
          width: 40,
          height: 40,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: still ? (rate ?? 0) : 0, end: rate ?? 0),
            duration: still ? Duration.zero : const Duration(milliseconds: 1100),
            curve: Curves.easeOutCubic,
            builder: (context, p, _) => CustomPaint(
              painter: _RingPainter(progress: p, color: ringColor),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: FittedBox(
                  child: Text(rate == null ? '—' : '${(p * 100).round()}%', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: ringColor == DashUi.muted ? DashUi.slate : ringColor)),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: _StoryStat(done.toDouble(), (v) => '${v.round()} of $scored', 'scheduled counts done', DashUi.ink),
              ),
              Text(callout.$1, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.meta.copyWith(fontWeight: FontWeight.w700, color: callout.$2)),
            ],
          ),
        ),
      ],
    );

    String month(String iso) {
      final d = DateTime.tryParse(iso);
      return d == null ? '' : _monthLetters[d.month - 1];
    }

    final header = Row(
      children: [
        const SizedBox(width: _zoneW),
        Expanded(
          child: Row(
            children: [
              for (var i = 0; i < cols; i++)
                Expanded(
                  child: Text(
                    i == cols - 1 ? 'Latest' : month(longest.weeks[i].$1),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    style: DashText.column.copyWith(fontSize: 11.5, color: i == cols - 1 ? DashUi.ink : DashUi.subtle, fontWeight: i == cols - 1 ? FontWeight.w700 : FontWeight.w600),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: _rightW),
      ],
    );

    Widget dot(Color fill, {Color? border, IconData? icon, Color iconColor = Colors.white}) => Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: fill, shape: BoxShape.circle, border: border == null ? null : Border.all(color: border, width: 1.5)),
          child: icon == null ? null : Icon(icon, size: 9, color: iconColor),
        );
    final key = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _keyItem(dot(DashUi.emerald, icon: Icons.check_rounded), 'Done'),
          const SizedBox(width: 16),
          _keyItem(dot(DashUi.red, icon: Icons.close_rounded), 'Missed'),
          const SizedBox(width: 16),
          _keyItem(dot(Colors.white, border: DashUi.amber), 'Still open'),
          const SizedBox(width: 16),
          _keyItem(dot(DashUi.faint, border: DashUi.line), 'Before counts were recorded'),
        ],
      ),
    );

    final headH = math.max(40.0, g.line(22, 1.1) + g.line(12)) + 2;
    final headerH = g.line(11.5) + 2;
    final keyH = g.line(12) + 2;
    return Semantics(
      label: rate == null ? 'No cycle counts have come due since counts were recorded' : '$done of $scored scheduled cycle counts done. ${callout.$1}.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: headH, child: headline),
          const SizedBox(height: 10),
          SizedBox(height: headerH, child: header),
          Expanded(
            child: _ListRows(
              children: [for (var i = 0; i < zones.length; i++) _ZoneTimeline(record: zones[i], cols: cols, index: i)],
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(height: keyH, child: key),
        ],
      ),
    );
  }
}

class _ZoneTimeline extends StatelessWidget {
  final _ZoneRecord record;
  final int cols;
  final int index;
  const _ZoneTimeline({required this.record, required this.cols, required this.index});

  @override
  Widget build(BuildContext context) {
    final z = record;
    final still = MediaQuery.disableAnimationsOf(context);
    final ms = 700 + index * 140 + cols * 60;
    final (runText, runColor) = z.scored == 0
        ? ('Nothing due yet', DashUi.subtle)
        : (z.missedLast ? ('Missed latest', DashUi.redText) : (z.streak > 0 ? ('${z.streak} in a row', DashUi.emeraldText) : ('—', DashUi.subtle)));
    return Semantics(
      container: true,
      label: '${z.zone}: ${z.done} of ${z.scored} done. $runText.',
      child: ExcludeSemantics(
        child: Row(
          children: [
            SizedBox(width: _CycleStoryView._zoneW, child: Text(z.zone, maxLines: 1, style: DashText.name.copyWith(fontWeight: FontWeight.w800))),
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) {
                  final colW = c.maxWidth / cols;
                  final s = math.max(12.0, math.min(26.0, math.min(c.maxHeight - 8, colW - 8)));
                  // A zone with fewer weeks lines its latest week up with everyone else's.
                  final offset = cols - z.weeks.length;
                  return TweenAnimationBuilder<double>(
                    tween: Tween(begin: still ? 1 : 0, end: 1),
                    duration: still ? Duration.zero : Duration(milliseconds: ms),
                    builder: (context, t, _) {
                      final at = still ? 1.0 : (t * ms - index * 140) / (ms - index * 140);
                      return Stack(
                        children: [
                          // The line the weeks sit on, drawing itself left to right.
                          Positioned(
                            left: colW * (offset + 0.5),
                            top: c.maxHeight / 2 - 1,
                            height: 2,
                            width: math.max(0.0, colW * (z.weeks.length - 1) * at.clamp(0.0, 1.0)),
                            child: const ColoredBox(color: DashUi.line),
                          ),
                          for (var i = 0; i < z.weeks.length; i++)
                            Positioned(
                              left: colW * (offset + i) + (colW - s) / 2,
                              top: (c.maxHeight - s) / 2,
                              width: s,
                              height: s,
                              child: Transform.scale(
                                scale: Curves.easeOutBack.transform(((at * (z.weeks.length + 2) - i) / 2).clamp(0.0, 1.0)),
                                child: _WeekDot(week: z.weeks[i], size: s),
                              ),
                            ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
            SizedBox(
              width: _CycleStoryView._rightW,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(z.scored == 0 ? '—' : '${z.done}/${z.scored} done', maxLines: 1, style: DashText.money),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(runText, maxLines: 1, style: DashText.meta.copyWith(color: runColor, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WeekDot extends StatelessWidget {
  final (String, String) week;
  final double size;
  const _WeekDot({required this.week, required this.size});

  @override
  Widget build(BuildContext context) {
    final status = week.$2;
    final d = DateTime.tryParse(week.$1);
    final when = d == null ? week.$1 : 'Week of ${_monthLetters[d.month - 1]} ${d.day}';
    final (fill, border, icon, iconColor, words) = switch (status) {
      'Complete' => (DashUi.emerald, null, Icons.check_rounded, Colors.white, 'done'),
      'Missed' => (DashUi.red, null, Icons.close_rounded, Colors.white, 'missed'),
      'Untracked' => (DashUi.faint, DashUi.line, Icons.remove_rounded, DashUi.muted, 'before counts were recorded'),
      _ => (Colors.white, DashUi.amber, Icons.schedule_rounded, DashUi.amberText, 'still open'),
    };
    return Tooltip(
      message: '$when · $words',
      child: Container(
        decoration: BoxDecoration(
          color: fill,
          shape: BoxShape.circle,
          border: border == null ? null : Border.all(color: border, width: 1.6),
          boxShadow: status == 'Complete' || status == 'Missed' ? [BoxShadow(color: fill.withValues(alpha: 0.3), blurRadius: 6, offset: const Offset(0, 2))] : null,
        ),
        child: Icon(icon, size: size * 0.6, color: iconColor),
      ),
    );
  }
}

// =============================================================================
// CYCLE COUNT ZONES
// =============================================================================

/// Each zone's current count: the week it is worked, how many items so far, and whether it is complete, in progress or
/// overdue (the status is a word and an icon as well as a colour). The zones slide in one after another: as rows in a
/// short window, as a two-by-two board once rows would be left with more air than content ([_ZoneList]).
class _ZonesPanel extends StatelessWidget {
  final List<_ZoneCount> zones;

  /// " · as of today" when an earlier year is picked.
  final String today;

  /// How much of the warehouse the year's counts reached (null from an older server).
  final _Coverage? coverage;
  const _ZonesPanel({required this.zones, required this.today, this.coverage});

  /// A row at its smallest: the zone's name over its week, with room for the status beside them.
  static double rowMin(DashGeo g) => math.max(48.0, g.line(14) + g.line(12) + 14);

  /// The panel at its smallest for [n] zones.
  static double minHeight(DashGeo g, int n) => g.panelTop + math.max(n, 2) * rowMin(g);

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    final cov = coverage;
    final list = zones.isEmpty
        ? const DashEmptyNote('No cycle count zones are set up yet')
        : _ZoneList(zones: zones);
    return LayoutBuilder(
      builder: (context, c) {
        // The coverage sits over the zones when there is room for both; in a short window it shrinks to a note in the
        // title row, so it is never lost.
        final sumH = _CoverageSummary.height(g);
        final roomy = cov != null && (!c.maxHeight.isFinite || c.maxHeight >= minHeight(g, zones.length) + sumH + 9);
        return DashPanel(
          fill: true,
          header: DashPanelHeader(
            g: g,
            title: 'Cycle count zones',
            note: today.isEmpty ? null : 'as of today',
            tooltip: "Each zone is counted in its own week, Wednesday to Friday, on a schedule. The card shows each zone's current period. "
                'It is overdue once that week has passed without the count being finished. Nothing records who counted, so this is the whole team.',
            trailing: cov == null || roomy
                ? null
                : Tooltip(
                    message: cov.definition,
                    child: Text('${cov.items} of ${cov.of} items on a count', maxLines: 1, style: DashText.meta.copyWith(fontWeight: FontWeight.w600)),
                  ),
          ),
          child: !roomy
              ? list
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: sumH, child: _CoverageSummary(coverage: cov)),
                    const SizedBox(height: 8),
                    const Divider(height: 1, thickness: 1, color: DashUi.line),
                    Expanded(child: list),
                  ],
                ),
        );
      },
    );
  }
}

/// How much of the warehouse the year's counts reached: active items on a count, out of all of them, and the share of
/// the stock's value (at cost, today) those items hold.
class _Coverage {
  final int items;
  final int of;
  final double value;
  final double stockValue;
  final int year;
  const _Coverage({required this.items, required this.of, required this.value, required this.stockValue, required this.year});

  double get share => of == 0 ? 0 : (items / of).clamp(0.0, 1.0);
  double? get valueShare => stockValue <= 0 ? null : (value / stockValue).clamp(0.0, 1.0);

  String get definition => 'Active inventory items that were on a zone count in $year, finished or still in progress: $items of $of. Together they hold '
      '${_wholeMoney(value)} of the ${_wholeMoney(stockValue)} the stock is worth at cost today'
      '${valueShare == null ? '' : ' (${_pct(valueShare!)})'}. Every item comes round once all four zones have been counted.';
}

/// A share as a percentage: one decimal near the ends (99.8%, 4.5%), whole otherwise.
String _pct(double share) {
  final p = share * 100;
  return (p > 99 && p < 100) || (p > 0 && p < 10) ? '${p.toStringAsFixed(1)}%' : '${p.round()}%';
}

/// The coverage over the zone list: a ring of the items counted (it fills in) and the figures in words.
class _CoverageSummary extends StatelessWidget {
  final _Coverage coverage;
  const _CoverageSummary({required this.coverage});

  static double height(DashGeo g) => math.max(44.0, g.line(14) + g.line(12) + 6);

  @override
  Widget build(BuildContext context) {
    final c = coverage;
    final still = MediaQuery.disableAnimationsOf(context);
    final vs = c.valueShare;
    return Tooltip(
      message: c.definition,
      waitDuration: const Duration(milliseconds: 400),
      child: Semantics(
        container: true,
        label: '${c.items} of ${c.of} items on a count in ${c.year}${vs == null ? '' : ', holding ${_pct(vs)} of the stock value'}',
        child: ExcludeSemantics(
          child: Row(
            children: [
              SizedBox(
                width: 40,
                height: 40,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: still ? c.share : 0, end: c.share),
                  duration: still ? Duration.zero : const Duration(milliseconds: 1100),
                  curve: Curves.easeOutCubic,
                  builder: (context, p, _) => CustomPaint(
                    painter: _RingPainter(progress: p, color: DashUi.sky),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: FittedBox(child: Text('${(p * 100).round()}%', style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: DashUi.sky))),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(children: [
                        TextSpan(text: '${c.items} of ${c.of}', style: const TextStyle(fontWeight: FontWeight.w800, fontFeatures: DashText.tabular)),
                        TextSpan(text: ' items on a count in ${c.year}'),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DashText.name.copyWith(fontSize: 14),
                    ),
                    Text(
                      c.items == 0 ? 'None counted in ${c.year}' : (vs == null ? 'No stock value on record' : "They hold ${_pct(vs)} of the stock's value"),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DashText.meta.copyWith(color: c.items > 0 && vs != null && vs >= 0.9 ? DashUi.emeraldText : DashUi.subtle, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The rows of a list panel: they share the height they are given, up to [maxRow] each (a tall window leaves empty
/// panel under the list rather than rows with a hand's width of air between them).
class _ListRows extends StatelessWidget {
  final List<Widget> children;
  const _ListRows({required this.children});

  static const maxRow = 112.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) {
          final h = children.isEmpty || !c.maxHeight.isFinite ? maxRow : math.min(c.maxHeight / children.length, maxRow);
          return Align(
            alignment: Alignment.topCenter,
            child: Column(mainAxisSize: MainAxisSize.min, children: [for (final w in children) SizedBox(height: h, child: w)]),
          );
        },
      );
}

/// The zones in the height the panel has left: rows up to [_rowMax] each, beyond that a board of two columns whose cells
/// share the height, so a tall window has nothing to spread out.
class _ZoneList extends StatelessWidget {
  final List<_ZoneCount> zones;
  const _ZoneList({required this.zones});

  static const _rowMax = 84.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) {
          final n = zones.length;
          if (n < 3 || !c.maxHeight.isFinite || c.maxHeight / n <= _rowMax) {
            return _ListRows(children: [for (var i = 0; i < n; i++) _ZoneRow(zone: zones[i], index: i, divider: i > 0)]);
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < n; i += 2)
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final k in [i, i + 1])
                        Expanded(child: k < n ? _ZoneRow(zone: zones[k], index: k, divider: i > 0, leftDivider: k.isOdd, board: true) : const SizedBox.shrink()),
                    ],
                  ),
                ),
            ],
          );
        },
      );
}

class _ZoneRow extends StatelessWidget {
  final _ZoneCount zone;
  final int index;
  final bool divider;
  final bool leftDivider;

  /// A cell of the board: the status under the name instead of beside it.
  final bool board;
  const _ZoneRow({required this.zone, required this.index, required this.divider, this.leftDivider = false, this.board = false});

  @override
  Widget build(BuildContext context) {
    final z = zone;
    final color = z.complete ? DashUi.emeraldText : (z.overdue ? DashUi.redText : DashUi.amberText);
    final icon = z.complete ? Icons.check_circle_rounded : (z.overdue ? Icons.error_rounded : Icons.timelapse_rounded);
    final label = z.complete ? 'Complete' : (z.overdue ? 'Overdue' : z.status);
    final week = DateTime.tryParse(z.periodStart);
    final weekText = week == null ? '' : 'Week of ${_monthLetters[week.month - 1]} ${week.day}';
    final done = z.completedAt == null ? null : _shortDay(z.completedAt!.toIso8601String());
    final detail = z.complete
        ? '${done == null ? '' : '$done · '}${dashCount(z.counted, 'item')}'
        : (z.counted > 0 ? '${dashCount(z.counted, 'item')} so far' : 'Nothing counted yet');
    final still = MediaQuery.disableAnimationsOf(context);
    final total = 420 + index * 110;
    final name = Text(z.zone, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.name.copyWith(fontSize: board ? 16 : 14, fontWeight: FontWeight.w800));
    final weekLine = Text(weekText, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.meta);
    final statusIcon = _ZoneStatusIcon(icon: icon, color: color, overdue: z.overdue && !z.complete, complete: z.complete, index: index, size: board ? 28 : 20);
    final status = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.label.copyWith(fontSize: board ? 15 : null, fontWeight: FontWeight.w700, color: color));
    final detailLine = Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.meta);
    final row = Row(
      children: [
        statusIcon,
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [name, if (weekText.isNotEmpty) weekLine],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [status, detailLine],
        ),
      ],
    );
    final boardCell = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              statusIcon,
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [name, if (weekText.isNotEmpty) weekLine],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          status,
          detailLine,
        ],
      ),
    );
    return Semantics(
      container: true,
      label: '${z.zone}${weekText.isEmpty ? '' : ', $weekText'}: $label, $detail',
      child: ExcludeSemantics(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: still ? 1 : 0, end: 1),
          duration: still ? Duration.zero : Duration(milliseconds: total),
          builder: (context, t, child) {
            final p = Curves.easeOutCubic.transform(Interval(index * 110 / total, 1).transform(t));
            return Opacity(opacity: p, child: Transform.translate(offset: Offset(0, (1 - p) * 10), child: child));
          },
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                top: divider ? const BorderSide(color: DashUi.line) : BorderSide.none,
                left: leftDivider ? const BorderSide(color: DashUi.line) : BorderSide.none,
              ),
            ),
            child: _HoverTint(child: board ? boardCell : row),
          ),
        ),
      ),
    );
  }
}

/// A row of a list that lights up under the pointer: a faint wash fades in behind it, so the eye can follow a row
/// across to its figures.
class _HoverTint extends StatefulWidget {
  final Widget child;
  const _HoverTint({required this.child});

  @override
  State<_HoverTint> createState() => _HoverTintState();
}

class _HoverTintState extends State<_HoverTint> {
  bool _on = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _on = true),
        onExit: (_) => setState(() => _on = false),
        child: AnimatedContainer(
          duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 160),
          decoration: BoxDecoration(color: _on ? DashUi.faint : DashUi.faint.withValues(alpha: 0), borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: widget.child,
        ),
      );
}

/// A zone's status icon with a little life: a complete zone's check pops in after its row slides in, and an overdue
/// zone sends three red rings out of its icon to catch the eye, then settles. Nothing moves with reduced motion.
class _ZoneStatusIcon extends StatefulWidget {
  final IconData icon;
  final Color color;
  final bool overdue;
  final bool complete;
  final int index;
  final double size;
  const _ZoneStatusIcon({required this.icon, required this.color, required this.overdue, required this.complete, required this.index, this.size = 20});

  @override
  State<_ZoneStatusIcon> createState() => _ZoneStatusIconState();
}

class _ZoneStatusIconState extends State<_ZoneStatusIcon> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));
  Timer? _wait;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _wait?.cancel();
      _c.value = 1;
    } else if (_c.value == 0 && !_c.isAnimating && _wait == null) {
      // After the row's own entrance.
      _wait = Timer(Duration(milliseconds: 420 + widget.index * 110), () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, child) {
            final t = _c.value;
            final pop = widget.complete ? Curves.easeOutBack.transform((t / 0.25).clamp(0.0, 1.0)) : 1.0;
            return CustomPaint(
              painter: widget.overdue && t > 0 && t < 1 ? _RipplePainter(t: t, color: widget.color) : null,
              child: Transform.scale(scale: widget.complete ? 0.4 + 0.6 * pop : 1, child: child),
            );
          },
          child: Icon(widget.icon, size: widget.size, color: widget.color),
        ),
      );
}

/// Three rings rippling out of the middle of an icon, each fading as it grows.
class _RipplePainter extends CustomPainter {
  final double t;
  final Color color;
  const _RipplePainter({required this.t, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final f = Curves.easeOut.transform((t * 3) % 1);
    canvas.drawCircle(
      size.center(Offset.zero),
      size.width / 2 + 10 * f,
      Paint()
        ..color = color.withValues(alpha: 0.45 * (1 - f))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _RipplePainter old) => old.t != t || old.color != color;
}

// =============================================================================
// GRID (shared by the page and its skeleton)
// =============================================================================

/// Lays the page out to fit the window:
///   desktop    the scorecards (the team's inventory strikes last, as the dark team card); then the chart beside the
///              zones (1000 px wide and up)
///   narrower   everything in one column that scrolls, like the dashboards
class _WhGrid extends StatelessWidget {
  final List<_TileSpec> tiles;
  final Widget chart;
  final Widget zones;

  /// The zones' rows (what the list needs height for).
  final int rows;

  /// Placeholders instead of scorecards (the skeleton).
  final bool skeleton;
  const _WhGrid({required this.tiles, required this.chart, required this.zones, required this.rows, this.skeleton = false});

  static const _wideFrom = 1000.0;
  static const _minChart = 200.0;
  static const _tileGap = 12.0;

  Widget _tile(_TileSpec t, int index) => skeleton ? const DashSkeletonTile() : _KpiTile(spec: t, index: index);

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final body = c.maxHeight - g.tile - dashGap;
        // The taller of what has to fit beside each other: the zones at their smallest, and a chart.
        final minBody = math.max(_minChart, _ZonesPanel.minHeight(g, rows));
        final Widget content;
        if (w >= _wideFrom && c.maxHeight.isFinite && body >= minBody) {
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: g.tile,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < tiles.length; i++) ...[
                      if (i > 0) const SizedBox(width: _tileGap),
                      Expanded(child: _tile(tiles[i], i)),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: dashGap),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 3, child: chart),
                    const SizedBox(width: dashGap),
                    Expanded(flex: 2, child: zones),
                  ],
                ),
              ),
            ],
          );
        } else {
          final perRow = w >= 900 ? (tiles.length / 2).ceil() : (w >= 560 ? 2 : 1);
          final tileW = (w - _tileGap * (perRow - 1)) / perRow;
          final listH = _ZonesPanel.minHeight(g, rows) + 8;
          content = SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: _tileGap,
                  runSpacing: _tileGap,
                  children: [for (var i = 0; i < tiles.length; i++) SizedBox(width: tileW, height: g.tile, child: _tile(tiles[i], i))],
                ),
                const SizedBox(height: dashGap),
                SizedBox(height: 320, child: chart),
                const SizedBox(height: dashGap),
                SizedBox(height: listH, child: zones),
              ],
            ),
          );
        }
        return SizedBox(width: w, height: c.maxHeight, child: content);
      },
    );
  }
}

/// The page's shape while the first answer is on its way.
class _WhSkeleton extends StatelessWidget {
  const _WhSkeleton();

  @override
  Widget build(BuildContext context) {
    final placeholder = _TileSpec(title: '', value: null, format: (v) => '', captions: const [''], definition: '', color: DashUi.muted);
    return Semantics(
      label: 'Loading figures',
      child: ExcludeSemantics(
        child: SkeletonPulse(
          child: _WhGrid(
            skeleton: true,
            tiles: List.filled(7, placeholder),
            chart: const DashSkeletonPanel(fill: true),
            zones: const DashSkeletonPanel(fill: true),
            rows: 4,
          ),
        ),
      ),
    );
  }
}
