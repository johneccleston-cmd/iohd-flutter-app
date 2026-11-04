part of 'kpi_dashboard_screen.dart';

// =============================================================================
// TECHNICIAN KPI PAGE (/hr/kpis/:username for anyone whose role says "tech")
// =============================================================================
//
// Built from the dashboards' kit so it reads like the Technicians and Collections dashboards: the dark title bar with
// a year picker and Refresh, a row of scorecards, the monthly chart beside how the tech compares, and a row about the
// person, all on one screen without scrolling at desktop sizes (one scrolling column below 1000 px wide, like the
// dashboards). Every figure and animation the page had before is still here, as on every KPI page: rank, milestone and
// integrity score; peer rating; morale with its heartbeat and Preview; inventory and callback strikes; the streak's
// flame; rotating customer reviews; trend lines that draw themselves; a chart that steps through its views.
//
// Where each figure comes from (the year picked, unless it says otherwise):
//   GET /api/employees/:username/kpis?year=Y   `tech`: labor billed, the calendar days worked on those jobs, completed
//        jobs and the months; the rest of the team's labor per work day (line and total, and `team.sameMonths`: pooled
//        over only the months this tech worked, the one figure the page compares against); every current tech's
//        figures (`teamMembers`, newer servers); Google reviews that name the tech (all time); service-call
//        conversions. `employee.inventoryStrikes` is all time (the counter keeps no dates). `supervisor` marks the
//        field supervisor.
//   GET /api/tech_stats?year=Y   callback strikes, the jobs they are counted against and the callback-free streak for
//        every tech, and the company callback rate (the Technicians dashboard's source). Best effort: without it the
//        callback figures say they couldn't load (a failed Refresh keeps the last ones).
//   /users (the KPI list)   integrity score, rank and years with the company. The score starts each year at 100 and
//        loses points for every missed completion (a visit the office had to mark complete), sent as missedCompletions.

/// Callback tracking began here (the server's COMMISSION_RULES.GO_LIVE_DATE). Only used when an older server doesn't
/// say where this year's count starts.
const _callbackGoLive = '2026-10-05';

/// The fewest work days a month needs to count in the chart's stories (best month, months against the team, the
/// average month): a first month of two days is not a fair month to judge.
const _storyMinDays = 5;

/// The fewest work days a tech needs in the year to be ranked in the team table (fewer are listed after, unranked).
const _rankMinDays = 10;

/// One month of a tech's year. [laborDays] are the calendar days worked on completed labor jobs that month.
class _TechMonth {
  final int jobs;
  final double labor;
  final int laborDays;
  final double? laborPerDay;
  const _TechMonth(this.jobs, this.labor, this.laborDays, this.laborPerDay);
}

/// A current tech's year (`teamMembers`), on exactly the basis of their own page.
class _TeamMember {
  final String username;
  final String name;
  final double labor;
  final int laborDays;
  final double? laborPerDay;
  final int inventoryStrikes;
  const _TeamMember(this.username, this.name, this.labor, this.laborDays, this.laborPerDay, this.inventoryStrikes);
}

/// One tech's callback figures from /api/tech_stats: strikes since go-live, the completed jobs since then where they did
/// the original work (the only jobs a strike can come from), and the jobs since their last callback.
class _CallbackLine {
  final String username;
  final String name;
  final String avatarUrl;

  /// "Lead Technician" (the title the Technicians dashboard shows); '' from an older server.
  final String jobTitle;
  final int strikes;

  /// Null from a server that doesn't send `callbackJobs`: then there is no rate rather than a wrong one (its fallback,
  /// the whole year's jobs, would divide strikes since Oct 5 by jobs since January).
  final int? jobs;
  final int streak;
  const _CallbackLine(this.username, this.name, this.avatarUrl, this.strikes, this.jobs, this.streak, [this.jobTitle = '']);

  double? get ratePct => (jobs ?? 0) > 0 ? strikes / jobs! * 100 : null;
}

/// Callbacks over a group of techs: strikes ÷ jobs, each job counted once per tech who worked it (like the strikes).
double? _pooledCallbackRate(Iterable<_CallbackLine> lines) {
  final c = _pooledCallbacks(lines);
  return c == null || c.jobs <= 0 ? null : c.strikes / c.jobs * 100;
}

/// The strikes and jobs of a group of techs added up; null when a server doesn't send the jobs.
({int strikes, int jobs})? _pooledCallbacks(Iterable<_CallbackLine> lines) {
  var strikes = 0, jobs = 0;
  for (final l in lines) {
    if (l.jobs == null) return null;
    strikes += l.strikes;
    jobs += l.jobs!;
  }
  return (strikes: strikes, jobs: jobs);
}

/// A callback rate against a reference rate (lower is better): on par when they are less than one strike apart (100 ÷
/// the jobs the rate is counted on) or within 5% of each other, as one strike more or less on a few dozen jobs moves a
/// rate by several points. Null without both.
_Verdict? _callbackVerdict(double? rate, int? jobs, double? ref) {
  if (rate == null || ref == null || jobs == null || jobs <= 0) return null;
  if ((rate - ref).abs() < 100 / jobs) return _Verdict.par;
  return _verdict(rate, ref, higherBetter: false);
}

/// The rest of the team pooled over only the months this tech has labor days in (`team.sameMonths`): [months] are those
/// months (1-12), [allMonths] says they are every month the rest of the team worked (the same as the full year).
typedef _SameMonths = ({List<int> months, bool allMonths, double? laborPerDay, double labor, int days});

/// The company callback rate the Technicians dashboard shows: each callback visit once ÷ every completed job.
typedef _CompanyCallbacks = ({double? ratePct, int callbacks, int jobs});

/// Months (1-12) in words: "Jul–Oct", "Mar", "Jan–Mar, May–Oct"; "8 months" when broken up more than that.
String _monthSpan(List<int> months) {
  final sorted = {...months}.toList()..sort();
  if (sorted.isEmpty) return '';
  final runs = <(int, int)>[];
  for (final m in sorted) {
    if (runs.isNotEmpty && runs.last.$2 == m - 1) {
      runs[runs.length - 1] = (runs.last.$1, m);
    } else {
      runs.add((m, m));
    }
  }
  if (runs.length > 2) return '${sorted.length} months';
  String name(int m) => dashMonthNames[(m - 1).clamp(0, 11)];
  return [for (final r in runs) r.$1 == r.$2 ? name(r.$1) : '${name(r.$1)}–${name(r.$2)}'].join(', ');
}

/// Everything the page shows for one tech and one year.
class _TechPage {
  final int year;
  final String username;

  /// False when the server sent no technician figures for this person (a role it doesn't treat as a tech).
  final bool hasTech;
  final int jobs;
  final int laborJobs;
  final double labor;
  final double? laborPerDay;
  final int laborDays;

  /// Twelve months, January first; null where nothing was worked.
  final List<_TechMonth?> months;

  /// The rest of the team's labor per work day by month (twelve, null where none of them worked).
  final List<double?> teamPerDay;

  /// The rest of the team's labor per work day over the whole year.
  final double? teamLaborPerDay;

  /// The rest of the team over only the months this tech worked; null from an older server.
  final _SameMonths? sameMonths;
  final double? teamAvgStrikes;

  /// How many other current techs the team figures pool.
  final int? teamTechs;

  /// Every current tech's year (this one included); empty from an older server.
  final List<_TeamMember> members;
  final int inventoryStrikes;
  final _Rating? satisfaction;
  final List<_Mention> mentions;
  final _Rating? peerRating;
  final _Rating? morale;
  final ({int evals, int converted})? evalConversion;
  final bool supervisor;

  /// Every tech's callback figures; null when /api/tech_stats couldn't be loaded.
  final List<_CallbackLine>? callbackTeam;

  /// Where this year's callback count starts ("2026-10-05"); null when the year has none (before go-live).
  final String? callbackFrom;

  /// The Technicians dashboard's company callback rate; null when tech_stats couldn't be loaded or doesn't send it.
  final _CompanyCallbacks? company;

  const _TechPage({
    required this.year,
    required this.username,
    required this.hasTech,
    required this.jobs,
    required this.laborJobs,
    required this.labor,
    required this.laborPerDay,
    required this.laborDays,
    required this.months,
    required this.teamPerDay,
    required this.teamLaborPerDay,
    required this.sameMonths,
    required this.teamAvgStrikes,
    required this.teamTechs,
    required this.members,
    required this.inventoryStrikes,
    required this.satisfaction,
    required this.mentions,
    required this.peerRating,
    required this.morale,
    required this.evalConversion,
    required this.supervisor,
    required this.callbackTeam,
    required this.callbackFrom,
    required this.company,
  });

  factory _TechPage.parse({required Map<String, dynamic> kpis, Map<String, dynamic>? stats, required String username, required int year}) {
    final t = kpis['tech'] is Map ? Map<String, dynamic>.from(kpis['tech'] as Map) : const <String, dynamic>{};
    final emp = kpis['employee'] is Map ? kpis['employee'] as Map : const {};
    int whole(dynamic v) => int.tryParse(_str(v)) ?? (_num(v)?.round() ?? 0);

    final months = List<_TechMonth?>.filled(12, null);
    for (final m in (t['monthly'] is List ? t['monthly'] as List : const [])) {
      if (m is! Map) continue;
      final k = whole(m['month']) - 1;
      if (k < 0 || k > 11) continue;
      final labor = _num(m['labor']) ?? 0;
      final perDay = _num(m['laborPerDay']);
      // An older server doesn't send the month's days; labor ÷ labor per day gives them back (a whole number).
      final days = m.containsKey('laborDays') ? whole(m['laborDays']) : (perDay != null && perDay > 0 ? (labor / perDay).round() : 0);
      months[k] = _TechMonth(whole(m['jobs']), labor, days, perDay);
    }
    final team = _monthSeries(t['teamMonthly'], 'laborPerDay');
    final teamTotals = t['team'] is Map ? t['team'] as Map : const {};
    final same = teamTotals['sameMonths'];
    final ec = t['evalConversion'];

    List<_CallbackLine>? callbackTeam;
    String? callbackFrom;
    _CompanyCallbacks? company;
    if (stats != null) {
      callbackTeam = [
        for (final c in (stats['techs'] is List ? stats['techs'] as List : const []))
          if (c is Map)
            _CallbackLine(
              _str(c['id']),
              _str(c['name']),
              _str(c['avatarUrl']),
              whole(c['callbackCount']),
              c.containsKey('callbackJobs') ? whole(c['callbackJobs']) : null,
              whole(c['jobsSinceCallback']),
              _str(c['jobTitle']),
            ),
      ];
      final summary = stats['summary'] is Map ? stats['summary'] as Map : const {};
      final metrics = summary['metrics'] is Map ? summary['metrics'] as Map : const {};
      if (metrics.containsKey('callbackJobs')) {
        company = (ratePct: _num(metrics['callbackRatePct']), callbacks: whole(metrics['callbacks']), jobs: whole(metrics['callbackJobs']));
      }
      final period = metrics['callbackPeriod'];
      if (period is Map) {
        callbackFrom = _str(period['from']).isEmpty ? null : _str(period['from']);
      } else if (!metrics.containsKey('callbackPeriod')) {
        // An older server: the count starts at go-live (2026) or on January 1 (later years).
        callbackFrom = year < 2026 ? null : (year == 2026 ? _callbackGoLive : '$year-01-01');
      }
    }

    final monthDays = months.fold<int>(0, (s, m) => s + (m?.laborDays ?? 0));
    return _TechPage(
      year: year,
      username: username,
      hasTech: kpis['tech'] is Map,
      jobs: whole(t['jobs']),
      laborJobs: whole(t['laborJobs']),
      labor: _num(t['laborDollars']) ?? 0,
      laborPerDay: _num(t['laborPerDay']),
      laborDays: t.containsKey('laborDays') ? whole(t['laborDays']) : monthDays,
      months: months,
      teamPerDay: team.isEmpty ? List<double?>.filled(12, null) : team,
      teamLaborPerDay: _num(teamTotals['laborPerDay']),
      sameMonths: same is Map
          ? (
              months: [
                for (final m in (same['months'] is List ? same['months'] as List : const []))
                  if (whole(m) >= 1 && whole(m) <= 12) whole(m),
              ],
              allMonths: same['allMonths'] == true,
              laborPerDay: _num(same['laborPerDay']),
              labor: _num(same['labor']) ?? 0,
              days: whole(same['days']),
            )
          : null,
      teamAvgStrikes: _num(teamTotals['avgInventoryStrikes']),
      teamTechs: teamTotals['techs'] == null ? null : whole(teamTotals['techs']),
      members: [
        for (final m in (t['teamMembers'] is List ? t['teamMembers'] as List : const []))
          if (m is Map && _str(m['username']).isNotEmpty)
            _TeamMember(
              _str(m['username']),
              _str(m['name']).isEmpty ? _str(m['username']) : _str(m['name']),
              _num(m['labor']) ?? 0,
              whole(m['laborDays']),
              _num(m['laborPerDay']),
              whole(m['inventoryStrikes']),
            ),
      ],
      inventoryStrikes: whole(emp['inventoryStrikes']),
      satisfaction: _Rating.fromJson(t['satisfaction']),
      mentions: [
        for (final m in (t['reviews'] is List ? t['reviews'] as List : const [])) ?_Mention.fromJson(m),
      ],
      peerRating: _Rating.fromJson(t['employeeRating']),
      morale: _Rating.fromJson(kpis['morale']),
      evalConversion: ec is Map ? (evals: whole(ec['evals']), converted: whole(ec['converted'])) : null,
      supervisor: kpis['supervisor'] is Map,
      callbackTeam: callbackTeam,
      callbackFrom: callbackFrom,
      company: company,
    );
  }

  bool _isMe(String u) => u.toLowerCase() == username.toLowerCase();

  /// This tech's callback figures; null when they couldn't be loaded or the tech isn't listed.
  _CallbackLine? get callbacks => callbackTeam?.where((c) => _isMe(c.username)).firstOrNull;

  /// Everyone else's callback rate, pooled (the comparison leaves this tech out, like the labor figure).
  double? get othersCallbackRate {
    final o = othersCallbacks;
    return o == null || o.jobs <= 0 ? null : o.strikes / o.jobs * 100;
  }

  /// Everyone else's strikes and jobs added up; null without this tech's own figures to compare.
  ({int strikes, int jobs})? get othersCallbacks {
    final team = callbackTeam;
    if (team == null || callbacks == null) return null;
    return _pooledCallbacks(team.where((c) => !_isMe(c.username)));
  }

  /// This tech's callback rate against everyone else's (on par within a strike's worth or 5%).
  _Verdict? get callbackVerdict => _callbackVerdict(callbacks?.ratePct, callbacks?.jobs, othersCallbackRate);

  /// Every tech's callback rate pooled, this one included (what the other techs' rows in the team table read against).
  double? get wholeTeamCallbackRate => callbackTeam == null ? null : _pooledCallbackRate(callbackTeam!);

  /// Every current tech's inventory strikes averaged, this one included (what the other techs' strikes in the team
  /// table read against, like [wholeTeamCallbackRate]); null from an older server.
  double? get wholeTeamAvgStrikes => members.isEmpty ? null : members.fold<int>(0, (s, m) => s + m.inventoryStrikes) / members.length;

  /// THE rest-of-team labor per work day the page compares against: over only the months this tech worked (when the
  /// server sends it), else the whole year (an older server, or a year this tech didn't work at all: no months to pool
  /// over, and the team table still shows what the rest of the team did).
  double? get restPerDay => sameMonths != null && sameMonths!.months.isNotEmpty ? sameMonths!.laborPerDay : teamLaborPerDay;

  /// "Jul–Oct" when the rest of the team's figure covers fewer months than their whole year (the tech worked only
  /// some of them); null when it is the same as the year.
  String? get restSpan {
    final s = sameMonths;
    if (s == null || s.allMonths || s.months.isEmpty) return null;
    return _monthSpan(s.months);
  }

  /// An older server's rest-of-team figure is the whole year even when this tech worked only part of it: the months
  /// they worked ("Jul–Oct"), so the page can say so; null when there is nothing to say.
  String? get restYearOnlySpan {
    if (sameMonths != null) return null;
    final mine = [for (var i = 0; i < 12; i++) if ((months[i]?.laborDays ?? 0) > 0) i + 1];
    final theirs = [for (var i = 0; i < 12; i++) if (teamPerDay[i] != null) i + 1];
    if (mine.isEmpty || theirs.every(mine.contains)) return null;
    return _monthSpan(mine);
  }

  /// How many other current techs the rest of the team pools: those with work days in the year (a tech who didn't work
  /// that year adds nothing), or what an older server says.
  int? get restTechs => members.isNotEmpty ? members.where((m) => !_isMe(m.username) && m.laborDays > 0).length : teamTechs;

  /// Average labor on a job that had labor.
  double? get laborPerJob => laborJobs > 0 ? labor / laborJobs : null;

  /// Whether the year is this year (the callback-free streak is a "today" figure, only shown then).
  bool get isCurrentYear => year == DashClock.now().year;
}

/// How [mine] compares with [rest] (the rest of the team): "57% below rest of team ($1,736)", or "On par ..." within
/// 5% either way (as shown, so "5% above" never sits beside an "On par"). With [amount] false the figure in brackets is
/// left out (a narrow scorecard); with a [span] the months it covers are named ("59% below rest of team, Jul–Oct
/// ($1,849)"). Null without both.
String? _versusTeam(double? mine, double? rest, {bool amount = true, String? span}) {
  if (mine == null || rest == null || rest <= 0) return null;
  final pct = (mine - rest) / rest * 100;
  final tail = '${span == null ? '' : ', $span'}${amount ? ' (${_wholeMoney(rest)})' : ''}';
  if (_parPct(pct)) return 'On par with rest of team$tail';
  return '${pct.abs().round()}% ${pct > 0 ? 'above' : 'below'} rest of team$tail';
}

/// Within 5% either way, as the page shows it (rounded to a whole percent).
bool _parPct(double pct) => pct.abs().round() <= 5;

/// "1st", "2nd", "3rd", "4th", "11th".
String _ordinal(int n) {
  final teen = n % 100 >= 11 && n % 100 <= 13;
  final suffix = teen ? 'th' : switch (n % 10) { 1 => 'st', 2 => 'nd', 3 => 'rd', _ => 'th' };
  return '$n$suffix';
}

/// A rate as shown on the page: "4.5%".
String _pct1(double v) => '${v.toStringAsFixed(1)}%';

/// A scorecard's trend line over the finished months, or none when they are all zero (a year with no work in it): a
/// flat line along the bottom says nothing.
List<double>? _trendOf(List<double> monthly, int year) {
  final t = dashTrend(monthly, year);
  return t == null || t.every((v) => v <= 0) ? null : t;
}

/// The photo URL to show, or '' for initials: the old /users fallback is a third-party avatar service, and names are
/// never sent to an outside service.
String _ownPhoto(String url) => url.contains('ui-avatars.com') ? '' : url;


/// Ahead / On par / Behind, the team comparison's words: within 5% of the rest of the team either way is on par.
enum _Verdict { ahead, par, behind }

_Verdict? _verdict(double? mine, double? rest, {required bool higherBetter}) {
  if (mine == null || rest == null) return null;
  final diff = mine - rest;
  if (rest == 0 ? diff == 0 : _parPct(diff / rest.abs() * 100)) return _Verdict.par;
  return (diff > 0) == higherBetter ? _Verdict.ahead : _Verdict.behind;
}


// =============================================================================
// THE PAGE
// =============================================================================

/// Peer rating and morale, shown in the title bar but loaded with the page's figures, and the Preview's sample scores
/// (which also fill in sample reviews when there are none). Real figures always win over samples.
class _TechRatings extends ChangeNotifier {
  /// Only the technician and warehouse pages show a peer rating; the office and sales pages show morale alone.
  final bool hasPeer;
  _TechRatings({this.hasPeer = true});

  _Rating? peer;
  _Rating? morale;

  /// Preview: sample scores so the ratings can be seen before anything records them, labelled as samples.
  bool sample = false;
  int sampleIdx = 0;
  static const _sampleMorale = [3.6, 4.5, 2.4, 1.6];
  static const _samplePeer = _Rating(4.2, 6);

  _Rating? get shownPeer => peer ?? (sample ? _samplePeer : null);
  _Rating? get shownMorale => morale ?? (sample ? _Rating(_sampleMorale[sampleIdx % _sampleMorale.length], 9) : null);
  bool get peerIsSample => peer == null && sample;
  bool get moraleIsSample => morale == null && sample;

  /// Nothing to preview once both are recorded (just morale on a page without a peer rating).
  bool get canPreview => (hasPeer && peer == null) || morale == null;

  void set(_Rating? p, _Rating? m) {
    peer = p;
    morale = m;
    notifyListeners();
  }

  /// Shows or hides the samples outright (the office page's response-time card has its own Preview and Hide).
  void preview(bool on) {
    if (on == sample) return;
    sample = on;
    sampleIdx = 0;
    notifyListeners();
  }

  /// The morale badge's tap: the first shows samples, the next ones try other sample scores, after the last it hides.
  void tapPreview() {
    if (!canPreview) return;
    if (!sample) {
      sample = true;
    } else if (sampleIdx < _sampleMorale.length - 1) {
      sampleIdx++;
    } else {
      sample = false;
      sampleIdx = 0;
    }
    notifyListeners();
  }
}

/// The title bar (back button, photo, name, title, time with the company, rank, milestone, integrity score, peer
/// rating and morale) and the year picker; the content below loads the year picked.
class _TechKpiPage extends StatefulWidget {
  final _EmployeeKpiArgs args;
  final String employeeId;
  const _TechKpiPage({super.key, required this.args, required this.employeeId});

  @override
  State<_TechKpiPage> createState() => _TechKpiPageState();
}

class _TechKpiPageState extends State<_TechKpiPage> {
  final _ratings = _TechRatings();

  _EmployeeKpiArgs get args => widget.args;
  String get employeeId => widget.employeeId;
  _EmployeeUser get user => args.entry.user;

  @override
  void dispose() {
    _ratings.dispose();
    super.dispose();
  }

  /// The years the picker offers: from the year this person was hired (as far as yearsWorked says) to now, at most
  /// four; the dashboards' three when the hire date isn't known.
  List<int> _years() {
    final now = DashClock.now();
    final hired = _hireDate(user)?.year;
    if (hired == null) return [now.year, now.year - 1, now.year - 2];
    return [for (var yr = now.year; yr >= math.max(hired, now.year - 3); yr--) yr];
  }

  /// The year asked for in the link (`?year=2025`, as a teammate's row passes it on), so going from one tech's 2025 to
  /// another's stays on 2025; null without one (or outside the app's router).
  int? _linkedYear(BuildContext context) {
    final uri = GoRouter.maybeOf(context)?.routerDelegate.currentConfiguration.uri;
    if (uri == null || uri.pathSegments.isEmpty || Uri.decodeComponent(uri.pathSegments.last) != employeeId) return null;
    return int.tryParse(uri.queryParameters['year'] ?? '');
  }

  @override
  Widget build(BuildContext context) {
    final tenure = user.yearsWorked == null ? null : '${_fmtTenure(user.yearsWorked)} at IOHD';
    return DashboardLayout(
      title: user.name,
      heading: user.name.toUpperCase(),
      subtitle: [user.displayTitle, ?tenure].join(' · '),
      leading: _HeaderLead(user: user, rank: args.entry.rank),
      titleTrailing: _HeaderBadges(args: args, ratings: _ratings),
      years: _years(),
      initialYear: _linkedYear(context),
      builder: (context, year) => _TechKpiContent(user: user, employeeId: employeeId, year: year, ratings: _ratings),
    );
  }
}

/// When this person started, as far as their time with the company says (to the day it gives, so about right); null
/// when it isn't known.
DateTime? _hireDate(_EmployeeUser user) {
  final y = user.yearsWorked;
  return y == null ? null : DashClock.now().subtract(Duration(days: (y * 365.25).round()));
}

/// The stretch of [year] a year-to-date figure covers for someone hired on [hired]: from the hire month when they
/// started that year ("Jul – today", "Jul – Dec"), otherwise the dashboards' words ("Jan 1 – today", "all of 2025").
String _techPeriod(int year, DateTime? hired) {
  if (hired == null || hired.year != year || hired.month == 1) return dashPeriodLabel(year);
  final from = dashMonthNames[hired.month - 1];
  return year == DashClock.now().year ? '$from – today' : '$from – Dec';
}

/// The photo in a person's title bar is taller than the bar: centred on the ribbon, it breaks out over the bottom of
/// the navigation bar above and the top of the page below.
const _kpiPhotoSize = 84.0;

/// Back to the KPI list, and the person's photo breaking out of the ribbon (a gold ring for the top rank, as on the
/// KPI list). The navigation bar paints over the page, so the ribbon keeps a slot and the photo goes on the shell's
/// [NavOverhang] layer, centred on the slot. Outside the shell it stays in the slot, overflowing it.
class _HeaderLead extends StatefulWidget {
  final _EmployeeUser user;
  final int? rank;
  const _HeaderLead({required this.user, required this.rank});

  @override
  State<_HeaderLead> createState() => _HeaderLeadState();
}

class _HeaderLeadState extends State<_HeaderLead> {
  final _slot = LayerLink();
  ValueNotifier<Widget?>? _layer;
  ModalRoute<Object?>? _route;
  bool _onScreen = true;
  Widget? _shown;

  Widget _photo() => _HeaderPhoto(name: widget.user.name, imageUrl: _ownPhoto(widget.user.avatarUrl), first: widget.rank == 1);

  /// The photo for the shell's layer: it follows the slot (hidden whenever the slot isn't painted) and fades with
  /// the page's route.
  Widget _overhang() {
    final route = _route;
    Widget photo = _photo();
    if (route?.animation != null) photo = FadeTransition(opacity: route!.animation!, child: photo);
    if (route?.secondaryAnimation != null) {
      photo = FadeTransition(opacity: ReverseAnimation(route!.secondaryAnimation!), child: photo);
    }
    return Positioned(
      key: ObjectKey(this),
      left: 0,
      top: 0,
      child: CompositedTransformFollower(
        link: _slot,
        showWhenUnlinked: false,
        targetAnchor: Alignment.center,
        followerAnchor: Alignment.center,
        child: SizedBox.square(dimension: _kpiPhotoSize, child: photo),
      ),
    );
  }

  /// Puts the photo on the shell's layer after this frame (the shell is above the page, so not while building).
  void _publish() {
    if (_layer == null) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _layer == null || !_onScreen) return;
      _layer!.value = _shown = _overhang();
    });
  }

  /// Takes the photo off the layer, unless another page's has replaced it meanwhile.
  void _withdraw(ValueNotifier<Widget?>? layer) {
    final mine = _shown;
    if (layer == null || mine == null) return;
    _shown = null;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (layer.value == mine) layer.value = null;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final layer = NavOverhang.maybeOf(context);
    _route = ModalRoute.of(context);
    if (layer != _layer) _withdraw(_layer);
    _layer = layer;
    // Another top-menu section open keeps this page built but hidden, with its tickers off: the photo goes too, and
    // comes back with its entrance.
    _onScreen = TickerMode.valuesOf(context).enabled;
    if (_onScreen) {
      _publish();
    } else {
      _withdraw(_layer);
    }
  }

  @override
  void didUpdateWidget(_HeaderLead old) {
    super.didUpdateWidget(old);
    if (old.user != widget.user || old.rank != widget.rank) _publish();
  }

  @override
  void dispose() {
    _withdraw(_layer);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'All employees',
          icon: const Icon(Icons.arrow_back_rounded),
          iconSize: 20,
          color: Colors.white,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 36, height: 36),
          padding: EdgeInsets.zero,
          onPressed: () => GoRouter.maybeOf(context)?.go('/hr/kpis'),
        ),
        const SizedBox(width: 10),
        // The slot takes a row's height in the bar; the photo over it is taller.
        CompositedTransformTarget(
          link: _slot,
          child: SizedBox(
            width: _kpiPhotoSize,
            height: 36,
            child: _layer != null
                ? null
                : OverflowBox(minHeight: _kpiPhotoSize, maxHeight: _kpiPhotoSize, child: _photo()),
          ),
        ),
      ],
    );
  }
}

/// The big title-bar photo: a navy coin with a gradient ring that sweeps round as the page opens while the photo
/// pops in, then a glint crosses it (again on hover). Still when animations are off.
class _HeaderPhoto extends StatefulWidget {
  final String name;
  final String imageUrl;
  final bool first;
  const _HeaderPhoto({required this.name, required this.imageUrl, required this.first});

  @override
  State<_HeaderPhoto> createState() => _HeaderPhotoState();
}

class _HeaderPhotoState extends State<_HeaderPhoto> with TickerProviderStateMixin {
  static const _ring = 3.5;
  static const _gap = 3.0;
  static const _sky = [Color(0xFF7DD3FC), Color(0xFF38BDF8), DashUi.indigo, Color(0xFF38BDF8), Color(0xFF7DD3FC)];
  static const _golden = [Color(0xFFFDE68A), _gold, Color(0xFFB45309), _gold, Color(0xFFFDE68A)];

  late final _enter = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) _shine.forward(from: 0);
    });
  late final _shine = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  bool _still = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.disableAnimationsOf(context);
    if (_still) {
      _enter.value = 1;
      _shine.value = 1;
    } else if (_enter.isDismissed) {
      _enter.forward();
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    _shine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.first ? _golden : _sky;
    const inner = _kpiPhotoSize - 2 * (_ring + _gap);
    // It sits over the navigation bar's edge and the page's top: clicks pass through to them, only hovering is caught.
    return MouseRegion(
      hitTestBehavior: HitTestBehavior.translucent,
      onEnter: (_) {
        if (!_still && _enter.isCompleted && !_shine.isAnimating) _shine.forward(from: 0);
      },
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: AnimatedBuilder(
            animation: Listenable.merge([_enter, _shine]),
            builder: (context, _) {
              final t = _enter.value;
              final sweep = Curves.easeOutCubic.transform(t);
              final pop = Curves.easeOutBack.transform((t / 0.55).clamp(0.0, 1.0));
              return Opacity(
                opacity: (t / 0.2).clamp(0.0, 1.0),
                child: Transform.scale(
                  scale: 0.72 + 0.28 * pop,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(color: colors[1].withValues(alpha: 0.35 * sweep), blurRadius: 18, spreadRadius: 1),
                        const BoxShadow(color: Color(0x59000000), blurRadius: 12, offset: Offset(0, 5)),
                      ],
                    ),
                    child: CustomPaint(
                      painter: _PhotoRingPainter(progress: sweep, colors: colors, width: _ring),
                      child: Padding(
                        padding: const EdgeInsets.all(_ring + _gap),
                        child: ClipOval(
                          child: ColoredBox(
                            // White behind the photo so the initials stand out on the navy bar.
                            color: Colors.white,
                            child: CustomPaint(
                              foregroundPainter: _GlintPainter(Curves.easeInOut.transform(_shine.value)),
                              child: DashAvatar(name: widget.name, imageUrl: widget.imageUrl, size: inner, accent: DashUi.sky),
                            ),
                          ),
                        ),
                      ),
                    ),
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

/// A navy disc with a faint track and a gradient ring drawn [progress] of the way round from the top.
class _PhotoRingPainter extends CustomPainter {
  final double progress;
  final List<Color> colors;
  final double width;
  const _PhotoRingPainter({required this.progress, required this.colors, required this.width});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    canvas.drawCircle(c, r, Paint()..color = DashUi.ink);
    final ring = Rect.fromCircle(center: c, radius: r - width / 2);
    canvas.drawCircle(c, r - width / 2, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = const Color(0x24FFFFFF));
    if (progress <= 0) return;
    canvas.drawArc(
      ring,
      -math.pi / 2,
      2 * math.pi * progress.clamp(0.0, 1.0),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = progress < 1 ? StrokeCap.round : StrokeCap.butt
        ..shader = SweepGradient(colors: colors, transform: const GradientRotation(-math.pi / 2)).createShader(ring),
    );
  }

  @override
  bool shouldRepaint(_PhotoRingPainter old) => old.progress != progress || old.colors != colors || old.width != width;
}

/// A soft diagonal band of light crossing the photo, top left to bottom right, as [t] runs 0 to 1.
class _GlintPainter extends CustomPainter {
  final double t;
  const _GlintPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1) return;
    final at = -0.35 + 1.7 * t;
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: const [Color(0x00FFFFFF), Color(0x00FFFFFF), Color(0x73FFFFFF), Color(0x00FFFFFF), Color(0x00FFFFFF)],
          stops: [0, (at - 0.14).clamp(0.0, 1.0), at.clamp(0.0, 1.0), (at + 0.14).clamp(0.0, 1.0), 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_GlintPainter old) => old.t != t;
}

/// "2 missed completions this year." for the score's hover text (nothing from an older server).
String _missedLine(int? n) => n == null
    ? ''
    : n == 0
    ? 'No missed completions this year.'
    : '$n missed completion${n == 1 ? '' : 's'} this year.';

/// Beside the name: the rank and milestone badges and the integrity score, its ring filling as the page opens.
/// The score is the KPI list's (/users); the hover text says what lowered it.
class _HeaderBadges extends StatelessWidget {
  final _EmployeeKpiArgs args;

  /// Peer rating and morale beside the score; null leaves them out (a page that shows morale in a card of its own).
  final _TechRatings? ratings;
  const _HeaderBadges({required this.args, required this.ratings});

  Widget _pill(IconData icon, String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
            Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, height: 1.2, color: color)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final user = args.entry.user;
    final rank = args.entry.rank;
    final score = user.integrityScore;
    final avg = args.teamAvg;
    final milestone = _milestone(user.yearsWorked);
    final delta = score != null && avg != null ? score - avg : null;
    final still = MediaQuery.disableAnimationsOf(context);
    final ringColor = score == null ? DashUi.muted : Color.lerp(_scoreColor(score), Colors.white, 0.15)!;
    final versus = delta == null
        ? null
        : (delta.abs() < 0.05 ? 'at team average' : '${delta >= 0 ? '▲' : '▼'} ${delta.abs().toStringAsFixed(1)} vs team avg');
    // A narrow window keeps the rank, the score and the ratings' figures; the milestone, the comparison and the
    // ratings' labels are in the hover text (and the time with the company is in the title).
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 1400;
    final roomy = width >= 1500;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (rank != null) ...[
          Tooltip(
            message: 'Integrity rank: #$rank by integrity score among all employees.',
            child: _pill(Icons.emoji_events_rounded, 'Rank #$rank', rank == 1 ? const Color(0xFFFBBF24) : const Color(0xFFCBD5E1)),
          ),
          const SizedBox(width: 8),
        ],
        if (milestone != null && !compact) ...[
          _pill(Icons.workspace_premium_rounded, milestone, const Color(0xFFA5B4FC)),
          const SizedBox(width: 12),
        ],
        Tooltip(
          message: 'Integrity score${versus == null ? '' : ' ($versus)'}. It starts the year at 100 and loses points each time '
              'the office has to mark one of their visits complete. ${_missedLine(user.missedCompletions)}',
          child: Semantics(
            label: score == null ? 'Integrity score: not recorded' : 'Integrity score ${_fmtNum(score)}%${versus == null ? '' : ', $versus'}',
            child: ExcludeSemantics(
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: still ? (score ?? 0) / 100 : 0, end: ((score ?? 0) / 100).clamp(0.0, 1.0)),
                duration: still ? Duration.zero : const Duration(milliseconds: 1400),
                curve: Curves.easeOutCubic,
                builder: (context, p, _) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: CustomPaint(
                        painter: _RingPainter(progress: p, color: ringColor),
                        child: Center(child: Icon(Icons.verified_rounded, size: 13, color: ringColor)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          score == null ? '—' : '${_fmtNum(p * 100)}%',
                          style: _headerValue,
                        ),
                        Text(versus == null || !roomy ? 'Integrity' : 'Integrity · $versus', style: _headerLabel),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (ratings != null) ...[const SizedBox(width: 18), _HeaderRatings(ratings: ratings!, compact: compact)],
      ],
    );
  }
}

const _headerValue = TextStyle(fontSize: 15, fontWeight: FontWeight.w800, height: 1.15, color: Colors.white, fontFeatures: DashText.tabular);
const _headerLabel = TextStyle(fontSize: 11, fontWeight: FontWeight.w600, height: 1.2, color: Color(0xFF94A3B8));

/// Peer rating (stars that fill as the page opens; technician and warehouse pages only) and morale (the heartbeat
/// trace) in the title bar, beside the integrity score. Tapping morale previews sample scores while nothing records them.
class _HeaderRatings extends StatelessWidget {
  final _TechRatings ratings;
  final bool compact;
  const _HeaderRatings({required this.ratings, required this.compact});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ratings,
      builder: (context, _) {
        final still = MediaQuery.disableAnimationsOf(context);
        final peer = ratings.shownPeer;
        final morale = ratings.shownMorale;
        final peerItem = Tooltip(
          message: peer == null
              ? 'Peer rating: how fellow techs rate this tech, 1 to 5. Nothing records it yet.'
              : 'Peer rating ${_fmtNum(peer.avg)} out of 5 from ${dashCount(peer.count, 'fellow tech')}${ratings.peerIsSample ? ' (a sample)' : ''}',
          child: Semantics(
            label: peer == null ? 'Peer rating: not tracked yet' : 'Peer rating ${_fmtNum(peer.avg)} out of 5${ratings.peerIsSample ? ', a sample' : ''}',
            child: ExcludeSemantics(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: peer?.avg ?? 0),
                        duration: still ? Duration.zero : const Duration(milliseconds: 1100),
                        curve: Curves.easeOutCubic,
                        builder: (context, x, _) => SizedBox(width: 66, height: 13, child: CustomPaint(painter: _StarsPainter(x, const Color(0xFFFBBF24)))),
                      ),
                      const SizedBox(width: 6),
                      Text(peer == null ? '—' : _fmtNum(peer.avg), style: _headerValue),
                    ],
                  ),
                  if (!compact) Text(ratings.peerIsSample ? 'Peer rating · sample' : 'Peer rating', style: _headerLabel),
                ],
              ),
            ),
          ),
        );
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (ratings.hasPeer) ...[peerItem, const SizedBox(width: 14)],
            _HeaderMorale(
              rating: morale,
              label: compact ? null : (ratings.moraleIsSample ? 'Morale · sample' : 'Morale'),
              canPreview: ratings.canPreview,
              sample: ratings.moraleIsSample,
              onTap: ratings.tapPreview,
            ),
          ],
        );
      },
    );
  }
}

/// Morale in the title bar: the KPI pages' heartbeat trace (its bright head sweeps across once there is a score;
/// dim and still without one) and the score.
class _HeaderMorale extends StatefulWidget {
  final _Rating? rating;
  final String? label;
  final bool canPreview;
  final bool sample;
  final VoidCallback onTap;
  const _HeaderMorale({required this.rating, required this.label, required this.canPreview, required this.sample, required this.onTap});

  @override
  State<_HeaderMorale> createState() => _HeaderMoraleState();
}

class _HeaderMoraleState extends State<_HeaderMorale> with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(vsync: this, duration: const Duration(milliseconds: 6000));

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  // The morale card's colours, a step lighter for the dark bar.
  static Color _tone(double score) => score >= 4 ? DashUi.emerald : (score >= 3 ? const Color(0xFFFBBF24) : const Color(0xFFF87171));

  @override
  Widget build(BuildContext context) {
    final r = widget.rating;
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (reduce || r == null) {
      _sweep.stop(); // nothing to animate: the dim trace is still, so it doesn't repaint every frame
    } else if (!_sweep.isAnimating) {
      _sweep.repeat();
    }
    final color = r == null ? const Color(0xFF94A3B8) : _tone(r.avg);
    final body = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 66,
          height: 30,
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _sweep,
              builder: (context, _) => CustomPaint(
                painter: _HeartbeatPainter(progress: reduce ? 1.0 : _sweep.value, color: color, live: r != null, baseline: const Color(0x1FFFFFFF)),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(r == null ? '—' : _fmtNum(r.avg), style: _headerValue.copyWith(color: r == null ? Colors.white : Color.lerp(color, Colors.white, 0.2))),
            if (widget.label != null) Text(widget.label!, style: _headerLabel),
          ],
        ),
      ],
    );
    final tip = r == null
        ? 'Morale: how this tech is feeling, 1 to 5. Nothing records it yet.${widget.canPreview ? ' Select to preview sample scores.' : ''}'
        : widget.sample
            ? 'Morale ${_fmtNum(r.avg)} out of 5, a sample. Select for another; after the last one the preview hides.'
            : 'Morale ${_fmtNum(r.avg)} out of 5 from ${dashCount(r.count, 'check-in')}';
    return Tooltip(
      message: tip,
      child: DashPressable(
        onTap: widget.canPreview ? widget.onTap : null,
        label: r == null ? 'Morale: not tracked yet' : 'Morale ${_fmtNum(r.avg)} out of 5${widget.sample ? ', a sample' : ''}',
        hint: widget.canPreview ? (widget.sample ? 'Tries another sample score' : 'Previews sample scores') : null,
        radius: BorderRadius.circular(8),
        builder: (hover) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(color: hover ? const Color(0x1AFFFFFF) : const Color(0x00FFFFFF), borderRadius: BorderRadius.circular(8)),
          child: body,
        ),
      ),
    );
  }
}


class _TechKpiContent extends StatefulWidget {
  final _EmployeeUser user;
  final String employeeId;
  final int year;
  final _TechRatings ratings;
  const _TechKpiContent({required this.user, required this.employeeId, required this.year, required this.ratings});

  @override
  State<_TechKpiContent> createState() => _TechKpiContentState();
}

/// Loads the two sources together, the way the dashboards load one (DashboardLoading): a skeleton on the first load, a
/// refresh keeps the figures on screen and the header says if it failed, an answer for an older request is ignored.
class _TechKpiContentState extends State<_TechKpiContent> {
  final _kpiRequests = DashRequests();
  final _statsRequests = DashRequests();
  _TechPage? _data;

  /// The last callback figures that loaded (kept when a Refresh can't get them).
  DashPayload? _stats;
  DashLoadException? _failure;
  bool _loading = true;
  bool _busy = false;
  DashFreshness? _freshness;
  DateTime? _updatedAt;
  bool _computedTime = false;

  String get _first {
    final n = widget.user.name.trim();
    return n.isEmpty ? 'This tech' : n.split(RegExp(r'\s+')).first;
  }

  @override
  void initState() {
    super.initState();
    // The Preview (in the title bar) also fills in sample reviews.
    widget.ratings.addListener(_onRatings);
    _load();
  }

  void _onRatings() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _freshness = DashFreshnessScope.maybeOf(context);
  }

  @override
  void dispose() {
    _kpiRequests.cancel();
    _statsRequests.cancel();
    widget.ratings.removeListener(_onRatings);
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
    // Callbacks are a second source: the page still loads without them (they say they couldn't load), and a failed
    // Refresh keeps the last ones on screen and says so in the header.
    DashLoadException? statsFailure;
    final statsF = _statsRequests.get('/api/tech_stats', query: {'year': year}, fresh: fresh).then<DashPayload?>(
      (p) => p,
      onError: (Object e) {
        statsFailure = e is DashLoadException ? e : const DashLoadException(DashFailure.badData);
        return null;
      },
    );
    try {
      final kpis = await kpisF;
      final fetched = await statsF;
      if (kpis == null || !mounted) return; // a newer request took over, or the page is gone
      final stats = fetched ?? (keep && statsFailure != null ? _stats : null);
      final _TechPage data;
      try {
        data = _TechPage.parse(kpis: kpis.body, stats: stats?.body, username: widget.employeeId, year: widget.year);
      } catch (_) {
        throw const DashLoadException(DashFailure.badData);
      }
      // The older of the two answers is how old the page's figures are.
      final stamps = [kpis.generatedAt ?? kpis.receivedAt, if (stats != null) stats.generatedAt ?? stats.receivedAt];
      setState(() {
        _data = data;
        _stats = stats;
        _loading = false;
        _busy = false;
        _updatedAt = stamps.reduce((a, b) => a.isBefore(b) ? a : b);
        _computedTime = kpis.generatedAt != null;
      });
      widget.ratings.set(data.peerRating, data.morale);
      // A Refresh whose callbacks failed kept the last ones: the header says the refresh didn't fully work.
      _report(refreshFailure: keep && fetched == null ? statsFailure : null);
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
    if (_loading) return const _TechSkeleton();
    final failure = _failure;
    if (failure != null) {
      return DashErrorPanel.failure(failure, what: "$_first's figures", onRetry: _load);
    }
    return _TechBody(
      data: _data!,
      user: widget.user,
      first: _first,
      employeeId: widget.employeeId,
      sample: widget.ratings.sample,
    );
  }
}

// =============================================================================
// SCORECARDS
// =============================================================================

/// A scorecard before it knows its width: [captions] go from the fullest to the shortest, and the card shows the first
/// that fits on one line.
class _TileSpec {
  final String title;
  final double? value;
  final String Function(double) format;
  final List<String> captions;
  final String definition;
  final Color color;
  final List<double>? trend;
  final Widget? trailing;

  /// A card that stands out from the row (dark, with a bar per person in [breakdown]): the supervisor's whole-team
  /// figure, which no one else's page has.
  final bool featured;
  final List<(String, double?)>? breakdown;

  /// Opens the list behind the figure when [count] is above zero.
  final VoidCallback? onOpen;
  final int count;
  final String noun;
  const _TileSpec({
    required this.title,
    required this.value,
    required this.format,
    required this.captions,
    required this.definition,
    required this.color,
    this.trend,
    this.trailing,
    this.featured = false,
    this.breakdown,
    this.onOpen,
    this.count = 0,
    this.noun = 'job',
  });

  /// How wide [caption] is on one line.
  double captionWidth(BuildContext context, String caption) {
    final base = DefaultTextStyle.of(context).style.merge(const TextStyle(fontSize: 12, fontWeight: FontWeight.w500));
    return (TextPainter(text: TextSpan(text: caption, style: base), textDirection: TextDirection.ltr, textScaler: MediaQuery.textScalerOf(context), maxLines: 1)..layout()).width;
  }

  /// The fullest caption that fits [inner] px beside nothing (the caption has the card's whole width).
  String captionFor(BuildContext context, double inner) {
    for (final c in captions) {
      if (captionWidth(context, c) <= inner) return c;
    }
    return captions.last;
  }
}

/// A KPI scorecard with the dashboards' look and motion (AnimatedMetricCard: staggered entrance, count-up, hover lift
/// with a tinted border, the full definition on hover), laid out for a page of captions: the trend line sits beside
/// the number rather than beside the words, so it keeps its room, and it draws itself after the count-up with a soft
/// fill fading in under it. An illustration (the streak's flame) can take the trend line's place.
class _KpiTile extends StatefulWidget {
  final _TileSpec spec;
  final int index;
  const _KpiTile({required this.spec, required this.index});

  @override
  State<_KpiTile> createState() => _KpiTileState();
}

class _KpiTileState extends State<_KpiTile> with SingleTickerProviderStateMixin {
  static const _baseMs = 520;
  static const _staggerMs = 110;
  static const _countMs = 1100;
  static const _valueStyle = TextStyle(fontSize: 28, fontWeight: FontWeight.w800, height: 1.1, fontFeatures: DashText.tabular);
  static const _titleStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.3, color: DashUi.slate);

  late final AnimationController _enter;
  late final Animation<double> _t;
  bool _still = false;

  @override
  void initState() {
    super.initState();
    final total = _baseMs + widget.index * _staggerMs;
    _enter = AnimationController(vsync: this, duration: Duration(milliseconds: total));
    _t = CurvedAnimation(parent: _enter, curve: Interval(widget.index * _staggerMs / total, 1, curve: Curves.easeOutCubic));
    _enter.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.disableAnimationsOf(context);
    if (_still) _enter.value = 1;
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.spec;
    final v = s.value;
    final scaler = MediaQuery.textScalerOf(context);
    final valueH = scaler.scale(28) * 1.1;
    final titleH = scaler.scale(13) * 1.3;
    final shown = v == null ? '—' : s.format(v);
    final valueW = (TextPainter(
      text: TextSpan(text: shown, style: DefaultTextStyle.of(context).style.merge(_valueStyle)),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout())
        .width;

    final value = v == null
        ? Text('—', maxLines: 1, style: _valueStyle.copyWith(color: s.featured ? const Color(0xFF94A3B8) : DashUi.muted))
        : TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: v),
            duration: _still ? Duration.zero : const Duration(milliseconds: _countMs),
            curve: Curves.easeOutCubic,
            builder: (context, x, _) => Text(s.format(x), maxLines: 1, softWrap: false, style: _valueStyle.copyWith(color: s.featured ? Colors.white : s.color)),
          );

    final open = s.onOpen != null && s.count > 0;
    Widget card = HoverLift(
      builder: (context, hovering) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: s.featured ? null : Colors.white,
          gradient: s.featured
              ? const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF0F172A), Color(0xFF1E3A5F)])
              : null,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: s.featured
                ? (hovering ? s.color.withValues(alpha: 0.9) : s.color.withValues(alpha: 0.45))
                : (hovering ? s.color.withValues(alpha: 0.55) : DashUi.line),
          ),
          boxShadow: s.featured ? [BoxShadow(color: s.color.withValues(alpha: hovering ? 0.28 : 0.16), blurRadius: 16, offset: const Offset(0, 4))] : null,
        ),
        child: LayoutBuilder(
          builder: (context, c) {
            final room = c.maxWidth - valueW - 14;
            // The bars take the card's right side, narrower on a narrow card (six scorecards at 1280), as long as the
            // figure and the shortest caption still fit beside them.
            final people = s.featured ? (s.breakdown?.length ?? 0) : 0;
            final wantW = math.min(80.0, (c.maxWidth >= 200 ? 20.0 : 16.0) * people);
            final beside = c.maxWidth - wantW - 8;
            final bars = people > 0 && valueW <= beside && s.captionWidth(context, s.captions.last) <= beside;
            final barsW = bars ? wantW : 0.0;
            final sparkW = math.min(room, 104.0);
            final spark = s.trend != null && sparkW >= 56;
            final titleW = (TextPainter(
              text: TextSpan(text: s.title, style: DefaultTextStyle.of(context).style.merge(_titleStyle)),
              textDirection: TextDirection.ltr,
              textScaler: scaler,
              maxLines: 1,
            )..layout())
                .width;
            // The illustration sits beside the title and the number, so it only shows when the title still fits whole.
            final art = s.trend == null && s.trailing != null && room >= 44 && titleW + 48 <= c.maxWidth;
            // A card that opens a list keeps its chevron's corner clear of the caption.
            final caption = s.captionFor(context, c.maxWidth - (open ? 22 : 0) - (bars ? barsW + 8 : 0));
            return Stack(
              children: [
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(right: art ? 48 : 0),
                      child: Row(
                        children: [
                          if (s.featured) ...[const Icon(Icons.shield_rounded, size: 14, color: DashUi.amber), const SizedBox(width: 5)],
                          Flexible(child: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: s.featured ? _titleStyle.copyWith(color: const Color(0xFFE2E8F0), fontWeight: FontWeight.w700) : _titleStyle)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      height: valueH,
                      child: Row(
                        children: [
                          Expanded(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: value)),
                          if (spark) ...[
                            const SizedBox(width: 14),
                            SizedBox(width: sparkW, height: valueH, child: _Spark(values: s.trend!, color: s.color, still: _still, delayMs: _countMs)),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, height: 1.3, color: s.featured ? const Color(0xFFA9B6C8) : DashUi.subtle),
                    ),
                  ],
                ),
                if (bars) Positioned(right: 0, top: titleH + 4, bottom: 0, width: barsW, child: _BreakdownBars(items: s.breakdown!, team: v, still: _still)),
                if (art) Positioned(right: 0, top: 0, width: 44, height: titleH + 4 + valueH, child: s.trailing!),
              ],
            );
          },
        ),
      ),
    );
    card = DashHoverCard(title: s.title, value: v == null ? '—' : s.format(v), body: s.definition, color: s.color, child: card);

    final label ='${s.title}: ${v == null ? 'no figure yet' : s.format(v)}. ${s.definition}';
    final Widget body = open
        ? DashPressable(
            onTap: s.onOpen,
            label: label,
            hint: 'Opens the list of ${dashCount(s.count, s.noun)}',
            radius: BorderRadius.circular(12),
            builder: (hover) => Stack(
              fit: StackFit.expand,
              children: [
                card,
                Positioned(bottom: 8, right: 10, child: Icon(Icons.chevron_right_rounded, size: 20, color: hover ? s.color : DashUi.subtle)),
              ],
            ),
          )
        : Semantics(container: true, label: label, child: ExcludeSemantics(child: card));

    return FadeTransition(
      opacity: _t,
      child: SlideTransition(position: Tween<Offset>(begin: const Offset(0, 0.12), end: Offset.zero).animate(_t), child: body),
    );
  }
}

/// A trend line that waits for the number's count-up, then draws itself left to right with a soft fill rising under
/// it and a glowing dot at the latest point. Still (drawn whole) with reduced motion.
class _Spark extends StatelessWidget {
  final List<double> values;
  final Color color;
  final bool still;
  final int delayMs;
  const _Spark({required this.values, required this.color, required this.still, required this.delayMs});

  static const _drawMs = 700;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: still ? Duration.zero : Duration(milliseconds: delayMs + _drawMs),
        builder: (context, t, _) {
          final progress = still ? 1.0 : ((t * (delayMs + _drawMs) - delayMs) / _drawMs).clamp(0.0, 1.0);
          return CustomPaint(painter: _SparkPainter(values: values, color: color, progress: Curves.easeOutCubic.transform(progress)));
        },
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final List<double> values;
  final Color color;
  final double progress;
  const _SparkPainter({required this.values, required this.color, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2 || progress <= 0) return;
    const pad = 4.0;
    final lo = values.reduce(math.min);
    final hi = values.reduce(math.max);
    final span = hi - lo <= 0 ? 1.0 : hi - lo;
    final pts = [
      for (var i = 0; i < values.length; i++)
        Offset(pad + (size.width - pad * 2) * i / (values.length - 1), pad + (size.height - pad * 2) * (1 - (values[i] - lo) / span)),
    ];
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      final cx = (pts[i - 1].dx + pts[i].dx) / 2;
      path.cubicTo(cx, pts[i - 1].dy, cx, pts[i].dy, pts[i].dx, pts[i].dy);
    }
    final metric = path.computeMetrics().first;
    final drawn = metric.extractPath(0, metric.length * progress);
    final head = metric.getTangentForOffset(metric.length * progress)?.position ?? pts.last;

    // The fill follows the line as it draws, fading in as it goes.
    final fill = Path.from(drawn)
      ..lineTo(head.dx, size.height)
      ..lineTo(pts.first.dx, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.18 * progress), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      drawn,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    if (progress >= 1) canvas.drawCircle(head, 6, Paint()..color = color.withValues(alpha: 0.18));
    canvas.drawCircle(head, 3, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) => old.progress != progress || old.color != color || !listEquals(old.values, values);
}

/// The streak's flame: bigger and hotter the longer the streak (full size at 40 jobs), flickering unless the OS asks
/// for reduced motion; a grey ember at zero.
class _StreakFlame extends StatefulWidget {
  final int streak;
  const _StreakFlame({required this.streak});

  @override
  State<_StreakFlame> createState() => _StreakFlameState();
}

class _StreakFlameState extends State<_StreakFlame> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final heat = widget.streak.clamp(0, 40) / 40.0;
    return ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, c) {
          // Grows into the room it is given: from about two thirds of the box at zero to all of it at 40 jobs.
          final h = c.maxHeight * (0.62 + 0.38 * heat);
          return Align(
            alignment: Alignment.bottomCenter,
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _c,
                builder: (_, _) => CustomPaint(
                  size: Size(h * 0.62, h),
                  painter: _FlamePainter(t: _c.value, heat: heat, lit: widget.streak > 0),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One bar per person on the featured card: each tech's callback rate, growing up from the bottom when the card
/// appears (a tech with no callbacks is a short green stub, one with no figure a grey one), their initial under it, their
/// name and rate on hover.
/// The [team] rate is a dashed line across them, drawn once the bars are up, so a bar over it reads as above the team.
class _BreakdownBars extends StatelessWidget {
  final List<(String, double?)> items;
  final double? team;
  final bool still;
  const _BreakdownBars({required this.items, required this.still, this.team});

  @override
  Widget build(BuildContext context) {
    final rates = [for (final i in items) i.$2 ?? 0.0];
    final max = math.max(rates.fold<double>(0, math.max), team ?? 0);
    final labelH = 3 + MediaQuery.textScalerOf(context).scale(10.5) * 1.1;
    return ExcludeSemantics(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: still ? Duration.zero : const Duration(milliseconds: 1500),
        curve: Curves.easeOutCubic,
        builder: (context, t, _) => Stack(
          children: [
            Positioned.fill(child: _bars(rates, max, t)),
            if (team != null && team! > 0 && max > 0)
              Positioned.fill(
                bottom: labelH,
                child: Tooltip(
                  message: 'Team rate ${_pct1(team!)}',
                  child: CustomPaint(painter: _TeamRateLine(fraction: team! / max, opacity: ((t - 0.6) / 0.4).clamp(0.0, 1.0))),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _bars(List<double> rates, double max, double t) => Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < items.length; i++)
              Expanded(
                child: Tooltip(
                  message: '${items[i].$1}: ${items[i].$2 == null ? 'no figure' : _pct1(items[i].$2!)}',
                  child: Column(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: FractionallySizedBox(
                            heightFactor: (rates[i] <= 0 || max <= 0 ? 0.07 : math.max(0.12, rates[i] / max)) * t,
                            child: Container(
                              width: 13,
                              decoration: BoxDecoration(
                                // No figure (no jobs to count against) is grey, not the green of "no callbacks".
                                color: items[i].$2 == null
                                    ? DashUi.muted
                                    : rates[i] <= 0
                                        ? DashUi.emerald
                                        : (rates[i] >= max ? DashUi.amber : DashUi.amber.withValues(alpha: 0.5)),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        items[i].$1.isEmpty ? '?' : items[i].$1[0].toUpperCase(),
                        style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, height: 1.1, color: Color(0xFFA9B6C8)),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
}

/// The team's rate across the breakdown bars: a dashed line [fraction] of the way up, fading in by [opacity].
class _TeamRateLine extends CustomPainter {
  final double fraction;
  final double opacity;
  const _TeamRateLine({required this.fraction, required this.opacity});

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0) return;
    final y = size.height * (1 - fraction.clamp(0.0, 1.0));
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.85 * opacity)
      ..strokeWidth = 1.4;
    for (var x = 0.0; x < size.width; x += 6) {
      canvas.drawLine(Offset(x, y), Offset(math.min(x + 3.5, size.width), y), p);
    }
  }

  @override
  bool shouldRepaint(_TeamRateLine old) => old.fraction != fraction || old.opacity != opacity;
}

class _TechBody extends StatelessWidget {
  final _TechPage data;
  final _EmployeeUser user;
  final String first;
  final String employeeId;
  final bool sample;
  const _TechBody({
    required this.data,
    required this.user,
    required this.first,
    required this.employeeId,
    required this.sample,
  });

  static const _sampleReviews = [
    _Mention('On time, fixed our spring in under an hour and cleaned up after the job.', 'Sample customer', 'Sample'),
    _Mention('Explained exactly what was wrong before touching anything. Honest and fair price.', 'Sample customer', 'Sample'),
  ];

  void _openCallbacks(BuildContext context) => showDialog<void>(
        context: context,
        builder: (_) => _CallbackStrikesDialog(employeeId: employeeId, name: user.name, year: data.year),
      );

  @override
  Widget build(BuildContext context) {
    final d = data;
    final g = DashGeo.of(context);
    final year = d.year;
    final period = _techPeriod(year, _hireDate(user));
    final soFar = d.isCurrentYear ? 'so far' : 'in $year';
    final cb = d.callbacks;
    final since = d.callbackFrom == null ? null : dashShortDate(d.callbackFrom!);
    String whole(double v) => _wholeMoney(v);

    // --- Labor per work day: the headline, against the rest of the team (over the same months as this tech). ---
    final rest = d.restPerDay;
    final span = d.restSpan;
    final others = d.restTechs == null ? 'the other current techs' : 'the other ${dashCount(d.restTechs!, 'current tech')}';
    final restWords = rest == null
        ? ''
        : span != null
            ? ' The rest of the team is $others pooled the same way over the same months $first worked ($span): ${whole(rest)} a '
                'day.${d.teamLaborPerDay == null ? '' : ' Over all of $year it is ${whole(d.teamLaborPerDay!)}.'}'
            : d.restYearOnlySpan != null
                ? ' The rest of the team is $others pooled the same way over all of $year: ${whole(rest)} a day. $first worked '
                    'only ${d.restYearOnlySpan}, and this server can\'t pool the rest of the team over just those months.'
                : ' The rest of the team is $others pooled the same way: ${whole(rest)} a day.';
    final perDayTrend = () {
      final pts = [
        for (var i = 0; i < dashCompleteMonths(year) && i < 12; i++)
          if (d.months[i]?.laborPerDay != null) d.months[i]!.laborPerDay!,
      ];
      return pts.length >= 2 ? pts : null;
    }();
    final perJob = d.laborPerJob;
    final tiles = <_TileSpec>[
      _TileSpec(
        title: 'Labor per work day',
        value: d.laborPerDay,
        format: whole,
        captions: d.laborPerDay == null
            ? ['No labor jobs $soFar']
            : [
                ?_versusTeam(d.laborPerDay, rest, span: span),
                ?_versusTeam(d.laborPerDay, rest),
                ?_versusTeam(d.laborPerDay, rest, amount: false),
                'Labor ÷ days worked',
              ],
        definition: d.laborPerDay == null
            ? 'Labor billed on completed jobs divided by the days $first worked on them. No completed labor jobs $soFar.'
            : 'Labor billed on $first\'s completed $year jobs (${whole(d.labor)}) divided by the ${dashCount(d.laborDays, 'calendar day')} '
                '$first worked on them; a day with several jobs counts once.$restWords The Technicians dashboard\'s Work pace counts '
                'more work days: every day with a visit marked complete, including jobs not finished yet and visits with no labor.',
        color: DashUi.sky,
        trend: perDayTrend,
      ),
      _TileSpec(
        title: 'Labor billed',
        value: d.laborJobs == 0 ? null : d.labor,
        format: whole,
        captions: d.laborJobs == 0
            ? ['No labor jobs $soFar']
            : ['Over ${dashCount(d.laborDays, 'work day')} · $period', 'Over ${dashCount(d.laborDays, 'work day')}', dashCount(d.laborDays, 'work day')],
        definition: 'The labor lines (services, installs, service packages) on completed jobs that started in $year and that $first '
            'worked, split by day weight with anyone else on the job. Parts and materials are not labor. Callback visits, and '
            'visits that carry no day weight (site checks, deliveries, visits not booked as a half or full day), add nothing.',
        color: DashUi.sky,
        trend: _trendOf([for (final m in d.months) m?.labor ?? 0], year),
      ),
      _TileSpec(
        title: 'Completed jobs worked',
        value: d.jobs.toDouble(),
        format: (v) => '${v.round()}',
        captions: perJob == null
            ? [d.jobs == 0 ? 'None $soFar' : period]
            : ['${whole(perJob)} average per labor job', '${whole(perJob)} per labor job', '${whole(perJob)} a labor job'],
        definition: 'Completed jobs that started in $year where $first has a credited work day (not a callback visit or a visit with '
            'no day weight). ${d.laborJobs} of them had labor${perJob == null ? '.' : ', ${whole(perJob)} on average: '
                'bigger jobs (installs) mean fewer jobs a day and more labor a day.'} On the chart a job worked in two months '
            'counts in each, so the months add up to more than the year; work days are the days on jobs with labor.',
        color: DashUi.indigo,
        trend: _trendOf([for (final m in d.months) (m?.jobs ?? 0).toDouble()], year),
      ),
      _callbackTile(context, d, cb, since),
      if (d.isCurrentYear) _streakTile(d, cb),
      if (first.toLowerCase() == 'brett' && d.evalConversion != null) _conversionTile(d),
      if (d.supervisor) _teamCallbackTile(d, since),
    ];

    final table = _TeamRows.of(d, first, user.displayTitle);
    final reviews = d.mentions.isNotEmpty ? d.mentions : (sample ? _sampleReviews : const <_Mention>[]);

    return _TechGrid(
      tiles: tiles,
      chart: _TechChart(data: d, first: first),
      table: table,
      team: (fit, fill) => _TeamPanel(g: g, data: d, table: table, first: first, fit: fit, fill: fill),
      reviews: _ReviewsCard(
        mentions: reviews,
        rating: d.satisfaction ?? (reviews.isEmpty || d.mentions.isNotEmpty ? null : const _Rating(4.7, 22)),
        first: first,
        sample: d.mentions.isEmpty && sample,
      ),
      hasReviews: reviews.isNotEmpty,
    );
  }

  _TileSpec _callbackTile(BuildContext context, _TechPage d, _CallbackLine? cb, String? since) {
    final rate = cb?.ratePct;
    final others = d.othersCallbackRate;
    final o = d.othersCallbacks;
    final verdict = d.callbackVerdict;
    final String definition;
    final List<String> captions;
    if (d.callbackTeam == null) {
      captions = ["Couldn't load callbacks"];
      definition = "The callback figures couldn't be loaded. Refresh to try again.";
    } else if (since == null) {
      captions = ['Tracking began Oct 5, 2026'];
      definition = 'Callbacks are counted from Oct 5, 2026, so ${d.year} has no callback rate.';
    } else if (cb == null || cb.jobs == null) {
      captions = ['No figures for $first yet'];
      definition = 'The Technicians figures have no callback count for $first yet.';
    } else if (rate == null) {
      captions = ['No jobs since $since yet'];
      definition = 'No completed jobs since $since where $first did the original work, so there is nothing to count callbacks against.';
    } else {
      final strikes = dashCount(cb.strikes, 'strike');
      captions = ['$strikes on ${dashCount(cb.jobs!, 'job')} since $since', '$strikes, ${cb.jobs} jobs since $since', '$strikes on ${dashCount(cb.jobs!, 'job')}'];
      definition = 'Callback strikes divided by the completed jobs since $since (callback tracking began Oct 5, 2026) where $first '
          'did the original work: ${cb.strikes} ÷ ${cb.jobs}. A strike is a verified callback visit on a job $first worked; '
          'callback visits to someone else\'s job and visits with no day weight are not $first\'s jobs here.'
          '${others == null || o == null ? '' : ' Rest of team: ${_pct1(others)} (${o.strikes} on ${dashCount(o.jobs, 'job')}). Less than '
              'one strike apart (${(100 / cb.jobs!).toStringAsFixed(1)} points on $first\'s ${cb.jobs} jobs) or within 5% is on par.'}';
    }
    return _TileSpec(
      title: 'Callback rate',
      value: rate,
      format: _pct1,
      captions: captions,
      definition: definition,
      // Amber only when behind the rest of the team; green with no strikes or when ahead.
      color: rate == null
          ? DashUi.muted
          : verdict == _Verdict.behind
              ? DashUi.amber
              : (cb!.strikes == 0 || verdict == _Verdict.ahead ? DashUi.emeraldDeep : DashUi.ink),
      count: cb?.strikes ?? 0,
      noun: 'callback visit',
      onOpen: () => _openCallbacks(context),
    );
  }

  _TileSpec _streakTile(_TechPage d, _CallbackLine? cb) {
    final n = cb?.streak;
    final none = cb != null && cb.strikes == 0;
    final since = d.callbackFrom == null ? 'Oct 5' : dashShortDate(d.callbackFrom!);
    return _TileSpec(
      title: 'Callback-free streak',
      value: n?.toDouble(),
      format: (v) => '${v.round()}',
      captions: cb == null
          ? [d.callbackTeam == null ? "Couldn't load callbacks" : 'No figures for $first yet']
          : none
              ? ['No callbacks since $since', 'No callbacks yet']
              : ['Jobs since the last callback', 'Since the last callback'],
      definition: 'Completed jobs $first worked (the original work, verified) since a callback last came back on one of '
          '$first\'s jobs, counted from Oct 5, 2026.${none ? ' No callback has come back on $first\'s jobs, so every one counts.' : ''}',
      color: DashUi.ink,
      trailing: n == null ? null : _StreakFlame(streak: n),
    );
  }

  _TileSpec _conversionTile(_TechPage d) {
    final c = d.evalConversion!;
    final rate = c.evals > 0 ? c.converted / c.evals * 100 : null;
    return _TileSpec(
      title: 'Service call conversion',
      value: rate,
      format: (v) => '${v.round()}%',
      captions: c.evals == 0
          ? ['No service evals ${d.isCurrentYear ? 'so far' : 'in ${d.year}'}']
          : ['${c.converted} of ${dashCount(c.evals, 'service eval')} converted', '${c.converted} of ${c.evals} evals converted', '${c.converted} of ${c.evals} evals'],
      definition: 'Service evaluations (Residential Diagnostic Visit jobs) $first worked in ${d.year}, and how many got the Same Day '
          'Service Credit, i.e. the customer bought a service package.',
      color: rate == null ? DashUi.muted : (rate >= 40 ? DashUi.emeraldDeep : (rate >= 20 ? DashUi.amber : DashUi.red)),
    );
  }

  _TileSpec _teamCallbackTile(_TechPage d, String? since) {
    final team = d.callbackTeam;
    final rate = team == null ? null : _pooledCallbackRate(team);
    var strikes = 0, jobs = 0;
    for (final c in team ?? const <_CallbackLine>[]) {
      strikes += c.strikes;
      jobs += c.jobs ?? 0;
    }
    String who(_CallbackLine c) => (c.name.isEmpty ? c.username : c.name).split(' ').first;
    final rated = [for (final c in team ?? const <_CallbackLine>[]) if (c.ratePct != null) c]
      ..sort((a, b) => b.ratePct!.compareTo(a.ratePct!));
    final clean = rated.where((c) => c.ratePct == 0).length;
    // The finding in words: who has the most callbacks against the team rate, every one of them when the highest rate
    // is shared (as shown), or that no one has any.
    final top = rated.isEmpty ? const <_CallbackLine>[] : [for (final c in rated) if (_pct1(c.ratePct!) == _pct1(rated.first.ratePct!)) c];
    final finding = rated.isEmpty
        ? null
        : rated.first.ratePct! <= 0
            ? 'No callbacks on anyone\'s jobs'
            : 'Highest: ${top.map(who).join(', ')} ${_pct1(rated.first.ratePct!)}${clean > 0 ? ' · $clean with none' : ''}';
    final company = d.company;
    final from = since == null || d.callbackFrom!.length < 4 ? 'Oct 5, 2026' : '$since, ${d.callbackFrom!.substring(0, 4)}';
    return _TileSpec(
      title: 'Team callback rate',
      value: rate,
      format: _pct1,
      captions: team == null
          ? ["Couldn't load callbacks"]
          : rate == null
              ? [since == null ? 'Tracking began Oct 5, 2026' : 'No jobs since $since yet']
              : [
                  if (finding != null) '${dashCount(strikes, 'strike')} on ${dashCount(jobs, 'job')} · $finding',
                  '${dashCount(strikes, 'strike')} on ${dashCount(jobs, 'job')} since $since',
                  '${dashCount(strikes, 'strike')} on ${dashCount(jobs, 'job')}',
                  '$strikes of ${dashCount(jobs, 'job')}',
                ],
      definition: team == null
          ? "The callback figures couldn't be loaded. Refresh to try again."
          : 'The field supervisor\'s view of the whole team: every current tech\'s callback strikes added up, divided by the '
              'jobs they did the original work on since $from, $first included'
              '${rate == null ? '.' : ': ${dashCount(strikes, 'strike')} on ${dashCount(jobs, 'job')}.'} A job two techs worked '
              'counts once for each of them, like the strikes. The Technicians dashboard\'s company callback rate counts each '
              'callback visit once over every completed job'
              '${company?.ratePct == null ? '' : ' (${_pct1(company!.ratePct!)}: ${dashCount(company.callbacks, 'visit')} on ${dashCount(company.jobs, 'job')})'}'
              ', so the two differ. The bars are each tech\'s own rate under their initial: the brightest is the highest, a '
              'short green stub means no callbacks, a grey stub means no figure, and the dashed line is the team rate.'
              '${rated.isEmpty ? '' : ' ${[for (final c in rated) '${who(c)} ${_pct1(c.ratePct!)}'].join(', ')}.'}',
      color: rate == null ? DashUi.muted : DashUi.amber,
      featured: true,
      breakdown: [
        for (final c in team ?? const <_CallbackLine>[]) (c.name.isEmpty ? c.username : c.name, c.ratePct),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// The monthly chart: per work day against the rest of the team, labor, jobs
// -----------------------------------------------------------------------------

class _TechChart extends StatelessWidget {
  final _TechPage data;
  final String first;
  const _TechChart({required this.data, required this.first});

  @override
  Widget build(BuildContext context) {
    final d = data;
    final year = d.year;
    double v(int i, double? Function(_TechMonth) f) => d.months[i] == null ? 0 : (f(d.months[i]!) ?? 0);
    final perDay = [for (var i = 0; i < 12; i++) v(i, (m) => m.laborPerDay)];
    final labor = [for (var i = 0; i < 12; i++) v(i, (m) => m.labor)];
    final jobs = [for (var i = 0; i < 12; i++) v(i, (m) => m.jobs.toDouble())];
    final days = [for (var i = 0; i < 12; i++) v(i, (m) => m.laborDays.toDouble())];
    final team = [for (final t in d.teamPerDay) t ?? 0.0];
    // Months none of the rest of the team worked: the line breaks there instead of dropping to $0.
    final teamGaps = {for (var i = 0; i < 12; i++) if (d.teamPerDay[i] == null) i};
    // The months before this tech's first one (a start in July): the work days line starts there instead of running
    // along zero through months they weren't here.
    final firstMonth = d.months.indexWhere((m) => m != null);
    final beforeFirst = {for (var i = 0; i < firstMonth; i++) i};
    // The rest of the team's line only with something of this tech's to read it against (an empty year says so).
    final hasTeam = d.laborDays > 0 && d.teamPerDay.any((t) => t != null);
    String whole(double x) => _wholeMoney(x);
    final empty = '$first has no completed labor jobs ${d.isCurrentYear ? 'in $year yet' : 'in $year'}.';

    // What every month's tooltip lists, whichever view: the view's own figures first, then the others, and the change
    // from the month before (as the old chart's tooltip did).
    List<DashTipRow> rows(int i, {required String lead, required List<double> series, required String Function(double) f}) {
      final m = d.months[i];
      final prev = i > 0 ? series[i - 1] : 0.0;
      final partial = d.isCurrentYear && i == DashClock.now().month - 1;
      final change = m != null && !partial && prev > 0 ? (series[i] - prev) / prev * 100 : null;
      return [
        if (lead == 'perDay') DashTipRow(first, m?.laborPerDay == null ? '—' : whole(m!.laborPerDay!), color: DashUi.sky),
        if (lead == 'perDay' && hasTeam) DashTipRow('Rest of team', d.teamPerDay[i] == null ? '—' : whole(d.teamPerDay[i]!), color: DashUi.slate),
        if (lead == 'labor') DashTipRow('Labor', m == null ? '—' : whole(m.labor), color: DashUi.sky),
        if (lead == 'jobs') DashTipRow('Jobs', m == null ? '—' : '${m.jobs}', color: DashUi.sky),
        if (lead == 'jobs') DashTipRow('Work days', m == null ? '—' : '${m.laborDays}', color: DashUi.slate),
        if (lead != 'jobs' && m != null) DashTipRow('Work days', '${m.laborDays}'),
        if (lead != 'labor' && m != null) DashTipRow('Labor', whole(m.labor)),
        if (lead != 'jobs' && m != null) DashTipRow('Jobs', '${m.jobs}'),
        if (lead == 'labor' && m?.laborPerDay != null) DashTipRow('Per work day', whole(m!.laborPerDay!)),
        if (change != null) DashTipRow('vs ${dashMonthNames[i - 1]}', '${change >= 0 ? '+' : '−'}${change.abs().round()}%'),
      ];
    }

    String summary(String title, List<double> values, String Function(double) f, int last) =>
        '$title: ${[for (var i = 0; i <= last && i < 12; i++) if (d.months[i] != null) '${dashMonthNames[i]} ${f(values[i])}'].join(', ')}';

    // --- The stories: each view's answer in figures over it, and its finding in words. ---
    final soFar = d.isCurrentYear ? 'so far in $year' : 'in $year';
    final now = DashClock.now();
    final lastWhole = year < now.year ? 11 : (year == now.year ? now.month - 2 : -1);
    // A month counts in the stories (best month, the months against the team, the average month) only with at least
    // [_storyMinDays] work days in it: a first month of two days (a start in late July) is not a fair month to judge.
    bool full(int i) => (d.months[i]?.laborDays ?? 0) >= _storyMinDays;
    List<double> fullOnly(List<double> values) => [for (var i = 0; i < 12; i++) full(i) ? values[i] : 0.0];
    final wholeMonths = [for (var i = 0; i <= lastWhole && i < 12; i++) if (full(i) && perDay[i] > 0) i];

    // Per work day: the year's figure, how far ahead of (or behind) the rest of the team (over the same months), and in
    // how many whole months the tech beat the team's line. Without the team's figures, the usual best month / latest month.
    final perDayBase = dashMonthStory(
      values: fullOnly(perDay),
      year: year,
      figure: d.laborPerDay ?? 0,
      figureFormat: whole,
      figureLabel: 'a work day $soFar',
      figureColor: DashUi.sky,
      format: whole,
    );
    final rest = d.restPerDay;
    final span = d.restSpan;
    final vsTeam = hasTeam && d.laborPerDay != null && rest != null && rest > 0 ? (d.laborPerDay! - rest) / rest * 100 : null;
    final both = [for (final i in wholeMonths) if (d.teamPerDay[i] != null && d.teamPerDay[i]! > 0) i];
    // Months within 5% of the team's line are level, as the headline's "on par" is.
    final aheadIn = both.where((i) => !_parPct((perDay[i] - d.teamPerDay[i]!) / d.teamPerDay[i]! * 100) && perDay[i] > d.teamPerDay[i]!).length;
    final behindIn = both.where((i) => !_parPct((perDay[i] - d.teamPerDay[i]!) / d.teamPerDay[i]! * 100) && perDay[i] < d.teamPerDay[i]!).length;
    final String perDayCallout;
    var perDayColor = perDayBase.calloutColor;
    if (both.length >= 2) {
      var best = both.first;
      for (final i in both) {
        if (perDay[i] > perDay[best]) best = i;
      }
      // Both of two months are named with their figures ("in Aug ($1,083) and Sep ($408)"), which says all a "best" would;
      // otherwise counted ("in 7 of 9 full months", "in all 3 full months").
      String named(int i) => '${dashMonthNames[i]} (${whole(perDay[i])})';
      final pair = both.length == 2 && (aheadIn == 2 || behindIn == 2 || aheadIn + behindIn == 0);
      String months(int n) => n == both.length
          ? (pair ? 'in ${named(both.first)} and ${named(both.last)}' : 'in all $n full months')
          : 'in $n of ${both.length} full months';
      // Said from the side the tech is on: "Ahead of ... in 7 of 9", "Behind ... in all 3"; level when it is even.
      final String side;
      if (aheadIn > behindIn) {
        side = 'Ahead of the rest of the team ${months(aheadIn)}';
        perDayColor = DashUi.emeraldText;
      } else if (behindIn > aheadIn) {
        side = 'Behind the rest of the team ${months(behindIn)}';
        perDayColor = DashUi.redText;
      } else {
        side = aheadIn == 0
            ? 'Level with the rest of the team ${months(both.length)}'
            : 'Level with the rest of the team: ahead in $aheadIn, behind in $behindIn of ${both.length} full months';
        perDayColor = DashUi.slate;
      }
      // A finished month too short to judge (two days after a start late in July) can stand taller on the chart than
      // the best one judged: then it is the best *full* month, which says why the taller bar isn't it.
      final taller = [for (var i = 0; i <= lastWhole && i < 12; i++) if (!full(i) && perDay[i] > perDay[best]) i].isNotEmpty;
      perDayCallout = pair ? side : '$side · best${taller ? ' full month' : ''}: ${dashMonthNames[best]}, ${whole(perDay[best])}';
    } else {
      perDayCallout = perDayBase.callout;
    }
    // The months the rest of the team is pooled over, named as the scorecard's caption names them (none when it is
    // their whole year): one comparison, not to be mistaken for the month-on-month chip beside the title.
    final over = span == null ? '' : ', $span';
    final perDayStory = DashStory(
      [
        perDayBase.headline.first,
        if (vsTeam != null)
          _parPct(vsTeam)
              ? DashStoryStat(rest!, whole, 'for the rest of the team$over: on par', DashUi.slate)
              : DashStoryStat(
                  vsTeam.abs(),
                  (x) => '${vsTeam >= 0 ? '▲' : '▼'} ${x.round()}%',
                  '${vsTeam >= 0 ? 'above' : 'below'} the rest of the team$over (${whole(rest!)})',
                  vsTeam >= 0 ? DashUi.emeraldText : DashUi.redText,
                ),
      ],
      perDayCallout,
      perDayColor,
    );

    // Labor: the year's total and the average whole month (months with at least [_storyMinDays] work days).
    final laborWhole = [for (var i = 0; i <= lastWhole && i < 12; i++) if (full(i) && labor[i] > 0) labor[i]];
    final laborStory = dashMonthStory(
      values: fullOnly(labor),
      year: year,
      figure: d.labor,
      figureFormat: whole,
      figureLabel: 'labor billed $soFar',
      figureColor: DashUi.sky,
      format: whole,
      extra: [
        if (laborWhole.length >= 2)
          DashStoryStat(laborWhole.fold<double>(0, (a, x) => a + x) / laborWhole.length, whole, 'in an average month', DashUi.slate),
      ],
    );

    // Jobs: how many, over how many days, and the labor a job.
    final jobsStory = dashMonthStory(
      values: fullOnly(jobs),
      year: year,
      figure: d.jobs.toDouble(),
      figureFormat: (x) => '${x.round()}',
      figureLabel: 'jobs over ${dashCount(d.laborDays, 'work day')}',
      figureColor: DashUi.sky,
      format: (x) => '${x.round()}',
      unit: ' jobs',
      bestWord: 'Busiest month',
      extra: [
        if (d.laborPerJob != null) DashStoryStat(d.laborPerJob!, whole, 'per labor job', DashUi.slate),
      ],
    );

    // Each view's figures are their own widgets, so switching views counts the new ones up from zero instead of
    // rolling the last view's figure (dollars) down to this one's (jobs).
    DashStory own(String view, DashStory s) => DashStory(
          [for (final (i, w) in s.headline.indexed) KeyedSubtree(key: ValueKey('$view-$i'), child: w)],
          s.callout,
          s.calloutColor,
        );

    return DashMonthChart(
      year: year,
      // Steps through the three views like the old chart did (it holds while the pointer is on it).
      autoCycle: const Duration(seconds: 8),
      views: [
        DashChartView(
          tab: 'Per work day',
          title: 'Labor per work day',
          story: own('perDay', perDayStory),
          series: [
            DashSeries(first, perDay, DashUi.sky),
            if (hasTeam) DashSeries('Rest of team', team, DashUi.slate, kind: DashSeriesKind.line, gaps: teamGaps),
          ],
          average: d.laborPerDay,
          averageLabel: d.laborPerDay == null ? null : "$first's year: ${whole(d.laborPerDay!)}",
          axis: _compactMoney,
          barLabel: _compactMoney,
          badge: DashChangeChip.monthOverMonth(perDay, year, what: 'Labor per work day'),
          tip: (i) => rows(i, lead: 'perDay', series: perDay, f: whole),
          summary: (last) => summary('Labor per work day', perDay, whole, last),
          emptyText: empty,
          semanticsLabel: 'Labor per work day by month, $year${hasTeam ? ', with the rest of the team as a line' : ''}',
        ),
        DashChartView(
          tab: 'Labor',
          title: 'Labor billed',
          story: own('labor', laborStory),
          series: [DashSeries(first, labor, DashUi.sky)],
          axis: _compactMoney,
          barLabel: _compactMoney,
          badge: DashChangeChip.monthOverMonth(labor, year, what: 'Labor billed'),
          tip: (i) => rows(i, lead: 'labor', series: labor, f: whole),
          summary: (last) => summary('Labor billed', labor, whole, last),
          emptyText: empty,
          semanticsLabel: 'Labor billed by month, $year',
        ),
        DashChartView(
          tab: 'Jobs',
          title: 'Jobs and work days',
          story: own('jobs', jobsStory),
          series: [
            DashSeries('Jobs', jobs, DashUi.sky),
            DashSeries('Work days', days, DashUi.slate, kind: DashSeriesKind.line, gaps: beforeFirst),
          ],
          axis: (x) => '${x.round()}',
          barLabel: (x) => '${x.round()}',
          badge: DashChangeChip.monthOverMonth(jobs, year, what: 'Completed jobs worked'),
          tip: (i) => rows(i, lead: 'jobs', series: jobs, f: (x) => '${x.round()}'),
          summary: (last) => summary('Jobs', jobs, (x) => '${x.round()}', last),
          emptyText: empty,
          semanticsLabel: 'Completed jobs worked and days worked by month, $year',
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// How the tech compares: every current tech, ranked by labor per work day
// -----------------------------------------------------------------------------

/// One row of the team table: a tech, or the rest of the team as one.
class _TeamRow {
  final String username; // '' for the rest-of-team row
  final String name;
  final String title;
  final String avatarUrl;
  final double? perDay;
  final int? days;
  final double? callbackRate;

  /// The jobs [callbackRate] is counted on (how far one strike moves it).
  final int? callbackJobs;
  final double? strikes;
  final bool me;

  /// The place by labor per work day; null for a tech with too few work days to rank (or no figure) and the pooled row.
  final int? rank;
  const _TeamRow({
    required this.username,
    required this.name,
    required this.title,
    required this.avatarUrl,
    required this.perDay,
    required this.days,
    required this.callbackRate,
    this.callbackJobs,
    required this.strikes,
    required this.me,
    this.rank,
  });

  _TeamRow ranked(int? place) => _TeamRow(
        username: username,
        name: name,
        title: title,
        avatarUrl: avatarUrl,
        perDay: perDay,
        days: days,
        callbackRate: callbackRate,
        callbackJobs: callbackJobs,
        strikes: strikes,
        me: me,
        rank: place,
      );

  /// Ranked by labor per work day: a figure, over at least [_rankMinDays] work days.
  bool get rankable => perDay != null && (days ?? 0) >= _rankMinDays;
}

/// The team table's rows and, under them, the rest of the team pooled (the figure the scorecards compare against).
typedef _TeamTable = ({List<_TeamRow> rows, _TeamRow? summary});

/// What of the team table fits: the "vs rest of team" tiles over the table (or, when the panel is short, the same
/// verdicts as chips in a line under the tech's own row), the pooled row, and how many rows.
typedef _TeamFit = ({bool tiles, bool verdict, bool summary, int maxRows});

/// The team table's columns. With [bar], the names take [names] and the rest goes to a bar with the labor a day at
/// its tip ([value] is that figure's width); without it (large text, narrow panel), labor a day is a column [value]
/// wide. The figure columns are as wide as their text, and [photo] says whether the photos fit. [invHead] is the inventory
/// strikes heading: "Inv. strikes (all time)" when the bars keep their room, else "Inv. strikes" (its hover says all time).
typedef _Cols = ({bool bar, bool photo, double names, double value, double days, double cb, double inv, String invHead});

abstract final class _TeamRows {
  /// Every current tech by labor per work day, highest first: those with at least [_rankMinDays] work days ranked (an
  /// equal figure, as shown, shares a place), then the rest unranked (no figure last). The rest of the team is pooled
  /// underneath, on the page's one rest-of-team figure (over the same months as this tech when the server sends it).
  /// From an older server without `teamMembers`, this tech and the rest of the team as two rows.
  static _TeamTable of(_TechPage d, String first, String myTitle) {
    final cbs = d.callbackTeam ?? const <_CallbackLine>[];
    _CallbackLine? cbOf(String u) => cbs.where((c) => c.username.toLowerCase() == u.toLowerCase()).firstOrNull;
    final restName = d.restTechs == null ? 'Rest of team' : 'Rest of team (${d.restTechs})';
    final span = d.restSpan;
    // "Rest of team" already leaves this tech out; with months named, the title keeps to them so it fits.
    final restTitle = span == null ? 'Pooled, without $first' : 'Pooled over $span';
    if (d.members.isNotEmpty) {
      final rows = [
        for (final m in d.members)
          _TeamRow(
            username: m.username,
            name: m.name,
            title: d._isMe(m.username) && myTitle.isNotEmpty ? myTitle : (cbOf(m.username)?.jobTitle ?? ''),
            avatarUrl: _ownPhoto(cbOf(m.username)?.avatarUrl ?? ''),
            perDay: m.laborPerDay,
            days: m.laborDays,
            callbackRate: cbOf(m.username)?.ratePct,
            callbackJobs: cbOf(m.username)?.jobs,
            strikes: m.inventoryStrikes.toDouble(),
            me: d._isMe(m.username),
          ),
      ];
      rows.sort((a, b) {
        if (a.rankable != b.rankable) return a.rankable ? -1 : 1;
        if ((a.perDay == null) != (b.perDay == null)) return a.perDay == null ? 1 : -1;
        final c = (b.perDay ?? 0).compareTo(a.perDay ?? 0);
        return c != 0 ? c : a.name.compareTo(b.name);
      });
      // Places as on a leaderboard: equal figures share one, and the next place skips ("1st, 1st, 3rd").
      final placed = <_TeamRow>[];
      for (var i = 0; i < rows.length; i++) {
        final r = rows[i];
        int? place;
        if (r.rankable) {
          final prev = placed.isEmpty ? null : placed.last;
          place = prev?.rank != null && _wholeMoney(prev!.perDay!) == _wholeMoney(r.perDay!) ? prev.rank : i + 1;
        }
        placed.add(r.ranked(place));
      }
      // The days behind the pooled figure: over this tech's months, or (an older server, a year this tech didn't work)
      // the rest of the team's whole year.
      final same = d.sameMonths;
      final restDays = same != null && same.months.isNotEmpty ? same.days : placed.where((r) => !r.me).fold<int>(0, (s, r) => s + (r.days ?? 0));
      return (
        rows: placed,
        summary: _TeamRow(
          username: '',
          name: restName,
          title: restTitle,
          avatarUrl: '',
          perDay: d.restPerDay,
          days: restDays,
          callbackRate: d.othersCallbackRate,
          strikes: d.teamAvgStrikes,
          me: false,
        ),
      );
    }
    final mine = d.callbacks;
    return (
      rows: [
        _TeamRow(
          username: d.username,
          name: first,
          title: myTitle,
          avatarUrl: _ownPhoto(mine?.avatarUrl ?? ''),
          perDay: d.laborPerDay,
          days: d.laborDays,
          callbackRate: mine?.ratePct,
          callbackJobs: mine?.jobs,
          strikes: d.inventoryStrikes.toDouble(),
          me: true,
        ),
        _TeamRow(
          username: '',
          name: restName,
          title: restTitle,
          avatarUrl: '',
          perDay: d.restPerDay,
          days: d.sameMonths?.days,
          callbackRate: d.othersCallbackRate,
          strikes: d.teamAvgStrikes,
          me: false,
        ),
      ],
      summary: null,
    );
  }

  /// The rows shown when only [n] fit: the first ones, with this tech always among them.
  static List<_TeamRow> shown(List<_TeamRow> rows, int n) {
    if (rows.length <= n) return rows;
    final top = rows.take(n).toList();
    if (top.any((r) => r.me)) return top;
    final me = rows.where((r) => r.me).firstOrNull;
    return me == null ? top : [...rows.take(n - 1), me];
  }
}

/// One line of the tech against the rest of the team: what is compared, the verdict in words ("Behind 57%") and both
/// figures ("$755 vs $1,736").
typedef _Versus = ({String label, _Verdict? verdict, String text, String detail});

/// "How X compares": the answer first, then the evidence.
///   - The verdict: the tech against the rest of the team pooled on labor a day, callback rate and inventory strikes,
///     as three tiles with an arrow, a word and both figures (a line of chips under the tech's row when short).
///   - The leaderboard: every current tech by labor a day (a square photo with their rank on it, name and title, a bar
///     with the figure riding at its tip, days, callbacks, inventory strikes). A dashed line through the bars marks
///     the rest of the team; the pooled row underneath draws its bar to that line, and the tech's own bar shades the
///     gap to it when behind.
/// The tiles rise in, the bars grow one after another with their figures counting up, and the line draws down
/// through them.
class _TeamPanel extends StatelessWidget {
  final DashGeo g;
  final _TechPage data;
  final _TeamTable table;
  final String first;
  final _TeamFit fit;

  /// Take the height given (rows spread out), or size to the rows.
  final bool fill;
  const _TeamPanel({required this.g, required this.data, required this.table, required this.first, required this.fit, required this.fill});

  static const _avatar = 40.0;
  static const _barMin = 48.0;

  /// The most a row grows in a tall panel; its photo and bar grow with it. Enough to fill the panel at 1920x940, where
  /// a page with no reviews gives the table everything above the one-line reviews strip.
  static const _maxGrow = 56.0;

  /// A row: a square photo, and a name over a title.
  static double rowHeight(DashGeo g) => math.max(48.0, g.line(14) + g.line(12) + 14);

  /// The Ahead / On par / Behind chips under the tech's own row (when the tiles don't fit).
  static double verdictHeight(DashGeo g) => g.line(11.5) + 10;

  /// The pooled row, under a hairline.
  static double summaryHeight(DashGeo g) => math.max(46.0, g.line(13) + g.line(12) + 14);

  /// The "vs rest of team" heading, the three tiles and the gap under them.
  static double tilesHeight(DashGeo g) => g.columnHead + _VersusTile.height(g) + 12;

  /// Everything above the rows, without the tiles.
  static double top(DashGeo g) => g.panelTop + g.columnHead;

  /// The panel's natural height with the tiles, every row and the pooled row.
  static double natural(DashGeo g, _TeamTable t) =>
      top(g) + tilesHeight(g) + t.rows.length * rowHeight(g) + (t.summary == null ? 0 : summaryHeight(g));

  /// The fullest panel that fits [avail] px: the tiles with every row and the pooled row; then the verdicts as chips
  /// under the tech's row with every row and the pooled row; then without the pooled row; then as many rows as fit
  /// (this tech always among them, with an "All" link for the rest).
  static _TeamFit fitFor(DashGeo g, _TeamTable t, double avail) {
    final n = t.rows.length;
    final rowH = rowHeight(g);
    final summary = t.summary == null ? 0.0 : summaryHeight(g);
    final room = avail - top(g);
    if (room >= tilesHeight(g) + n * rowH + summary) return (tiles: true, verdict: false, summary: t.summary != null, maxRows: n);
    final inline = room - verdictHeight(g);
    // Too short even for two rows with the chips: two rows without them.
    if (inline < 2 * rowH) return (tiles: false, verdict: false, summary: false, maxRows: math.max(2, (room / rowH).floor()));
    if (t.summary != null && inline >= n * rowH + summary) return (tiles: false, verdict: true, summary: true, maxRows: n);
    if (inline >= n * rowH) return (tiles: false, verdict: true, summary: false, maxRows: n);
    return (tiles: false, verdict: true, summary: false, maxRows: math.max(2, (inline / rowH).floor()));
  }

  List<_TeamRow> get rows => table.rows;

  @override
  Widget build(BuildContext context) {
    final d = data;
    final ranked = d.members.isNotEmpty;
    final mine = rows.where((r) => r.me).firstOrNull;
    final placed = rows.where((r) => r.rank != null).length;
    final tied = mine?.rank != null && rows.where((r) => r.rank == mine!.rank).length > 1;
    final note = !ranked || mine == null || mine.perDay == null
        ? 'against the rest of the team'
        : mine.rank == null
            ? 'Not ranked: under $_rankMinDays work days'
            : '${tied ? 'Tied' : 'Ranked'} ${_ordinal(mine.rank!)} of $placed by labor per work day';
    final shown = _TeamRows.shown(rows, fit.maxRows);
    final cut = shown.length < rows.length;
    final span = d.restSpan;
    final header = DashPanelHeader(
      g: g,
      title: 'How $first compares',
      note: note,
      tooltip: 'Labor per work day: labor billed on completed ${d.year} jobs ÷ the calendar days worked on them, as a bar '
          'for each tech. The dashed line is the rest of the team pooled (without $first)'
          '${span == null ? '' : ' over the same months $first worked ($span)'}; the shaded gap on $first\'s bar is how far '
          'short of it they are. Days: the days worked. Callbacks: callback strikes ÷ jobs since '
          '${d.callbackFrom == null ? 'Oct 5, 2026' : dashShortDate(d.callbackFrom!)} where the tech did the original work. '
          '$first\'s is green when ahead of the rest of the team and amber when behind (less than one strike apart, or '
          'within 5%, is on par); everyone else\'s is green below the whole team\'s rate and amber above it. Inv. strikes: '
          'days none of the day\'s job materials were checked out by 4 PM (8:30 AM before November 2026), all time (the '
          'counter keeps no dates). '
          '${d.isCurrentYear ? '$first\'s is green when fewer than the rest of the team\'s average and amber when more '
              '(within 5% is on par); everyone else\'s is the same against the whole team\'s average. ' : 'A past year '
              'has no verdict on them, so only none is green. '}'
          'Ahead, on par (within 5%) or behind: $first against the rest of the team.'
          '${ranked ? ' Every current tech, highest labor per work day first; techs with fewer than $_rankMinDays work days '
              'are listed after, unranked, and equal figures share a place. Select one to open their page.' : ''}',
      trailing: cut ? DashLink(text: 'All ${rows.length}', label: 'See all ${dashCount(rows.length, 'technician')}', onTap: () => _openAll(context)) : null,
    );
    // Bars are drawn against the highest figure on show, the pooled one included.
    final scale = [...rows, ?table.summary].fold<double>(0, (m, r) => math.max(m, r.perDay ?? 0));
    final rest = d.restPerDay;
    final mark = rest == null || scale <= 0 ? null : (rest / scale).clamp(0.0, 1.0);
    final rowH = rowHeight(g);

    return DashPanel(
      fill: fill,
      header: header,
      child: LayoutBuilder(
        builder: (context, c) {
          final summary = fit.summary ? table.summary : null;
          final heights = [
            for (final r in shown) rowH + (r.me && fit.verdict ? verdictHeight(g) : 0),
            if (summary != null) summaryHeight(g),
          ];
          final base = heights.fold<double>(0, (s, h) => s + h) + g.columnHead + (fit.tiles ? tilesHeight(g) : 0);
          // Spread the rows over a tall panel (at most 40 px more each); their photos and bars grow with them.
          final spare = fill && c.maxHeight.isFinite ? (c.maxHeight - base).clamp(0.0, _maxGrow * heights.length) : 0.0;
          final extra = heights.isEmpty ? 0.0 : spare / heights.length;
          final size = (photo: _avatar + extra * 0.4, bar: 12 + extra * 0.15);
          final cols = _columns(context, [...shown, ?summary], c.maxWidth, size.photo);
          final versus = _versus();
          var i = 0;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (fit.tiles) SizedBox(height: tilesHeight(g), child: _tiles(versus)),
              _headings(cols, mark, size.photo),
              for (final r in shown)
                SizedBox(
                  height: heights[i++] + extra,
                  child: _row(context, r, cols, versus, scale: scale, mark: mark, order: i, size: size, rank: ranked ? r.rank : null),
                ),
              if (summary != null)
                Container(
                  height: heights.last + extra,
                  decoration: const BoxDecoration(border: Border(top: BorderSide(color: DashUi.line))),
                  child: _row(context, summary, cols, versus, scale: scale, mark: mark, order: i + 1, size: size, rank: null),
                ),
            ],
          );
        },
      ),
    );
  }

  /// The whole table in a dialog, when the page has room for only part of it.
  void _openAll(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: _TeamPanel(
            g: g,
            data: data,
            table: table,
            first: first,
            fit: (tiles: true, verdict: false, summary: table.summary != null, maxRows: table.rows.length),
            fill: false,
          ),
        ),
      ),
    );
  }

  /// Each figure column as wide as its widest text (heading, figures, the chip under it). The names take what they
  /// need and the bar the rest; when the bar has too little room (large text) it goes, and then the photo.
  _Cols _columns(BuildContext context, List<_TeamRow> rows, double width, double photo) {
    final scaler = MediaQuery.textScalerOf(context);
    final base = DefaultTextStyle.of(context).style;
    double w(String s, TextStyle st) =>
        (TextPainter(text: TextSpan(text: s, style: base.merge(st)), textDirection: TextDirection.ltr, textScaler: scaler, maxLines: 1)..layout()).width.ceilToDouble() + 2;
    double widest(String head, Iterable<String> cells, [List<String> chips = const []]) => [
          w(head, DashText.column),
          for (final c in cells) w(c, DashText.money),
          for (final v in chips) w(v, _verdictStyle) + 14,
        ].reduce(math.max);
    final value = widest('Labor / work day', rows.map(_perDayText), ['Behind 100%']);
    final tip = rows.map((r) => w(_perDayText(r), _tipStyle)).fold<double>(0, math.max);
    final days = widest('Days', rows.map((r) => r.days == null ? '—' : '${r.days}'));
    final cb = widest('Callbacks', rows.map((r) => r.callbackRate == null ? '—' : _pct1(r.callbackRate!)), ['On par', 'Behind']);
    final invLong = widest(_invHead, rows.map(_strikesText), ['On par', 'Behind']);
    final invShort = widest(_invHeadShort, rows.map(_strikesText), ['On par', 'Behind']);
    final names = [
      for (final r in rows) ...[w(r.name, DashText.name.copyWith(fontSize: 14, fontWeight: FontWeight.w800)), w(r.title, DashText.meta)],
      if (fit.verdict) w('vs rest of team', _verdictStyle),
    ].fold<double>(0, math.max).clamp(0.0, 190.0 * scaler.scale(1)).toDouble();
    // The long heading only while the bars keep room for their track and the "Rest of team" tag over its line.
    final longRoom = width - (days + cb + invLong + 3 * 10 + 22 + 22) - names - 12 - tip - 8 - photo - 12;
    final long = longRoom >= _invLongMinTrack;
    final inv = long ? invLong : invShort;
    // The figure columns, their gaps, the chevron and the row's padding.
    final fixed = days + cb + inv + 3 * 10 + 22 + 22;
    final hasPhoto = width >= fixed + names + 10 + value + photo + 12;
    final bar = hasPhoto && width >= fixed + names + 12 + tip + 8 + _barMin + photo + 12;
    return (bar: bar, photo: hasPhoto, names: names, value: bar ? tip : value, days: days, cb: cb, inv: inv, invHead: long ? _invHead : _invHeadShort);
  }

  static const _verdictStyle = TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, height: 1.3);

  /// The inventory strikes column's heading: the counter keeps no dates, so the figures are all time whatever the year.
  /// The short one (a narrower panel) says so on hover, as do the verdict tile and the panel's hover text.
  static const _invHead = 'Inv. strikes (all time)';
  static const _invHeadShort = 'Inv. strikes';

  /// The bar track the long heading leaves at the least.
  static const _invLongMinTrack = 200.0;

  /// The labor a day at a bar's tip.
  static const _tipStyle = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, height: 1.3, fontFeatures: DashText.tabular);

  static String _perDayText(_TeamRow r) => r.perDay == null ? '—' : _wholeMoney(r.perDay!);
  static String _strikesText(_TeamRow r) =>
      r.strikes == null ? '—' : (r.username.isEmpty ? '${_fmtNum(r.strikes!)} avg' : '${r.strikes!.round()}');

  /// The tech against the rest of the team pooled: labor a day, callback rate, inventory strikes.
  List<_Versus> _versus() {
    final d = data;
    String word(_Verdict? v) => switch (v) {
          _Verdict.ahead => 'Ahead',
          _Verdict.par => 'On par',
          _Verdict.behind => 'Behind',
          null => 'No figure yet',
        };
    String vs(String? mine, String? rest) => mine == null || rest == null ? 'Nothing to compare yet' : '$mine vs $rest';
    final rest = d.restPerDay;
    final span = d.restSpan;
    final perDay = _verdict(d.laborPerDay, rest, higherBetter: true);
    final pct = d.laborPerDay != null && rest != null && rest > 0 ? ((d.laborPerDay! - rest) / rest * 100).abs().round() : null;
    final mine = d.callbacks;
    final o = d.othersCallbacks;
    final cb = d.callbackVerdict;
    // Inventory strikes are an all-time count (no dates): compared only on this year's page, never as a past year's.
    final inv = d.isCurrentYear ? _verdict(d.inventoryStrikes.toDouble(), d.teamAvgStrikes, higherBetter: false) : null;
    final strikes = vs('${d.inventoryStrikes}', d.teamAvgStrikes == null ? null : '${_fmtNum(d.teamAvgStrikes!)} avg');
    return [
      (
        label: 'Labor per work day',
        verdict: perDay,
        text: perDay == null || perDay == _Verdict.par || pct == null ? word(perDay) : '${word(perDay)} $pct%',
        detail: '${vs(d.laborPerDay == null ? null : _wholeMoney(d.laborPerDay!), rest == null ? null : _wholeMoney(rest))}'
            '${span == null || perDay == null ? '' : ' · $span'}',
      ),
      (
        label: 'Callback rate',
        verdict: cb,
        text: d.callbackTeam == null ? "Couldn't load" : word(cb),
        // The counts behind both rates: one strike more or less moves a rate on a few dozen jobs by several points.
        detail: d.callbackTeam == null
            ? 'Refresh to try again'
            : mine?.jobs == null || o == null || cb == null
                ? 'Nothing to compare yet'
                : '${mine!.strikes} of ${dashCount(mine.jobs!, 'job')} vs ${o.strikes} of ${o.jobs}',
      ),
      (
        label: 'Inventory strikes',
        verdict: inv,
        text: d.isCurrentYear ? word(inv) : 'Not kept by year',
        detail: strikes == 'Nothing to compare yet' ? strikes : '$strikes · all time',
      ),
    ];
  }

  /// "vs rest of team" with the tally in words on the right ("Behind on 2 of 3"), over the three tiles.
  Widget _tiles(List<_Versus> versus) {
    final counted = versus.where((v) => v.verdict != null).toList();
    final n = counted.length;
    final ahead = counted.where((v) => v.verdict == _Verdict.ahead).length;
    final behind = counted.where((v) => v.verdict == _Verdict.behind).length;
    // One figure to compare is named ("Behind on inventory strikes"); more are counted ("Behind on 2 of 3").
    final (String? tally, Color color, IconData icon) = switch ((n, ahead, behind)) {
      (0, _, _) => (null, DashUi.subtle, Icons.remove_rounded),
      (1, 1, _) => ('Ahead on ${counted.single.label.toLowerCase()}', DashUi.emeraldText, Icons.trending_up_rounded),
      (1, _, 1) => ('Behind on ${counted.single.label.toLowerCase()}', DashUi.redText, Icons.trending_down_rounded),
      (1, _, _) => ('On par on ${counted.single.label.toLowerCase()}', DashUi.slate, Icons.drag_handle_rounded),
      (_, 0, 0) => (n == 2 ? 'On par on both' : 'On par on all $n', DashUi.slate, Icons.drag_handle_rounded),
      _ when ahead > behind => (ahead == n ? (n == 2 ? 'Ahead on both' : 'Ahead on all $n') : 'Ahead on $ahead of $n', DashUi.emeraldText, Icons.trending_up_rounded),
      _ when behind > ahead => (behind == n ? (n == 2 ? 'Behind on both' : 'Behind on all $n') : 'Behind on $behind of $n', DashUi.redText, Icons.trending_down_rounded),
      _ => ('Ahead on $ahead, behind on $behind', DashUi.slate, Icons.swap_vert_rounded),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: g.columnHead,
          child: Row(
            children: [
              const Expanded(child: Text('vs rest of team', maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.column)),
              if (tally != null) ...[
                Icon(icon, size: 15, color: color),
                const SizedBox(width: 4),
                Text(tally, maxLines: 1, style: DashText.column.copyWith(fontWeight: FontWeight.w700, color: color)),
              ],
            ],
          ),
        ),
        SizedBox(
          height: _VersusTile.height(g),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, v) in versus.indexed) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: _VersusTile(versus: v, who: first, order: i)),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _headings(_Cols cols, double? mark, double photo) {
    Widget head(String t, double w) => SizedBox(width: w, child: Text(t, textAlign: TextAlign.right, maxLines: 1, style: DashText.column));
    return ExcludeSemantics(
      child: SizedBox(
        height: g.columnHead,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11),
          child: Row(
            children: [
              if (cols.photo) SizedBox(width: photo + 12),
              if (cols.bar) ...[
                SizedBox(width: cols.names, child: const Text('Tech', maxLines: 1, style: DashText.column)),
                const SizedBox(width: 12),
                Expanded(child: _BarHeading(mark: mark, tip: cols.value)),
              ] else ...[
                const Expanded(child: Text('Tech', maxLines: 1, style: DashText.column)),
                const SizedBox(width: 10),
                head('Labor / work day', cols.value),
              ],
              const SizedBox(width: 10),
              head('Days', cols.days),
              const SizedBox(width: 10),
              head('Callbacks', cols.cb),
              const SizedBox(width: 10),
              cols.invHead == _invHead
                  ? head(_invHead, cols.inv)
                  : Tooltip(message: 'Inventory strikes, all time: the counter keeps no dates', child: head(_invHeadShort, cols.inv)),
              const SizedBox(width: 22),
            ],
          ),
        ),
      ),
    );
  }

  /// A coloured pill: Ahead (green), On par (grey), Behind (red).
  Widget _chip(_Versus v, {double? width, Alignment align = Alignment.centerRight}) {
    final verdict = v.verdict;
    if (verdict == null) return SizedBox(width: width);
    final color = _versusColor(verdict);
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
      child: Text(v.text, maxLines: 1, style: _verdictStyle.copyWith(color: color)),
    );
    return SizedBox(width: width, child: Align(alignment: align, child: pill));
  }

  /// The tech against the rest of the team, column by column, when the tiles don't fit.
  Widget _verdicts(_Cols cols, List<_Versus> versus, double photo, double? mark) {
    const label = Text('vs rest of team', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, height: 1.3, color: DashUi.subtle));
    return Row(
      children: [
        if (cols.photo) SizedBox(width: photo + 12),
        if (cols.bar) ...[
          SizedBox(width: cols.names, child: label),
          const SizedBox(width: 12),
          // The team's line carries on under the bar, so the chip reads against it.
          Expanded(
            child: CustomPaint(
              painter: _MarkLinePainter(mark: mark, tip: cols.value),
              child: _chip(versus[0], align: Alignment.centerLeft),
            ),
          ),
        ] else ...[
          const Expanded(child: label),
          const SizedBox(width: 10),
          _chip(versus[0], width: cols.value),
        ],
        const SizedBox(width: 10),
        SizedBox(width: cols.days),
        const SizedBox(width: 10),
        _chip(versus[1], width: cols.cb),
        const SizedBox(width: 10),
        _chip(versus[2], width: cols.inv),
        const SizedBox(width: 22),
      ],
    );
  }

  /// A square photo with their rank on it (gold, silver, bronze for the first three); a team badge for the pooled row.
  Widget _photo(_TeamRow r, int? rank, double size) {
    final Widget avatar;
    if (r.username.isEmpty) {
      avatar = Container(
        decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(8), border: Border.all(color: DashUi.line)),
        child: Icon(Icons.groups_rounded, size: size * 0.5, color: DashUi.slate),
      );
    } else if (r.me) {
      avatar = DashAvatar(name: r.name, imageUrl: r.avatarUrl, size: size - 4, square: true, accent: DashUi.sky, ringColor: DashUi.sky, ringWidth: 2);
    } else {
      avatar = DashAvatar(name: r.name, imageUrl: r.avatarUrl, size: size, square: true, accent: DashUi.slate);
    }
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: avatar),
          if (rank != null) Positioned(left: -6, top: -6, child: DashRankBadge(rank: rank, size: 20)),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    _TeamRow r,
    _Cols cols,
    List<_Versus> versus, {
    required double scale,
    required double? mark,
    required int order,
    required ({double photo, double bar}) size,
    int? rank,
  }) {
    final d = data;
    final pooled = r.username.isEmpty;
    final open = !pooled && !r.me;
    final perDay = _perDayText(r);
    final cb = r.callbackRate == null ? '—' : _pct1(r.callbackRate!);
    final strikes = _strikesText(r);
    final label = pooled
        ? '${r.name}, pooled: $perDay labor per work day${r.days == null ? '' : ' over ${dashCount(r.days!, 'day')}'}, '
            'callback rate $cb, inventory strikes (all time) $strikes'
        : '${rank == null ? '' : 'Number $rank. '}${r.name}${r.me ? ' (this page)' : ''}: $perDay labor per work day'
            '${r.days == null ? '' : ' over ${dashCount(r.days!, 'day')}'}, callback rate $cb, inventory strikes (all time) $strikes';
    Widget cell(String text, double w, {TextStyle style = DashText.money}) => SizedBox(
          width: w,
          child: Text(text, textAlign: TextAlign.right, maxLines: 1, style: style),
        );
    final quiet = DashText.money.copyWith(fontWeight: FontWeight.w600, color: DashUi.slate);
    // Callback rates: this tech's by its verdict against the rest of the team (as the chip says); everyone else's
    // against the whole team's rate, so a teammate's colour doesn't change with whose page it is. Green when lower,
    // amber when higher, ink when on par (less than one strike apart, or within 5%).
    final cbVerdict = r.me ? d.callbackVerdict : _callbackVerdict(r.callbackRate, r.callbackJobs, d.wholeTeamCallbackRate);
    final cbColor = r.callbackRate == null
        ? DashUi.subtle
        : pooled
            ? DashUi.slate
            : switch (cbVerdict) {
                _Verdict.ahead => DashUi.emeraldText,
                _Verdict.behind => DashUi.amberText,
                _Verdict.par => DashUi.ink,
                null => r.callbackRate == 0 ? DashUi.emeraldText : DashUi.ink,
              };
    // Inventory strikes the same way, against the average count: every tech has some (all time), so a colour for "any"
    // would mark every row. This tech's as its chip says (the rest of the team's average), everyone else's against the
    // whole team's. A past year has no verdict on them (the count keeps no dates): only none is green. The pooled
    // average stays quiet.
    final invVerdict = pooled || r.strikes == null || !d.isCurrentYear
        ? null
        : (r.me ? versus[2].verdict : _verdict(r.strikes, d.wholeTeamAvgStrikes, higherBetter: false));
    final strikesColor = r.strikes == null || pooled
        ? DashUi.slate
        : switch (invVerdict) {
            _Verdict.ahead => DashUi.emeraldText,
            _Verdict.behind => DashUi.amberText,
            _Verdict.par => DashUi.ink,
            null => r.strikes == 0 ? DashUi.emeraldText : DashUi.ink,
          };
    final tipColor = r.me ? DashUi.sky : (pooled ? DashUi.slate : DashUi.ink);
    final line = Row(
      children: [
        if (cols.photo) ...[_photo(r, rank, size.photo), const SizedBox(width: 12)],
        if (cols.bar) ...[
          SizedBox(width: cols.names, child: _name(r, pooled)),
          const SizedBox(width: 12),
          Expanded(
            child: _LeaderBar(
              value: r.perDay,
              scale: scale,
              mark: mark,
              tip: cols.value,
              order: order,
              barHeight: size.bar,
              style: _tipStyle.copyWith(color: tipColor, fontWeight: pooled ? FontWeight.w700 : FontWeight.w800),
              kind: pooled ? _BarKind.pooled : (r.me ? _BarKind.mine : _BarKind.other),
              short: r.me && versus[0].verdict == _Verdict.behind,
            ),
          ),
        ] else ...[
          Expanded(child: _name(r, pooled)),
          const SizedBox(width: 10),
          cell(perDay, cols.value, style: DashText.money.copyWith(fontSize: 14.5, color: tipColor)),
        ],
        const SizedBox(width: 10),
        cell(r.days == null ? '—' : '${r.days}', cols.days, style: quiet),
        const SizedBox(width: 10),
        cell(cb, cols.cb, style: DashText.money.copyWith(color: cbColor)),
        const SizedBox(width: 10),
        cell(strikes, cols.inv, style: DashText.money.copyWith(color: strikesColor)),
        SizedBox(width: 22, child: open ? const Icon(Icons.chevron_right_rounded, size: 18, color: DashUi.subtle) : null),
      ],
    );
    final verdict = r.me && fit.verdict;
    final body = verdict
        ? Column(children: [Expanded(child: line), SizedBox(height: verdictHeight(g), child: _verdicts(cols, versus, size.photo, mark))])
        : line;
    if (pooled) {
      return Semantics(
        container: true,
        label: label,
        child: ExcludeSemantics(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 11), child: body)),
      );
    }
    return DashPressable(
      // The teammate's page opens on the same year (this year needs no `?year=`).
      onTap: open
          ? () => GoRouter.maybeOf(context)?.go('/hr/kpis/${Uri.encodeComponent(r.username)}${d.isCurrentYear ? '' : '?year=${d.year}'}')
          : null,
      label: label,
      hint: open ? "Opens ${r.name}'s page" : null,
      radius: BorderRadius.circular(12),
      builder: (hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: r.me ? DashUi.sky.withValues(alpha: 0.07) : (hover ? DashUi.faint : DashUi.faint.withValues(alpha: 0)),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: r.me ? DashUi.sky.withValues(alpha: 0.32) : DashUi.sky.withValues(alpha: 0)),
        ),
        child: body,
      ),
    );
  }

  /// A name over a title.
  Widget _name(_TeamRow r, bool pooled) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            r.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: DashText.name.copyWith(
              fontSize: pooled ? 13 : 14,
              fontWeight: r.me ? FontWeight.w800 : FontWeight.w700,
              color: pooled ? DashUi.slate : DashUi.ink,
            ),
          ),
          if (r.title.isNotEmpty) Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.meta),
        ],
      );
}

/// Green for ahead, grey for on par, red for behind.
Color _versusColor(_Verdict? v) => switch (v) {
      _Verdict.ahead => DashUi.emeraldText,
      _Verdict.par => DashUi.slate,
      _Verdict.behind => DashUi.redText,
      null => DashUi.subtle,
    };

/// One of the "vs rest of team" tiles: what is compared, an arrow and the verdict in words, and both figures. It rises
/// in after the one before it, its arrow popping in.
class _VersusTile extends StatelessWidget {
  final _Versus versus;
  final String who;
  final int order;
  const _VersusTile({required this.versus, required this.who, required this.order});

  static double height(DashGeo g) => 20 + g.line(12) + 2 + math.max(20.0, g.line(15, 1.2)) + 2 + g.line(12);

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final v = versus;
    final color = _versusColor(v.verdict);
    final icon = switch (v.verdict) {
      _Verdict.ahead => Icons.arrow_upward_rounded,
      _Verdict.par => Icons.drag_handle_rounded,
      _Verdict.behind => Icons.arrow_downward_rounded,
      null => Icons.remove_rounded,
    };
    final ms = 520 + 140 * order;
    final tile = Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(v.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.meta.copyWith(color: DashUi.slate, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Row(
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: still ? 1 : 0, end: 1),
                duration: still ? Duration.zero : Duration(milliseconds: ms + 260),
                curve: Interval((ms - 100) / (ms + 260), 1, curve: Curves.easeOutBack),
                builder: (context, t, child) => Transform.scale(scale: t, child: child),
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.14), shape: BoxShape.circle),
                  child: Icon(icon, size: 14, color: color),
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(v.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, height: 1.2, color: color)),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(v.detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.meta.copyWith(fontFeatures: DashText.tabular)),
        ],
      ),
    );
    return Semantics(
      container: true,
      label: '${v.label}, $who against the rest of the team: ${v.text}, ${v.detail}',
      child: ExcludeSemantics(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: still ? 1 : 0, end: 1),
          duration: still ? Duration.zero : Duration(milliseconds: ms),
          curve: Interval(140 * order / ms, 1, curve: Curves.easeOutCubic),
          builder: (context, t, child) => Opacity(opacity: t, child: Transform.translate(offset: Offset(0, 10 * (1 - t)), child: child)),
          child: tile,
        ),
      ),
    );
  }
}

enum _BarKind { mine, other, pooled }

/// The bar area's heading: "Labor per work day" (or "Per work day") at its start, and "Rest of team" over the dashed
/// line when there is room for both.
class _BarHeading extends StatelessWidget {
  final double? mark;
  final double tip;
  const _BarHeading({required this.mark, required this.tip});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final scaler = MediaQuery.textScalerOf(context);
        final base = DefaultTextStyle.of(context).style;
        double w(String s, TextStyle st) =>
            (TextPainter(text: TextSpan(text: s, style: base.merge(st)), textDirection: TextDirection.ltr, textScaler: scaler, maxLines: 1)..layout()).width + 2;
        const team = 'Rest of team';
        final teamStyle = DashText.column.copyWith(color: DashUi.slate, fontWeight: FontWeight.w700);
        final track = math.max(0.0, c.maxWidth - tip - 8);
        final x = mark == null ? null : track * mark!;
        final teamW = w(team, teamStyle);
        // Centred over the line and kept inside the area; the heading shortens to clear it, and it goes when even
        // the short heading doesn't.
        final left = x == null ? null : (x - teamW / 2).clamp(0.0, math.max(0.0, c.maxWidth - teamW)).toDouble();
        final head = left == null || left >= w('Labor per work day', DashText.column) + 8 ? 'Labor per work day' : 'Per work day';
        final showTeam = left != null && left >= w(head, DashText.column) + 8;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Align(alignment: Alignment.centerLeft, child: Text(head, maxLines: 1, style: DashText.column)),
            if (showTeam)
              Positioned(left: left, top: 0, bottom: 0, child: Center(child: Text(team, maxLines: 1, style: teamStyle))),
          ],
        );
      },
    );
  }
}

/// A leaderboard bar: it grows in after the one above it with its figure counting up at its tip, and the dashed
/// rest-of-team line fades in through it. The tech's own bar is solid sky, shading the gap to the line when short of
/// it; the others are a lighter sky; the pooled row is a dashed outline ending on the line.
class _LeaderBar extends StatelessWidget {
  final double? value;
  final double scale;
  final double? mark;

  /// Room kept at the right for the figure at the tip.
  final double tip;
  final int order;
  final double barHeight;
  final TextStyle style;
  final _BarKind kind;

  /// Short of the rest of the team: shade the gap.
  final bool short;
  const _LeaderBar({
    required this.value,
    required this.scale,
    required this.mark,
    required this.tip,
    required this.order,
    required this.barHeight,
    required this.style,
    required this.kind,
    required this.short,
  });

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final ms = 760 + 110 * order;
    final frac = value == null || scale <= 0 ? 0.0 : (value! / scale).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (context, c) {
        final track = math.max(0.0, c.maxWidth - tip - 8);
        return TweenAnimationBuilder<double>(
          // A new figure (another year) grows in again.
          key: ValueKey(value),
          tween: Tween(begin: still ? 1 : 0, end: 1),
          duration: still ? Duration.zero : Duration(milliseconds: ms),
          curve: Interval(110 * order / ms, 1, curve: Curves.easeOutCubic),
          builder: (context, t, _) {
            final end = track * frac * t;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _LeaderBarPainter(
                      end: end,
                      mark: mark == null ? null : track * mark!,
                      markOpacity: const Interval(0.45, 1).transform(t),
                      gap: short ? const Interval(0.7, 1).transform(t) : 0,
                      barHeight: barHeight,
                      kind: kind,
                    ),
                  ),
                ),
                Positioned(
                  left: value == null ? 0 : end + 8,
                  top: 0,
                  bottom: 0,
                  child: Center(child: Text(value == null ? '—' : _wholeMoney(value! * t), maxLines: 1, style: style)),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Dashes along [path].
void _dashPath(Canvas canvas, Path path, Paint paint, {double on = 4, double off = 3}) {
  for (final m in path.computeMetrics()) {
    for (var d = 0.0; d < m.length; d += on + off) {
      canvas.drawPath(m.extractPath(d, math.min(d + on, m.length)), paint);
    }
  }
}

/// The rest of the team's dashed line, top to bottom of a row, at [x].
void _paintMark(Canvas canvas, Size size, double x, double opacity) {
  if (opacity <= 0) return;
  final paint = Paint()
    ..color = DashUi.slate.withValues(alpha: 0.6 * opacity)
    ..strokeWidth = 1.5
    ..style = PaintingStyle.stroke;
  _dashPath(canvas, Path()..moveTo(x, 0)..lineTo(x, size.height), paint);
}

class _LeaderBarPainter extends CustomPainter {
  final double end;
  final double? mark;
  final double markOpacity;
  final double gap;
  final double barHeight;
  final _BarKind kind;
  const _LeaderBarPainter({required this.end, required this.mark, required this.markOpacity, required this.gap, required this.barHeight, required this.kind});

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final h = barHeight;
    final r = Radius.circular(h / 2);
    final m = mark;
    // How far short of the team: a red tint from the bar's tip to the line.
    if (gap > 0 && m != null && m > end) {
      final rect = RRect.fromLTRBR(math.max(0.0, end - h / 2), cy - h / 2, m, cy + h / 2, r);
      canvas.drawRRect(rect, Paint()..color = DashUi.red.withValues(alpha: 0.11 * gap));
    }
    if (end > 0) {
      final bar = RRect.fromLTRBR(0, cy - h / 2, math.max(end, h), cy + h / 2, r);
      switch (kind) {
        case _BarKind.pooled:
          canvas.drawRRect(bar, Paint()..color = DashUi.slate.withValues(alpha: 0.08));
          _dashPath(
            canvas,
            Path()..addRRect(bar),
            Paint()
              ..color = DashUi.slate.withValues(alpha: 0.55)
              ..strokeWidth = 1.2
              ..style = PaintingStyle.stroke,
          );
        case _BarKind.mine:
          canvas.drawRRect(bar.shift(const Offset(0, 2)), Paint()..color = DashUi.sky.withValues(alpha: 0.18));
          canvas.drawRRect(
            bar,
            Paint()..shader = LinearGradient(colors: [DashUi.sky.withValues(alpha: 0.7), DashUi.sky]).createShader(bar.outerRect),
          );
        case _BarKind.other:
          canvas.drawRRect(
            bar,
            Paint()..shader = LinearGradient(colors: [DashUi.sky.withValues(alpha: 0.2), DashUi.sky.withValues(alpha: 0.4)]).createShader(bar.outerRect),
          );
      }
    }
    if (m != null) _paintMark(canvas, size, m, markOpacity);
  }

  @override
  bool shouldRepaint(_LeaderBarPainter old) =>
      old.end != end || old.mark != mark || old.markOpacity != markOpacity || old.gap != gap || old.barHeight != barHeight || old.kind != kind;
}

/// The dashed line alone, under the tech's row where the chips sit, so it runs unbroken down the table.
class _MarkLinePainter extends CustomPainter {
  final double? mark;
  final double tip;
  const _MarkLinePainter({required this.mark, required this.tip});

  @override
  void paint(Canvas canvas, Size size) {
    final m = mark;
    if (m == null) return;
    _paintMark(canvas, size, math.max(0.0, size.width - tip - 8) * m, 1);
  }

  @override
  bool shouldRepaint(_MarkLinePainter old) => old.mark != mark || old.tip != tip;
}

// -----------------------------------------------------------------------------
// Customer reviews
// -----------------------------------------------------------------------------

/// What customers say: the star average and a review at a time, sliding up to the next every 12 seconds with a thin
/// line counting down along the bottom (it holds under the pointer and with reduced motion). "All" opens them one at
/// a time in full.
class _ReviewsCard extends StatefulWidget {
  final List<_Mention> mentions;
  final _Rating? rating;
  final String first;
  final bool sample;
  const _ReviewsCard({required this.mentions, required this.rating, required this.first, required this.sample});

  /// The card's height for [lines] lines of a review: its title row, the lines, and the byline with the arrows.
  static double height(DashGeo g, int lines) => 12 + math.max(g.line(13), 18.0) + 6 + lines * g.line(13.5, 1.35) + 4 + g.line(11.5) + 8 + 6;

  /// The card with no review to show, as one line: the title with the empty note after it.
  static double emptyHeight(DashGeo g) => 12 + math.max(g.line(13.5), 18.0) + 12;

  @override
  State<_ReviewsCard> createState() => _ReviewsCardState();
}

class _ReviewsCardState extends State<_ReviewsCard> with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(vsync: this, duration: const Duration(seconds: 12));
  int _i = 0;
  bool _hovered = false;
  bool _still = false;

  @override
  void initState() {
    super.initState();
    _clock.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) _step(1);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.disableAnimationsOf(context);
    _sync();
  }

  @override
  void didUpdateWidget(covariant _ReviewsCard old) {
    super.didUpdateWidget(old);
    if (old.mentions.length != widget.mentions.length) {
      _i = 0;
      _clock.value = 0;
      _sync();
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  void _sync() {
    if (widget.mentions.length < 2 || _still || _hovered) {
      _clock.stop();
    } else if (!_clock.isAnimating) {
      _clock.forward();
    }
  }

  void _step(int by) {
    final n = widget.mentions.length;
    if (n < 2) return;
    setState(() => _i = ((_i + by) % n + n) % n);
    _clock.value = 0;
    _sync();
  }

  void _openAll() {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 420),
          child: _MentionsCard(
            mentions: widget.mentions,
            satisfaction: widget.rating,
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
            header: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Expanded(child: Text('Customer reviews · ${widget.first}', style: DashText.panelTitle)),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(ctx).pop(),
                    icon: const Icon(Icons.close_rounded, size: 20, color: DashUi.slate),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.mentions;
    final r = widget.rating;
    final m = list.isEmpty ? null : list[_i % list.length];
    const quoteStyle = TextStyle(fontSize: 13, fontStyle: FontStyle.italic, height: 1.3, color: DashUi.ink);
    final emptyNote = 'No Google reviews mention ${widget.first} yet.';
    final emptyStyle = DashText.empty.copyWith(fontSize: 13.5);
    // The title row; [note] goes after the title (no review to show, and the card is a single line high).
    Widget headerRow({Widget? note}) => Row(
      children: [
        const Text('Customer reviews', maxLines: 1, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.3, color: DashUi.slate)),
        if (widget.sample) const Text(' · sample', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, height: 1.3, color: DashUi.amberText)),
        if (note != null) ...[const SizedBox(width: 12), Expanded(child: note)] else const Spacer(),
        if (r != null)
          Semantics(
            label: '${_fmtNum(r.avg)} out of 5 stars from ${dashCount(r.count, 'review')}',
            child: ExcludeSemantics(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: r.avg),
                    duration: _still ? Duration.zero : const Duration(milliseconds: 1100),
                    curve: Curves.easeOutCubic,
                    builder: (context, x, _) => SizedBox(width: 70, height: 14, child: CustomPaint(painter: _StarsPainter(x, DashUi.amber))),
                  ),
                  const SizedBox(width: 6),
                  Text(r.avg.toStringAsFixed(1), style: DashText.money),
                  Text(' (${r.count})', style: DashText.meta),
                ],
              ),
            ),
          ),
      ],
    );

    Widget body;
    if (m == null) {
      body = Expanded(
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(emptyNote, maxLines: 2, style: emptyStyle),
        ),
      );
    } else {
      body = Expanded(
        child: LayoutBuilder(
          builder: (context, c) {
            // The largest size (16 down to 13) at which the whole review fits; failing that, as many lines as fit.
            final scaler = MediaQuery.textScalerOf(context);
            final base = DefaultTextStyle.of(context).style;
            double fontSize = 13;
            for (final size in const [16.0, 15.0, 14.0, 13.5]) {
              final tp = TextPainter(
                text: TextSpan(text: '“${m.quote}”', style: base.merge(quoteStyle.copyWith(fontSize: size))),
                textDirection: TextDirection.ltr,
                textScaler: scaler,
              )..layout(maxWidth: c.maxWidth);
              final fits = tp.height <= c.maxHeight;
              tp.dispose();
              if (fits) {
                fontSize = size;
                break;
              }
            }
            final lineH = scaler.scale(fontSize) * 1.3;
            final lines = math.max(1, (c.maxHeight / lineH).floor());
            return ClipRect(
              child: AnimatedSwitcher(
                duration: _still ? Duration.zero : const Duration(milliseconds: 480),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(position: Tween(begin: const Offset(0, 0.35), end: Offset.zero).animate(anim), child: child),
                ),
                layoutBuilder: (cur, prev) => Stack(alignment: Alignment.topLeft, children: [...prev, ?cur]),
                child: SizedBox(
                  key: ValueKey(_i),
                  width: c.maxWidth,
                  child: Text('“${m.quote}”', maxLines: lines, overflow: TextOverflow.ellipsis, style: quoteStyle.copyWith(fontSize: fontSize)),
                ),
              ),
            );
          },
        ),
      );
    }

    final footer = m == null
        ? null
        : Row(
            children: [
              Expanded(
                child: Text(
                  [m.customer, ?m.when].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DashText.meta.copyWith(fontSize: 11.5),
                ),
              ),
              if (list.length > 1) ...[
                _StepButton(icon: Icons.chevron_left_rounded, tooltip: 'Previous review', onTap: () => _step(-1)),
                Text('${_i % list.length + 1}/${list.length}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: DashUi.subtle)),
                _StepButton(icon: Icons.chevron_right_rounded, tooltip: 'Next review', onTap: () => _step(1)),
                const SizedBox(width: 4),
              ],
              DashPressable(
                onTap: _openAll,
                label: 'Read the reviews that name ${widget.first} in full',
                radius: BorderRadius.circular(6),
                builder: (hover) => Text(
                  list.length > 1 ? 'All ${list.length} ›' : 'Read ›',
                  style: DashText.link.copyWith(fontSize: 12, decoration: hover ? TextDecoration.underline : null),
                ),
              ),
            ],
          );

    return MouseRegion(
      onEnter: (_) {
        _hovered = true;
        _sync();
      },
      onExit: (_) {
        _hovered = false;
        _sync();
      },
      child: Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: DashUi.line)),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            LayoutBuilder(
              builder: (context, c) {
                final g = DashGeo.of(context);
                // No review, and no room for the note on a line of its own (the technician page gives a single
                // line's height and the rest to its team table): the note follows the title.
                if (m == null && c.maxHeight < 12 + g.line(13) + 4 + g.line(13.5) + 8) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 12, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: headerRow(note: Text(emptyNote, maxLines: 1, overflow: TextOverflow.ellipsis, style: emptyStyle)),
                    ),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 12, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [headerRow(), const SizedBox(height: 4), body, if (footer != null) ...[const SizedBox(height: 2), footer]],
                  ),
                );
              },
            ),
            // Time to the next review, across the bottom edge.
            if (list.length > 1 && !_still)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 2.5,
                child: RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: _clock,
                    builder: (context, _) => Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: _clock.value.clamp(0.0, 1.0),
                        heightFactor: 1,
                        child: const ColoredBox(color: DashUi.amber),
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

/// Lays the page out to fit the window:
///   desktop    the scorecards; then the monthly chart on the left, and on the right how the tech compares over the
///              customer reviews, which take the height left for as many lines of a review as fit (1000 px wide and up)
///   narrower   everything in one column that scrolls, like the dashboards
class _TechGrid extends StatelessWidget {
  final List<_TileSpec> tiles;
  final Widget chart;
  final _TeamTable? table;
  final Widget Function(_TeamFit fit, bool fill) team;

  /// The reviews card, and whether there are reviews to read (otherwise it is a short strip).
  final Widget reviews;
  final bool hasReviews;

  /// Placeholders instead of scorecards (the skeleton).
  final bool skeleton;
  const _TechGrid({
    required this.tiles,
    required this.chart,
    required this.table,
    required this.team,
    required this.reviews,
    required this.hasReviews,
    this.skeleton = false,
  });

  static const _wideFrom = 1000.0;
  static const _minChart = 200.0;
  static const _tileGap = 12.0;

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final body = c.maxHeight - g.tile - dashGap;
        final t = table;
        final minTeam = _TeamPanel.top(g) + 2 * _TeamPanel.rowHeight(g);
        // The reviews card at its smallest: one line of review, or two when the window has room; with none to read, a
        // single line (the title and the note) and the rest goes to the team table.
        final reviewsMin = !hasReviews
            ? _ReviewsCard.emptyHeight(g)
            : _ReviewsCard.height(g, body - minTeam - dashGap >= _ReviewsCard.height(g, 2) ? 2 : 1);
        final Widget content;
        if (w >= _wideFrom && c.maxHeight.isFinite && body >= math.max(_minChart, minTeam + dashGap + reviewsMin)) {
          final natural = t == null ? minTeam : _TeamPanel.natural(g, t);
          // Room for three lines of review beside the whole table: the table keeps its natural height (spread a
          // little when the window is tall) and the review takes the rest. Otherwise the review is two lines and the
          // table gives up its pooled row, then rows, to fit.
          final roomy = hasReviews && body - natural - dashGap >= _ReviewsCard.height(g, 3);
          final Widget right;
          if (t != null && roomy) {
            final teamH = (body * 0.6).clamp(natural, natural + 40.0 * (t.rows.length + 1)).toDouble().clamp(0.0, body - dashGap - _ReviewsCard.height(g, 3)).toDouble();
            right = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: teamH, child: team(_TeamPanel.fitFor(g, t, teamH), true)),
                const SizedBox(height: dashGap),
                Expanded(child: reviews),
              ],
            );
          } else {
            final fit = t == null ? (tiles: false, verdict: false, summary: false, maxRows: 4) : _TeamPanel.fitFor(g, t, body - dashGap - reviewsMin);
            right = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: team(fit, true)),
                const SizedBox(height: dashGap),
                SizedBox(height: reviewsMin, child: reviews),
              ],
            );
          }
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: g.tile, child: _row(context, w)),
              const SizedBox(height: dashGap),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 11, child: chart),
                    const SizedBox(width: dashGap),
                    Expanded(flex: 12, child: right),
                  ],
                ),
              ),
            ],
          );
        } else {
          final perRow = w >= 900 ? tiles.length : (w >= 560 ? 2 : 1);
          final tileW = (w - _tileGap * (perRow - 1)) / perRow;
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
                if (t != null) team((tiles: true, verdict: false, summary: t.summary != null, maxRows: t.rows.length), false),
                const SizedBox(height: dashGap),
                SizedBox(height: hasReviews ? _ReviewsCard.height(g, 5) : _ReviewsCard.emptyHeight(g), child: reviews),
              ],
            ),
          );
        }
        return SizedBox(width: w, height: c.maxHeight, child: content);
      },
    );
  }

  Widget _row(BuildContext context, double width) => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0) const SizedBox(width: _tileGap),
            Expanded(child: _tile(tiles[i], i)),
          ],
        ],
      );

  Widget _tile(_TileSpec t, int index) => skeleton ? const DashSkeletonTile() : _KpiTile(spec: t, index: index);
}

/// The page's shape while the first answer is on its way.
class _TechSkeleton extends StatelessWidget {
  const _TechSkeleton();

  @override
  Widget build(BuildContext context) {
    final placeholder = _TileSpec(title: '', value: null, format: (v) => '', captions: const [''], definition: '', color: DashUi.muted);
    return Semantics(
      label: 'Loading figures',
      child: ExcludeSemantics(
        child: SkeletonPulse(
          child: _TechGrid(
            skeleton: true,
            tiles: List.filled(5, placeholder),
            chart: const DashSkeletonPanel(fill: true),
            table: null,
            team: (fit, fill) => const DashSkeletonPanel(fill: true),
            // The reviews strip's one line (its title and note).
            reviews: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              alignment: Alignment.centerLeft,
              decoration: DashUi.panel(),
              child: const SkeletonBox(h: 14, w: 160),
            ),
            hasReviews: false,
          ),
        ),
      ),
    );
  }
}
