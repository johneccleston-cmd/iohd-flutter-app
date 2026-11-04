part of 'kpi_dashboard_screen.dart';

// =============================================================================
// OFFICE KPI PAGE (/hr/kpis/:username for the person who owns collections and the phones: Bella)
// =============================================================================
//
// Built like the technician and warehouse pages (employee_kpi_tech.dart, employee_kpi_warehouse.dart) from the
// dashboards' kit: the dark title bar with a year picker and Refresh, a row of scorecards, and the chart beside the
// unpaid-invoice stages under it, all on one screen without scrolling at desktop sizes (one scrolling column below
// 1000 px wide, like the dashboards). Every figure and animation the page had before is still here: rank, milestone
// and integrity score; morale with its heartbeat and Preview (in the title bar); what is owed, what is over 90 days,
// the collection rate and the call answer rate with its monthly line; the missed-calls graph and its list; the
// lead-to-booked line; the unpaid invoices by stage; customer reviews; customer response time, now a graph above the
// unpaid invoices; and scheduling errors, which nothing records yet and says so. Cash collected by month moved to the
// Collections dashboard (dash_story.dart's DashCashByMonth); the collection rate still carries the year's cash.
//
// Where each figure comes from (GET /api/employees/:username/kpis?year=Y, `office`, with the Collections dashboard's
// own numbers for outstanding, over 90, cash and the stages swapped in so the two screens always agree): cash, the
// collection rate, the call answer rate and the leads are for the year picked. What is owed and its stages are how things
// stand today (nothing keeps their past), and the missed-calls graph is always the last 30 days; the cards say so when an
// earlier year is picked. All of it is company-wide: nothing records whose invoice or whose call it was beyond Bella's
// Quo lines.

/// Everything the page shows for one year.
class _OfficePage {
  final int year;
  final _ReceivablesKpis office;
  final _Rating? morale;
  const _OfficePage({required this.year, required this.office, required this.morale});

  /// Null when the server sends no office figures (an older build, or someone who doesn't own collections).
  static _OfficePage? parse(Map<String, dynamic> kpis, Map? collections, int year) {
    final bundle = _bundleFrom(kpis);
    var office = bundle.office;
    if (office == null) return null;
    if (collections != null && collections['summary'] is Map && collections['stages'] is List) {
      office = office.withCollections(collections);
    }
    return _OfficePage(year: year, office: office, morale: bundle.morale);
  }

  bool get isCurrentYear => year == DashClock.now().year;
}

/// The unpaid-invoice stages run from green (just invoiced) through amber to red (90 days) and indigo (a payment check).
const _agingColors = [DashUi.emerald, DashUi.sky, DashUi.amber, Color(0xFFF97316), DashUi.red, DashUi.indigo];

// =============================================================================
// THE PAGE
// =============================================================================

/// The title bar (back button, photo, name, title, time with the company, rank, milestone, integrity score and morale)
/// and the year picker; the content below loads the year picked.
class _OfficeKpiPage extends StatefulWidget {
  final _EmployeeKpiArgs args;
  final String employeeId;

  /// Whether it is still being decided that this person has an office page (the server's answer says so). The title bar
  /// and the skeleton show meanwhile, so the page the person opens is never another one first; the same widget carries
  /// on with the figures once they are known to be there.
  final bool pending;
  const _OfficeKpiPage({super.key, required this.args, required this.employeeId, this.pending = false});

  @override
  State<_OfficeKpiPage> createState() => _OfficeKpiPageState();
}

class _OfficeKpiPageState extends State<_OfficeKpiPage> {
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
      builder: (context, year) => widget.pending
          ? const _OfficeSkeleton()
          : _OfficeKpiContent(user: user, employeeId: widget.employeeId, year: year, ratings: _ratings),
    );
  }
}

class _OfficeKpiContent extends StatefulWidget {
  final _EmployeeUser user;
  final String employeeId;
  final int year;
  final _TechRatings ratings;
  const _OfficeKpiContent({required this.user, required this.employeeId, required this.year, required this.ratings});

  @override
  State<_OfficeKpiContent> createState() => _OfficeKpiContentState();
}

/// Loads the figures the way the dashboards do (DashboardLoading): a skeleton on the first load, a refresh keeps the
/// figures on screen and the header says if it failed, an answer for an older request is ignored. The Collections
/// dashboard's answer is a second source: the page still loads without it (the KPI answer carries the same figures).
class _OfficeKpiContentState extends State<_OfficeKpiContent> {
  final _kpiRequests = DashRequests();
  final _collectionRequests = DashRequests();
  _OfficePage? _data;
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
    _kpiRequests.cancel();
    _collectionRequests.cancel();
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
    final year = '${widget.year}';
    final kpisF = _kpiRequests.get('/api/employees/${Uri.encodeComponent(widget.employeeId)}/kpis', query: {'year': year}, fresh: fresh);
    final collectionsF = _collectionRequests
        .get('/api/dashboards/collections', query: {'year': year}, fresh: fresh)
        .then<DashPayload?>((p) => p, onError: (Object _) => null);
    try {
      final kpis = await kpisF;
      final collections = await collectionsF;
      if (kpis == null || !mounted) return; // a newer request took over, or the page is gone
      final _OfficePage? data;
      try {
        data = _OfficePage.parse(kpis.body, collections?.body, widget.year);
      } catch (_) {
        throw const DashLoadException(DashFailure.badData);
      }
      if (data == null) {
        setState(() {
          _data = null;
          _failure = null;
          _loading = false;
          _busy = false;
          _updatedAt = null;
        });
        _report();
        return;
      }
      final stamps = [kpis.generatedAt ?? kpis.receivedAt, if (collections != null) collections.generatedAt ?? collections.receivedAt];
      setState(() {
        _data = data;
        _loading = false;
        _busy = false;
        _updatedAt = stamps.reduce((a, b) => a.isBefore(b) ? a : b);
        _computedTime = kpis.generatedAt != null;
      });
      widget.ratings.set(null, data.morale); // nothing records a peer rating for the office yet
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
    if (_loading) return const _OfficeSkeleton();
    final failure = _failure;
    if (failure != null) {
      return DashErrorPanel.failure(failure, what: "$_first's figures", onRetry: _load);
    }
    final data = _data;
    if (data == null) {
      return DashErrorPanel(
        title: "Office figures aren't available yet",
        message: 'The server has not been updated to send them. Try again once it has.',
        hint: null,
        onRetry: () => _load(fresh: true),
      );
    }
    return _OfficeBody(data: data, user: widget.user, first: _first, employeeId: widget.employeeId, ratings: widget.ratings);
  }
}

// =============================================================================
// SCORECARDS
// =============================================================================

class _OfficeBody extends StatelessWidget {
  final _OfficePage data;
  final _EmployeeUser user;
  final String first;
  final String employeeId;
  final _TechRatings ratings;
  const _OfficeBody({required this.data, required this.user, required this.first, required this.employeeId, required this.ratings});

  @override
  Widget build(BuildContext context) {
    final off = data.office;
    final year = data.year;
    final now = data.isCurrentYear;
    // What is owed and its stages are how things stand today; an earlier year says so in every caption, however short.
    final today = now ? '' : ' · as of today';
    final jobs = off.aging.fold<int>(0, (t, a) => t + a.jobs);

    final outstanding = _TileSpec(
      title: 'Outstanding',
      value: off.outstanding,
      format: _wholeMoney,
      captions: now
          ? ['Owed on ${dashCount(jobs, 'invoiced job')}', 'Owed on ${dashCount(jobs, 'job')}', 'Unpaid']
          : ['Owed on ${dashCount(jobs, 'job')}$today', '${dashCount(jobs, 'job')}$today', 'As of today'],
      definition: 'Everything customers still owe on jobs that have been invoiced, across the ${dashCount(jobs, 'job')} in the unpaid stages. '
          "The same number as the Collections dashboard. It is today's balance: nothing keeps what was owed on an earlier date.",
      color: DashUi.ink,
    );

    final over90 = _TileSpec(
      title: 'Over 90 days',
      value: off.over90,
      format: _wholeMoney,
      captions: now
          ? ['In the 90 Day Notice stage', '90 Day Notice stage', '90 Day Notice']
          : ['In the 90 Day Notice stage$today', '90 Day Notice$today', 'As of today'],
      definition: 'The part of what is owed on jobs at the 90 Day Notice stage: the notice the job has reached, not how old its invoice is. '
          "The Collections dashboard shows the same number. It is today's balance.",
      color: off.over90 > 0 ? DashUi.red : DashUi.emeraldDeep,
    );

    // The rate needs what was owed alongside the cash. Only today's balance is known, so an earlier year has no rate.
    final collection = _TileSpec(
      title: 'Collection rate',
      value: now ? off.collectionRatePct : null,
      format: (v) => '${_fmtNum(v)}%',
      captions: !now
          ? ['Current year only']
          : off.collectionRatePct == null
              ? ['No payments or balances yet']
              : ['${_wholeMoney(off.collected)} collected · ${dashPeriodLabel(year)}', '${_wholeMoney(off.collected)} collected', 'Cash ÷ (cash + owed)'],
      definition: !now
          ? '${_wholeMoney(off.collected)} came in during $year. A rate for $year needs what was still owed at the end of it, and nothing '
              "keeps past balances (what is owed is only known for today), so there is no rate for $year."
          : 'Cash received Jan 1 – today (${_wholeMoney(off.collected)}) as a share of that cash plus what is owed today '
              "(${_wholeMoney(off.outstanding)}) on invoices from any year. A rough guide: this year's cash also pays older invoices. "
              'The Collections dashboard shows the cash month by month.',
      color: now ? DashUi.emeraldDeep : DashUi.muted,
    );

    // --- Calls: this year's answer rate (Mon-Fri 8-5 incoming calls to Bella's lines) and the last 30 days' misses. ---
    final callsYear = off.callsMonthly;
    final matched = off.missedDaily.isNotEmpty || (callsYear.length >= 12 && off.missedMonthly.length >= 12);
    final yearCalls = callsYear.fold<double>(0, (t, v) => t + v);
    final yearMissed = off.missedMonthly.fold<double>(0, (t, v) => t + v);
    final String period = dashPeriodLabel(year);
    final answerKnown = callsYear.length >= 12 && off.missedMonthly.length >= 12 && yearCalls > 0;
    final answerRate = answerKnown ? (yearCalls - yearMissed) / yearCalls * 100 : null;
    // 80% and up is good, under 60% is a problem; there is no target set yet, so these are the page's own cut-offs.
    final answerColor = answerRate == null ? DashUi.muted : (answerRate >= 80 ? DashUi.emeraldDeep : (answerRate >= 60 ? DashUi.amber : DashUi.red));
    // Finished months only, like every other trend line: a few days of the month in progress swing the rate.
    final finished = math.min(callsYear.length, dashCompleteMonths(year));
    final answerTrend = answerKnown
        ? [for (var m = 0; m < finished; m++) if (callsYear[m] > 0) (callsYear[m] - off.missedMonthly[m]) / callsYear[m] * 100]
        : const <double>[];
    final answeredN = _officeCount((yearCalls - yearMissed).round());
    final callsN = _officeCount(yearCalls.round());
    // The main office number counts for Bella from Mar 7, 2026, when she took it over (MAIN_LINE in employee_kpis.js).
    final lines = year < 2026
        ? "$first's own line (the main office number counts from Mar 7, 2026, when $first took it over)"
        : "$first's own line all year and the main office number from Mar 7, 2026, when $first took it over";
    final answer = _TileSpec(
      title: 'Call answer rate',
      value: answerRate == null ? null : (answerRate * 10).round() / 10,
      format: (v) => '${_fmtNum(v)}%',
      captions: !answerKnown
          ? [matched ? (now ? 'No calls this year yet' : 'No calls in $year') : 'No call figures']
          : ['$answeredN of $callsN calls answered · $period', '$answeredN of $callsN answered · $period', '$answeredN of $callsN · $period', period],
      definition: answerKnown
          ? 'The share of incoming calls in $period that were answered: $answeredN of $callsN. The calls are those to $lines. '
              'Only calls from Monday to Friday, 8 AM to 5 PM count, and calls from our own staff are left out. The line is each finished month\'s rate.'
          : matched
              ? 'The share of incoming calls to $first\'s lines that were answered. No calls came in during $period.'
              : 'The share of incoming calls to $first\'s lines that were answered. The server sent no call figures: $first may not be matched to a '
                  "Quo line yet, or the calls couldn't be read. Refresh to try again.",
      color: answerColor,
      trend: answerTrend.length >= 2 ? answerTrend : null,
    );

    final days = off.missedDaily;
    final daily = days.isNotEmpty;
    final missed30 = days.fold<int>(0, (t, d) => t + d.missed);
    final calls30 = days.fold<int>(0, (t, d) => t + d.total);
    final share30 = calls30 == 0 ? 0.0 : missed30 / calls30 * 100;
    final missedColor = !daily ? DashUi.muted : (missed30 == 0 ? DashUi.emeraldDeep : (share30 >= 40 ? DashUi.red : (share30 >= 20 ? DashUi.amber : DashUi.emeraldDeep)));
    final missed = _TileSpec(
      title: 'Missed calls',
      value: daily ? missed30.toDouble() : null,
      format: (v) => '${v.round()}',
      captions: !matched
          ? ['No call figures']
          : !daily
              ? ['Last 30 days not available yet']
              : calls30 == 0
                  ? ['No calls in the last 30 days', 'None in the last 30 days', 'Last 30 days']
                  : ['of ${dashCount(calls30, 'call')} · last 30 days', 'of ${_officeCount(calls30)} · last 30 days', 'Last 30 days'],
      definition: daily
          ? 'Incoming calls nobody answered over the last 30 days: ${_officeCount(missed30)} of ${dashCount(calls30, 'call')} (${_fmtNum(share30)}%), '
              'Monday to Friday, 8 AM to 5 PM. Always the last 30 days, whatever year is picked. The line is one point a weekday. '
              'Select to open the calls, newest first, to check them against Quo.'
          : 'Incoming calls nobody answered over the last 30 days. The server sent no call figures: $first may not be matched to a Quo line yet, '
              "or the calls couldn't be read. Refresh to try again.",
      color: missedColor,
      trend: daily ? [for (final d in days) if (d.total > 0) d.missed.toDouble()].takeIfTwo : null,
      count: missed30,
      noun: 'missed call',
      onOpen: matched
          ? () => showDialog<void>(
                context: context,
                builder: (_) => _MissedCallsDialog(employeeId: employeeId, name: user.name.trim().isEmpty ? 'Missed calls' : user.name.trim()),
              )
          : null,
    );

    // --- A measure nothing records yet: it stays on the page and says so. ---
    const scheduling = _TileSpec(
      title: 'Scheduling errors',
      value: null,
      format: _noFigure,
      captions: ['Not tracked yet'],
      definition: 'Jobs booked wrongly (wrong day, wrong tech, missing details). Nothing records them yet, so there is no figure.',
      color: DashUi.muted,
    );

    return _OfficeGrid(
      tiles: [outstanding, over90, collection, answer, missed, scheduling],
      chart: _OfficeChartPanel(
        off: off,
        year: year,
        period: period,
        first: first,
        onViewList: () => showDialog<void>(
          context: context,
          builder: (_) => _MissedCallsDialog(employeeId: employeeId, name: user.name.trim().isEmpty ? 'Missed calls' : user.name.trim()),
        ),
      ),
      // Call backs after missed calls, from Quo; an older server sends none, and the Preview fills in sample days.
      response: _ResponsePanel(callbacks: off.callbacks, ratings: ratings, first: first),
      aging: (layout, columns) => _AgingPanel(rows: off.aging, over90: off.over90, today: today, layout: layout, columns: columns),
      stages: off.aging,
      reviews: (lines) => _ReviewsCard(mentions: off.mentions, rating: off.satisfaction, first: first, sample: false),
      hasReviews: off.mentions.isNotEmpty,
    );
  }
}

String _noFigure(double v) => '—';

/// A whole number with thousands separators: "1,299".
String _officeCount(int n) => '${n < 0 ? '-' : ''}${n.abs().toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},')}';

extension on List<double> {
  /// This list, or null when it has too few points to draw a line.
  List<double>? get takeIfTwo => length >= 2 ? this : null;
}

// =============================================================================
// THE CHART: missed calls and leads, stepping through themselves
// =============================================================================

/// One panel with two views of the office's work, behind a switch in the title row. It steps to the next view every
/// 8 seconds, holds while the pointer or the keyboard is on it, never moves with reduced motion, and a view picked by
/// hand restarts the wait.
class _OfficeChartPanel extends StatefulWidget {
  final _ReceivablesKpis off;
  final int year;
  final String period;

  /// The person's first name, for the hover text ("Bella's own line").
  final String first;
  final VoidCallback onViewList;
  const _OfficeChartPanel({required this.off, required this.year, required this.period, required this.first, required this.onViewList});

  @override
  State<_OfficeChartPanel> createState() => _OfficeChartPanelState();
}

class _OfficeChartPanelState extends State<_OfficeChartPanel> with SingleTickerProviderStateMixin {
  static const _views = [(0, 'Missed calls'), (1, 'Leads')];
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
    final off = widget.off;
    final daily = off.missedDaily.isNotEmpty;
    final (title, note, tip) = switch (_view) {
      0 => (
          'Missed calls',
          daily ? 'last 30 days' : widget.period,
          "Incoming calls to ${widget.first}'s own line and the main office number that nobody answered, one point for each weekday "
              '(Monday to Friday, 8 AM to 5 PM). The main number counts from Mar 7, 2026, when ${widget.first} took it over. '
              'A day with no calls at all is a gap, not a zero. Hover a day to read it.'
        ),
      _ => (
          'Lead to booked job',
          'by month',
          'The share of each month\'s new leads that were booked as jobs. Nothing records new leads yet, so this fills in once they are.'
        ),
    };
    final Widget content = switch (_view) {
      0 => _MissedCallsView(off: off, year: widget.year, period: widget.period, onViewList: widget.onViewList, first: widget.first),
      _ => _LeadsView(off: off, year: widget.year),
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

/// "Wed Oct 21".
String _dayWords(DateTime d) => '${_weekdayLetters[d.weekday - 1]} ${_monthLetters[d.month - 1]} ${d.day}';

/// Missed calls as a question: how many of the calls that came in went unanswered? The headline answers it (calls missed,
/// the share answered, calls that came in) and names the worst day; under it each weekday is a point on a line, with the
/// list of the calls behind it one click away. A year's monthly totals stand in while the server sends no daily figures.
class _MissedCallsView extends StatelessWidget {
  final _ReceivablesKpis off;
  final int year;
  final String period;
  final VoidCallback onViewList;

  /// The person's first name, for the empty state.
  final String first;
  const _MissedCallsView({required this.off, required this.year, required this.period, required this.onViewList, required this.first});

  @override
  Widget build(BuildContext context) {
    final days = off.missedDaily;
    final daily = days.isNotEmpty;
    final now = DashClock.now();
    // The months a monthly line can have: all of an earlier year, this year's up to the month in progress.
    final shownMonths = year < now.year ? 12 : (year == now.year ? now.month : 0);
    final calls = off.callsMonthly;
    final matched = daily || (off.missedMonthly.length >= 12 && calls.length >= 12);
    if (!matched) {
      return DashEmptyNote("No call figures came back from the server.\n$first may not be matched to a Quo line yet, or the calls couldn't be read.");
    }
    final inYear = year == now.year ? 'this year' : 'in $year';

    // A day or month with no calls at all is a gap, not a zero.
    final series = <double?>[
      if (daily)
        for (final d in days) d.total > 0 ? d.missed.toDouble() : null
      else
        for (var m = 0; m < 12; m++) m < shownMonths && calls[m] > 0 ? off.missedMonthly[m] : null,
    ];
    final totalMissed = daily ? days.fold<int>(0, (t, d) => t + d.missed).toDouble() : off.missedMonthly.fold<double>(0, (t, v) => t + v);
    final totalCalls = daily ? days.fold<int>(0, (t, d) => t + d.total).toDouble() : calls.fold<double>(0, (t, v) => t + v);
    final answered = totalCalls > 0 ? (totalCalls - totalMissed) / totalCalls * 100 : null;
    final answeredColor = answered == null ? DashUi.slate : (answered >= 80 ? DashUi.emeraldText : (answered >= 60 ? DashUi.amberText : DashUi.redText));

    // The worst day (or month): the most misses, the latest when tied. The chart rings it.
    int? worstAt;
    String callout;
    Color calloutColor = DashUi.redText;
    if (totalCalls == 0) {
      callout = daily ? 'No calls came in over the last 30 days' : 'No calls came in $inYear';
      calloutColor = DashUi.slate;
    } else if (totalMissed == 0) {
      callout = daily ? 'No missed calls in the last 30 days' : 'No missed calls $inYear';
      calloutColor = DashUi.emeraldText;
    } else if (daily) {
      var worst = days.first;
      for (var i = 0; i < days.length; i++) {
        if (days[i].missed >= worst.missed) {
          worst = days[i];
          worstAt = i;
        }
      }
      callout = 'Worst day: ${_dayWords(worst.date)}, ${worst.missed} of ${dashCount(worst.total, 'call')} missed';
    } else {
      var w = 0;
      for (var m = 0; m < 12; m++) {
        if (series[m] != null && series[m]! >= (series[w] ?? -1)) w = m;
      }
      worstAt = w;
      callout = 'Worst month: ${dashMonthNames[w]}, ${_fmtNum(off.missedMonthly[w])} of ${_fmtNum(calls[w])} calls missed';
    }

    final headline = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        _StoryStat(totalMissed, (v) => '${v.round()}', 'calls missed', DashUi.redText),
        const SizedBox(width: 22),
        if (answered != null) ...[
          // One decimal, like the Call answer rate scorecard, so the two never read as one figure rounded two ways.
          _StoryStat(answered, (v) => '${_fmtNum((v * 10).round() / 10)}%', 'answered', answeredColor),
          const SizedBox(width: 22),
        ],
        _StoryStat(totalCalls, (v) => '${v.round()}', totalCalls == 1 ? 'call came in' : 'calls came in', DashUi.ink),
      ],
    );

    final maxPoint = series.whereType<double>().fold<double>(0, math.max);
    return Semantics(
      label: '${_fmtNum(totalMissed)} of ${_fmtNum(totalCalls)} calls missed, $period. $callout.',
      child: DashStoryFrame(
        headline: headline,
        callout: callout,
        calloutColor: calloutColor,
        action: Semantics(
          button: true,
          label: 'View the list of missed calls',
          child: DashPressable(
            onTap: onViewList,
            label: 'View the list of missed calls',
            radius: BorderRadius.circular(8),
            builder: (hover) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.list_alt_rounded, size: 16, color: DashUi.blue),
                  const SizedBox(width: 4),
                  Text('View list', style: DashText.link.copyWith(fontSize: 12.5, fontWeight: FontWeight.w700, decoration: hover ? TextDecoration.underline : null)),
                ],
              ),
            ),
          ),
        ),
        chart: _MonthlyChart(
          expand: true,
          showLegend: false,
          line: true,
          values: series,
          highlight: worstAt,
          color: DashUi.red,
          // Daily points are labelled on Mondays only, so the axis stays readable.
          labels: daily ? [for (final d in days) d.date.weekday == DateTime.monday ? '${_monthLetters[d.date.month - 1]} ${d.date.day}' : ''] : null,
          titles: daily ? [for (final d in days) _dayWords(d.date)] : null,
          // Rounded up to a multiple of 4 so the four gridlines are whole numbers (the shared rounding jumps 52 to 100).
          maxValue: math.max(4, ((maxPoint * 1.1) / 4).ceil() * 4).toDouble(),
          axisFormat: (v) => '${v.round()}',
          tipFormat: (i) {
            final m = daily ? days[i].missed : off.missedMonthly[i].round();
            final t = daily ? days[i].total : calls[i].round();
            return '$m missed of $t calls (${_fmtNum(t == 0 ? 0 : m / t * 100)}%)';
          },
          emptyText: daily ? 'No missed calls in the last 30 days' : 'No missed calls in $year',
        ),
        legend: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            dashKeyItem(
              Container(width: 10, height: 10, decoration: const BoxDecoration(color: DashUi.red, shape: BoxShape.circle)),
              daily ? 'Calls missed each weekday, 8 AM–5 PM' : 'Calls missed each month, weekdays 8 AM–5 PM',
            ),
            const SizedBox(width: 16),
            dashKeyItem(dashDashedKey(), daily ? 'Average day' : 'Average month'),
            if (worstAt != null) ...[
              const SizedBox(width: 16),
              dashKeyItem(
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: DashUi.red.withValues(alpha: 0.6), width: 1.5), color: DashUi.red.withValues(alpha: 0.14)),
                ),
                daily ? 'Worst day' : 'Worst month',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Leads as a question: of the people who asked for work, how many became jobs? Nothing records leads yet, and the view
/// says so in words rather than drawing an empty line; once they are recorded the headline is the booked share and the
/// line is each month's.
class _LeadsView extends StatelessWidget {
  final _ReceivablesKpis off;
  final int year;
  const _LeadsView({required this.off, required this.year});

  @override
  Widget build(BuildContext context) {
    final leads = off.leadsMonthly, booked = off.bookedMonthly;
    final totalLeads = leads.fold<double>(0, (t, v) => t + v);
    if (totalLeads <= 0) {
      return const DashEmptyNote('No leads are recorded yet, so there is no booked share to show.\nIt will fill in once new leads are recorded.');
    }
    final totalBooked = booked.fold<double>(0, (t, v) => t + v);
    final now = DashClock.now();
    final shown = year == now.year ? now.month : 12;
    final rate = <double?>[
      for (var m = 0; m < 12; m++)
        m < shown && m < leads.length && leads[m] > 0 ? (m < booked.length ? booked[m] : 0) / leads[m] * 100 : null,
    ];
    int? best;
    for (var m = 0; m < 12; m++) {
      if (rate[m] != null && (best == null || rate[m]! > rate[best]!)) best = m;
    }
    final share = totalBooked / totalLeads * 100;
    final callout = best == null ? 'No month has leads yet' : 'Best month: ${dashMonthNames[best]}, ${_fmtNum(rate[best]!)}% booked';
    return Semantics(
      label: '${_fmtNum(share)}% of leads booked in $year. $callout.',
      child: DashStoryFrame(
        headline: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            _StoryStat(share, (v) => '${v.round()}%', 'of leads booked', DashUi.emeraldText),
            const SizedBox(width: 22),
            _StoryStat(totalBooked, (v) => '${v.round()}', 'of ${_fmtNum(totalLeads)} leads', DashUi.ink),
          ],
        ),
        callout: callout,
        calloutColor: DashUi.emeraldText,
        chart: _MonthlyChart(
          expand: true,
          line: true,
          showLegend: false,
          values: rate,
          color: DashUi.emerald,
          maxValue: 100,
          axisFormat: (v) => '${v.round()}%',
          tipFormat: (i) {
            final l = i < leads.length ? leads[i].round() : 0;
            final b = i < booked.length ? booked[i].round() : 0;
            return '${_fmtNum(rate[i] ?? 0)}%  ($b of $l leads)';
          },
          emptyText: 'No leads recorded in $year yet',
        ),
        legend: dashKeyItem(Container(width: 10, height: 10, decoration: const BoxDecoration(color: DashUi.emerald, shape: BoxShape.circle)), 'Share of each month\'s leads booked as jobs'),
      ),
    );
  }
}

// =============================================================================
// CUSTOMER RESPONSE TIME
// =============================================================================

/// The call-back goal the graph is measured against. Nothing sets a target yet, so this is the page's own: within an
/// hour (the server counts against the same hour).
const _replyGoalMinutes = 60.0;

/// What happened after the missed calls of one weekday (`missedCalls.callbacks.daily`), or of the 30 days together
/// (`totals`). Waits are in working minutes (Monday to Friday, 8 AM to 5 PM).
class _ReplyDay {
  final DateTime? date;
  final int missed;

  /// Called back by us, with a wait; [within] of them inside the hour.
  final int calledBack;
  final int within;

  /// Late and still not called back (over an hour of working time with no call back).
  final int notCalledBack;

  /// Not called back yet, but still under an hour old: late neither way yet.
  final int pending;

  /// The customer called again and got through before anyone called them: nothing left to return.
  final int gotThrough;

  /// Call backs this person made themselves (the rest came from coworkers).
  final int byMe;
  final double? medianMinutes;
  const _ReplyDay({
    required this.date,
    required this.missed,
    required this.calledBack,
    required this.within,
    required this.notCalledBack,
    required this.pending,
    required this.gotThrough,
    required this.byMe,
    required this.medianMinutes,
  });

  /// The customers who were waiting on a call back: the base of "called back within the hour".
  int get waiting => calledBack + notCalledBack;

  static _ReplyDay fromJson(Map j, {DateTime? date}) {
    int n(String k) => (_num(j[k]) ?? 0).round();
    return _ReplyDay(
      date: date,
      missed: n('missed'),
      calledBack: n('calledBack'),
      within: n('within'),
      notCalledBack: n('notCalledBack'),
      pending: n('pending'),
      gotThrough: n('gotThrough'),
      byMe: n('byMe'),
      medianMinutes: _num(j['medianMinutes']),
    );
  }
}

/// Call backs after missed calls over the last 30 days: one entry a weekday, and the 30 days together (the typical wait
/// can't be added up from the days, so the server sends it).
class _Callbacks {
  final List<_ReplyDay> daily;
  final _ReplyDay totals;
  const _Callbacks(this.daily, this.totals);

  static _Callbacks? fromJson(dynamic j) {
    if (j is! Map || j['totals'] is! Map) return null;
    return _Callbacks(
      [
        for (final d in (j['daily'] is List ? j['daily'] as List : const []))
          if (d is Map && DateTime.tryParse(_str(d['date'])) != null) _ReplyDay.fromJson(d, date: DateTime.parse(_str(d['date']))),
      ],
      _ReplyDay.fromJson(j['totals'] as Map),
    );
  }
}

/// Made-up call backs for the Preview, one for each weekday of the last 30 days, with a slow spell and one bad day so
/// the card's story shows. Only ever on screen with the Preview on, and labelled a sample there.
_Callbacks _sampleCallbacks() {
  const minutes = <double>[24, 31, 18, 42, 66, 27, 19, 35, 52, 97, 44, 26, 33, 15, 38, 71, 29, 23, 47, 36, 21, 28];
  const missed = [9, 12, 7, 11, 14, 8, 10, 9, 13, 16, 11, 8, 10, 6, 12, 15, 9, 8, 12, 10, 7, 11];
  final now = DashClock.now();
  final days = <_ReplyDay>[];
  for (var back = 29; back >= 0; back--) {
    final d = DateTime(now.year, now.month, now.day - back);
    if (d.weekday > DateTime.friday) continue;
    final i = days.length;
    final m = minutes[i % minutes.length];
    final total = missed[i % missed.length];
    final through = i % 4 == 0 ? 1 : 0;
    final notBack = m > 60 ? 1 : 0;
    final returned = total - through - notBack;
    // The slower the day, the fewer call backs inside the hour.
    final within = (returned * (1.2 - m / 110).clamp(0.25, 1.0)).round().clamp(0, returned).toInt();
    days.add(_ReplyDay(date: d, missed: total, calledBack: returned, within: within, notCalledBack: notBack, pending: 0, gotThrough: through, byMe: returned - 1, medianMinutes: m));
  }
  int sum(int Function(_ReplyDay) f) => days.fold(0, (t, d) => t + f(d));
  final waits = [for (final d in days) d.medianMinutes!]..sort();
  final totals = _ReplyDay(
    date: null,
    missed: sum((d) => d.missed),
    calledBack: sum((d) => d.calledBack),
    within: sum((d) => d.within),
    notCalledBack: sum((d) => d.notCalledBack),
    pending: 0,
    gotThrough: sum((d) => d.gotThrough),
    byMe: sum((d) => d.byMe),
    medianMinutes: waits[waits.length ~/ 2],
  );
  return _Callbacks(days, totals);
}

/// "42 min", "1 h 37 min", "2 h".
String _waitWords(double minutes) {
  final m = minutes.round();
  if (m < 60) return '$m min';
  final h = m ~/ 60, rest = m % 60;
  return rest == 0 ? '$h h' : '$h h $rest min';
}

/// The axis: "0", "30m", "1h", "1h 30m".
String _waitAxis(double minutes) {
  final m = minutes.round();
  if (m == 0) return '0';
  if (m < 60) return '${m}m';
  final h = m ~/ 60, rest = m % 60;
  return rest == 0 ? '${h}h' : '${h}h ${rest}m';
}

/// How long customers wait to be called back after calling the office and not getting through, as a graph. The
/// headline answers it (the typical wait, the share called back within the hour), the callout names the calls nobody
/// returned and the slowest day, and each weekday is a point on a line against the green one-hour goal. The missed calls
/// are the Missed calls graph's; the call backs come from Quo. Without the server's figures (an older server) the card
/// says so, with a Preview that fills in sample days (the same Preview as morale's in the title bar).
class _ResponsePanel extends StatelessWidget {
  /// The server's call backs for the last 30 days; null from an older server.
  final _Callbacks? callbacks;
  final _TechRatings ratings;
  final String first;
  const _ResponsePanel({required this.callbacks, required this.ratings, required this.first});

  /// The chart's height under the headline: what it should keep (about 60 px of plot over the day labels; a short window
  /// gives the unpaid invoices their one-line layout rather than squeeze it), and the least it can still be read at,
  /// for a short window with large text where nothing else fits.
  static const _minChart = 106.0;
  static const _tightChart = 80.0;

  /// The card at its smallest: title, headline and a chart that can still be read.
  static double minHeight(DashGeo g, {bool tight = false}) => g.panelTop + DashStoryFrame.headHeight(g) + 12 + (tight ? _tightChart : _minChart);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ratings,
      builder: (context, _) {
        final g = DashGeo.of(context);
        final sample = callbacks == null && ratings.sample;
        final shown = callbacks ?? (sample ? _sampleCallbacks() : null);
        final t = shown?.totals;
        final byMe = t == null || t.calledBack == 0
            ? ''
            : ' ${t.byMe} of the ${dashCount(t.calledBack, 'call back')} ${sample ? 'here are' : 'were'} made by $first; the rest by coworkers.';
        return DashPanel(
          fill: true,
          header: DashPanelHeader(
            g: g,
            title: 'Customer response time',
            note: sample ? 'sample' : 'last 30 days',
            tooltip: 'How long a customer waits to be called back after calling the office and not getting through (the calls on the '
                'Missed calls graph): from their call to our first call back to that number, counted in working hours, Monday to '
                'Friday, 8 AM to 5 PM, so a call missed at 4:50 PM and returned at 8:10 the next morning waited 20 minutes. A text '
                'back is not a call back. A customer who called again and got through first is not counted as waiting. The line is '
                'the typical (median) wait of each weekday\'s missed calls; the green line is the goal of calling back within an '
                'hour.$byMe',
            trailing: sample
                ? DashLink(text: 'Hide sample', label: 'Hide the sample call backs', onTap: () => ratings.preview(false))
                : null,
          ),
          child: shown == null ? _notTracked() : _ReplyStory(callbacks: shown, sample: sample, first: first),
        );
      },
    );
  }

  Widget _notTracked() => Semantics(
        container: true,
        label: 'Customer response time is not available yet',
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.schedule_rounded, size: 22, color: DashUi.muted),
                const SizedBox(height: 4),
                const Text('No call-back times from the server yet', style: DashText.empty),
                const SizedBox(height: 2),
                Text('This shows how long customers wait for $first to call back after a missed call', style: DashText.meta),
                const SizedBox(height: 6),
                TextButton.icon(
                  onPressed: () => ratings.preview(true),
                  icon: const Icon(Icons.visibility_outlined, size: 16),
                  label: Text('Preview with sample data', style: DashText.link.copyWith(fontWeight: FontWeight.w700)),
                  style: TextButton.styleFrom(foregroundColor: DashUi.blue, visualDensity: VisualDensity.compact),
                ),
              ],
            ),
          ),
        ),
      );
}

class _ReplyStory extends StatelessWidget {
  final _Callbacks callbacks;
  final bool sample;
  final String first;
  const _ReplyStory({required this.callbacks, required this.sample, required this.first});

  @override
  Widget build(BuildContext context) {
    final t = callbacks.totals;
    final days = callbacks.daily;
    if (t.missed == 0) return const DashEmptyNote('No missed calls in the last 30 days, so nobody waited for a call back');
    final waiting = t.waiting;
    final share = waiting == 0 ? null : t.within / waiting * 100;
    final median = t.medianMinutes;

    // The slowest weekday by its typical wait, and how many weekdays were over the hour.
    final timed = days.where((d) => d.medianMinutes != null && d.date != null).toList();
    _ReplyDay? slowest;
    for (final d in timed) {
      if (slowest == null || d.medianMinutes! >= slowest.medianMinutes!) slowest = d;
    }
    final overGoal = timed.where((d) => d.medianMinutes! > _replyGoalMinutes).length;

    final parts = <String>[
      if (t.notCalledBack > 0) '${dashCount(t.notCalledBack, 'call')} not called back',
      if (slowest != null && slowest.medianMinutes! > _replyGoalMinutes)
        '${t.notCalledBack > 0 ? 'slowest' : 'Slowest'} day: ${_dayWords(slowest.date!)}, ${_waitWords(slowest.medianMinutes!)}${overGoal > 1 ? ' · $overGoal days over the hour' : ''}',
    ];
    final String callout;
    final Color calloutColor;
    if (parts.isEmpty) {
      callout = t.calledBack == 0 ? 'Nobody was waiting on a call back' : 'Every weekday\'s typical call back was within the hour';
      calloutColor = DashUi.emeraldText;
    } else {
      callout = parts.join(' · ');
      final bad = t.notCalledBack > 0 || (slowest?.medianMinutes ?? 0) > _replyGoalMinutes * 1.5;
      calloutColor = bad ? DashUi.redText : DashUi.amberText;
    }
    final medianColor = median == null
        ? DashUi.muted
        : (median <= _replyGoalMinutes * 0.5 ? DashUi.emeraldText : (median <= _replyGoalMinutes ? DashUi.amberText : DashUi.redText));
    final peak = timed.fold<double>(0, (m, d) => math.max(m, d.medianMinutes!));
    final words = '${sample ? 'Sample: ' : ''}'
        '${median == null ? 'no missed call was called back' : 'customers typically waited ${_waitWords(median)} for a call back'}'
        '${share == null ? '' : ', ${share.round()}% were called back within the hour'}, over the last 30 days. $callout.';

    String tip(int i) {
      final d = days[i];
      if (d.missed == 0) return 'No missed calls';
      final bits = <String>[
        if (d.medianMinutes != null) '${_waitWords(d.medianMinutes!)} typical wait',
        if (d.waiting > 0) '${d.within} of ${d.waiting} called back within the hour',
        if (d.notCalledBack > 0) '${d.notCalledBack} not called back',
        if (d.gotThrough > 0) '${d.gotThrough} got through by calling again',
        if (d.pending > 0) '${d.pending} still under an hour',
      ];
      return bits.isEmpty ? dashCount(d.missed, 'missed call') : bits.join(' · ');
    }

    return Semantics(
      label: words,
      child: DashStoryFrame(
        headline: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            if (median != null) ...[DashStoryStat(median, _waitWords, 'typical wait', medianColor), const SizedBox(width: 22)],
            if (share != null) DashStoryStat(share, (v) => '${v.round()}%', 'called back within the hour', DashUi.ink),
          ],
        ),
        callout: callout,
        calloutColor: calloutColor,
        chart: _MonthlyChart(
          expand: true,
          line: true,
          showLegend: false,
          average: false,
          values: [for (final d in days) d.medianMinutes],
          color: DashUi.sky,
          labels: [for (final d in days) d.date != null && d.date!.weekday == DateTime.monday ? '${_monthLetters[d.date!.month - 1]} ${d.date!.day}' : ''],
          titles: [for (final d in days) d.date == null ? '' : _dayWords(d.date!)],
          // Whole hours at the top, so the four gridlines fall on quarter hours or half hours.
          maxValue: math.max(120.0, ((peak * 1.1) / 60).ceil() * 60.0),
          axisFormat: _waitAxis,
          goal: _replyGoalMinutes,
          goalLabel: '1-hour goal',
          tipFormat: tip,
          emptyText: 'No call backs in the last 30 days',
        ),
        legend: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            dashKeyItem(
              Container(width: 10, height: 10, decoration: const BoxDecoration(color: DashUi.sky, shape: BoxShape.circle)),
              'Typical wait each weekday',
            ),
            // The goal line carries its own label on the chart, so the key doesn't name it again.
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// UNPAID INVOICES BY STAGE
// =============================================================================

/// How the unpaid-invoices card lays its stages out, from roomiest to smallest:
///   rows   a row per stage with its jobs, its share and its amount over a bar (a tall window)
///   grid   one bar split by stage, then the stages in a grid: name, amount, jobs and share (most windows)
///   mini   the stages in a grid on one line each, the finding in the title row (a short window with large text)
enum _AgingLayout { rows, grid, mini }

/// Short names for the stages in the smallest layout, where the full ones don't fit beside their amounts.
const _shortStage = {
  'Final Invoice Sent': 'Invoiced',
  '14 Day Notice': '14 days',
  '30 Day Notice': '30 days',
  '60 Day Notice': '60 days',
  '90 Day Notice': '90 days',
  'Check on Payment': 'Checking',
};

/// Where the unpaid invoices stand, oldest stages last, with what is at the 90 Day Notice stage in words. The stage's colour runs
/// from green (just invoiced) to red (90 days); the name and the figures say the same, so colour is never alone.
class _AgingPanel extends StatelessWidget {
  final List<_AgingRow> rows;
  final double over90;

  /// " · as of today" when an earlier year is picked.
  final String today;
  final _AgingLayout layout;

  /// The grid's columns (the grid layouts only).
  final int columns;
  const _AgingPanel({required this.rows, required this.over90, required this.today, this.layout = _AgingLayout.rows, this.columns = 3});

  /// A row at its smallest: the stage over its bar.
  static double rowMin(DashGeo g) => math.max(36.0, g.line(13.5) + 6 + 8 + 8);
  static double calloutH(DashGeo g) => g.line(12) + 8;

  /// The split bar and the gap under it.
  static const _splitH = 10.0 + 10;

  /// A grid cell: the stage's name over its amount and jobs, or (mini) both on one line.
  static double cellH(DashGeo g, {required bool mini}) => mini ? g.line(13) + 9 : g.line(12.5) + g.line(13.5, 1.2) + 12;

  /// The card at its smallest for [n] stages in [layout] with [columns] columns.
  static double minHeight(DashGeo g, int n, {_AgingLayout layout = _AgingLayout.rows, int columns = 3}) {
    final gridRows = (math.max(n, 1) / columns).ceil();
    return switch (layout) {
      _AgingLayout.rows => g.panelTop + calloutH(g) + math.max(n, 2) * rowMin(g),
      _AgingLayout.grid => g.panelTop + calloutH(g) + _splitH + gridRows * cellH(g, mini: false),
      _AgingLayout.mini => g.panelTop + gridRows * cellH(g, mini: true),
    };
  }

  /// The width a grid cell needs to show every stage whole: the colour dot, the name (mini: the short name) and the
  /// figures under it (mini: the amount beside it).
  static double cellWidth(BuildContext context, List<_AgingRow> rows, {required bool mini}) {
    final scaler = MediaQuery.textScalerOf(context);
    final family = DefaultTextStyle.of(context).style.fontFamily;
    double w(String text, TextStyle style) => (TextPainter(
          text: TextSpan(text: text, style: style.copyWith(fontFamily: family)),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
          maxLines: 1,
        )..layout())
            .width;
    final shares = dashShares([for (final r in rows) r.amount]);
    var widest = 0.0;
    for (final (i, r) in rows.indexed) {
      final share = dashShareLabel(shares[i], r.amount);
      final cell = mini
          ? w(_shortStage[r.label] ?? r.label, DashText.label) + 10 + w(_wholeMoney(r.amount), DashText.money)
          : math.max(
              w(r.label, DashText.label.copyWith(fontSize: 12.5)),
              w(_wholeMoney(r.amount), DashText.money) + w('  ${dashCount(r.jobs, 'job')} · $share', DashText.meta),
            );
      widest = math.max(widest, cell);
    }
    return widest + 16 + 12; // the dot and its gap, and room for the half pixels text rounds up to
  }

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    final max = rows.fold<double>(0, (m, r) => math.max(m, r.amount));
    final total = rows.fold<double>(0, (t, r) => t + r.amount);
    // Whole percentages that add up to 100 (a sliver reads "<1%", never 0%).
    final shares = dashShares([for (final r in rows) r.amount]);
    // The server sends every stage, $0 ones too, so nothing owed is every stage at $0, not an empty list.
    final owed = rows.any((r) => r.amount > 0);
    final callout = over90 > 0 ? '${_wholeMoney(over90)} is at the 90 Day Notice stage' : 'Nothing is at the 90 Day Notice stage';
    final calloutStyle = DashText.meta.copyWith(fontWeight: FontWeight.w700, color: over90 > 0 ? DashUi.redText : DashUi.emeraldText);
    final mini = layout == _AgingLayout.mini;
    return DashPanel(
      fill: true,
      header: DashPanelHeader(
        g: g,
        title: 'Unpaid invoices by stage',
        note: today.isEmpty ? null : 'as of today',
        tooltip: 'Jobs that have been invoiced and not paid in full, grouped by how far the collection process has got (the notice the job has '
            "reached, not how old its invoice is). The same stages and amounts as the Collections dashboard. It is today's balance: nothing keeps "
            'what was owed on an earlier date.',
        // The smallest layout has no line to spare under the title, so the finding sits at its right.
        trailing: mini && owed
            ? Text(over90 > 0 ? '${_wholeMoney(over90)} at 90 Day Notice' : 'None at 90 Day Notice', maxLines: 1, style: calloutStyle)
            : null,
      ),
      child: !owed
          ? const DashEmptyNote('Nothing is waiting to be collected')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!mini) SizedBox(height: calloutH(g), child: Text(callout, maxLines: 1, overflow: TextOverflow.ellipsis, style: calloutStyle)),
                if (layout == _AgingLayout.grid) ...[
                  _AgingSplitBar(rows: rows, total: total),
                  const SizedBox(height: 10),
                ],
                Expanded(child: layout == _AgingLayout.rows ? _rowsView(max, shares) : _gridView(g, shares, mini: mini)),
              ],
            ),
    );
  }

  Widget _rowsView(double max, List<int> shares) => LayoutBuilder(
        builder: (context, c) {
          final h = c.maxHeight.isFinite ? math.min(c.maxHeight / rows.length, 64.0) : 64.0;
          return Align(
            alignment: Alignment.topCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < rows.length; i++)
                  SizedBox(height: h, child: _AgingRowView(row: rows[i], color: _agingColors[i % _agingColors.length], max: max, share: shares[i], index: i)),
              ],
            ),
          );
        },
      );

  /// The stages in [columns] columns, in order across then down, spread over the height there is (never below a cell).
  Widget _gridView(DashGeo g, List<int> shares, {required bool mini}) {
    final lines = (rows.length / columns).ceil();
    final base = cellH(g, mini: mini);
    return LayoutBuilder(
      builder: (context, c) {
        final h = c.maxHeight.isFinite ? (c.maxHeight / lines).clamp(base, base + 14).toDouble() : base;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var r = 0; r < lines; r++)
              SizedBox(
                height: h,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var col = 0; col < columns; col++) ...[
                      if (col > 0) const SizedBox(width: 10),
                      Expanded(
                        child: r * columns + col < rows.length
                            ? _AgingCell(
                                row: rows[r * columns + col],
                                color: _agingColors[(r * columns + col) % _agingColors.length],
                                share: shares[r * columns + col],
                                mini: mini,
                                index: r * columns + col,
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// All of what is owed as one bar, split by stage in the stages' colours; it sweeps in from the left.
class _AgingSplitBar extends StatelessWidget {
  final List<_AgingRow> rows;
  final double total;
  const _AgingSplitBar({required this.rows, required this.total});

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final parts = [for (var i = 0; i < rows.length; i++) if (rows[i].amount > 0) i];
    return ExcludeSemantics(
      child: SizedBox(
        height: 10,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: still ? 1 : 0, end: 1),
          duration: still ? Duration.zero : const Duration(milliseconds: 900),
          curve: Curves.easeOutCubic,
          builder: (context, v, child) => ClipRect(child: Align(alignment: Alignment.centerLeft, widthFactor: v, child: child)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var k = 0; k < parts.length; k++) ...[
                  if (k > 0) const SizedBox(width: 2),
                  Expanded(
                    flex: math.max(1, (rows[parts[k]].amount / (total <= 0 ? 1 : total) * 1000).round()),
                    child: ColoredBox(color: _agingColors[parts[k] % _agingColors.length]),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One stage in the grid: its colour, its name, and its amount with the jobs and the share (mini: the short name and
/// the amount on one line, the rest in the hover text). Each one rises in after the one before.
class _AgingCell extends StatelessWidget {
  final _AgingRow row;
  final Color color;

  /// The stage's whole-percent share of what is owed (the shares add up to 100).
  final int share;
  final bool mini;
  final int index;
  const _AgingCell({required this.row, required this.color, required this.share, required this.mini, required this.index});

  @override
  Widget build(BuildContext context) {
    final pct = dashShareLabel(share, row.amount);
    final still = MediaQuery.disableAnimationsOf(context);
    final dot = Container(width: 9, height: 9, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)));
    final Widget body = mini
        ? Row(
            children: [
              dot,
              const SizedBox(width: 7),
              Expanded(child: Text(_shortStage[row.label] ?? row.label, maxLines: 1, style: DashText.label)),
              Text(_wholeMoney(row.amount), maxLines: 1, style: DashText.money),
            ],
          )
        : Row(
            children: [
              dot,
              const SizedBox(width: 7),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(row.label, maxLines: 1, style: DashText.label.copyWith(fontSize: 12.5)),
                    Text.rich(
                      TextSpan(children: [
                        TextSpan(text: _wholeMoney(row.amount), style: DashText.money.copyWith(height: 1.2)),
                        TextSpan(text: '  ${dashCount(row.jobs, 'job')} · $pct', style: DashText.meta.copyWith(height: 1.2)),
                      ]),
                      maxLines: 1,
                    ),
                  ],
                ),
              ),
            ],
          );
    return Tooltip(
      message: '${row.label}: ${_wholeMoney(row.amount)} on ${dashCount(row.jobs, 'job')}, $pct of what is owed',
      waitDuration: const Duration(milliseconds: 400),
      child: Semantics(
        container: true,
        label: '${row.label}: ${_wholeMoney(row.amount)}, ${dashCount(row.jobs, 'job')}, $pct of what is owed',
        child: ExcludeSemantics(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: still ? 1 : 0, end: 1),
            duration: still ? Duration.zero : Duration(milliseconds: 420 + index * 90),
            curve: Curves.easeOutCubic,
            builder: (context, v, child) => Opacity(opacity: v, child: Transform.translate(offset: Offset(0, (1 - v) * 6), child: child)),
            child: body,
          ),
        ),
      ),
    );
  }
}

class _AgingRowView extends StatelessWidget {
  final _AgingRow row;
  final Color color;
  final double max;

  /// The stage's whole-percent share of what is owed (the shares add up to 100).
  final int share;
  final int index;
  const _AgingRowView({required this.row, required this.color, required this.max, required this.share, required this.index});

  @override
  Widget build(BuildContext context) {
    final frac = max > 0 ? row.amount / max : 0.0;
    final pct = dashShareLabel(share, row.amount);
    final still = MediaQuery.disableAnimationsOf(context);
    final ms = 500 + index * 90;
    return Semantics(
      container: true,
      label: '${row.label}: ${_wholeMoney(row.amount)}, ${dashCount(row.jobs, 'job')}, $pct of what is owed',
      child: ExcludeSemantics(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(child: Text(row.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.name.copyWith(fontWeight: FontWeight.w700))),
                Text('${dashCount(row.jobs, 'job')} · $pct', maxLines: 1, style: DashText.meta),
                const SizedBox(width: 12),
                Text(_wholeMoney(row.amount), maxLines: 1, style: DashText.bigMoney),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: Container(
                height: 8,
                color: DashUi.faint,
                alignment: Alignment.centerLeft,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: still ? frac : 0, end: frac),
                  duration: still ? Duration.zero : Duration(milliseconds: ms),
                  curve: Curves.easeOutCubic,
                  builder: (context, v, _) => FractionallySizedBox(
                    widthFactor: v.clamp(0.0, 1.0),
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [color.withValues(alpha: 0.65), color]),
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// GRID (shared by the page and its skeleton)
// =============================================================================

/// How the right-hand column is split: the unpaid invoices' layout and height, and whether the column takes half the
/// width (rather than two fifths) so a short window's grid fits three stages to a line.
typedef _RightPlan = ({_AgingLayout layout, int columns, double agingH, bool wide});

/// Lays the page out to fit the window:
///   desktop    the scorecards; then the chart over the customer reviews on the left, and down the right the customer
///              response time over the unpaid invoices by stage (1000 px wide and up). The invoices take the roomiest
///              layout that leaves the response graph its room: a row per stage on a tall window, a split bar and a grid
///              of stages on most, one line per stage on the shortest; the response graph takes the rest.
///   narrower   everything in one column that scrolls, like the dashboards
class _OfficeGrid extends StatelessWidget {
  final List<_TileSpec> tiles;
  final Widget chart;
  final Widget response;
  final Widget Function(_AgingLayout layout, int columns) aging;

  /// The stages (what the invoices card needs room for).
  final List<_AgingRow> stages;

  /// The reviews card for a number of lines of review, and whether there are reviews to read.
  final Widget Function(int lines) reviews;
  final bool hasReviews;

  /// Placeholders instead of scorecards (the skeleton).
  final bool skeleton;
  const _OfficeGrid({
    required this.tiles,
    required this.chart,
    required this.response,
    required this.aging,
    required this.stages,
    required this.reviews,
    required this.hasReviews,
    this.skeleton = false,
  });

  static const _wideFrom = 1000.0;
  static const _minChart = 236.0;
  static const _tileGap = 12.0;

  /// The response graph's extra room before the invoices get a row per stage.
  static const _roomForRows = 90.0;

  Widget _tile(_TileSpec t, int index) => skeleton ? const DashSkeletonTile() : _KpiTile(spec: t, index: index);

  /// The roomiest split of the right-hand column that fits [body], or null when none does.
  _RightPlan? _plan(BuildContext context, DashGeo g, double width, double body) {
    final n = math.max(stages.length, 1);
    final rowsH = _AgingPanel.minHeight(g, n) + n * 6;
    if (body - dashGap - rowsH >= _ResponsePanel.minHeight(g) + _roomForRows) return (layout: _AgingLayout.rows, columns: 1, agingH: rowsH, wide: false);
    int columns(bool wide, bool mini) {
      final inner = (width - dashGap) * (wide ? 1 / 2 : 2 / 5) - 40; // the panel's padding
      final need = _AgingPanel.cellWidth(context, stages, mini: mini);
      return (inner - 20) / 3 >= need ? 3 : ((inner - 10) / 2 >= need ? 2 : 1);
    }

    for (final tight in const [false, true]) {
      final respMin = _ResponsePanel.minHeight(g, tight: tight);
      for (final (layout, wide) in const [
        (_AgingLayout.grid, false),
        (_AgingLayout.grid, true),
        (_AgingLayout.mini, false),
        (_AgingLayout.mini, true),
      ]) {
        final cols = columns(wide, layout == _AgingLayout.mini);
        final h = _AgingPanel.minHeight(g, n, layout: layout, columns: cols);
        if (body - dashGap - h >= respMin) return (layout: layout, columns: cols, agingH: h, wide: wide);
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final body = c.maxHeight - g.tile - dashGap;
        final leftFits = body >= _minChart + dashGap + _ReviewsCard.height(g, 1);
        final plan = w >= _wideFrom && c.maxHeight.isFinite && leftFits ? _plan(context, g, w, body) : null;
        final Widget content;
        if (plan != null) {
          // More lines of review while the chart keeps its room.
          final lines = hasReviews
              ? (body - dashGap - _ReviewsCard.height(g, 3) >= 300 ? 3 : (body - dashGap - _ReviewsCard.height(g, 2) >= 270 ? 2 : 1))
              : 1;
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
                    Expanded(
                      flex: plan.wide ? 1 : 3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: chart),
                          const SizedBox(height: dashGap),
                          SizedBox(height: _ReviewsCard.height(g, lines), child: skeleton ? const DashSkeletonPanel(rows: 1, rowH: 20) : reviews(lines)),
                        ],
                      ),
                    ),
                    const SizedBox(width: dashGap),
                    Expanded(
                      flex: plan.wide ? 1 : 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: response),
                          const SizedBox(height: dashGap),
                          SizedBox(height: plan.agingH, child: aging(plan.layout, plan.columns)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        } else {
          final perRow = w >= 900 ? (tiles.length / 2).ceil() : (w >= 560 ? 2 : 1);
          final tileW = (w - _tileGap * (perRow - 1)) / perRow;
          final n = math.max(stages.length, 1);
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
                SizedBox(height: 360, child: chart),
                const SizedBox(height: dashGap),
                SizedBox(height: 320, child: response),
                const SizedBox(height: dashGap),
                SizedBox(height: _AgingPanel.minHeight(g, n) + 8, child: aging(_AgingLayout.rows, 1)),
                const SizedBox(height: dashGap),
                SizedBox(height: _ReviewsCard.height(g, hasReviews ? 5 : 1), child: skeleton ? const DashSkeletonPanel(rows: 1, rowH: 20) : reviews(5)),
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
class _OfficeSkeleton extends StatelessWidget {
  const _OfficeSkeleton();

  /// Stand-ins the size of the real stages, so the skeleton takes the same layout as the page.
  static const _stages = [
    _AgingRow('Final Invoice Sent', 68400, 105),
    _AgingRow('14 Day Notice', 44500, 30),
    _AgingRow('30 Day Notice', 10500, 8),
    _AgingRow('60 Day Notice', 8600, 6),
    _AgingRow('90 Day Notice', 22577, 40),
    _AgingRow('Check on Payment', 83600, 20),
  ];

  @override
  Widget build(BuildContext context) {
    final placeholder = _TileSpec(title: '', value: null, format: (v) => '', captions: const [''], definition: '', color: DashUi.muted);
    return Semantics(
      label: 'Loading figures',
      child: ExcludeSemantics(
        child: SkeletonPulse(
          child: _OfficeGrid(
            skeleton: true,
            tiles: List.filled(6, placeholder),
            chart: const DashSkeletonPanel(fill: true),
            response: const DashSkeletonPanel(fill: true),
            aging: (layout, columns) => const DashSkeletonPanel(fill: true),
            stages: _stages,
            reviews: (_) => const SizedBox.shrink(),
            hasReviews: false,
          ),
        ),
      ),
    );
  }
}
