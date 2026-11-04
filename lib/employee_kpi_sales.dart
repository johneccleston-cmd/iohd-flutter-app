part of 'kpi_dashboard_screen.dart';

// =============================================================================
// SALES KPI PAGE (/hr/kpis/:username for the salespeople: Heather Vera, residential, and Zac Clemens, commercial)
// =============================================================================
//
// Built like the technician, warehouse and office pages (employee_kpi_tech.dart, employee_kpi_warehouse.dart,
// employee_kpi_office.dart) from the dashboards' kit: the dark title bar with a year picker and Refresh, a row of
// scorecards, then a chart that steps through its stories over the customer reviews and the year's largest deal, beside
// the open estimates, all on one screen without scrolling at desktop sizes (one scrolling column below 1000 px wide, like
// the dashboards). Every figure and animation the page had before is still here: rank, milestone and integrity score;
// morale with its heartbeat and Preview (in the title bar); close rate, sales won, gross profit and margin; stale
// estimates (with the on track / aging / stale split), estimates late to send (with the clock that runs faster the more
// there are), turnaround; Zac's inventory strikes; revenue and profit by month for each kind of estimate, close rate by
// month and Zac's estimate mix; the open-estimate pipeline in dollars; the largest deal with its confetti; and the
// customer reviews.
//
// Where each figure comes from: GET /api/employees/:username/kpis?year=Y, `sales` (the server sends it to the people in
// SALES_PEOPLE, by name). Everything is for estimates dated in the year picked and owned by this person (Opportunity
// Owner in Service Fusion), except the open estimates and the stale count: every estimate of theirs still open today,
// whatever its date, so they are the same whichever year is picked. The turnaround and late counts only take estimates
// created once the status history became trustworthy (Sep 10, 2026): a year before that has none, and the cards say so.

/// Everything the page shows for one year.
class _SalesPage {
  final int year;

  /// Null when this person owned no estimates dated in [year] (or the server sends no sales figures).
  final _SalesKpis? sales;
  final int inventoryStrikes;
  final _Rating? morale;

  /// The day limits behind "stale" and "late to send"; the server's defaults when it doesn't say.
  final int requestedDays;
  final int providedDays;
  final int turnaroundDays;
  final int hardBidDays;
  const _SalesPage({
    required this.year,
    required this.sales,
    required this.inventoryStrikes,
    required this.morale,
    this.requestedDays = 5,
    this.providedDays = 14,
    this.turnaroundDays = 3,
    this.hardBidDays = 14,
  });

  static _SalesPage parse(Map<String, dynamic> body, int year) {
    final bundle = _bundleFrom(body);
    final emp = body['employee'] is Map ? body['employee'] as Map : const {};
    final raw = body['sales'] is Map ? body['sales'] as Map : const {};
    final strikes = raw['strikes'] is Map ? raw['strikes'] as Map : const {};
    final limits = strikes['limits'] is Map ? strikes['limits'] as Map : const {};
    int limit(String key, int fallback) => int.tryParse(_str(limits[key])) ?? fallback;
    return _SalesPage(
      year: year,
      sales: bundle.sales,
      inventoryStrikes: int.tryParse(_str(emp['inventoryStrikes'])) ?? 0,
      morale: bundle.morale,
      requestedDays: limit('requestedDays', 5),
      providedDays: limit('providedDays', 14),
      turnaroundDays: limit('turnaroundDays', 3),
      hardBidDays: limit('hardBidDays', 14),
    );
  }

  bool get isCurrentYear => year == DashClock.now().year;
}

// =============================================================================
// THE PAGE
// =============================================================================

/// The title bar (back button, photo, name, title, time with the company, rank, milestone, integrity score and morale)
/// and the year picker; the content below loads the year picked.
class _SalesKpiPage extends StatefulWidget {
  final _EmployeeKpiArgs args;
  final String employeeId;
  const _SalesKpiPage({super.key, required this.args, required this.employeeId});

  @override
  State<_SalesKpiPage> createState() => _SalesKpiPageState();
}

class _SalesKpiPageState extends State<_SalesKpiPage> {
  final _ratings = _TechRatings(hasPeer: false);

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
      builder: (context, year) => _SalesKpiContent(user: user, employeeId: widget.employeeId, year: year, ratings: _ratings),
    );
  }
}

class _SalesKpiContent extends StatefulWidget {
  final _EmployeeUser user;
  final String employeeId;
  final int year;
  final _TechRatings ratings;
  const _SalesKpiContent({required this.user, required this.employeeId, required this.year, required this.ratings});

  @override
  State<_SalesKpiContent> createState() => _SalesKpiContentState();
}

/// Loads the figures the way the dashboards do (DashboardLoading): a skeleton on the first load, a refresh keeps the
/// figures on screen and the header says if it failed, an answer for an older request is ignored.
class _SalesKpiContentState extends State<_SalesKpiContent> {
  final _requests = DashRequests();
  _SalesPage? _data;
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
    widget.ratings.addListener(_onRatings);
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _freshness = DashFreshnessScope.maybeOf(context);
  }

  @override
  void dispose() {
    widget.ratings.removeListener(_onRatings);
    _requests.cancel();
    _freshness?.release(this);
    super.dispose();
  }

  /// The morale badge's Preview also fills in sample reviews while there are none.
  void _onRatings() {
    if (mounted) setState(() {});
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
      final p = await _requests.get('/api/employees/${Uri.encodeComponent(widget.employeeId)}/kpis', query: {'year': '${widget.year}'}, fresh: fresh);
      if (p == null || !mounted) return; // a newer request took over, or the page is gone
      final _SalesPage data;
      try {
        data = _SalesPage.parse(p.body, widget.year);
      } catch (_) {
        throw const DashLoadException(DashFailure.badData);
      }
      setState(() {
        _data = data;
        _loading = false;
        _busy = false;
        _updatedAt = p.generatedAt ?? p.receivedAt;
        _computedTime = p.generatedAt != null;
      });
      widget.ratings.set(null, data.morale); // nothing records a peer rating for salespeople yet
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
    if (_loading) return const _SalesSkeleton();
    final failure = _failure;
    if (failure != null) {
      return DashErrorPanel.failure(failure, what: "$_first's figures", onRetry: _load);
    }
    final data = _data!;
    if (data.sales == null) {
      return DashErrorPanel(
        title: data.isCurrentYear ? 'No estimates in ${data.year} yet' : 'No estimates in ${data.year}',
        // Three lines at most in the panel, so it stays short.
        message: '$_first owns no estimates dated in ${data.year} (as Opportunity Owner in Service Fusion). '
            '${data.isCurrentYear ? 'Refresh once some are recorded, or pick another year.' : 'Pick another year.'}',
        hint: null,
        icon: Icons.request_quote_outlined,
        // A finished year won't fill in, so only this year offers a refresh.
        onRetry: data.isCurrentYear ? () => _load(fresh: true) : null,
        retryLabel: 'Refresh',
      );
    }
    return _SalesBody(data: data, s: data.sales!, user: widget.user, first: _first, employeeId: widget.employeeId, sample: widget.ratings.sample);
  }
}

// =============================================================================
// SCORECARDS
// =============================================================================

class _SalesBody extends StatelessWidget {
  final _SalesPage data;
  final _SalesKpis s;
  final _EmployeeUser user;
  final String first;
  final String employeeId;
  final bool sample;
  const _SalesBody({required this.data, required this.s, required this.user, required this.first, required this.employeeId, required this.sample});

  static const _sampleReviews = [
    _Mention('Quick quote, clear pricing, and the new door looks great.', 'Sample customer', 'Sample'),
    _Mention('Answered every question and the install went exactly as promised.', 'Sample customer', 'Sample'),
  ];

  String get _name => user.name.trim().isEmpty ? 'Estimates' : user.name.trim();

  void _openList(BuildContext context, _EstimateListKind kind) => showDialog<void>(
        context: context,
        builder: (_) => _LateEstimatesDialog(employeeId: employeeId, name: _name, kind: kind, year: data.year),
      );

  @override
  Widget build(BuildContext context) {
    final year = data.year;
    final now = data.isCurrentYear;
    final period = dashPeriodLabel(year);
    final soFar = now ? 'so far' : 'in $year';
    // The status history is trusted from Sep 10, 2026, and turnaround and late to send only take estimates created from
    // then: a year before it has none ("not tracked", never a 0), its own year counts "since Sep 10", a later year all of it.
    final from = s.trackedFrom ?? DateTime(2026, 9, 10);
    final since = s.since ?? '${_monthLetters[from.month - 1]} ${from.day}';
    final sinceFull = '$since, ${from.year}';
    final untracked = year < from.year;
    final fromStart = year == from.year;
    final untrackedCaptions = ['Not tracked before $sinceFull', 'Not tracked in $year', 'Not tracked'];
    final untrackedWhy = 'Not tracked for $year: the status history only became reliable on $sinceFull.';
    final won = s.wonCount, lost = s.lostCount, closed = won + lost;
    final rates = _salesCloseRates(s, year);

    // --- Results: close rate, sales won, gross profit (with the margin). ---
    // The commercial estimator's hard bids on their own, when he has any decided.
    final bids = s.residential ? null : s.bids;
    final bidRate = bids?.closeRatePct;
    final bidText = bids == null || bidRate == null ? null : 'Hard bids ${_fmtNum(bidRate)}% (${bids.wonCount} of ${bids.wonCount + bids.lostCount})';
    final close = _TileSpec(
      title: 'Close rate',
      value: s.closeRatePct,
      format: (v) => '${_fmtNum(v)}%',
      captions: closed == 0
          ? ['Nothing won or lost $soFar']
          : [
              if (bids != null && bidText != null) ...['$won of $closed won · $bidText', '$won of $closed won · hard bids ${bids.wonCount} of ${bids.wonCount + bids.lostCount}'],
              '$won won of $closed closed · $period',
              '$won won of $closed closed',
              '$won of $closed won',
            ],
      definition: 'The estimates dated in $year that $first owns and that were won, as a share of those won or lost: $won of $closed (the Sales '
          'dashboard calls this the win rate). Estimates still open count neither way.${bidText == null ? '' : ' $bidText on their own.'} '
          'The line is each finished month\'s rate; a month with nothing decided keeps the month before\'s.',
      color: DashUi.indigo,
      trend: () {
        // Finished months only, one point a month from the first with anything decided (the month in progress, a few days
        // of answers, would end the line on a guess).
        final done = math.min(dashCompleteMonths(year), rates.length);
        final pts = <double>[];
        for (var m = 0; m < done; m++) {
          final r = rates[m] ?? (pts.isEmpty ? null : pts.last);
          if (r != null) pts.add(r);
        }
        return pts.length >= 2 ? pts : null;
      }(),
    );

    List<double> monthlyTotal(List<List<double>> all) => [for (var m = 0; m < 12; m++) all.fold<double>(0, (t, b) => t + (m < b.length ? b[m] : 0))];
    final wonValue = _TileSpec(
      title: 'Sales won',
      value: s.wonValue,
      format: _wholeMoney,
      captions: won == 0 ? ['Nothing won $soFar'] : ['${dashCount(won, 'estimate')} won · $period', '${dashCount(won, 'estimate')} won', '$won won'],
      definition: 'The value of the $won estimates dated in $year that $first owns (Opportunity Owner in Service Fusion) and that '
          'reached a won status. ${s.residential ? 'The Sales chart shows it month by month.' : 'The chart\'s Hard bids and Commercial views '
              'split it by kind of estimate; the Mix view has the rest.'}',
      color: DashUi.sky,
      trend: s.monthlyRevenue.isEmpty ? null : dashTrend(monthlyTotal(s.monthlyRevenue), year),
    );

    final margin = s.marginPct;
    // Won estimates without a profit figure add nothing to the profit and are left out of the margin, so every caption
    // says how many were left out when there are any. Ones worth $0 change neither side of the margin, so when every
    // left-out estimate is $0 (the won value all sits on priced estimates) nothing is said.
    final priced = s.wonWithProfit;
    final pricedValue = s.monthlyRevenueWithProfit.isEmpty
        ? null
        : s.monthlyRevenueWithProfit.expand((m) => m).fold<double>(0, (a, b) => a + b);
    final partial = priced != null && priced < won && (pricedValue == null || s.wonValue - pricedValue >= 1);
    final left = partial ? won - priced : 0;
    final profit = _TileSpec(
      title: 'Gross profit',
      value: s.grossProfit,
      format: _wholeMoney,
      captions: margin == null
          ? [won == 0 ? 'Nothing won $soFar' : 'No profit figures on the won estimates']
          : partial
              ? [
                  '${_fmtNum(margin)}% margin · $left won left out, no profit figure',
                  '${_fmtNum(margin)}% margin · $left won left out',
                  '${_fmtNum(margin)}% margin · $left left out',
                  '${_fmtNum(margin)}% · $left left out',
                ]
              : ['${_fmtNum(margin)}% margin · $period', '${_fmtNum(margin)}% margin', '${_fmtNum(margin)}%'],
      definition: 'The profit Service Fusion shows on the won estimates (quoted price minus estimated cost), not invoiced or collected.'
          '${!partial ? '' : priced == 0 ? ' None of the $won won estimates carries a profit figure${now ? ' yet' : ''}.' : ' Only $priced of the $won won '
              'estimates carry a profit figure; the other ${won - priced} add nothing to it, so it may read low.'}'
          '${margin == null ? '' : ' The margin is that profit as a share of the value of ${partial ? 'the $priced estimates that carry it' : 'the won estimates'} '
              '(${_fmtNum(margin)}%)${s.markupPct == null ? '.' : '; as a markup on cost it is ${_fmtNum(s.markupPct!)}%.'}'}',
      color: DashUi.blue,
      trend: s.monthlyProfit.isEmpty ? null : dashTrend(monthlyTotal(s.monthlyProfit), year),
    );

    // --- The negatives: stale, late to send, and how long sending takes. ---
    // Stale estimates are in the Open estimates panel (the counts, the dollars and the list).
    // An older server sent 0 for a year it couldn't measure; that is "not tracked" too.
    final late = untracked ? null : s.slowEstimates;
    final lateColor = late == null ? DashUi.muted : (late <= 15 ? DashUi.emeraldDeep : (late <= 25 ? DashUi.amber : DashUi.red));
    // The target in the caption (hard bids have their own), then the stretch it covers.
    final lateWhen = fromStart ? 'since $since' : period;
    final overTarget = 'Over ${dashCount(data.turnaroundDays, 'day')}${s.residential ? '' : ' (hard bids ${data.hardBidDays})'}';
    final lateTile = _TileSpec(
      title: 'Late to send',
      value: late?.toDouble(),
      format: (v) => '${v.round()}',
      captions: untracked
          ? untrackedCaptions
          : late == null
              ? ['Not available yet']
              : [
                  '$overTarget to send · $lateWhen',
                  '$overTarget · $lateWhen',
                  if (!s.residential) 'Over the target · $lateWhen',
                  fromStart ? 'Since $since' : period,
                ],
      definition: 'Estimates that took longer than the target to go from created to sent: ${data.turnaroundDays} days, or ${data.hardBidDays} for '
          'a hard bid. An estimate isn\'t counted if anything happened on it while it waited (a status change, a note or an edit in Service '
          'Fusion). ${untracked ? untrackedWhy : '${fromStart ? 'Only estimates created from $sinceFull count, when the status history became '
              'reliable. ' : ''}Select to open the list.'}',
      color: lateColor,
      trailing: late == null ? null : _LateClock(count: late),
      count: late ?? 0,
      noun: 'late estimate',
      onOpen: untracked ? null : () => _openList(context, _EstimateListKind.late),
    );

    final turn = untracked ? null : s.turnaround;
    final bidTurn = untracked ? null : s.bidTurnaround;
    final bid = s.residential ? null : bidTurn;
    String days(double v) => '${_fmtNum(v)} ${v == 1 ? 'day' : 'days'}';
    // Each kind against its own target (hard bids get more days), so hard bids taking their allowed time don't turn the
    // card amber. The other estimates' average comes out of the whole and the hard bids' (average x count).
    final restN = turn == null ? 0 : turn.count - (bidTurn?.count ?? 0);
    final restAvg = turn == null || restN <= 0
        ? null
        : (bidTurn == null ? turn.avgDays : math.max(0.0, (turn.avgDays * turn.count - bidTurn.avgDays * bidTurn.count) / restN));
    final onTarget = (restAvg == null || restAvg <= data.turnaroundDays) && (bidTurn == null || bidTurn.avgDays <= data.hardBidDays);
    final targets = [
      if (restAvg != null)
        bidTurn == null
            ? 'the average is ${data.turnaroundDays} days or less'
            : 'the estimates other than hard bids average ${data.turnaroundDays} days or less (${days((restAvg * 10).round() / 10)} over $restN)',
      if (bidTurn != null) 'hard bids ${data.hardBidDays} or less (${days(bidTurn.avgDays)} on average over ${bidTurn.count})',
    ];
    final turnTile = _TileSpec(
      title: 'Turnaround',
      value: turn?.avgDays,
      format: days,
      captions: turn == null
          ? (untracked ? untrackedCaptions : [fromStart ? 'Nothing sent since $since${now ? ' yet' : ''}' : 'Nothing sent $soFar'])
          : [
              // The commercial estimator's hard bids, which have their own target; on a narrow card they win over the median
              // (half were sent within it).
              if (bid != null) ...[
                'Half in ${days(turn.medianDays)} · hard bids average ${days(bid.avgDays)}',
                'Hard bids average ${days(bid.avgDays)}',
                'Hard bids avg ${days(bid.avgDays)}',
              ],
              'Half in ${days(turn.medianDays)} · ${dashCount(turn.count, 'estimate')} ${fromStart ? 'since $since' : soFar}',
              'Half sent within ${days(turn.medianDays)}',
              'Half within ${days(turn.medianDays)}',
              'Created to sent',
            ],
      definition: untracked
          ? 'The average days from an estimate being created to being sent. $untrackedWhy'
          : turn == null
              ? 'The average days from an estimate being created to being sent.'
                  '${fromStart ? ' Only estimates created from $sinceFull count, when the status history became reliable.' : ''}'
              : 'The average days from an estimate being created to first being sent (Estimate Provided), over the ${dashCount(turn.count, 'estimate')} '
                  '${fromStart ? 'created since $since' : 'created in $year'} and sent. Half took ${days(turn.medianDays)} or less. Each kind is held '
                  'to its own target: green when ${targets.join(' and ')}.',
      color: turn == null ? DashUi.muted : (onTarget ? DashUi.emeraldDeep : DashUi.amber),
    );

    final tiles = <_TileSpec>[close, wonValue, profit, lateTile, turnTile];
    // The commercial estimator installs too, so his inventory strikes stay on his page.
    if (!s.residential) {
      final n = data.inventoryStrikes;
      tiles.add(_TileSpec(
        title: 'Inventory strikes',
        value: n.toDouble(),
        format: (v) => '${v.round()}',
        captions: const ['All time · from the stock audit', 'All time'],
        definition: 'Days $first had checked out none of the day\'s job materials by 4 PM (8:30 AM before November 2026), found by the '
            'stock audit. An all-time count: nothing records when each one happened.',
        color: _strikeColor(n),
      ));
    }

    final reviews = s.mentions.isNotEmpty ? s.mentions : (sample ? _sampleReviews : const <_Mention>[]);
    return _SalesGrid(
      tiles: tiles,
      chart: _SalesChartPanel(s: s, year: year, first: first, employeeId: employeeId, name: _name),
      pipeline: _PipelinePanel(s: s, data: data, onOpen: () => _openList(context, _EstimateListKind.stale)),
      deal: s.largestDeal == null ? null : _BigDealCard(deal: s.largestDeal!, year: year),
      reviews: _ReviewsCard(
        mentions: reviews,
        rating: s.satisfaction ?? (reviews.isEmpty || s.mentions.isNotEmpty ? null : const _Rating(4.7, 22)),
        first: first,
        sample: s.mentions.isEmpty && sample,
      ),
      hasReviews: reviews.isNotEmpty,
    );
  }
}

/// Close rate (won / (won + lost)) per month of [year] that has begun, null for a month with nothing closed.
List<double?> _salesCloseRates(_SalesKpis s, int year) {
  final now = DashClock.now();
  final shown = year < now.year ? 12 : (year > now.year ? 0 : now.month);
  return [
    for (var m = 0; m < shown; m++)
      if (m < s.closeWon.length && m < s.closeLost.length && s.closeWon[m] + s.closeLost[m] > 0)
        s.closeWon[m] / (s.closeWon[m] + s.closeLost[m]) * 100
      else
        null,
  ];
}

/// The clock beside "Late to send": its hands run faster the more estimates went out late (still at none, and with
/// reduced motion), and faster again while the pointer is on the card.
class _LateClock extends StatefulWidget {
  final int count;
  const _LateClock({required this.count});

  @override
  State<_LateClock> createState() => _LateClockState();
}

class _LateClockState extends State<_LateClock> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<double> _turns = ValueNotifier(0); // minute-hand revolutions so far
  Duration _last = Duration.zero;
  bool _hovering = false;
  bool _still = false;

  double get _speed {
    final n = widget.count;
    if (n == 0 || _still) return 0;
    final base = n <= 15 ? 0.08 : (n <= 25 ? 0.25 : 0.7);
    return _hovering ? base * 2.5 : base;
  }

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      final dt = (elapsed - _last).inMicroseconds / 1e6;
      _last = elapsed;
      final v = _speed;
      if (v > 0) _turns.value += dt * v;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.disableAnimationsOf(context);
    // A clock with nothing late, or with reduced motion, stands still and asks for no frames.
    if (_still || widget.count == 0) {
      if (_ticker.isActive) _ticker.stop();
    } else if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _turns.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.count;
    final color = n <= 15 ? DashUi.emerald : (n <= 25 ? DashUi.amber : DashUi.red);
    return MouseRegion(
      opaque: false,
      onEnter: (_) => _hovering = true,
      onExit: (_) => _hovering = false,
      child: ExcludeSemantics(
        child: Center(
          child: SizedBox(
            width: 40,
            height: 40,
            child: RepaintBoundary(
              child: ValueListenableBuilder<double>(
                valueListenable: _turns,
                builder: (context, t, _) => CustomPaint(painter: _ClockPainter(turns: t, color: color)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// THE CHART: sales by month (by kind of estimate for commercial), close rate, and the estimate mix
// =============================================================================

/// One panel with a view for each story, behind a switch in the title row. It steps to the next view every 8 seconds,
/// holds while the pointer or the keyboard is on it, never moves with reduced motion, and a view picked by hand restarts
/// the wait. A residential salesperson sees Sales and Close rate; the commercial one sees hard bids and other commercial
/// work apart, the close rate and the mix of estimates.
class _SalesChartPanel extends StatefulWidget {
  final _SalesKpis s;
  final int year;
  final String first;
  final String employeeId;
  final String name;
  const _SalesChartPanel({required this.s, required this.year, required this.first, required this.employeeId, required this.name});

  @override
  State<_SalesChartPanel> createState() => _SalesChartPanelState();
}

class _SalesChartPanelState extends State<_SalesChartPanel> {
  static const _every = Duration(seconds: 8);
  int _view = 0;
  Timer? _timer;
  bool _pointerIn = false;
  bool _focused = false;

  /// (tab, what the view shows) in order.
  List<(String, String)> get _views => widget.s.residential
      ? const [('Sales', 'sales'), ('Close rate', 'close')]
      : const [('Hard bids', 'bids'), ('Commercial', 'commercial'), ('Close rate', 'close'), ('Mix', 'mix')];

  @override
  void initState() {
    super.initState();
    _restart();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _restart() {
    _timer?.cancel();
    _timer = Timer.periodic(_every, (_) {
      // Also still while the page is off screen (another branch of the app's tabs is showing): tickers are off there.
      if (!mounted || _pointerIn || _focused || MediaQuery.disableAnimationsOf(context) || !TickerMode.getValuesNotifier(context).value.enabled) return;
      setState(() => _view = (_view + 1) % _views.length);
    });
  }

  void _pick(int v) {
    setState(() => _view = v);
    _restart();
  }

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    final s = widget.s;
    final year = widget.year;
    final views = _views;
    final view = _view.clamp(0, views.length - 1);
    final kind = views[view].$2;
    final (title, note, tip) = switch (kind) {
      'sales' => ('Sales won', 'by estimate date', 'The value of the estimates won, by the month of the estimate\'s date, and the gross profit on them, for every kind of estimate.'),
      'bids' => ('Hard bids won', 'by estimate date', 'Hard bids (the Service Fusion category "Commercial Hard Bid") won, by the month of the estimate\'s date, and the gross profit on them.'),
      'commercial' => ('Other commercial won', 'by estimate date', 'Commercial estimates that are not hard bids, won, by the month of the estimate\'s date, and the gross profit on them.'),
      'close' => ('Close rate', 'by estimate date', 'Of the estimates dated each month that were won or lost, the share that was won. A month with nothing closed is a gap.'),
      _ => ('Estimate mix', dashPeriodLabel(year), 'Every estimate dated in $year by its Service Fusion category. Select a slice or a row to list the estimates.'),
    };
    final Widget content = switch (kind) {
      'sales' => _SalesMonthView(s: s, year: year, bucket: null, what: 'sales'),
      'bids' => _SalesMonthView(s: s, year: year, bucket: 0, what: 'hard bids'),
      'commercial' => _SalesMonthView(s: s, year: year, bucket: 1, what: 'other commercial work'),
      'close' => _CloseRateView(s: s, year: year),
      _ => _MixView(s: s, year: year, employeeId: widget.employeeId, name: widget.name),
    };
    final reduce = MediaQuery.disableAnimationsOf(context);
    return MouseRegion(
      onEnter: (_) => _pointerIn = true,
      onExit: (_) => _pointerIn = false,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (f) => _focused = f,
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
                      child: DashSegmented<int>(
                        value: view,
                        options: [for (var i = 0; i < views.length; i++) (i, views[i].$1)],
                        onChanged: _pick,
                        label: 'Chart view',
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          child: AnimatedSwitcher(
            duration: reduce ? Duration.zero : const Duration(milliseconds: 260),
            switchInCurve: Curves.easeOutCubic,
            layoutBuilder: (cur, prev) => Stack(fit: StackFit.expand, children: [...prev, ?cur]),
            child: KeyedSubtree(key: ValueKey(kind), child: content),
          ),
        ),
      ),
    );
  }
}

/// Sales as a question: how much was won, and was it worth it? The headline answers it (won, the profit on it, the margin)
/// and names the best month; under it each month is a bar of what was won with the profit on it drawn solid inside, its
/// figure over it, against the dashed average of the finished months with sales. [bucket] is one kind of estimate (0 hard
/// bids, 1 other commercial), or null for everything.
class _SalesMonthView extends StatelessWidget {
  final _SalesKpis s;
  final int year;
  final int? bucket;

  /// What the figures are, for the empty and callout lines ("hard bids").
  final String what;
  const _SalesMonthView({required this.s, required this.year, required this.bucket, required this.what});

  @override
  Widget build(BuildContext context) {
    if (s.monthlyRevenue.isEmpty) return const DashEmptyNote('Monthly figures are not available yet');
    final now = DashClock.now();
    final shown = year < now.year ? 12 : (year > now.year ? 0 : now.month);
    List<double> series(List<List<double>> all) => [
          for (var m = 0; m < shown; m++)
            bucket == null ? all.fold<double>(0, (t, b) => t + (m < b.length ? b[m] : 0)) : (bucket! < all.length && m < all[bucket!].length ? all[bucket!][m] : 0),
        ];
    final rev = series(s.monthlyRevenue);
    final prof = series(s.monthlyProfit);
    // A margin is profit over the won revenue on estimates that carry a profit figure, as on the scorecard; an older server
    // only has all won revenue, which reads lower when some won estimates have no profit figure.
    final priced = s.monthlyRevenueWithProfit.isEmpty ? rev : series(s.monthlyRevenueWithProfit);
    // Everything: the year's own totals and margin, so the headline matches the scorecards to the dollar.
    final totalRev = bucket == null ? s.wonValue : rev.fold<double>(0, (t, v) => t + v);
    final totalProf = bucket == null ? s.grossProfit : prof.fold<double>(0, (t, v) => t + v);
    final totalPriced = priced.fold<double>(0, (t, v) => t + v);
    final margin = bucket == null ? s.marginPct : (totalPriced > 0 ? totalProf / totalPriced * 100 : null);
    // The month in progress isn't a whole month, so the best month and the average (the dashboards' rule: the finished
    // months with sales in them) leave it out.
    final partial = year == now.year && shown > 0 ? shown - 1 : null;
    var best = -1;
    for (var m = 0; m < rev.length; m++) {
      if (m != partial && rev[m] > 0 && (best < 0 || rev[m] > rev[best])) best = m;
    }
    final String callout;
    Color calloutColor = DashUi.emeraldText;
    if (totalRev <= 0) {
      callout = year == now.year ? 'No $what won in $year yet' : 'No $what won in $year';
      calloutColor = DashUi.slate;
    } else {
      final share = s.wonValue > 0 && bucket != null ? ' · ${(totalRev / s.wonValue * 100).round()}% of everything won' : '';
      callout = best >= 0
          ? 'Best month: ${dashMonthNames[best]}, ${_wholeMoney(rev[best])} won$share'
          : (partial != null && rev[partial] > 0
              ? 'Only ${dashMonthNames[partial]} so far: ${_wholeMoney(rev[partial])} won$share'
              : '${_wholeMoney(totalRev)} won in $year$share');
    }
    final avg = dashFinishedAverage([for (var m = 0; m < 12; m++) m < rev.length ? rev[m] : 0.0], year);
    final average = totalRev <= 0 || avg <= 0 ? null : avg;
    final showPartial = partial != null && rev[partial] > 0;
    return Semantics(
      label: '${_wholeMoney(totalRev)} of $what won in $year, ${_wholeMoney(totalProf)} profit. $callout.',
      child: DashStoryFrame(
        headline: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            _StoryStat(totalRev, _wholeMoney, 'won', DashUi.ink),
            const SizedBox(width: 22),
            _StoryStat(totalProf, _wholeMoney, 'profit', DashUi.emeraldText),
            if (margin != null) ...[
              const SizedBox(width: 22),
              _StoryStat(margin, (v) => '${_fmtNum((v * 10).round() / 10)}%', 'margin', DashUi.blue),
            ],
          ],
        ),
        callout: callout,
        calloutColor: calloutColor,
        chart: totalRev <= 0
            ? DashEmptyNote(callout)
            : DashMonthBars(
                values: [for (var m = 0; m < 12; m++) m < rev.length ? rev[m] : null],
                inner: [for (var m = 0; m < 12; m++) m < prof.length ? prof[m] : null],
                innerColor: DashUi.emerald,
                year: year,
                partial: partial,
                average: average,
                best: best < 0 ? null : best,
                color: DashUi.sky,
                labelFormat: _barMoney,
                detail: (m) => [
                  if (m < prof.length) 'Profit ${_wholeMoney(prof[m])}${priced[m] > 0 ? ' · ${(prof[m] / priced[m] * 100).round()}% margin' : ''}',
                ],
                label: '${what[0].toUpperCase()}${what.substring(1)} won by month, $year',
              ),
        legend: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            dashKeyItem(dashKeyBox(DashUi.sky), 'Value won'),
            const SizedBox(width: 16),
            dashKeyItem(dashKeyBox(DashUi.emerald), 'Gross profit'),
            if (showPartial) ...[
              const SizedBox(width: 16),
              dashKeyItem(dashKeyBox(DashUi.sky.withValues(alpha: 0.35), border: DashUi.sky), '${dashMonthNames[partial]} so far'),
            ],
            if (average != null) ...[const SizedBox(width: 16), dashKeyItem(dashDashedKey(), 'Average month with sales')],
            if (best >= 0) ...[const SizedBox(width: 16), dashKeyItem(dashDiamondKey(), 'Best month')],
          ],
        ),
      ),
    );
  }
}

/// A bar's figure: "$137k", "$8.5k", "$1.2M".
String _barMoney(double v) {
  if (v.abs() >= 1000000) return '\$${(v / 1000000).toStringAsFixed(1)}M';
  if (v.abs() >= 10000) return '\$${(v / 1000).round()}k';
  if (v.abs() >= 1000) return '\$${(v / 1000).toStringAsFixed(1)}k';
  return '\$${v.round()}';
}

/// Close rate as a question: of the estimates that were decided, how many were won? The headline answers it (the rate,
/// won, lost) and names the best and lowest whole month with at least three decided; under it each month's rate is a bar
/// out of 100% with its figure over it, against the dashed line of the year's rate. A month with nothing won or lost has
/// no bar.
class _CloseRateView extends StatelessWidget {
  final _SalesKpis s;
  final int year;
  const _CloseRateView({required this.s, required this.year});

  @override
  Widget build(BuildContext context) {
    if (s.closeWon.isEmpty) return const DashEmptyNote('Monthly close rates are not available yet');
    final rates = _salesCloseRates(s, year);
    final won = s.wonCount, lost = s.lostCount;
    final now = DashClock.now();
    final thisYear = year == now.year;
    final partial = thisYear && rates.isNotEmpty ? rates.length - 1 : null;
    // Best and lowest only among whole months with enough decided to mean something: one won of one is not a 100% month,
    // and the month in progress has only its first answers.
    const enough = 3;
    int n(int k) => s.closeWon[k] + s.closeLost[k];
    var best = -1, worst = -1;
    for (var m = 0; m < rates.length; m++) {
      final r = rates[m];
      if (r == null || m == partial || n(m) < enough) continue;
      // Ties go to the month with more estimates decided.
      if (best < 0 || r > rates[best]! || (r == rates[best]! && n(m) > n(best))) best = m;
      if (worst < 0 || r < rates[worst]! || (r == rates[worst]! && n(m) > n(worst))) worst = m;
    }
    final anyDecided = rates.any((r) => r != null);
    String month(int m) => '${dashMonthNames[m]}, ${_fmtNum(rates[m]!)}% (${s.closeWon[m]} of ${n(m)})';
    final String callout;
    Color calloutColor = DashUi.emeraldText;
    if (!anyDecided) {
      callout = 'No estimates were won or lost in $year${thisYear ? ' yet' : ''}';
      calloutColor = DashUi.slate;
    } else if (best < 0) {
      callout = 'No whole month has $enough or more estimates decided${thisYear ? ' yet' : ''}';
      calloutColor = DashUi.slate;
    } else if (best == worst) {
      callout = 'Only ${dashMonthNames[best]} has $enough or more decided: ${_fmtNum(rates[best]!)}% won (${s.closeWon[best]} of ${n(best)})';
    } else {
      callout = 'Best month: ${month(best)} · lowest: ${month(worst)}';
    }
    final rate = s.closeRatePct;
    final showPartial = partial != null && rates[partial] != null;
    String pct(double v) => '${v.round()}%';
    return Semantics(
      label: '${rate == null ? 'No' : '${_fmtNum(rate)}%'} close rate in $year, $won won, $lost lost. $callout.',
      child: DashStoryFrame(
        headline: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            if (rate != null) ...[
              _StoryStat(rate, (v) => '${_fmtNum((v * 10).round() / 10)}%', 'won', DashUi.indigo),
              const SizedBox(width: 22),
            ],
            _StoryStat(won.toDouble(), (v) => '${v.round()}', won == 1 ? 'estimate won' : 'estimates won', DashUi.emeraldText),
            const SizedBox(width: 22),
            _StoryStat(lost.toDouble(), (v) => '${v.round()}', 'lost', DashUi.redText),
          ],
        ),
        callout: callout,
        calloutColor: calloutColor,
        chart: !anyDecided
            ? DashEmptyNote('No closed estimates in $year')
            : DashMonthBars(
                values: [for (var m = 0; m < 12; m++) m < rates.length ? rates[m] : null],
                year: year,
                partial: partial,
                average: rate,
                best: best < 0 ? null : best,
                color: DashUi.indigo,
                maxValue: 100,
                format: (v) => '${_fmtNum(v)}% won',
                axisFormat: pct,
                labelFormat: pct,
                compare: false,
                detail: (m) => ['${s.closeWon[m]} won, ${s.closeLost[m]} lost'],
                label: 'Close rate by month, $year',
              ),
        legend: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            dashKeyItem(dashKeyBox(DashUi.indigo), 'Share of decided estimates won'),
            if (showPartial) ...[
              const SizedBox(width: 16),
              dashKeyItem(dashKeyBox(DashUi.indigo.withValues(alpha: 0.35), border: DashUi.indigo), '${dashMonthNames[partial]} so far'),
            ],
            if (rate != null) ...[const SizedBox(width: 16), dashKeyItem(dashDashedKey(), 'The year\'s rate, ${pct(rate)}')],
          ],
        ),
      ),
    );
  }
}

/// The estimate mix as a question: what kind of work is being quoted, and which kind turns into sales? The headline
/// names the biggest kind and its share. Under it the donut (it sweeps round; hover a slice to see its share) beside a
/// row for each kind, laid out like the open estimates: how many were quoted with a bar of their share, and how many were
/// won and for how much. Select a slice or a row to list those estimates.
class _MixView extends StatefulWidget {
  final _SalesKpis s;
  final int year;
  final String employeeId;
  final String name;
  const _MixView({required this.s, required this.year, required this.employeeId, required this.name});

  @override
  State<_MixView> createState() => _MixViewState();
}

class _MixViewState extends State<_MixView> {
  static const _colors = [DashUi.indigo, DashUi.sky, DashUi.emerald, DashUi.amber];
  int? _hover;

  void _setHover(int? k) {
    if (k != _hover) setState(() => _hover = k);
  }

  void _open(int bucket) => showDialog<void>(
        context: context,
        builder: (_) => _MixEstimatesDialog(
          employeeId: widget.employeeId,
          name: widget.name,
          bucket: bucket,
          label: _mixLabels[bucket],
          color: _colors[bucket],
          withOther: widget.s.residential,
          year: widget.year,
        ),
      );

  /// Which slice a point (relative to the donut's box) is over, or null for the hole and outside.
  static int? _slice(Offset p, double size, List<int> counts) {
    final total = counts.fold<int>(0, (a, b) => a + b);
    if (total == 0) return null;
    final d = p - Offset(size / 2, size / 2);
    final r = _MixPiePainter.radiusFor(size);
    final half = _MixPiePainter.strokeFor(size) / 2 + 4;
    if (d.distance < r - half || d.distance > r + half) return null;
    var a = math.atan2(d.dx, -d.dy); // 0 at 12 o'clock, clockwise
    if (a < 0) a += 2 * math.pi;
    var edge = 0.0;
    for (var k = 0; k < counts.length; k++) {
      edge += counts[k] / total * 2 * math.pi;
      if (counts[k] > 0 && a < edge) return k;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final year = widget.year;
    final counts = [0, 0, 0, 0];
    final won = [0, 0, 0, 0];
    final wonValue = [0.0, 0.0, 0.0, 0.0];
    for (final t in s.byType) {
      final k = _mixBucket(t.type);
      counts[k] += t.estimates;
      won[k] += t.wonCount;
      wonValue[k] += t.wonValue;
    }
    final total = counts.fold<int>(0, (a, b) => a + b);
    final yet = year == DashClock.now().year ? ' yet' : '';
    if (total == 0) return DashEmptyNote('No estimates dated in $year$yet');
    var top = 0;
    for (var k = 1; k < 4; k++) {
      if (counts[k] > counts[top]) top = k;
    }
    // Whole percentages that add up to 100, and "<1%" for a kind that is there but rounds to nothing.
    final shares = dashShares(counts);
    String pct(int k) => dashShareLabel(shares[k], counts[k]);
    final share = shares[top].toDouble();
    // The kind that brought in the most sales, when it isn't the one quoted most.
    int? earner;
    for (var k = 0; k < 4; k++) {
      if (wonValue[k] > 0 && (earner == null || wonValue[k] > wonValue[earner])) earner = k;
    }
    // "Most" only for more than half; a tie for the top names every kind in it.
    final topName = [for (var k = 0; k < 4; k++) if (counts[k] == counts[top]) _mixLabels[k].toLowerCase()].join(' and ');
    final quoted = counts[top] * 2 > total
        ? 'Most are $topName: ${counts[top]} of $total'
        : counts[top] * 2 == total
            ? 'Half are $topName: ${counts[top]} of $total'
            : 'Largest group: $topName, ${counts[top]} of $total${topName.contains(' and ') ? ' each' : ''}';
    final totalWon = wonValue.fold<double>(0, (a, b) => a + b);
    final sold = earner == null || earner == top
        ? ''
        : wonValue[earner] * 2 > totalWon
            ? ' · most sales from ${_mixLabels[earner].toLowerCase()}: ${_wholeMoney(wonValue[earner])}'
            : ' · biggest earner: ${_mixLabels[earner].toLowerCase()}, ${_wholeMoney(wonValue[earner])}';
    final g = DashGeo.of(context);
    final still = MediaQuery.disableAnimationsOf(context);

    Widget donut(double size) {
      final h = _hover;
      final center = h == null
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$total', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: DashUi.ink, height: 1.05, fontFeatures: DashText.tabular)),
                Text('estimates', style: DashText.meta.copyWith(fontWeight: FontWeight.w700, color: DashUi.slate)),
              ],
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(pct(h), style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: _colors[h], height: 1.05, fontFeatures: DashText.tabular)),
                Text('${counts[h]} of $total', style: DashText.meta.copyWith(fontWeight: FontWeight.w700, color: DashUi.slate)),
              ],
            );
      return MouseRegion(
        cursor: _hover != null ? SystemMouseCursors.click : MouseCursor.defer,
        onHover: (e) => _setHover(_slice(e.localPosition, size, counts)),
        onExit: (_) => _setHover(null),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            final k = _slice(d.localPosition, size, counts);
            if (k != null) _open(k);
          },
          child: SizedBox(
            width: size,
            height: size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: still ? 1 : 0, end: 1),
                  duration: still ? Duration.zero : const Duration(milliseconds: 1000),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, _) => CustomPaint(size: Size(size, size), painter: _MixPiePainter(counts: counts, colors: _colors, progress: t, hover: h)),
                ),
                IgnorePointer(child: SizedBox(width: size * 0.5, height: size * 0.4, child: FittedBox(fit: BoxFit.scaleDown, child: center))),
              ],
            ),
          ),
        ),
      );
    }

    final rows = [
      for (var k = 0; k < 4; k++)
        _RowSpec(
          name: _mixLabels[k],
          tip: counts[k] == 0
              ? 'No ${_mixLabels[k].toLowerCase()} dated in $year.'
              : '${counts[k]} of the $total estimates dated in $year. ${won[k] == 0 ? 'None won$yet.' : '${won[k]} won, worth ${_wholeMoney(wonValue[k])}.'} Select to list them.',
          figure: counts[k].toDouble(),
          format: (v) => '${v.round()}',
          figureColor: counts[k] == 0 ? DashUi.subtle : DashUi.ink,
          sub: pct(k),
          note: counts[k] == 0 ? 'None quoted' : (won[k] == 0 ? 'None won$yet' : '${won[k]} won · ${_compactMoney(wonValue[k])}'),
          noteColor: won[k] == 0 ? DashUi.subtle : DashUi.emeraldText,
          fraction: counts[k] / total,
          color: _colors[k],
          health: k,
          onTap: counts[k] == 0 ? null : () => _open(k),
        ),
    ];

    return Semantics(
      label: '$total estimates in $year. $quoted$sold. '
          '${[for (var k = 0; k < 4; k++) if (counts[k] > 0) '${_mixLabels[k]}: ${counts[k]}, ${won[k]} won'].join('; ')}.',
      child: DashStoryFrame(
        headline: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            _StoryStat(total.toDouble(), (v) => '${v.round()}', total == 1 ? 'estimate' : 'estimates', DashUi.ink),
            const SizedBox(width: 22),
            _StoryStat(share, (v) => '${v.round()}%', _mixLabels[top].toLowerCase(), DashUi.indigo),
          ],
        ),
        callout: '$quoted$sold',
        calloutColor: DashUi.slate,
        chart: LayoutBuilder(
          builder: (context, c) {
            final scale = MediaQuery.textScalerOf(context);
            final rowShort = g.line(13.5) + 6;
            final rowTall = g.line(13.5) + 5 + g.line(12) + 6;
            final showDonut = c.maxWidth >= 520 && c.maxHeight >= 120;
            final size = showDonut ? math.min(math.min(c.maxHeight, 240.0), c.maxWidth * 0.34) : 0.0;
            final rowsW = c.maxWidth - (showDonut ? size + 32 : 0);
            final rowsH = math.max(c.maxHeight, 4 * rowShort);
            final rowH = math.min(72.0, rowsH / 4);
            final tall = rowH >= rowTall;
            final list = SizedBox(
              width: rowsW,
              height: rowsH,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var k = 0; k < 4; k++)
                    SizedBox(
                      height: rowH,
                      child: _PipelineRow(
                        spec: rows[k],
                        index: k,
                        tall: tall,
                        nameWidth: math.min(scale.scale(170), rowsW * 0.36),
                        subWidth: scale.scale(44),
                        hover: _hover,
                        onHover: _setHover,
                      ),
                    ),
                ],
              ),
            );
            return ExcludeSemantics(
              child: Row(
                children: [
                  if (showDonut) ...[donut(size), const SizedBox(width: 32)],
                  // A very short chart shrinks the rows rather than cutting them.
                  Expanded(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: list)),
                ],
              ),
            );
          },
        ),
        legend: dashKeyItem(const Icon(Icons.touch_app_outlined, size: 14, color: DashUi.subtle), 'Select a slice or a row to list those estimates'),
      ),
    );
  }
}

// =============================================================================
// OPEN ESTIMATES
// =============================================================================

/// The open estimates (every one still open today, whatever its date) as a question: how much work is still open, and is
/// it still alive? The headline answers it in dollars, the bar under it splits them into still moving and gone quiet,
/// and the ring beside them splits the estimates by health. Then a row for each health (on track, aging, stale: select
/// Stale to list them) and each stage (not sent yet, sent and waiting for a reply), each with a bar of its share that
/// grows in, one after another. Hovering a health row or a slice of the ring lifts both.
class _PipelinePanel extends StatefulWidget {
  final _SalesKpis s;
  final _SalesPage data;
  final VoidCallback onOpen;
  const _PipelinePanel({required this.s, required this.data, required this.onOpen});

  static const _gap = 12.0;
  static double _headH(DashGeo g) => g.line(22, 1.1) + g.line(12) + 4;
  static double _dollarsH(DashGeo g) => g.line(12.5) + 6 + 12;

  /// A row on one line (a short window); from [_rowTall] up, the figures sit over the bar.
  static double _rowShort(DashGeo g) => g.line(13.5) + 6;
  static double _rowTall(DashGeo g) => g.line(13.5) + 5 + 8 + 10;
  static const _divider = 13.0;

  /// The panel at its smallest: the headline over the dollar bar, then five one-line rows.
  static double minHeight(DashGeo g) => g.panelTop + _headH(g) + _gap + _dollarsH(g) + _gap + 5 * _rowShort(g) + _divider;

  @override
  State<_PipelinePanel> createState() => _PipelinePanelState();
}

const _healthColors = [DashUi.emerald, DashUi.amber, DashUi.red];
const _healthNames = ['On track', 'Aging', 'Stale'];

class _PipelinePanelState extends State<_PipelinePanel> {
  /// The health (0 on track, 1 aging, 2 stale) under the pointer, on the ring or its row.
  int? _hover;

  static Color _text(int k) => k == 0 ? DashUi.emeraldText : (k == 1 ? DashUi.amberText : DashUi.redText);

  void _setHover(int? k) {
    if (k != _hover) setState(() => _hover = k);
  }

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    final s = widget.s;
    final data = widget.data;
    final p = s.pipeline;
    final open = p?.count ?? s.openEstimates ?? 0;
    final stale = (s.staleEstimates ?? 0).clamp(0, open);
    final aging = (s.agingEstimates ?? 0).clamp(0, open - stale);
    final onTrack = open - stale - aging;
    final counts = [onTrack, aging, stale];
    final value = p?.value ?? 0;
    final quiet = p?.quietValue ?? 0;
    final active = p?.activeValue ?? 0;

    // Each part says one thing: the headline the open dollars, the bar under it how much of them has gone quiet, the
    // ring the count split by health (the rows give each count and share). An older server with no dollars has the
    // count in the headline and the finding in words, with the stale share in the ring.
    final String callout;
    Color calloutColor = DashUi.emeraldText;
    if (open == 0) {
      callout = 'No open estimates today';
      calloutColor = DashUi.slate;
    } else if (stale == 0) {
      callout = 'Every open estimate is still moving';
    } else {
      callout = p == null ? '${dashCount(stale, 'estimate')} have gone quiet' : '${_compactMoney(quiet)} of it has gone quiet';
      calloutColor = DashUi.redText;
    }

    final action = Semantics(
      button: true,
      label: 'View the list of stale estimates',
      child: DashPressable(
        onTap: widget.onOpen,
        label: 'View the list of stale estimates',
        radius: BorderRadius.circular(8),
        builder: (hover) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.list_alt_rounded, size: 16, color: DashUi.blue),
              const SizedBox(width: 4),
              Text('Stale list', style: DashText.link.copyWith(fontSize: 12.5, fontWeight: FontWeight.w700, decoration: hover ? TextDecoration.underline : null)),
            ],
          ),
        ),
      ),
    );

    final stat = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: p != null
          ? _StoryStat(value, _wholeMoney, 'open', DashUi.ink)
          : _StoryStat(open.toDouble(), (v) => '${v.round()}', open == 1 ? 'estimate' : 'estimates', DashUi.ink),
    );
    final headline = p != null
        ? SizedBox(height: g.line(22, 1.1), child: stat)
        : SizedBox(
            height: _PipelinePanel._headH(g),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: stat),
                Text(callout, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.meta.copyWith(fontWeight: FontWeight.w700, color: calloutColor)),
              ],
            ),
          );

    // As tall as the headline, its finding and the dollar bar were together, but never so big that it squeezes their words;
    // the headline and the bar sit level with its middle.
    final ringSize = math.min(92.0, _PipelinePanel._headH(g) + (p == null ? 0 : _PipelinePanel._gap + _PipelinePanel._dollarsH(g)));
    final top = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              headline,
              if (p != null) ...[
                const SizedBox(height: _PipelinePanel._gap),
                SizedBox(height: _PipelinePanel._dollarsH(g), child: _DollarBar(active: active, quiet: quiet)),
              ],
            ],
          ),
        ),
        const SizedBox(width: 18),
        _HealthRing(counts: counts, size: ringSize, hover: _hover, onHover: _setHover, onOpenStale: widget.onOpen, showTotal: p != null),
      ],
    );

    // Whole percentages that add up to 100 (the ring's middle uses the same), "<1%" for a sliver.
    final shares = dashShares(counts);
    String share(int k) => open == 0 ? '' : dashShareLabel(shares[k], counts[k]);
    const tips = [
      'Still inside the time its stage allows, with room to spare.',
      'Past half the time its stage allows: worth a nudge soon.',
      'No activity for longer than its stage allows: gone quiet.',
    ];
    final rows = <_RowSpec>[
      for (var k = 0; k < 3; k++)
        _RowSpec(
          name: _healthNames[k],
          tip: '${tips[k]} ${data.requestedDays} days unsent (${data.hardBidDays} for a hard bid); ${data.providedDays} days after it was sent.',
          figure: counts[k].toDouble(),
          format: (v) => '${v.round()}',
          figureColor: _text(k),
          sub: share(k),
          fraction: open == 0 ? 0 : counts[k] / open,
          color: _healthColors[k],
          health: k,
          onTap: k == 2 && stale > 0 ? widget.onOpen : null,
        ),
      if (p != null) ...[
        _RowSpec(
          name: 'Not sent yet',
          tip: 'Asked for (Estimate Requested) but not sent to the customer yet.',
          figure: p.requestedValue,
          format: _wholeMoney,
          figureColor: DashUi.ink,
          sub: dashCount(p.requestedCount, 'estimate'),
          fraction: value <= 0 ? 0 : p.requestedValue / value,
          color: DashUi.indigo,
        ),
        _RowSpec(
          name: 'Sent, awaiting a reply',
          tip: 'Sent to the customer (Estimate Provided or Estimate Follow Up) and waiting on a yes or no.',
          figure: p.providedValue,
          format: _wholeMoney,
          figureColor: DashUi.ink,
          sub: dashCount(p.providedCount, 'estimate'),
          fraction: value <= 0 ? 0 : p.providedValue / value,
          color: DashUi.sky,
        ),
      ],
    ];

    return DashPanel(
      fill: true,
      header: DashPanelHeader(
        g: g,
        title: 'Open estimates',
        // Every estimate open today, whatever year it is dated, so the same whichever year is picked.
        note: 'all open · today',
        tooltip: 'Every estimate still open today, whatever its date: not sent yet (Estimate Requested), or sent and waiting on a yes or no '
            '(Estimate Provided or Estimate Follow Up). The same whichever year is picked. '
            '"Stale" means no activity for longer than the stage allows (${data.requestedDays} days unsent, ${data.hardBidDays} for a hard bid; '
            '${data.providedDays} days after it was sent); "aging" ones are past half that. Select Stale to list the stale ones.',
        trailing: open == 0 ? null : action,
      ),
      child: open == 0
          ? const DashEmptyNote('No open estimates today')
          : Semantics(
              label: '${p == null ? '' : '${_wholeMoney(value)} in '}${dashCount(open, 'open estimate')}. $callout. $onTrack on track, $aging aging, $stale stale.'
                  '${p == null ? '' : ' ${p.requestedCount} not sent yet, ${p.providedCount} sent and awaiting a reply.'}',
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    top,
                    const SizedBox(height: _PipelinePanel._gap),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, c) {
                          final n = rows.length;
                          final divider = n > 3 ? _PipelinePanel._divider : 0.0;
                          final rowH = math.max(_PipelinePanel._rowShort(g), math.min(64.0, (c.maxHeight - divider) / n));
                          final tall = rowH >= _PipelinePanel._rowTall(g);
                          final scale = MediaQuery.textScalerOf(context);
                          final nameWidth = math.min(scale.scale(156), c.maxWidth * 0.36);
                          final subWidth = scale.scale(80);
                          Widget row(int i) => SizedBox(
                                height: rowH,
                                child: _PipelineRow(spec: rows[i], index: i, tall: tall, nameWidth: nameWidth, subWidth: subWidth, hover: _hover, onHover: _setHover),
                              );
                          return Column(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var i = 0; i < math.min(3, n); i++) row(i),
                              if (n > 3) ...[
                                const SizedBox(height: _PipelinePanel._divider, child: Center(child: Divider(height: 1, thickness: 1, color: DashUi.line))),
                                for (var i = 3; i < n; i++) row(i),
                              ],
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// One row of the open estimates: what it is, its figure and a smaller note, and a bar of its share.
class _RowSpec {
  final String name;
  final String tip;
  final double figure;
  final String Function(double) format;
  final Color figureColor;
  final String sub;
  final double fraction;
  final Color color;

  /// A second figure in words at the right of the bar ("2 won · $30.1k"), when the row has one.
  final String? note;
  final Color noteColor;

  /// The slice this row is linked with on its ring or donut (hovering one lifts the other); null for none.
  final int? health;
  final VoidCallback? onTap;
  const _RowSpec({
    required this.name,
    required this.tip,
    required this.figure,
    required this.format,
    required this.figureColor,
    required this.sub,
    required this.fraction,
    required this.color,
    this.note,
    this.noteColor = DashUi.slate,
    this.health,
    this.onTap,
  });
}

/// A row like the Collections dashboard's stages: the name and the figure (counting up) over a bar that grows in after
/// the rows above it; in a short window all on one line. A row that opens a list has a chevron and lifts on hover.
class _PipelineRow extends StatelessWidget {
  final _RowSpec spec;
  final int index;
  final bool tall;
  final int? hover;
  final ValueChanged<int?> onHover;
  /// The name column's width on a one-line row, the same for every row so the bars line up.
  final double nameWidth;

  /// The note's column at the right (the share or the count), for the same reason.
  final double subWidth;
  const _PipelineRow({required this.spec, required this.index, required this.tall, required this.nameWidth, required this.subWidth, required this.hover, required this.onHover});

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final k = spec.health;
    final lit = k != null && hover == k;
    final dim = k != null && hover != null && hover != k;
    final name = Tooltip(
      message: spec.tip,
      waitDuration: const Duration(milliseconds: 500),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: lit ? 12 : 9,
            height: lit ? 12 : 9,
            decoration: BoxDecoration(color: spec.color, borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              spec.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DashText.name.copyWith(fontSize: 13.5, fontWeight: lit ? FontWeight.w800 : FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    final figure = TweenAnimationBuilder<double>(
      tween: Tween(begin: still ? spec.figure : 0, end: spec.figure),
      duration: still ? Duration.zero : const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => Text(
        spec.format(v),
        maxLines: 1,
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, height: 1.1, color: spec.figureColor, fontFeatures: DashText.tabular),
      ),
    );
    final sub = Text(spec.sub, maxLines: 1, style: DashText.meta.copyWith(fontFeatures: DashText.tabular));
    final bar = ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Container(
        height: tall ? 8 : 7,
        color: DashUi.faint,
        alignment: Alignment.centerLeft,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: still ? 1 : 0, end: 1),
          duration: still ? Duration.zero : const Duration(milliseconds: 1100),
          curve: Interval(math.min(0.5, index * 0.08), 1, curve: Curves.easeOutCubic),
          builder: (context, t, _) => FractionallySizedBox(
            widthFactor: (spec.fraction * t).clamp(0.0, 1.0),
            heightFactor: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                gradient: LinearGradient(colors: [spec.color, Color.lerp(spec.color, Colors.white, 0.25)!]),
              ),
            ),
          ),
        ),
      ),
    );
    final note = spec.note == null
        ? null
        : SizedBox(
            width: MediaQuery.textScalerOf(context).scale(124),
            child: Align(
              alignment: Alignment.centerRight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(spec.note!, maxLines: 1, style: DashText.meta.copyWith(fontWeight: FontWeight.w700, color: spec.noteColor)),
              ),
            ),
          );
    final chevron = SizedBox(
      width: 20,
      child: spec.onTap == null ? null : const Icon(Icons.chevron_right_rounded, size: 18, color: DashUi.subtle),
    );
    final Widget body = tall
        ? Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(child: Align(alignment: Alignment.centerLeft, child: name)),
                        const SizedBox(width: 8),
                        figure,
                        if (note != null) SizedBox(width: subWidth, child: Align(alignment: Alignment.centerRight, child: sub)),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Expanded(child: bar),
                        const SizedBox(width: 10),
                        note ?? ConstrainedBox(constraints: BoxConstraints(minWidth: subWidth), child: Align(alignment: Alignment.centerRight, widthFactor: 1, child: sub)),
                      ],
                    ),
                  ],
                ),
              ),
              chevron,
            ],
          )
        : Row(
            children: [
              SizedBox(width: nameWidth, child: Align(alignment: Alignment.centerLeft, child: name)),
              const SizedBox(width: 8),
              Expanded(child: bar),
              const SizedBox(width: 10),
              FittedBox(fit: BoxFit.scaleDown, child: figure),
              SizedBox(width: subWidth, child: Align(alignment: Alignment.centerRight, child: FittedBox(fit: BoxFit.scaleDown, child: sub))),
              if (note != null) ...[const SizedBox(width: 6), note],
              chevron,
            ],
          );
    final content = AnimatedOpacity(
      duration: const Duration(milliseconds: 160),
      opacity: dim ? 0.4 : 1,
      child: body,
    );
    if (k == null && spec.onTap == null) return content;
    return MouseRegion(
      cursor: spec.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: (_) => onHover(k),
      onExit: (_) => onHover(null),
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: spec.onTap, child: content),
    );
  }
}

/// The ring beside the headline: the open estimates as on track, aging and stale. It sweeps round as the page opens,
/// shows how many estimates are open in the middle, like the estimate mix's donut (or the share of the slice or row under
/// the pointer), and the stale slice opens the list. [showTotal] false (an older server, whose headline is the count)
/// shows the share gone quiet instead.
class _HealthRing extends StatelessWidget {
  final List<int> counts;
  final double size;
  final int? hover;
  final ValueChanged<int?> onHover;
  final VoidCallback onOpenStale;
  final bool showTotal;
  const _HealthRing({required this.counts, required this.size, required this.hover, required this.onHover, required this.onOpenStale, this.showTotal = true});

  static Color _text(int k) => k == 0 ? DashUi.emeraldText : (k == 1 ? DashUi.amberText : DashUi.redText);

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final total = counts.fold<int>(0, (a, b) => a + b);
    final h = hover;
    final whole = h == null && showTotal;
    final shown = h ?? 2;
    // A share of the estimates (not of the dollars beside it), rounded with the rows so the two always agree.
    final share = total == 0 ? '0%' : dashShareLabel(dashShares(counts)[shown], counts[shown]);
    final small = DashText.meta.copyWith(fontSize: 10.5, fontWeight: FontWeight.w700, color: DashUi.slate, height: 1.15);
    final center = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          whole ? '$total' : share,
          maxLines: 1,
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, height: 1.05, color: whole ? DashUi.ink : _text(shown), fontFeatures: DashText.tabular),
        ),
        // One short line keeps it readable in the 92 px ring; that a share is of the estimates (not of the dollars
        // beside it) is in the tooltip.
        Text(whole ? (total == 1 ? 'estimate' : 'estimates') : (h == null ? 'gone quiet' : _healthNames[h].toLowerCase()), maxLines: 1, style: small),
      ],
    );
    final names = h == null ? 'gone quiet' : _healthNames[h].toLowerCase();
    return Tooltip(
      message: whole
          ? '${dashCount(total, 'open estimate')}: ${counts[0]} on track, ${counts[1]} aging, ${counts[2]} stale'
          : '$share of the ${dashCount(total, 'open estimate')} $names (a share of the estimates, not of their dollars)',
      child: MouseRegion(
      cursor: h == 2 ? SystemMouseCursors.click : MouseCursor.defer,
      onHover: (e) => onHover(_HealthRingPainter.sliceAt(e.localPosition, size, counts)),
      onExit: (_) => onHover(null),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          if (_HealthRingPainter.sliceAt(d.localPosition, size, counts) == 2) onOpenStale();
        },
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              TweenAnimationBuilder<double>(
                key: ValueKey(counts.join(',')),
                tween: Tween(begin: still ? 1 : 0, end: 1),
                duration: still ? Duration.zero : const Duration(milliseconds: 1100),
                curve: Curves.easeOutCubic,
                builder: (context, t, _) => CustomPaint(size: Size(size, size), painter: _HealthRingPainter(counts: counts, progress: t, hover: h)),
              ),
              // Inside the hole (about 0.67 of the size across), clear of the ring.
              IgnorePointer(child: SizedBox(width: size * 0.58, height: size * 0.54, child: FittedBox(fit: BoxFit.scaleDown, child: center))),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

/// The ring: a slice for each of on track, aging and stale, with a little space between them. A slice that is only a
/// sliver of the whole is still drawn wide enough to see; the biggest one gives up the difference.
class _HealthRingPainter extends CustomPainter {
  final List<int> counts;
  final double progress;
  final int? hover;
  const _HealthRingPainter({required this.counts, required this.progress, required this.hover});

  static double stroke(double size) => size * 0.13;

  /// (start, sweep) in radians from 12 o'clock for each slice; a sweep of 0 where there is none.
  static List<(double, double)> slices(List<int> counts) {
    final total = counts.fold<int>(0, (a, b) => a + b);
    if (total == 0) return [for (final _ in counts) (0.0, 0.0)];
    final live = [for (var k = 0; k < counts.length; k++) if (counts[k] > 0) k];
    final gap = live.length > 1 ? 0.06 : 0.0;
    final avail = 2 * math.pi - gap * live.length;
    const minSweep = 0.14;
    final sweep = [for (final n in counts) n / total * avail];
    var deficit = 0.0;
    var biggest = live.first;
    for (final k in live) {
      if (sweep[k] > sweep[biggest]) biggest = k;
      if (sweep[k] < minSweep) {
        deficit += minSweep - sweep[k];
        sweep[k] = minSweep;
      }
    }
    sweep[biggest] -= deficit;
    var at = gap / 2;
    final out = <(double, double)>[];
    for (var k = 0; k < counts.length; k++) {
      out.add((at, sweep[k]));
      if (counts[k] > 0) at += sweep[k] + gap;
    }
    return out;
  }

  /// Which slice a point (relative to the ring's box) is over, or null for the hole and outside.
  static int? sliceAt(Offset p, double size, List<int> counts) {
    final d = p - Offset(size / 2, size / 2);
    final r = size / 2 - stroke(size) / 2 - 3;
    final half = stroke(size) / 2 + 4;
    if (d.distance < r - half || d.distance > r + half) return null;
    var a = math.atan2(d.dx, -d.dy); // 0 at 12 o'clock, clockwise
    if (a < 0) a += 2 * math.pi;
    final sl = slices(counts);
    for (var k = 0; k < sl.length; k++) {
      if (counts[k] > 0 && a >= sl[k].$1 && a <= sl[k].$1 + sl[k].$2) return k;
    }
    return null;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = stroke(size.width);
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: size.width / 2 - w / 2 - 3);
    canvas.drawArc(
      rect,
      0,
      2 * math.pi,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..color = DashUi.faint,
    );
    final limit = progress * 2 * math.pi;
    final sl = slices(counts);
    for (var k = 0; k < sl.length; k++) {
      if (counts[k] == 0) continue;
      final len = math.min(sl[k].$2, math.max(0.0, limit - sl[k].$1));
      if (len <= 0) continue;
      canvas.drawArc(
        rect,
        -math.pi / 2 + sl[k].$1,
        len,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = hover == k ? w + 3 : w
          ..color = _healthColors[k].withValues(alpha: hover == null || hover == k ? 1 : 0.3),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HealthRingPainter old) => old.progress != progress || old.hover != hover || !listEquals(old.counts, counts);
}

/// The dollars as one bar: what is still moving against what has gone quiet, each named with its amount (the panel's
/// finding, so the amounts carry the colours of their halves).
class _DollarBar extends StatelessWidget {
  final double active;
  final double quiet;
  const _DollarBar({required this.active, required this.quiet});

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final total = active + quiet;
    Widget key(Color dot, String word, double v, Color figure) => Text.rich(
          TextSpan(children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Container(width: 9, height: 9, margin: const EdgeInsets.only(right: 6), decoration: BoxDecoration(color: dot, borderRadius: BorderRadius.circular(3))),
            ),
            TextSpan(text: '$word ', style: DashText.meta.copyWith(fontSize: 12.5, color: DashUi.slate)),
            TextSpan(text: _compactMoney(v), style: DashText.meta.copyWith(fontSize: 12.5, fontWeight: FontWeight.w800, color: figure)),
          ]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, c) {
            // The amounts are the finding: on a narrow bar (large text) the words shorten, never the figures.
            double width(String word, double v) =>
                (TextPainter(
                  text: TextSpan(text: '$word ${_compactMoney(v)}', style: DefaultTextStyle.of(context).style.merge(DashText.meta.copyWith(fontSize: 12.5, fontWeight: FontWeight.w800))),
                  textDirection: TextDirection.ltr,
                  textScaler: MediaQuery.textScalerOf(context),
                  maxLines: 1,
                )..layout())
                    .width +
                15; // the dot and its gap
            final full = width('Still moving', active) + width('Gone quiet', quiet) + 12 <= c.maxWidth;
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(child: key(DashUi.emerald, full ? 'Still moving' : 'Moving', active, active > 0 ? DashUi.emeraldText : DashUi.ink)),
                const SizedBox(width: 12),
                Flexible(child: Align(alignment: Alignment.centerRight, child: key(DashUi.red, full ? 'Gone quiet' : 'Quiet', quiet, quiet > 0 ? DashUi.redText : DashUi.ink))),
              ],
            );
          },
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Container(
            height: 12,
            color: DashUi.faint,
            alignment: Alignment.centerLeft,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: still ? 1 : 0, end: 1),
              duration: still ? Duration.zero : const Duration(milliseconds: 900),
              curve: Curves.easeOutCubic,
              builder: (context, t, _) => FractionallySizedBox(
                widthFactor: t,
                heightFactor: 1,
                child: total <= 0
                    ? const SizedBox.shrink()
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (active > 0) Expanded(flex: (active / total * 1000).round().clamp(1, 1000), child: const ColoredBox(color: DashUi.emerald)),
                          if (active > 0 && quiet > 0) const SizedBox(width: 2),
                          if (quiet > 0) Expanded(flex: (quiet / total * 1000).round().clamp(1, 1000), child: const ColoredBox(color: DashUi.red)),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// GRID (shared by the page and its skeleton)
// =============================================================================

/// Lays the page out to fit the window:
///   desktop    the scorecards with the largest deal as the last card; then the chart down the left, and the open estimates
///              over the customer reviews on the right (1000 px wide and up)
///   narrower   everything in one column that scrolls, like the dashboards
class _SalesGrid extends StatelessWidget {
  final List<_TileSpec> tiles;
  final Widget chart;
  final Widget pipeline;
  final Widget? deal;
  final Widget reviews;
  final bool hasReviews;

  /// Placeholders instead of scorecards (the skeleton).
  final bool skeleton;
  const _SalesGrid({
    required this.tiles,
    required this.chart,
    required this.pipeline,
    required this.deal,
    required this.reviews,
    required this.hasReviews,
    this.skeleton = false,
  });

  static const _wideFrom = 1000.0;
  /// The chart panel at its smallest: its title row, a story's headline and finding, 72 px of plot, and the key.
  static double minChart(DashGeo g) => g.panelTop + g.line(22, 1.1) + g.line(12) + 2 + 12 + 72 + 8 + g.line(12) + 2;
  static const _tileGap = 12.0;

  /// The deal card is laid out for a scorecard's height, so it fills a slot of that size as it is.
  Widget _dealSlot() => deal!;

  Widget _tile(_TileSpec t, int index) => skeleton ? const DashSkeletonTile() : _KpiTile(spec: t, index: index);

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        // The top row: the scorecards, and the largest deal as the last card, the same size as a scorecard.
        final topH = g.tile;
        final body = c.maxHeight - topH - dashGap;
        final Widget content;
        final pipeMin = _PipelinePanel.minHeight(g);
        // The reviews sit under the open estimates when that column still has room for both; in a short window they sit
        // under the chart instead, which has more room to give.
        final reviewsRight = body >= pipeMin + dashGap + _ReviewsCard.height(g, 1);
        if (w >= _wideFrom && c.maxHeight.isFinite && (reviewsRight || body >= math.max(pipeMin, minChart(g) + dashGap + _ReviewsCard.height(g, 1)))) {
          // As many lines of review as leave the open estimates room for a comfortable ring.
          var lines = 1;
          if (hasReviews) {
            for (final n in const [5, 4, 3, 2]) {
              if (body - dashGap - _ReviewsCard.height(g, n) >= pipeMin + 150) {
                lines = n;
                break;
              }
            }
          }
          final reviewsCard = SizedBox(height: _ReviewsCard.height(g, lines), child: skeleton ? const DashSkeletonPanel(rows: 1, rowH: 20) : reviews);
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: topH,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < tiles.length; i++) ...[
                      if (i > 0) const SizedBox(width: _tileGap),
                      Expanded(flex: 2, child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [SizedBox(height: g.tile, child: _tile(tiles[i], i))])),
                    ],
                    if (deal != null) ...[const SizedBox(width: _tileGap), Expanded(flex: 2, child: _dealSlot())],
                  ],
                ),
              ),
              const SizedBox(height: dashGap),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: chart),
                          if (!reviewsRight) ...[const SizedBox(height: dashGap), reviewsCard],
                        ],
                      ),
                    ),
                    const SizedBox(width: dashGap),
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: pipeline),
                          if (reviewsRight) ...[const SizedBox(height: dashGap), reviewsCard],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        } else {
          final perRow = w >= 900 ? ((tiles.length + (deal == null ? 0 : 1)) / 2).ceil() : (w >= 560 ? 2 : 1);
          final tileW = (w - _tileGap * (perRow - 1)) / perRow;
          content = SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: _tileGap,
                  runSpacing: _tileGap,
                  children: [
                    for (var i = 0; i < tiles.length; i++) SizedBox(width: tileW, height: g.tile, child: _tile(tiles[i], i)),
                    if (deal != null) SizedBox(width: tileW, height: g.tile, child: _dealSlot()),
                  ],
                ),
                const SizedBox(height: dashGap),
                SizedBox(height: 360, child: chart),
                const SizedBox(height: dashGap),
                SizedBox(height: _PipelinePanel.minHeight(g) + 100, child: pipeline),
                const SizedBox(height: dashGap),
                SizedBox(height: _ReviewsCard.height(g, hasReviews ? 5 : 1), child: reviews),
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
class _SalesSkeleton extends StatelessWidget {
  const _SalesSkeleton();

  @override
  Widget build(BuildContext context) {
    final placeholder = _TileSpec(title: '', value: null, format: (v) => '', captions: const [''], definition: '', color: DashUi.muted);
    return Semantics(
      label: 'Loading figures',
      child: ExcludeSemantics(
        child: SkeletonPulse(
          child: _SalesGrid(
            skeleton: true,
            tiles: List.filled(5, placeholder),
            chart: const DashSkeletonPanel(fill: true),
            pipeline: const DashSkeletonPanel(fill: true),
            deal: const DashSkeletonTile(),
            reviews: const SizedBox.shrink(),
            hasReviews: false,
          ),
        ),
      ),
    );
  }
}
