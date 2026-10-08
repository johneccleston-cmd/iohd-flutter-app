part of 'kpi_dashboard_screen.dart';

/// What the KPI card hands over when tapped, so the page opens instantly without refetching.
class _EmployeeKpiArgs {
  final _Entry entry;
  final double? teamAvg;
  final int teamSize;
  const _EmployeeKpiArgs(this.entry, this.teamAvg, this.teamSize);
}

/// Estimate turnaround in whole days: estimate created to first "Estimate Provided".
class _Turnaround {
  final int count;
  final double avgDays;
  final double medianDays;
  const _Turnaround(this.count, this.avgDays, this.medianDays);

  static _Turnaround? fromJson(dynamic j) {
    if (j is! Map) return null;
    return _Turnaround(
      int.tryParse(_str(j['count'])) ?? 0,
      _num(j['avgDays']) ?? 0,
      _num(j['medianDays']) ?? 0,
    );
  }

  String get avgText => '${_fmtNum(avgDays)} ${avgDays == 1 ? 'day' : 'days'}';
}

/// One project type's results (jobs.category; blank is "Uncategorized").
class _TypeKpis {
  final String type;
  final int estimates;
  final int wonCount;
  final double wonValue;
  final double grossProfit;
  final double? markupPct;
  const _TypeKpis(this.type, this.estimates, this.wonCount, this.wonValue, this.grossProfit, this.markupPct);

  factory _TypeKpis.fromJson(Map<String, dynamic> j) => _TypeKpis(
        _str(j['type']),
        int.tryParse(_str(j['estimates'])) ?? 0,
        int.tryParse(_str(j['wonCount'])) ?? 0,
        _num(j['wonValue']) ?? 0,
        _num(j['grossProfit']) ?? 0,
        _num(j['markupPct']),
      );
}

/// Hard-bid results (estimates whose category is a bid type).
class _BidKpis {
  final int total;
  final int wonCount;
  final int lostCount;
  final int openCount;
  final double? closeRatePct;
  const _BidKpis(this.total, this.wonCount, this.lostCount, this.openCount, this.closeRatePct);

  factory _BidKpis.fromJson(Map<String, dynamic> j) => _BidKpis(
        int.tryParse(_str(j['total'])) ?? 0,
        int.tryParse(_str(j['wonCount'])) ?? 0,
        int.tryParse(_str(j['lostCount'])) ?? 0,
        int.tryParse(_str(j['openCount'])) ?? 0,
        _num(j['closeRatePct']),
      );
}

/// Sales results for the year, from /api/employees/:id/kpis.
class _SalesKpis {
  final int wonCount;
  final int lostCount;
  final double? closeRatePct;
  final double wonValue;
  final double grossProfit;
  final double? markupPct; // profit / cost
  final double? marginPct; // profit / revenue
  final int wonWithProfit;
  final List<_TypeKpis> byType;
  final _BidKpis? bids;

  /// Customer satisfaction and comments naming this person, same shape as the techs'. Nothing sends them for sales
  /// yet (the app shows a quiet empty state, or sample data behind the Morale card's Preview switch).
  final _Rating? satisfaction;
  final List<_Mention> mentions;

  /// Negatives: open estimates gone quiet past the stage limit, and estimates sent slower than the target. Null
  /// until the backend sends `strikes`.
  final int? staleEstimates;
  final int? slowEstimates;

  /// Open estimates in total and how many are past half their stage limit but not stale yet (for the freshness bar).
  final int? openEstimates;
  final int? agingEstimates;

  /// Won revenue and profit per month (January first) for each estimate bucket: [hard bid, commercial, other].
  /// Empty until the backend sends `monthlyByType`.
  final List<List<double>> monthlyRevenue;
  final List<List<double>> monthlyProfit;

  /// The salesperson's focus from the backend ("Residential Sales", "Commercial Sales"); empty if not sent.
  final String focus;
  bool get residential => focus.toLowerCase().startsWith('residential');

  // Commercial KPIs the backend can't measure yet (it reports false until real data exists).
  final bool tracksBidTurnaround;
  final bool tracksEstimatingErrors;
  final bool tracksChangeOrders;
  final _Turnaround? turnaround;
  final _Turnaround? bidTurnaround;

  const _SalesKpis({
    this.satisfaction,
    this.mentions = const [],
    this.staleEstimates,
    this.slowEstimates,
    this.openEstimates,
    this.agingEstimates,
    this.focus = '',
    this.monthlyRevenue = const [],
    this.monthlyProfit = const [],
    required this.byType,
    required this.bids,
    required this.tracksBidTurnaround,
    required this.tracksEstimatingErrors,
    required this.tracksChangeOrders,
    required this.turnaround,
    required this.bidTurnaround,
    required this.wonCount,
    required this.lostCount,
    required this.closeRatePct,
    required this.wonValue,
    required this.grossProfit,
    required this.markupPct,
    required this.marginPct,
    required this.wonWithProfit,
  });

  factory _SalesKpis.fromJson(Map<String, dynamic> j) {
    final cov = j['profitCoverage'];
    final tr = j['tracking'] is Map ? j['tracking'] as Map : const {};
    final types = j['byType'] is List ? j['byType'] as List : const [];
    final strikes = j['strikes'] is Map ? j['strikes'] as Map : const {};
    final mbt = j['monthlyByType'] is Map ? j['monthlyByType'] as Map : const {};
    List<double> series(String key, String field) {
      final l = mbt[key];
      return [
        for (var m = 0; m < 12; m++) l is List && m < l.length && l[m] is Map ? (_num((l[m] as Map)[field]) ?? 0) : 0.0,
      ];
    }

    final haveMonthly = mbt.isNotEmpty;
    return _SalesKpis(
      monthlyRevenue: haveMonthly ? [series('hardBid', 'revenue'), series('commercial', 'revenue'), series('other', 'revenue')] : const [],
      monthlyProfit: haveMonthly ? [series('hardBid', 'profit'), series('commercial', 'profit'), series('other', 'profit')] : const [],
      staleEstimates: int.tryParse(_str(strikes['staleEstimates'])),
      slowEstimates: int.tryParse(_str(strikes['slowEstimates'])),
      focus: _str(j['focus']),
      openEstimates: int.tryParse(_str(strikes['openEstimates'])),
      agingEstimates: int.tryParse(_str(strikes['agingEstimates'])),
      satisfaction: _Rating.fromJson(j['satisfaction']),
      mentions: [
        for (final m in (j['reviews'] is List ? j['reviews'] as List : const []))
          if (m is Map && _str(m['quote']).isNotEmpty)
            _Mention(_str(m['quote']), _str(m['customer']).isEmpty ? 'Customer' : _str(m['customer']), _str(m['source']).isEmpty ? null : _str(m['source'])),
      ],
      byType: [for (final t in types) if (t is Map) _TypeKpis.fromJson(Map<String, dynamic>.from(t))],
      bids: j['bids'] is Map ? _BidKpis.fromJson(Map<String, dynamic>.from(j['bids'] as Map)) : null,
      tracksBidTurnaround: tr['bidTurnaround'] == true,
      tracksEstimatingErrors: tr['estimatingErrors'] == true,
      tracksChangeOrders: tr['changeOrderOpportunities'] == true,
      turnaround: _Turnaround.fromJson(j['turnaround']),
      bidTurnaround: _Turnaround.fromJson(j['bidTurnaround']),
      wonCount: int.tryParse(_str(j['wonCount'])) ?? 0,
      lostCount: int.tryParse(_str(j['lostCount'])) ?? 0,
      closeRatePct: _num(j['closeRatePct']),
      wonValue: _num(j['wonValue']) ?? 0,
      grossProfit: _num(j['grossProfit']) ?? 0,
      markupPct: _num(j['markupPct']),
      marginPct: _num(j['marginPct']),
      wonWithProfit: cov is Map
          ? int.tryParse(_str(cov['withProfit'])) ?? 0
          : 0,
    );
  }
}

bool _flag(Map m, String key) => m[key] == true;

/// Technician results from /api/employees/:id/kpis.
/// One month of a tech's results (month the jobs started).
class _MonthPoint {
  final int month; // 1..12
  final double labor;
  final double? laborPerDay;
  final int jobs;
  const _MonthPoint(this.month, this.labor, this.laborPerDay, this.jobs);
}

/// A 1-5 star rating average and how many ratings it is based on.
class _Rating {
  final double avg;
  final int count;
  const _Rating(this.avg, this.count);

  static _Rating? fromJson(dynamic j) {
    if (j is! Map) return null;
    final avg = _num(j['avg']);
    return avg == null ? null : _Rating(avg, int.tryParse(_str(j['count'])) ?? 0);
  }
}

/// [{month: 1..12, <key>: number}] as a 12-slot list (null where there is no data). Empty if the backend sent none.
List<double?> _monthSeries(dynamic j, String key) {
  if (j is! List) return const [];
  final out = List<double?>.filled(12, null);
  var any = false;
  for (final m in j) {
    if (m is! Map) continue;
    final i = (int.tryParse(_str(m['month'])) ?? 0) - 1;
    final v = _num(m[key]);
    if (i >= 0 && i < 12 && v != null) {
      out[i] = v;
      any = true;
    }
  }
  return any ? out : const [];
}

/// A customer comment that names a tech (Google review, survey answer or something the office typed in).
class _Mention {
  final String quote;
  final String customer;
  final String? source;
  const _Mention(this.quote, this.customer, [this.source]);

  static _Mention? fromJson(dynamic j) {
    if (j is! Map) return null;
    final quote = _str(j['quote']).trim();
    if (quote.isEmpty) return null;
    final who = _str(j['customer']).trim();
    final src = _str(j['source']).trim();
    return _Mention(quote, who.isEmpty ? 'A customer' : who, src.isEmpty ? null : src);
  }
}

class _TechKpis {
  final _Rating? satisfaction;
  final _Rating? employeeRating;

  /// Customer mentions. Nothing sends `reviews` yet, so this is empty until the backend is wired up.
  final List<_Mention> mentions;

  /// Month-by-month series (index 0 = January), null for months without data. Nothing sends these yet:
  /// `teamMonthly` [{month, laborPerDay}], `satisfactionMonthly` and `employeeRatingMonthly` [{month, avg}].
  final List<double?> teamPerDay;
  final List<double?> satisfactionTrend;
  final List<double?> peerTrend;

  /// Current techs' figures for the scorecard (`team` in the response): pooled labor per work day and the average
  /// inventory strikes. Null until the backend sends them.
  final double? teamLaborPerDay;
  final double? teamAvgStrikes;
  final List<_MonthPoint> monthly;
  final int jobs;
  final int laborJobs;
  final double laborDollars;
  final double? laborPerDay;
  final bool tracksPackages;
  final bool tracksEfficiency;

  /// Service call evals (Residential Diagnostic Visit jobs) this tech worked, and how many got the Same Day Service
  /// Credit, i.e. converted to a service package. Null until the backend sends `evalConversion`.
  final ({int evals, int converted})? evalConversion;
  const _TechKpis({
    this.evalConversion,
    required this.satisfaction,
    required this.employeeRating,
    required this.mentions,
    this.teamPerDay = const [],
    this.satisfactionTrend = const [],
    this.peerTrend = const [],
    this.teamLaborPerDay,
    this.teamAvgStrikes,
    required this.monthly,
    required this.jobs,
    required this.laborJobs,
    required this.laborDollars,
    required this.laborPerDay,
    required this.tracksPackages,
    required this.tracksEfficiency,
  });

  factory _TechKpis.fromJson(Map<String, dynamic> j) {
    final tr = j['tracking'] is Map ? j['tracking'] as Map : const {};
    final ec = j['evalConversion'];
    return _TechKpis(
      evalConversion: ec is Map
          ? (evals: int.tryParse(_str(ec['evals'])) ?? 0, converted: int.tryParse(_str(ec['converted'])) ?? 0)
          : null,
      satisfaction: _Rating.fromJson(j['satisfaction']),
      employeeRating: _Rating.fromJson(j['employeeRating']),
      teamPerDay: _monthSeries(j['teamMonthly'], 'laborPerDay'),
      satisfactionTrend: _monthSeries(j['satisfactionMonthly'], 'avg'),
      peerTrend: _monthSeries(j['employeeRatingMonthly'], 'avg'),
      teamLaborPerDay: j['team'] is Map ? _num((j['team'] as Map)['laborPerDay']) : null,
      teamAvgStrikes: j['team'] is Map ? _num((j['team'] as Map)['avgInventoryStrikes']) : null,
      mentions: [
        for (final m in (j['reviews'] is List ? j['reviews'] as List : const []))
          ?_Mention.fromJson(m),
      ],
      jobs: int.tryParse(_str(j['jobs'])) ?? 0,
      laborJobs: int.tryParse(_str(j['laborJobs'])) ?? 0,
      laborDollars: _num(j['laborDollars']) ?? 0,
      laborPerDay: _num(j['laborPerDay']),
      monthly: [
        for (final m in (j['monthly'] is List ? j['monthly'] as List : const []))
          if (m is Map) _MonthPoint(int.tryParse(_str(m['month'])) ?? 0, _num(m['labor']) ?? 0, _num(m['laborPerDay']), int.tryParse(_str(m['jobs'])) ?? 0),
      ],
      tracksPackages: _flag(tr, 'servicePackageCloseRate'),
      tracksEfficiency: _flag(tr, 'jobCompletionEfficiency'),
    );
  }
}

/// Field supervisor: which supervisor-only KPIs have data. (The jobs completed vs scheduled numbers were company-wide,
/// so they are no longer shown on a person's page.)
class _SupervisorKpis {
  final bool tracksOvertime;
  final bool tracksImprovement;
  const _SupervisorKpis({required this.tracksOvertime, required this.tracksImprovement});

  factory _SupervisorKpis.fromJson(Map<String, dynamic> j) {
    final tr = j['tracking'] is Map ? j['tracking'] as Map : const {};
    return _SupervisorKpis(
      tracksOvertime: _flag(tr, 'overtimeEfficiency'),
      tracksImprovement: _flag(tr, 'techImprovement'),
    );
  }
}

class _AgingRow {
  final String label;
  final double amount;
  final int jobs;
  const _AgingRow(this.label, this.amount, this.jobs);
}

/// Company-wide receivables for whoever owns collections (office).
class _ReceivablesKpis {
  final double outstanding;
  final double over90;
  final double collected;
  final double? collectionRatePct;
  final List<_AgingRow> aging;
  final bool tracksCallAnswer;
  final bool tracksMissedCall;
  final bool tracksLeadToBooked;
  final bool tracksCustomerResponse;
  const _ReceivablesKpis({
    required this.outstanding,
    required this.over90,
    required this.collected,
    required this.collectionRatePct,
    required this.aging,
    required this.tracksCallAnswer,
    required this.tracksMissedCall,
    required this.tracksLeadToBooked,
    required this.tracksCustomerResponse,
  });

  factory _ReceivablesKpis.fromJson(Map<String, dynamic> j) {
    final tr = j['tracking'] is Map ? j['tracking'] as Map : const {};
    final rows = j['aging'] is List ? j['aging'] as List : const [];
    return _ReceivablesKpis(
      outstanding: _num(j['outstanding']) ?? 0,
      over90: _num(j['over90']) ?? 0,
      collected: _num(j['collected']) ?? 0,
      collectionRatePct: _num(j['collectionRatePct']),
      aging: [
        for (final r in rows)
          if (r is Map) _AgingRow(_str(r['label']), _num(r['amount']) ?? 0, int.tryParse(_str(r['jobs'])) ?? 0),
      ],
      tracksCallAnswer: _flag(tr, 'callAnswerRate'),
      tracksMissedCall: _flag(tr, 'missedCallResponse'),
      tracksLeadToBooked: _flag(tr, 'leadToBooked'),
      tracksCustomerResponse: _flag(tr, 'customerResponse'),
    );
  }
}

/// Everything /api/employees/:id/kpis can return for one person. Each part is null when it doesn't apply.
class _KpiBundle {
  final _SalesKpis? sales;
  final _TechKpis? tech;
  final _SupervisorKpis? supervisor;
  final _ReceivablesKpis? office;

  /// Employee morale, 1-5. Every employee has one.
  final _Rating? morale;
  const _KpiBundle(this.sales, this.tech, this.supervisor, this.office, this.morale);
}

/// From /api/tech_stats: this year's callbacks and completed jobs for one tech, plus the team's callback rate.
class _TechStats {
  final int callbacks;
  final int completedJobs;

  /// Every tech's callbacks and completed jobs added up (a job counts once per tech who worked it, like the strikes).
  final int teamCallbacks;
  final int teamJobs;

  /// Jobs this tech completed since a callback last came back on one of their jobs. Null until the backend sends
  /// `jobsSinceCallback` (nothing does yet).
  final int? jobsSinceCallback;
  const _TechStats(this.callbacks, this.completedJobs, this.teamCallbacks, this.teamJobs, [this.jobsSinceCallback]);

  double? get callbackRatePct => completedJobs > 0 ? callbacks / completedJobs * 100 : null;
  double? get teamCallbackRatePct => teamJobs > 0 ? teamCallbacks / teamJobs * 100 : null;

  /// The callback rate of everyone else (this tech's callbacks and jobs taken out of the team's), for comparing a
  /// tech against their peers. Null when there is no one else with completed jobs.
  double? get othersCallbackRatePct {
    final jobs = teamJobs - completedJobs;
    return jobs > 0 ? (teamCallbacks - callbacks) / jobs * 100 : null;
  }
}

/// Per-person facts from /api/admin/users (the same source as the Team screen).
class _EmployeeDetails {
  final int? userId;
  final String role;
  final int inventoryStrikes;
  final int warehouseStrikes;
  final int? workDays90; // null when the backend didn't send it
  final String? lastWorkDate;

  /// Callbacks and jobs from /api/tech_stats. Null if they couldn't be loaded.
  _TechStats? techStats;

  _SalesKpis? sales;

  /// Won revenue per month (Jan..this month) from the Sales dashboard feed. Null if it couldn't be loaded.
  List<double?>? monthlyWon;
  _TechKpis? tech;
  _SupervisorKpis? supervisor;
  _ReceivablesKpis? office;
  _Rating? morale;

  _EmployeeDetails({
    required this.userId,
    required this.role,
    required this.inventoryStrikes,
    required this.warehouseStrikes,
    required this.workDays90,
    required this.lastWorkDate,
  });

  // Strikes only apply to some roles: techs get inventory + callback strikes, warehouse gets warehouse strikes.
  bool get isTech => role.toLowerCase().contains('tech');
  bool get isWarehouse => role.toLowerCase().contains('warehouse');

  factory _EmployeeDetails.fromJson(Map<String, dynamic> j) {
    int? i(dynamic v) => v == null ? null : int.tryParse(v.toString());
    return _EmployeeDetails(
      userId: i(j['id']),
      role: _str(j['role']),
      inventoryStrikes: i(j['inventory_strikes']) ?? 0,
      warehouseStrikes: i(j['warehouse_strikes']) ?? 0,
      workDays90: i(j['work_days_90']),
      lastWorkDate: _str(j['last_work_date']).isEmpty ? null : _str(j['last_work_date']),
    );
  }
}

Future<_EmployeeDetails> _loadDetailsLegacy(String username) async {
  final res = await http
      .get(Uri.parse('$kApiBaseUrl/api/admin/users'), headers: AuthSession.instance.headers())
      .timeout(const Duration(seconds: 40));
  if (res.statusCode == 401) {
    AuthSession.instance.logout(); // sends the app back to the sign-in screen
    throw Exception('Your session expired. Please sign in again.');
  }
  if (res.statusCode == 403) {
    throw Exception('Your account does not have access to employee details.');
  }
  if (res.statusCode != 200) {
    throw Exception('Server error (${res.statusCode})');
  }
  final body = json.decode(res.body);
  final list = body is Map && body['users'] is List ? body['users'] as List : const [];
  _EmployeeDetails? found;
  for (final u in list) {
    if (u is Map && _str(u['username']).toLowerCase() == username.toLowerCase()) {
      found = _EmployeeDetails.fromJson(Map<String, dynamic>.from(u));
      break;
    }
  }
  if (found == null) {
    throw Exception('No employee record found for "$username".');
  }

  final id = found.userId;
  if (id != null) {
    // Both extras are best effort: a failure leaves that part out instead of failing the page.
    final results = await Future.wait<Object?>([
      found.isTech ? _loadTechStats(username) : Future<_TechStats?>.value(null),
      _loadKpis(id),
    ]);
    found.techStats = results[0] as _TechStats?;
    final k = results[1] as _KpiBundle?;
    found.sales = k?.sales;
    found.tech = k?.tech;
    found.supervisor = k?.supervisor;
    found.office = k?.office;
    found.morale = k?.morale;
  }
  return found;
}

/// Role KPIs (GET /api/employees/:id/kpis). Null if it can't be loaded, e.g. the backend isn't updated yet.
Future<_KpiBundle?> _loadKpis(int userId) async {
  try {
    final res = await http
        .get(
          Uri.parse('$kApiBaseUrl/api/employees/$userId/kpis?year=${DateTime.now().year}'),
          headers: AuthSession.instance.headers(),
        )
        .timeout(const Duration(seconds: 40));
    if (res.statusCode != 200) return null;
    final body = json.decode(res.body);
    return body is Map ? _bundleFrom(body) : null;
  } catch (_) {
    return null;
  }
}

_KpiBundle _bundleFrom(Map body) {
  Map<String, dynamic>? part(String key) => body[key] is Map ? Map<String, dynamic>.from(body[key] as Map) : null;
  final sales = part('sales'), tech = part('tech'), sup = part('supervisor'), office = part('office');
  return _KpiBundle(
    sales == null ? null : _SalesKpis.fromJson(sales),
    tech == null ? null : _TechKpis.fromJson(tech),
    sup == null ? null : _SupervisorKpis.fromJson(sup),
    office == null ? null : _ReceivablesKpis.fromJson(office),
    _Rating.fromJson(body['morale']),
  );
}

/// Everything for one person in a single request (by username), with the callback numbers fetched at the same time:
/// GET /api/employees/:username/kpis plus /api/tech_stats in parallel. Falls back to the older two-step path if the
/// backend doesn't know usernames yet (it answers 400).
Future<_EmployeeDetails> _loadDetails(String username, {required bool likelyTech}) async {
  final techStatsF = likelyTech ? _loadTechStats(username) : null;
  final res = await http
      .get(
        Uri.parse('$kApiBaseUrl/api/employees/${Uri.encodeComponent(username)}/kpis?year=${DateTime.now().year}'),
        headers: AuthSession.instance.headers(),
      )
      .timeout(const Duration(seconds: 40));
  if (res.statusCode == 400) return _loadDetailsLegacy(username);
  if (res.statusCode == 401) {
    AuthSession.instance.logout(); // sends the app back to the sign-in screen
    throw Exception('Your session expired. Please sign in again.');
  }
  if (res.statusCode == 403) throw Exception('Your account does not have access to employee details.');
  if (res.statusCode == 404) throw Exception('No employee record found for "$username".');
  if (res.statusCode != 200) throw Exception('Server error (${res.statusCode})');

  final body = json.decode(res.body);
  final emp = body is Map && body['employee'] is Map ? body['employee'] as Map : null;
  if (body is! Map || emp == null || !emp.containsKey('inventoryStrikes')) return _loadDetailsLegacy(username);
  int n(dynamic v) => int.tryParse(_str(v)) ?? 0;
  final details = _EmployeeDetails(
    userId: int.tryParse(_str(emp['id'])),
    role: _str(emp['role']),
    inventoryStrikes: n(emp['inventoryStrikes']),
    warehouseStrikes: n(emp['warehouseStrikes']),
    workDays90: null,
    lastWorkDate: null,
  );
  final k = _bundleFrom(body);
  details.sales = k.sales;
  details.tech = k.tech;
  details.supervisor = k.supervisor;
  details.office = k.office;
  details.morale = k.morale;
  details.techStats = techStatsF != null ? await techStatsF : (details.isTech ? await _loadTechStats(username) : null);
  return details;
}

/// A sales rep's won revenue by month this year, from the Sales dashboard feed (people[].monthlyWon, matched by
/// name). Best effort: null on failure or if the rep isn't listed.
Future<List<double?>?> _loadMonthlyWon(String name) async {
  if (name.trim().isEmpty) return null;
  try {
    final now = DateTime.now();
    final res = await http
        .get(Uri.parse('$kApiBaseUrl/api/dashboards/sales?year=${now.year}'), headers: AuthSession.instance.headers())
        .timeout(const Duration(seconds: 40));
    if (res.statusCode != 200) return null;
    final body = json.decode(res.body);
    final people = body is Map && body['people'] is List ? body['people'] as List : const [];
    for (final p in people) {
      if (p is Map && _str(p['name']).toLowerCase() == name.trim().toLowerCase() && p['monthlyWon'] is List) {
        final m = p['monthlyWon'] as List;
        return [for (var i = 0; i < now.month; i++) i < m.length ? (_num(m[i]) ?? 0) : 0.0];
      }
    }
  } catch (_) {}
  return null;
}

/// Callbacks and completed jobs for this tech this year (same source as the Technicians dashboard, which
/// identifies techs by username). Best effort: null on failure or if they aren't listed.
Future<_TechStats?> _loadTechStats(String username) async {
  try {
    final res = await http
        .get(
          Uri.parse('$kApiBaseUrl/api/tech_stats?year=${DateTime.now().year}'),
          headers: AuthSession.instance.headers(),
        )
        .timeout(const Duration(seconds: 40));
    if (res.statusCode != 200) return null;
    final body = json.decode(res.body);
    if (body is! Map) return null;
    final techs = body['techs'] is List ? body['techs'] as List : const [];
    var teamCallbacks = 0, teamJobs = 0;
    _TechStats? mine;
    int n(dynamic v) => int.tryParse(_str(v)) ?? 0;
    for (final t in techs) {
      if (t is! Map) continue;
      teamCallbacks += n(t['callbackCount']);
      teamJobs += n(t['completedJobsYtd']);
    }
    for (final t in techs) {
      if (t is Map && _str(t['id']).toLowerCase() == username.toLowerCase()) {
        mine = _TechStats(n(t['callbackCount']), n(t['completedJobsYtd']), teamCallbacks, teamJobs, t['jobsSinceCallback'] == null ? null : n(t['jobsSinceCallback']));
      }
    }
    return mine;
  } catch (_) {}
  return null;
}

/// One employee's KPI page, at /hr/kpis/:id.
class EmployeeKpiScreen extends StatelessWidget {
  final String employeeId;

  /// Route `extra` from the KPI cards. Null on a direct link or refresh, then the page loads it.
  final Object? extra;

  const EmployeeKpiScreen({super.key, required this.employeeId, this.extra});

  @override
  Widget build(BuildContext context) {
    final initial = extra is _EmployeeKpiArgs ? extra as _EmployeeKpiArgs : null;
    // No header banner: it cost ~65px the page needs to fit without scrolling. The back button lives in the profile card.
    return Material(
      color: const Color(0xFFE2E8F0), // same page background as the dashboards
      child: LayoutBuilder(
        builder: (context, c) {
          final pad = c.maxWidth < 600 ? 10.0 : 12.0;
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1600),
              child: Padding(
                padding: EdgeInsets.all(pad),
                child: _EmployeeKpiBody(employeeId: employeeId, initial: initial),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _EmployeeKpiBody extends StatefulWidget {
  final String employeeId;
  final _EmployeeKpiArgs? initial;
  const _EmployeeKpiBody({required this.employeeId, required this.initial});

  @override
  State<_EmployeeKpiBody> createState() => _EmployeeKpiBodyState();
}

class _EmployeeKpiBodyState extends State<_EmployeeKpiBody> {
  _EmployeeKpiArgs? _data;
  bool _loading = false;
  String? _error;

  _EmployeeDetails? _details;
  bool _detailsLoading = true;
  String? _detailsError;

  /// Preview of the ratings cards with made-up scores, since nothing records them yet. Real scores always win.
  bool _sample = false;
  int _sampleIdx = 0;
  static const _sampleMorale = [3.6, 4.5, 2.4, 1.6];

  _Rating? _satisfactionOf(_TechKpis t) => t.satisfaction ?? (_sample ? const _Rating(4.7, 22) : null);
  _Rating? _employeeRatingOf(_TechKpis t) => t.employeeRating ?? (_sample ? const _Rating(4.2, 6) : null);
  static const _sampleMentions = [
    _Mention('On time, fixed our spring in under an hour and cleaned up after himself.', 'Karen M.', 'Google'),
    _Mention('Explained exactly what was wrong before touching anything. Honest and fair price.', 'David R.', 'Google'),
    _Mention('Our new door looks fantastic and the install crew was super polite.', 'Lennar – Unit 14', 'Office'),
    _Mention('Called ahead, went above and beyond. Would ask for him again.', 'Priya S.', 'Survey'),
  ];

  // Preview series for the toggle (months up to today), so the new charts can be seen before anything records them.
  List<double?> _sampleSeries(List<double> v) => [for (var m = 0; m < DateTime.now().month; m++) v[m % v.length]];
  List<double?> _teamPerDayOf(_TechKpis t) {
    if (t.teamPerDay.isNotEmpty) return t.teamPerDay;
    if (!_sample) return const [];
    return _sampleSeries([410, 425, 440, 435, 455, 470, 465, 480, 490, 500, 505, 510]);
  }

  List<double?> _satisfactionTrendOf(_TechKpis t) => t.satisfactionTrend.isNotEmpty ? t.satisfactionTrend : (_sample ? _sampleSeries([4.4, 4.5, 4.4, 4.6, 4.7, 4.6, 4.8, 4.7, 4.8, 4.7, 4.7, 4.8]) : const []);
  List<double?> _peerTrendOf(_TechKpis t) => t.peerTrend.isNotEmpty ? t.peerTrend : (_sample ? _sampleSeries([3.8, 3.9, 4.1, 4.0, 4.2, 4.1, 4.3, 4.2, 4.4, 4.3, 4.5, 4.4]) : const []);
  /// The scorecard: each metric against the current techs' figure. Ratings have no team figure yet.
  List<_ScoreRow> _scoreRows(_EmployeeDetails d, _TechKpis t) {
    final ts = d.techStats;
    final sat = _satisfactionOf(t);
    final peer = _employeeRatingOf(t);
    String stars(double v) => '${_fmtNum(v)} / 5';
    return [
      _ScoreRow('Labor / day', t.laborPerDay, t.teamLaborPerDay, dashMoney, higherBetter: true),
      _ScoreRow('Callback rate', ts?.callbackRatePct, ts?.othersCallbackRatePct, (v) => '${_fmtNum(v)}%', higherBetter: false),
      _ScoreRow('Inv. strikes', d.inventoryStrikes.toDouble(), t.teamAvgStrikes, _fmtNum, higherBetter: false),
      _ScoreRow('Customer rating', sat?.avg, null, stars, higherBetter: true, scaleMax: 5),
      _ScoreRow('Peer rating', peer?.avg, null, stars, higherBetter: true, scaleMax: 5),
    ];
  }

  int? _streakOf(_EmployeeDetails d) => d.techStats?.jobsSinceCallback ?? (_sample ? 17 : null);
  List<_Mention> _mentionsOf(_TechKpis t) => t.mentions.isNotEmpty ? t.mentions : (_sample ? _sampleMentions : const []);
  _Rating? _moraleOf(_EmployeeDetails d) => d.morale ?? (_sample ? _Rating(_sampleMorale[_sampleIdx % _sampleMorale.length], 9) : null);

  @override
  void initState() {
    super.initState();
    _data = widget.initial;
    if (_data == null) _load();
    _fetchDetails();
  }

  bool _monthlyTried = false;

  /// Sales chart view: 0 = won revenue by month, 1.. = revenue and profit lines for each estimate type's tab.
  int _view = 0;

  /// Loads the rep's monthly won revenue once both the person (for the name) and their details (for the role) are in.
  Future<void> _ensureMonthly() async {
    final d = _details, name = _data?.entry.user.name ?? '';
    if (_monthlyTried || d == null || d.sales == null || d.isTech || name.isEmpty) return;
    _monthlyTried = true;
    final m = await _loadMonthlyWon(name);
    if (mounted && m != null) setState(() => d.monthlyWon = m);
  }

  Future<void> _fetchDetails() async {
    setState(() {
      _detailsLoading = true;
      _detailsError = null;
    });
    try {
      final d = await _loadDetails(widget.employeeId, likelyTech: _looksLikeTech);
      if (!mounted) return;
      setState(() {
        _details = d;
        _detailsLoading = false;
      });
      _ensureMonthly();
    } on TimeoutException {
      _detailsFail('The request timed out.');
    } catch (e) {
      _detailsFail(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _detailsFail(String m) {
    if (!mounted) return;
    setState(() {
      _detailsError = m;
      _detailsLoading = false;
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _loadEntries();
      final scores = entries
          .map((e) => e.user.integrityScore)
          .whereType<double>()
          .toList();
      final match = entries.where((e) => e.user.id == widget.employeeId);
      if (!mounted) return;
      setState(() {
        _data = match.isEmpty
            ? null
            : _EmployeeKpiArgs(
                match.first,
                scores.isEmpty
                    ? null
                    : scores.reduce((a, b) => a + b) / scores.length,
                entries.length,
              );
        _error = match.isEmpty
            ? 'This employee was not found, or is no longer active.'
            : null;
        _loading = false;
      });
      _ensureMonthly();
    } on TimeoutException {
      _fail('The request timed out. Check your connection and try again.');
    } catch (e) {
      _fail(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFCC0007)),
      );
    }
    final data = _data;
    if (data == null) {
      return DashErrorPanel(
        title: "Couldn't load this employee",
        message: _error ?? 'Something went wrong.',
        onRetry: _load,
      );
    }

    final user = data.entry.user;
    final rank = data.entry.rank;
    final score = user.integrityScore;
    final scoreColor = _scoreColor(score);
    final milestone = _milestone(user.yearsWorked);
    final delta = (score != null && data.teamAvg != null) ? score - data.teamAvg! : null;

    final profile = _DetailCard(
      padding: 12,
      child: Stack(
        clipBehavior: Clip.none, // the back button's hover highlight sits partly outside the padded area
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  DashAvatar(
                    name: user.name,
                    imageUrl: user.avatarUrl,
                    size: 68,
                    ringColor: rank == 1 ? _gold : null,
                    ringWidth: rank == 1 ? 3 : 0,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          user.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: _ink),
                        ),
                        Text(
                          user.jobTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, color: _slate),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            if (rank != null) _Pill(icon: Icons.emoji_events_rounded, text: 'Rank #$rank', color: rank == 1 ? _gold : _slate),
                            if (milestone != null) _Pill(icon: Icons.workspace_premium_rounded, text: milestone, color: DashUi.indigo),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: scoreColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: scoreColor.withValues(alpha: 0.25)),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 42,
                      height: 42,
                      child: CustomPaint(
                        painter: _RingPainter(progress: score == null ? 0 : (score / 100).clamp(0.0, 1.0), color: scoreColor),
                        child: Center(child: Icon(Icons.verified_rounded, size: 16, color: scoreColor)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'INTEGRITY SCORE',
                            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: _slate, letterSpacing: 0.8),
                          ),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(
                                score == null ? '—' : '${_fmtNum(score)}%',
                                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: scoreColor, height: 1.1),
                              ),
                              if (delta != null) ...[
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    delta.abs() < 0.05 ? 'At team average' : '${delta >= 0 ? '▲' : '▼'} ${delta.abs().toStringAsFixed(1)} vs team avg',
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: delta.abs() < 0.05 ? _slate : (delta >= 0 ? DashUi.emeraldDeep : DashUi.amber),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Positioned(
            right: -8,
            top: -8,
            child: IconButton(
              tooltip: 'All employees',
              onPressed: () => context.go('/hr/kpis'),
              icon: const Icon(Icons.arrow_back_rounded, size: 18, color: _slate),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 900;
        final grid = _scoreGrid();
        Widget leftColumn({required bool fill}) {
          final morale = _moraleCard(fill: fill);
          final conversion = _conversionCard();
          return Column(
            mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              profile,
              if (grid != null) ...[const SizedBox(height: 8), grid],
              if (conversion != null) ...[const SizedBox(height: 8), conversion],
              if (morale != null) ...[
                const SizedBox(height: 8),
                if (fill) Expanded(child: morale) else SizedBox(height: 210, child: morale),
              ],
            ],
          );
        }

        // Technicians fit on one screen: the chart takes whatever height is left. Shorter windows scroll.
        final techLayout = _details?.isTech ?? (_detailsLoading && _looksLikeTech);
        // The supervisor has an extra scorecard on the left, so needs a little more height.
        // The tech layout (cards, charts, scorecard bars) fits one screen down to about this height.
        // A sales rep's page (sales card + bidding/type cards) also fits one screen; its hero card takes the spare height.
        final salesLayout = _details?.isTech == false && _details?.sales != null;
        final needed = _details?.isTech == true ? 560.0 : (salesLayout ? (c.maxWidth < 1450 ? 700.0 : 640.0) : (_details?.supervisor != null ? 545.0 : 450.0));
        if (wide && (techLayout || salesLayout) && c.maxHeight >= needed) {
          return SizedBox(
            height: c.maxHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 320, child: leftColumn(fill: true)),
                const SizedBox(width: 12),
                Expanded(child: _moreGroups(fill: true, chart: c.maxHeight >= 640)),
              ],
            ),
          );
        }

        return SingleChildScrollView(
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 320, child: leftColumn(fill: false)),
                    const SizedBox(width: 12),
                    Expanded(child: _moreGroups()),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [leftColumn(fill: false), const SizedBox(height: 12), _moreGroups()],
                ),
        );
      },
    );
  }

  /// Under the profile card: the employee's 1-5 rating, then inventory strikes and callback rate side by side, and
  /// (supervisor) the team callback rate full width. The colours for callbacks follow the strikes scale.
  Widget? _scoreGrid() {
    final d = _details;
    if (d == null) {
      // Same shape while loading, for anyone whose job title says technician.
      return _detailsLoading && _looksLikeTech
          ? const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SkelCard(h: 46, r: 18),
                SizedBox(height: 8),
                Row(children: [Expanded(child: _SkelCard(h: 88, r: 12)), SizedBox(width: 8), Expanded(child: _SkelCard(h: 88, r: 12))]),
              ],
            )
          : null;
    }
    if (!d.isTech) {
      final sales = d.sales;
      if (sales == null) return null;
      // Sales negatives: green at none, amber for a few, red past that (colours live in the cards).
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: 84, child: _StaleTube(
              stale: sales.staleEstimates,
              aging: sales.agingEstimates,
              open: sales.openEstimates,
              employeeId: widget.employeeId,
              name: _data?.entry.user.name ?? 'Stale estimates',
            )),
          const SizedBox(height: 8),
          SizedBox(height: 70, child: _LateCard(count: sales.slowEstimates, employeeId: widget.employeeId, name: _data?.entry.user.name ?? 'Late estimates')),
          const SizedBox(height: 8),
          SizedBox(height: 70, child: _TurnaroundCard(sales.turnaround)),
        ],
      );
    }
    final ts = d.techStats;
    final rate = ts?.callbackRatePct;
    final teamRate = ts?.teamCallbackRatePct;
    Color strikeColor(int n) => n == 0 ? DashUi.emerald : (n == 1 ? DashUi.amber : DashUi.red);
    Widget card(String title, double? value, Color color, int index, String Function(double) format) => SizedBox(
          height: 88,
          child: AnimatedMetricCard(title: title, value: value, valueColor: color, index: index, format: format),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (d.tech != null) ...[
          _RatingCard(
            title: 'Peer Rating',
            subtitle: switch (_employeeRatingOf(d.tech!)) {
              null => 'Rated by fellow techs',
              final r => 'Rated by ${r.count} fellow ${r.count == 1 ? 'tech' : 'techs'}',
            },
            rating: _employeeRatingOf(d.tech!),
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            Expanded(child: card('Inv. strikes', d.inventoryStrikes.toDouble(), strikeColor(d.inventoryStrikes), 0, (v) => '${v.round()}')),
            const SizedBox(width: 8),
            Expanded(child: card('Callback rate', rate, ts == null ? DashUi.muted : strikeColor(ts.callbacks), 1, (v) => '${_fmtNum(v)}%')),
          ],
        ),
        if (d.supervisor != null) ...[
          const SizedBox(height: 8),
          card('Team callback rate', teamRate, ts == null ? DashUi.muted : strikeColor(ts.teamCallbacks), 2, (v) => '${_fmtNum(v)}%'),
        ],
      ],
    );
  }

  static const _sampleConversion = (evals: 14, converted: 6);

  /// Eval-to-package conversions, above the Morale card. Brett only; null for everyone else.
  Widget? _conversionCard() {
    final d = _details;
    final t = d?.tech;
    if (d == null || !d.isTech || t == null || _firstName.toLowerCase() != 'brett') return null;
    return SizedBox(
      height: 70,
      child: _ConversionCard(data: (t.evalConversion?.converted ?? 0) > 0 ? t.evalConversion : (_sample ? _sampleConversion : t.evalConversion)),
    );
  }

  /// Morale card for the left column, under the profile (and the tech scorecards). Every employee gets one. It takes
  /// the height that is left (see [fill]).
  Widget? _moraleCard({required bool fill}) {
    final d = _details;
    if (d == null) return _detailsLoading ? const _SkelCard(h: 150, r: 18) : null;
    return _MoraleCard(
      title: "$_firstName's Current Morale",
      rating: _moraleOf(d),
      isSample: d.morale == null && _sample,
      canPreview: d.morale == null,
      onTogglePreview: () => setState(() => _sample = !_sample),
      onCycle: () => setState(() => _sampleIdx++),
    );
  }

  /// Customer feedback for salespeople (same card as the techs'), under the Morale card. Null for other roles.
  Widget? _salesFeedbackCard() {
    final sales = _details?.sales;
    if (sales == null || _details!.isTech) return null;
    return _MentionsCard(
      mentions: sales.mentions.isNotEmpty ? sales.mentions : (_sample ? _sampleMentions : const []),
      satisfaction: sales.satisfaction ?? (_sample ? const _Rating(4.7, 22) : null),
    );
  }

  /// First name for card titles ("John's Current Morale").
  String get _firstName {
    final n = (_data?.entry.user.name ?? '').trim();
    return n.isEmpty ? 'Employee' : n.split(RegExp(r'\s+')).first;
  }

  bool get _looksLikeTech => (_data?.entry.user.jobTitle ?? '').toLowerCase().contains('tech');

  /// Placeholder shaped like the technician page's right column.
  Widget _techSkeleton({bool fill = false}) {
    return SkeletonPulse(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, c) {
              final cols = c.maxWidth >= 640 ? 4 : 1;
              return Row(
                children: [
                  for (var i = 0; i < cols; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    const Expanded(child: _SkelCard(h: 88, r: 12)),
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          if (fill) const Expanded(child: _SkelCard(h: 200, r: 16)) else const _SkelCard(h: 330, r: 16),
        ],
      ),
    );
  }

  /// One card per topic under the header card. Every employee gets the same cards; which ones show depends on the role.
  Widget _moreGroups({bool fill = false, bool chart = true}) {
    if (_detailsLoading) {
      return _looksLikeTech ? _techSkeleton(fill: fill) : const _SkelCard(h: 170, r: 18);
    }
    final d = _details;
    if (d == null) {
      return _DetailCard(
        child: Row(
          children: [
            const Icon(Icons.cloud_off_rounded, color: DashUi.muted),
            const SizedBox(width: 12),
            Expanded(
              child: Text("Couldn't load employee details. ${_detailsError ?? ''}",
                  style: const TextStyle(fontSize: 13.5, color: _slate)),
            ),
            TextButton.icon(
              onPressed: _fetchDetails,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Try again'),
            ),
          ],
        ),
      );
    }

    Color strikeColor(int n) => n == 0 ? DashUi.emerald : (n == 1 ? DashUi.amber : DashUi.red);
    _InfoRow untracked(String label, bool tracked) =>
        tracked ? _InfoRow(label, '—') : _InfoRow(label, 'Not tracked yet', _muted);

    final strikes = <_InfoRow>[
      if (d.isWarehouse) _InfoRow('Warehouse strikes (all-time)', '${d.warehouseStrikes}', strikeColor(d.warehouseStrikes)),
    ];

    final sales = d.sales;
    final bids = sales?.bids;
    final commercial = <Widget>[
      // Bidding and the estimate mix are commercial: a residential salesperson (Heather) doesn't get them.
      if (sales != null && !sales.residential)
        _DetailCard(
          title: 'Bidding',
          icon: Icons.gavel_rounded,
          child: _InfoGroup(
            title: '',
            rows: [
              _InfoRow(
                bids == null
                    ? 'Bid close rate (no bids yet)'
                    : 'Bid close rate (${bids.wonCount} won · ${bids.lostCount} lost · ${bids.openCount} open)',
                bids?.closeRatePct == null ? '—' : '${_fmtNum(bids!.closeRatePct!)}%',
              ),
              sales.bidTurnaround != null
                  ? _InfoRow(
                      'Bid turnaround (${sales.bidTurnaround!.count} bids, median ${_fmtNum(sales.bidTurnaround!.medianDays)})',
                      sales.bidTurnaround!.avgText,
                    )
                  : untracked('Bid turnaround time', sales.tracksBidTurnaround),
              untracked('Estimating errors', sales.tracksEstimatingErrors),
              untracked('Change-order opportunities', sales.tracksChangeOrders),
            ],
          ),
        ),
      if (sales != null && !sales.residential)
        _DetailCard(
          title: 'Estimate mix',
          icon: Icons.pie_chart_rounded,
          trailing: '${DateTime.now().year} year to date',
          child: _EstimateMixPie(types: sales.byType, residential: sales.residential),
        ),
    ];

    // Technician performance, customer satisfaction and morale (every tech, including the supervisor).
    final tech = d.tech;
    final sup = d.supervisor;
    final techCard = tech == null
        ? null
        : _TechPerformance(
            tech: tech,
            fill: fill,
            satisfaction: _satisfactionOf(tech),
            mentions: _mentionsOf(tech),
            streak: _streakOf(d),
            scorecard: _scoreRows(d, tech),
            techName: (_data?.entry.user.name ?? '').trim().isEmpty ? 'This tech' : _data!.entry.user.name.trim(),
            teamPerDay: _teamPerDayOf(tech),
            customerTrend: _satisfactionTrendOf(tech),
            peerTrend: _peerTrendOf(tech),
            untracked: [
              if (!tech.tracksEfficiency) 'Job completion efficiency',
              if (sup != null && !sup.tracksOvertime) 'Overtime / production efficiency',
              if (sup != null && !sup.tracksImprovement) 'Technician performance improvement',
            ],
          );
    final off = d.office;
    final officeCard = off == null
        ? null
        : _DetailCard(
            title: 'Receivables and collections',
            icon: Icons.account_balance_wallet_rounded,
            trailing: 'Company-wide, ${DateTime.now().year} year to date',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _FigureRow([
                  _BigStat('OUTSTANDING', dashMoney(off.outstanding), DashUi.ink,
                      sub: '${off.aging.fold<int>(0, (t, a) => t + a.jobs)} invoiced jobs'),
                  _BigStat('OVER 90 DAYS', dashMoney(off.over90), off.over90 > 0 ? DashUi.red : DashUi.emerald,
                      sub: '90 Day Notice stage'),
                  _BigStat('COLLECTION RATE', off.collectionRatePct == null ? '—' : '${_fmtNum(off.collectionRatePct!)}%',
                      DashUi.emeraldDeep,
                      sub: '${dashMoney(off.collected)} collected'),
                ]),
                const SizedBox(height: 16),
                _InfoGroup(title: 'AR aging', rows: [
                  for (final a in off.aging) _InfoRow('${a.label} (${a.jobs} jobs)', dashMoney(a.amount)),
                ]),
                const SizedBox(height: 16),
                _UntrackedNote([
                  if (!off.tracksCallAnswer) 'Call answer rate',
                  if (!off.tracksMissedCall) 'Missed-call response time',
                  if (!off.tracksLeadToBooked) 'Lead-to-booked-job rate',
                  if (!off.tracksCustomerResponse) 'Customer response time',
                ]),
              ],
            ),
          );

    final smaller = <Widget>[
      if (strikes.isNotEmpty)
        _DetailCard(title: 'Strikes', icon: Icons.warning_amber_rounded, child: _InfoGroup(title: '', rows: strikes)),
    ];

    final wideCards = <Widget>[
      if (sales != null) _salesScorecards(sales),
      if (sales != null) fill && techCard == null ? Expanded(child: _salesCard(sales, expand: true, monthly: d.monthlyWon, showChart: chart)) : _salesCard(sales, monthly: d.monthlyWon, showChart: true),
      if (techCard != null) fill ? Expanded(child: techCard) : techCard,
      ?officeCard,
    ];

    if (wideCards.isEmpty && smaller.isEmpty && commercial.isEmpty) {
      return const _DetailCard(
        child: Text('No further KPIs are tracked for this role yet.', style: TextStyle(fontSize: 13.5, color: _slate)),
      );
    }

    Widget gap = const SizedBox(height: 16);
    Widget pair(List<Widget> items, {List<int>? flex, double breakpoint = 700, bool equalHeight = false}) => LayoutBuilder(
          builder: (context, c) {
            if (c.maxWidth < breakpoint) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (var i = 0; i < items.length; i++) ...[if (i > 0) gap, items[i]]],
              );
            }
            final row = Row(
              crossAxisAlignment: equalHeight ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const SizedBox(width: 16),
                  Expanded(flex: flex == null ? 1 : flex[i], child: items[i]),
                ],
              ],
            );
            return equalHeight ? IntrinsicHeight(child: row) : row;
          },
        );

    // Salespeople: scorecards on top, then the sales/bidding cards with the customer feedback card in a column on the
    // right, the same spot it has on the technician pages.
    final feedback = _salesFeedbackCard();
    if (sales != null && feedback != null) {
      final main = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          fill ? Expanded(child: _salesCard(sales, expand: true, monthly: d.monthlyWon, showChart: chart)) : _salesCard(sales, monthly: d.monthlyWon, showChart: true),
          if (commercial.isNotEmpty) ...[gap, pair(commercial, flex: commercial.length == 2 ? const [4, 6] : null, breakpoint: 760, equalHeight: fill)],
        ],
      );
      final body = LayoutBuilder(
        builder: (context, c) {
          if (c.maxWidth < 760) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [_salesCard(sales, monthly: d.monthlyWon, showChart: true), if (commercial.isNotEmpty) ...[gap, pair(commercial, breakpoint: 900)], gap, SizedBox(height: 226, child: feedback)],
            );
          }
          return Row(
            crossAxisAlignment: fill ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
            children: [
              Expanded(child: main),
              const SizedBox(width: 16),
              SizedBox(width: 240, child: fill ? feedback : SizedBox(height: 226, child: feedback)),
            ],
          );
        },
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [_salesScorecards(sales), gap, if (fill) Expanded(child: body) else body],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < wideCards.length; i++) ...[if (i > 0) gap, wideCards[i]],
        if (commercial.isNotEmpty) ...[
          if (wideCards.isNotEmpty) gap,
          pair(commercial, flex: commercial.length == 2 ? const [2, 3] : null, breakpoint: 900, equalHeight: fill),
        ],
        if (smaller.isNotEmpty) ...[
          if (wideCards.isNotEmpty || commercial.isNotEmpty) gap,
          pair(smaller),
        ],
      ],
    );
  }

  /// The four headline figures as scorecards along the top of a salesperson's page.
  Widget _salesScorecards(_SalesKpis s) {
    final items = <(String, double?, Color, String Function(double))>[
      ('Estimate close rate', s.closeRatePct, _ink, (v) => '${_fmtNum(v)}%'),
      ('Sales dollars won', s.wonValue, DashUi.sky, _wholeMoney),
      ('Gross profit', s.grossProfit, DashUi.blue, _wholeMoney),
      ('Markup', s.markupPct, DashUi.blue, (v) => '${_fmtNum(v)}%'),
    ];
    Widget card(int i) => SizedBox(
          height: 88,
          child: AnimatedMetricCard(
            title: items[i].$1,
            value: items[i].$2,
            valueColor: items[i].$3,
            index: i,
            format: items[i].$4,
          ),
        );
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 560) {
          return Column(
            children: [
              Row(children: [Expanded(child: card(0)), const SizedBox(width: 8), Expanded(child: card(1))]),
              const SizedBox(height: 8),
              Row(children: [Expanded(child: card(2)), const SizedBox(width: 8), Expanded(child: card(3))]),
            ],
          );
        }
        return Row(
          children: [
            for (var i = 0; i < 4; i++) ...[if (i > 0) const SizedBox(width: 8), Expanded(child: card(i))],
          ],
        );
      },
    );
  }

  /// The sales chart panel (no header): won revenue by month, or one tab per estimate type with a revenue line and a
  /// profit line by month. [expand] fills the height it is given, otherwise it is a fixed height.
  Widget _salesCard(_SalesKpis s, {bool expand = false, List<double?>? monthly, bool showChart = false}) {
    if (!showChart) return const SizedBox.shrink();
    final visible = _mixVisible(s.residential);
    final typeLabels = _mixLabelsFor(s.residential);
    final tabs = ['Monthly revenue', for (final k in visible) '${_typeTabName(typeLabels[k])} · rev & profit'];
    // Without the monthly feed the first tab has nothing to show, so open on the first type.
    var view = _view.clamp(0, tabs.length - 1);
    if (monthly == null && view == 0 && tabs.length > 1) view = 1;
    final now = DateTime.now().month;
    Widget content;
    if (view == 0) {
      content = _MonthlyChart(
        expand: expand,
        values: monthly ?? const [],
        color: DashUi.sky,
        tipFormat: (i) => dashMoney((monthly ?? const [])[i] ?? 0),
        emptyText: 'No won estimates in ${DateTime.now().year}',
      );
    } else {
      final k = visible[view - 1];
      final rev = k < s.monthlyRevenue.length ? s.monthlyRevenue[k] : const <double>[];
      final prof = k < s.monthlyProfit.length ? s.monthlyProfit[k] : const <double>[];
      content = rev.isEmpty
          ? const Center(child: Text('Monthly figures by type are not available yet.', style: TextStyle(fontSize: 13, color: _muted)))
          : _RevProfitLineChart(
              revenue: [for (var m = 0; m < now && m < rev.length; m++) rev[m]],
              profit: [for (var m = 0; m < now && m < prof.length; m++) prof[m]],
              expand: expand,
            );
    }
    return _DetailCard(
      expand: expand,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: _ChartToggle(labels: tabs, selected: view, onChanged: (i) => setState(() => _view = i))),
          ),
          const SizedBox(height: 8),
          if (expand) Expanded(child: content) else SizedBox(height: 252, child: content),
        ],
      ),
    );
  }
}

/// A white rounded card. With a [title] it gets a small header row (icon, title, optional trailing note).
class _DetailCard extends StatelessWidget {
  final String? title;
  final IconData? icon;
  final String? trailing;
  final double padding;

  /// Fill the height the parent gives (the child is then centred in what the header leaves).
  final bool expand;
  final Widget child;
  const _DetailCard({
    this.title,
    this.icon,
    this.trailing,
    this.padding = 22,
    this.expand = false,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(padding),
      decoration: DashUi.panel(radius: 18),
      child: Column(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) ...[
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: _slate),
                  const SizedBox(width: 8),
                ],
                Text(
                  title!,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: _ink,
                  ),
                ),
                const Spacer(),
                if (trailing != null)
                  Text(
                    trailing!,
                    style: const TextStyle(fontSize: 12.5, color: _muted),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          if (expand) Expanded(child: child) else child,
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const _Pill({required this.icon, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow {
  final String label;
  final String value;
  final Color? color;
  const _InfoRow(this.label, this.value, [this.color]);
}

/// A heading with plain label / value lines under it.
class _InfoGroup extends StatelessWidget {
  final String title;
  final List<_InfoRow> rows;
  const _InfoGroup({required this.title, required this.rows});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              title.toUpperCase(),
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: _muted,
                letterSpacing: 0.8,
              ),
            ),
          ),
        for (final r in rows)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: _line)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    r.label,
                    style: const TextStyle(fontSize: 14, color: _slate),
                  ),
                ),
                Text(
                  r.value,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: r.color ?? _ink,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _BigStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final String? sub;
  const _BigStat(this.label, this.value, this.color, {this.sub});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: _muted,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          value,
          style: TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w800,
            color: color,
            height: 1.1,
          ),
        ),
        if (sub != null) ...[
          const SizedBox(height: 4),
          Text(sub!, style: const TextStyle(fontSize: 12.5, color: _slate)),
        ],
      ],
    );
  }
}

/// Short name for a chart tab: "Commercial hard bids" -> "Hard bids", "Commercial estimates" -> "Commercial".
String _typeTabName(String label) => switch (label) {
      'Commercial hard bids' => 'Hard bids',
      'Commercial estimates' => 'Commercial',
      _ => label,
    };

/// 0 = Commercial hard bid, 1 = other Commercial estimate, 2 = everything else, from an estimate category.
int _mixBucket(String category) {
  final c = category.toLowerCase();
  if (c.contains('hard bid')) return 0;
  if (c.contains('commercial')) return 1;
  return 2;
}

const _mixLabels = ['Commercial hard bids', 'Commercial estimates', 'Other'];

/// Labels for the three buckets. A residential salesperson has no commercial work, so their "other" is Residential.
List<String> _mixLabelsFor(bool residential) => residential ? const ['Commercial hard bids', 'Commercial estimates', 'Residential'] : _mixLabels;

/// Which buckets to show: a residential salesperson only gets Residential; commercial gets all three.
List<int> _mixVisible(bool residential) => residential ? const [2] : const [0, 1, 2];

/// Estimates this year split into Commercial hard bids, other Commercial estimates and everything else, drawn like the
/// "Active jobs by status" donut on the Jobs dashboard: a big thick ring with the total in the middle and a plain legend
/// beside it. Hovering a slice or a legend row highlights it and shows its share and count in the middle.
class _EstimateMixPie extends StatefulWidget {
  final List<_TypeKpis> types;
  final bool residential;
  const _EstimateMixPie({required this.types, this.residential = false});

  @override
  State<_EstimateMixPie> createState() => _EstimateMixPieState();
}

class _EstimateMixPieState extends State<_EstimateMixPie> {
  static const double _size = 184;
  List<String> get _labels => _mixLabelsFor(widget.residential);
  static const _colors = [DashUi.indigo, DashUi.sky, DashUi.emerald];
  int? _hover;

  /// Estimate counts for [hard bid, commercial, other], bucketed by the estimate's category.
  List<int> get _counts {
    final out = [0, 0, 0];
    for (final t in widget.types) {
      out[_mixBucket(t.type)] += t.estimates;
    }
    return out;
  }

  /// Which slice a point (relative to the donut's box) is over, or null for the hole / outside.
  int? _slice(Offset p, List<int> counts) {
    final total = counts.fold<int>(0, (a, b) => a + b);
    if (total == 0) return null;
    final d = p - const Offset(_size / 2, _size / 2);
    final r = _MixPiePainter.radiusFor(_size);
    final half = _MixPiePainter.strokeFor(_size) / 2 + 4;
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
    final counts = _counts;
    final total = counts.fold<int>(0, (a, b) => a + b);
    final h = _hover;
    final Widget center;
    if (total == 0) {
      center = const Text('No estimates\nyet', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: _muted, fontWeight: FontWeight.w600));
    } else if (h != null) {
      center = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${(counts[h] / total * 100).toStringAsFixed(1)}%', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: _colors[h], height: 1.05)),
          const SizedBox(height: 2),
          Text(_labels[h], textAlign: TextAlign.center, maxLines: 2, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: _slate)),
          Text('${counts[h]} estimates', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _muted)),
        ],
      );
    } else {
      center = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$total', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: _ink, height: 1.05)),
          const SizedBox(height: 2),
          const Text('Total estimates', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _slate)),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        MouseRegion(
          onHover: (e) {
            final k = _slice(e.localPosition, counts);
            if (k != _hover) setState(() => _hover = k);
          },
          onExit: (_) => setState(() => _hover = null),
          child: SizedBox(
            width: _size,
            height: _size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 1000),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, _) => CustomPaint(
                    size: const Size(_size, _size),
                    painter: _MixPiePainter(counts: counts, colors: _colors, progress: t, hover: h),
                  ),
                ),
                IgnorePointer(child: SizedBox(width: _size * 0.56, child: FittedBox(fit: BoxFit.scaleDown, child: center))),
              ],
            ),
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final k in _mixVisible(widget.residential))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: MouseRegion(
                    onEnter: (_) => setState(() => _hover = k),
                    onExit: (_) => setState(() => _hover = null),
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 180),
                      opacity: h != null && h != k ? 0.35 : 1,
                      child: Row(
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            width: h == k ? 14 : 10,
                            height: h == k ? 14 : 10,
                            decoration: BoxDecoration(color: _colors[k], borderRadius: BorderRadius.circular(4)),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _labels[k],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, fontWeight: h == k ? FontWeight.w800 : FontWeight.w600, color: h == k ? _ink : _slate),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text('${counts[k]}', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: _colors[k])),
                          SizedBox(
                            width: 40,
                            child: Text(
                              total == 0 ? '' : '${(counts[k] / total * 100).round()}%',
                              textAlign: TextAlign.right,
                              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: _muted),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MixPiePainter extends CustomPainter {
  final List<int> counts;
  final List<Color> colors;
  final double progress;
  final int? hover;
  const _MixPiePainter({required this.counts, required this.colors, required this.progress, required this.hover});

  static double strokeFor(double side) => side * 0.16;
  static double radiusFor(double side) => (side - strokeFor(side) - 10) / 2;

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    final center = Offset(size.width / 2, size.height / 2);
    final stroke = strokeFor(side);
    final rect = Rect.fromCircle(center: center, radius: radiusFor(side));
    canvas.drawCircle(center, radiusFor(side), Paint()
      ..color = DashUi.faint
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke);
    final total = counts.fold<int>(0, (a, b) => a + b);
    if (total == 0) return;
    final nonZero = counts.where((c) => c > 0).length;
    final gap = nonZero > 1 ? 0.05 : 0.0;
    var start = -math.pi / 2;
    for (var k = 0; k < counts.length; k++) {
      if (counts[k] == 0) continue;
      final full = counts[k] / total * 2 * math.pi;
      final sweep = math.max(0.0, full - gap) * progress;
      final active = hover == k;
      final dim = hover != null && !active;
      canvas.drawArc(
        rect,
        start + gap / 2,
        sweep,
        false,
        Paint()
          ..color = colors[k].withValues(alpha: dim ? 0.3 : 1.0)
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke + (active ? 6 : 0)
          ..strokeCap = StrokeCap.butt,
      );
      start += full;
    }
  }

  @override
  bool shouldRepaint(covariant _MixPiePainter old) => old.progress != progress || old.hover != hover || !listEquals(old.counts, counts);
}

/// Average time from an estimate being created to it being provided, with the median and how many it is based on.
class _TurnaroundCard extends StatelessWidget {
  final _Turnaround? turnaround;
  const _TurnaroundCard(this.turnaround);

  @override
  Widget build(BuildContext context) {
    final t = turnaround;
    return HoverLift(
      lift: 2,
      builder: (context, hovering) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: hovering ? DashUi.sky.withValues(alpha: 0.55) : DashUi.line),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Estimate turnaround', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.slate)),
            const SizedBox(height: 1),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  t == null ? '—' : _fmtNum(t.avgDays),
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, height: 1.1, color: t == null ? DashUi.muted : DashUi.sky),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    t == null ? 'no data yet' : '${t.avgDays == 1 ? 'day' : 'days'} avg',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.muted),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Segmented switch between chart views, styled like the toggles on the company dashboards (a soft pill with the
/// selected option raised in white with blue text).
class _ChartToggle extends StatelessWidget {
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onChanged;
  const _ChartToggle({required this.labels, required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < labels.length; i++)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => onChanged(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: i == selected ? Colors.white : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: i == selected ? DashUi.line : Colors.transparent),
                  ),
                  child: Text(
                    labels[i],
                    style: TextStyle(fontSize: 12.5, fontWeight: i == selected ? FontWeight.w800 : FontWeight.w600, color: i == selected ? DashUi.blue : DashUi.slate),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Won revenue and gross profit by month as two lines (revenue in blue with a soft fill, profit in green). Hovering shows
/// a guide with that month's revenue, profit and margin.
class _RevProfitLineChart extends StatefulWidget {
  final List<double> revenue;
  final List<double> profit;
  final bool expand;
  const _RevProfitLineChart({required this.revenue, required this.profit, this.expand = false});

  @override
  State<_RevProfitLineChart> createState() => _RevProfitLineChartState();
}

class _RevProfitLineChartState extends State<_RevProfitLineChart> with SingleTickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..forward();
  int? _hover;

  @override
  void didUpdateWidget(covariant _RevProfitLineChart old) {
    super.didUpdateWidget(old);
    if (!listEquals(old.revenue, widget.revenue) || !listEquals(old.profit, widget.profit)) _intro.forward(from: 0);
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) _intro.value = 1;
    final empty = widget.revenue.every((v) => v == 0) && widget.profit.every((v) => v == 0);
    final chart = empty
        ? Center(child: Text('No won estimates in ${DateTime.now().year}', style: const TextStyle(fontSize: 13, color: _muted)))
        : LayoutBuilder(
            builder: (context, c) => MouseRegion(
              onHover: (e) {
                final n = widget.revenue.length;
                final plotW = c.maxWidth - _LineChartPainter.left - _LineChartPainter.right;
                if (n == 0 || plotW <= 0) return;
                final slot = plotW / n;
                final i = ((e.localPosition.dx - _LineChartPainter.left) / slot).floor();
                final next = i >= 0 && i < n ? i : null;
                if (next != _hover) setState(() => _hover = next);
              },
              onExit: (_) => setState(() => _hover = null),
              child: AnimatedBuilder(
                animation: _intro,
                builder: (context, _) => CustomPaint(
                  size: Size(c.maxWidth, c.maxHeight.isFinite ? c.maxHeight : 190),
                  painter: _LineChartPainter(
                    revenue: widget.revenue,
                    profit: widget.profit,
                    hover: _hover,
                    intro: Curves.easeOutCubic.transform(_intro.value),
                    fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
                  ),
                ),
              ),
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(width: 14, height: 3, decoration: BoxDecoration(color: DashUi.sky, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 6),
            const Text('Revenue', style: TextStyle(fontSize: 12, color: _slate)),
            const SizedBox(width: 14),
            Container(width: 14, height: 3, decoration: BoxDecoration(color: DashUi.emerald, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 6),
            const Text('Profit', style: TextStyle(fontSize: 12, color: _slate)),
          ],
        ),
        const SizedBox(height: 6),
        if (widget.expand) Expanded(child: chart) else SizedBox(height: 190, child: chart),
      ],
    );
  }
}

class _LineChartPainter extends CustomPainter {
  static const double left = 46;
  static const double right = 14;
  static const double top = 10;
  static const double bottom = 24;

  final List<double> revenue;
  final List<double> profit;
  final int? hover;
  final double intro;
  final String? fontFamily;
  const _LineChartPainter({required this.revenue, required this.profit, required this.hover, required this.intro, required this.fontFamily});

  TextPainter _text(String t, TextStyle style) => TextPainter(
        text: TextSpan(text: t, style: style.copyWith(fontFamily: fontFamily)),
        textDirection: TextDirection.ltr,
      )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(left, top, size.width - right, size.height - bottom);
    final n = revenue.length;
    if (plot.width <= 0 || plot.height <= 0 || n == 0) return;
    final maxV = _ChartPainter._niceMax([...revenue, ...profit].fold<double>(0, math.max));
    final minV = [...revenue, ...profit].fold<double>(0, math.min); // profit can dip below zero
    final lo = minV < 0 ? -_ChartPainter._niceMax(-minV) : 0.0;
    final span = maxV - lo;
    final slot = plot.width / n;
    double x(int i) => plot.left + slot * (i + 0.5);
    double y(double v) => plot.bottom - (v - lo) / span * plot.height;

    // grid + y labels
    const ticks = 4;
    for (var k = 0; k <= ticks; k++) {
      final v = lo + span * k / ticks;
      final yy = y(v);
      canvas.drawLine(Offset(plot.left, yy), Offset(plot.right, yy), Paint()
        ..color = DashUi.line.withValues(alpha: k == 0 ? 1 : 0.7)
        ..strokeWidth = 1);
      final tp = _text(_compactMoney(v), const TextStyle(fontSize: 10.5, color: DashUi.muted, fontWeight: FontWeight.w600));
      tp.paint(canvas, Offset(plot.left - 8 - tp.width, yy - tp.height / 2));
    }
    // month labels
    for (var i = 0; i < n; i++) {
      final tp = _text(_monthLetters[i], TextStyle(fontSize: 11, color: hover == i ? DashUi.ink : DashUi.slate, fontWeight: hover == i ? FontWeight.w800 : FontWeight.w500));
      tp.paint(canvas, Offset(x(i) - tp.width / 2, plot.bottom + 6));
    }

    Path linePath(List<double> v) {
      final path = Path();
      for (var i = 0; i < n; i++) {
        final p = Offset(x(i), y(v[i]));
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      return path;
    }

    // revenue fill, then both lines (drawn progressively with the intro)
    final revPath = linePath(revenue);
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, plot.left + (plot.width) * intro + 2, size.height));
    final fill = Path.from(revPath)
      ..lineTo(x(n - 1), plot.bottom)
      ..lineTo(x(0), plot.bottom)
      ..close();
    canvas.drawPath(
      fill,
      Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [DashUi.sky.withValues(alpha: 0.18), DashUi.sky.withValues(alpha: 0.0)]).createShader(plot),
    );
    for (final (v, color) in [(revenue, DashUi.sky), (profit, DashUi.emerald)]) {
      canvas.drawPath(
        linePath(v),
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.restore();
    // dots
    for (final (v, color) in [(revenue, DashUi.sky), (profit, DashUi.emerald)]) {
      for (var i = 0; i < n; i++) {
        if (x(i) > plot.left + plot.width * intro + 2) break;
        final active = hover == i;
        canvas.drawCircle(Offset(x(i), y(v[i])), active ? 5.5 : 3.5, Paint()..color = Colors.white);
        canvas.drawCircle(Offset(x(i), y(v[i])), active ? 5.5 : 3.5, Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
      }
    }

    // hover guide + tooltip
    final h = hover;
    if (h != null && h < n) {
      canvas.drawLine(Offset(x(h), plot.top), Offset(x(h), plot.bottom), Paint()
        ..color = DashUi.muted.withValues(alpha: 0.5)
        ..strokeWidth = 1);
      final r = revenue[h], p = profit[h];
      final lines = [
        _text(_monthLetters[h], const TextStyle(fontSize: 11, color: Colors.white70, fontWeight: FontWeight.w700)),
        _text('Revenue  ${dashMoney(r)}', const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w700)),
        _text('Profit  ${dashMoney(p)}${r > 0 ? '  ·  ${_fmtNum(p / r * 100)}%' : ''}', const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w700)),
      ];
      final w = lines.map((t) => t.width).reduce(math.max) + 20;
      final hgt = lines.fold<double>(0, (a, t) => a + t.height) + 16;
      var bx = x(h) + 12;
      if (bx + w > size.width - 4) bx = x(h) - 12 - w;
      final by = plot.top + 2;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(bx, by, w, hgt), const Radius.circular(8)), Paint()..color = DashUi.ink.withValues(alpha: 0.92));
      var ty = by + 8;
      for (final t in lines) {
        t.paint(canvas, Offset(bx + 10, ty));
        ty += t.height;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter old) =>
      old.hover != hover || old.intro != intro || !listEquals(old.revenue, revenue) || !listEquals(old.profit, profit);
}

/// Big figures side by side with dividers; a wrapped grid on narrow widths.
class _FigureRow extends StatelessWidget {
  final List<Widget> figures;
  const _FigureRow(this.figures);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 700) {
          return Wrap(
            spacing: 24,
            runSpacing: 16,
            children: [for (final f in figures) SizedBox(width: (c.maxWidth - 24) / 2, child: f)],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < figures.length; i++) ...[
                if (i > 0)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24),
                    child: VerticalDivider(width: 1, color: _line),
                  ),
                Expanded(child: figures[i]),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Whole dollars for headline figures ("$37,272"); cents add noise at this size.
String _wholeMoney(double v) => dashMoney(v.roundToDouble()).replaceFirst(RegExp(r'\.00$'), '');

const _monthLetters = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _compactMoney(double v) {
  if (v.abs() >= 1000000) return '\$${_fmtNum(v / 1000000)}M';
  if (v.abs() >= 1000) return '\$${_fmtNum(v / 1000)}k';
  return '\$${v.round()}';
}

const _amberLine = Color(0xFFF59E0B);

/// Chart panel in the style of the other dashboards: gradient bars (or a smooth area line) that grow in, a hover band
/// with a glow, a dashed average line, a diamond on the peak month, the current month drawn lighter with "so far",
/// and a dark tooltip with the change from the previous month. Starts at zero.
/// [values] has one entry per month from January; null means no data that month.
class _MonthlyChart extends StatefulWidget {
  final List<double?> values;
  final Color color;
  final bool line;
  final String Function(double) axisFormat;

  /// Tooltip value text for month index i.
  final String Function(int) tipFormat;
  final String emptyText;

  /// Fill the height the parent gives (otherwise a fixed 220px).
  final bool expand;
  const _MonthlyChart({
    required this.values,
    required this.color,
    required this.tipFormat,
    this.line = false,
    this.axisFormat = _compactMoney,
    this.emptyText = 'No data this year yet',
    this.expand = false,
  });

  @override
  State<_MonthlyChart> createState() => _MonthlyChartState();
}

class _MonthlyChartState extends State<_MonthlyChart> with TickerProviderStateMixin {
  static const double _chartHeight = 220;
  late final AnimationController _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  late final AnimationController _hoverAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 160));
  int? _active;
  int? _painted;

  @override
  void initState() {
    super.initState();
    _intro.forward();
  }

  @override
  void didUpdateWidget(covariant _MonthlyChart old) {
    super.didUpdateWidget(old);
    if (!identical(old.values, widget.values) || old.line != widget.line) {
      _active = null;
      _painted = null;
      _hoverAnim.value = 0;
      _intro.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    _hoverAnim.dispose();
    super.dispose();
  }

  bool _has(int i) => widget.values[i] != null;

  bool get _empty => widget.values.every((v) => v == null || v == 0);

  void _setActive(int? i) {
    if (i == _active) return;
    setState(() {
      if (i != null) _painted = i;
      _active = i;
    });
    i != null ? _hoverAnim.forward() : _hoverAnim.reverse();
  }

  int? _indexFor(double dx, double width) {
    final n = widget.values.length;
    final slot = (width - _ChartPainter.left - _ChartPainter.right) / n;
    if (slot <= 0) return null;
    final i = ((dx - _ChartPainter.left) / slot).floor();
    return i >= 0 && i < n && _has(i) ? i : null;
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (reduce) _intro.value = 1;
    final w = widget;
    final last = w.values.length - 1;

    // Average and peak over the finished months.
    final finished = [
      for (var i = 0; i < w.values.length; i++)
        if (w.values[i] != null && i != last) i,
    ];
    final avg = finished.isEmpty ? 0.0 : finished.map((i) => w.values[i]!).fold<double>(0, (a, b) => a + b) / finished.length;
    int? peak;
    var peakV = 0.0;
    for (final i in finished) {
      if (w.values[i]! > peakV) {
        peakV = w.values[i]!;
        peak = i;
      }
    }

    final summary = [
      for (var i = 0; i < w.values.length; i++)
        if (_has(i)) '${_monthLetters[i]} ${w.tipFormat(i)}',
    ].join('; ');

    final legend = <Widget>[
      if (avg > 0)
        _legend(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [for (var i = 0; i < 3; i++) Container(width: 4, height: 2.5, margin: EdgeInsets.only(right: i == 2 ? 0 : 2), color: _amberLine)],
          ),
          'Average',
        ),
    ];

    final area = _empty
              ? Center(child: Text(w.emptyText, style: const TextStyle(fontSize: 13.5, color: DashUi.muted)))
              : LayoutBuilder(
                  builder: (context, c) => Semantics(
                    label: 'Chart: $summary',
                    child: MouseRegion(
                      onHover: (e) => _setActive(_indexFor(e.localPosition.dx, c.maxWidth)),
                      onExit: (_) => _setActive(null),
                      child: AnimatedBuilder(
                        animation: Listenable.merge([_intro, _hoverAnim]),
                        builder: (context, _) => CustomPaint(
                          size: Size(c.maxWidth, c.maxHeight),
                          painter: _ChartPainter(
                            values: w.values,
                            color: w.color,
                            line: w.line,
                            axisFormat: w.axisFormat,
                            tipFormat: w.tipFormat,
                            average: avg,
                            peak: w.line ? null : peak,
                            index: _painted,
                            intro: Curves.easeOutCubic.transform(_intro.value),
                            hover: _active == null ? _hoverAnim.value : math.max(_hoverAnim.value, 0.001),
                            fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
                          ),
                        ),
                      ),
                    ),
                  ),
                );

    return Column(
      mainAxisSize: w.expand ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (legend.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: Wrap(spacing: 16, runSpacing: 6, children: legend)),
        if (w.expand) Expanded(child: area) else SizedBox(height: _chartHeight, child: area),
      ],
    );
  }

  Widget _legend(Widget swatch, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [swatch, const SizedBox(width: 6), Text(label, style: const TextStyle(fontSize: 12.5, color: DashUi.slate, fontWeight: FontWeight.w500))],
      );
}

class _ChartPainter extends CustomPainter {
  static const double left = 48, right = 4, top = 8, bottom = 36;

  final List<double?> values;
  final Color color;
  final bool line;
  final String Function(double) axisFormat;
  final String Function(int) tipFormat;
  final double average;
  final int? peak;
  final int? index;
  final double intro;
  final double hover;
  final String? fontFamily;
  const _ChartPainter({
    required this.values,
    required this.color,
    required this.line,
    required this.axisFormat,
    required this.tipFormat,
    required this.average,
    required this.peak,
    required this.index,
    required this.intro,
    required this.hover,
    required this.fontFamily,
  });

  static double _niceMax(double max) {
    if (max <= 0) return 1;
    final exp = math.pow(10, (math.log(max) / math.ln10).floor()).toDouble();
    for (final m in const [1, 2, 2.5, 5, 10]) {
      if (m * exp >= max) return m * exp;
    }
    return 10 * exp;
  }

  TextPainter _text(String t, TextStyle style, {double? maxWidth}) => TextPainter(
        text: TextSpan(text: t, style: style.copyWith(fontFamily: fontFamily)),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout(maxWidth: maxWidth ?? double.infinity);

  Color _light(Color c) => Color.lerp(c, Colors.white, 0.4)!;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(left, top, size.width - right, size.height - bottom);
    if (plot.width <= 0 || plot.height <= 0) return;
    final n = values.length;
    final slot = plot.width / n;
    final focusing = index != null && hover > 0.001;
    final maxV = _niceMax(values.whereType<double>().fold<double>(0, math.max));
    double y(double v) => plot.bottom - (v / maxV).clamp(0.0, 1.0) * plot.height;

    if (focusing) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(plot.left + index! * slot + 2, plot.top, slot - 4, plot.height), const Radius.circular(10)),
        Paint()..color = const Color(0xFFEFF6FF).withValues(alpha: hover),
      );
    }

    // Gridlines and y labels.
    for (var i = 0; i <= 4; i++) {
      final v = maxV * i / 4;
      final gy = y(v);
      canvas.drawLine(Offset(plot.left, gy), Offset(plot.right, gy), Paint()
        ..color = i == 0 ? DashUi.line : DashUi.faint
        ..strokeWidth = 1);
      final tp = _text(axisFormat(v), const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: DashUi.muted));
      tp.paint(canvas, Offset(left - 8 - tp.width, gy - tp.height / 2));
    }

    // Month labels (and "so far" under the current month).
    for (var i = 0; i < n; i++) {
      final cx = plot.left + slot * (i + 0.5);
      final focus = focusing && index == i;
      final has = values[i] != null;
      final tp = _text(
        _monthLetters[i],
        TextStyle(
          fontSize: 12.5,
          fontWeight: focus ? FontWeight.w800 : FontWeight.w600,
          color: focus ? DashUi.ink : (has ? DashUi.slate : const Color(0xFFCBD5E1)),
        ),
        maxWidth: slot,
      );
      tp.paint(canvas, Offset(cx - tp.width / 2, plot.bottom + 8));
      if (i == n - 1 && has) {
        final so = _text('so far', const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: DashUi.muted), maxWidth: slot);
        so.paint(canvas, Offset(cx - so.width / 2, plot.bottom + 8 + tp.height));
      }
    }

    if (line) {
      _paintLine(canvas, plot, slot, y);
    } else {
      _paintBars(canvas, plot, slot, y);
    }

    // Dashed average line.
    if (average > 0 && average <= maxV) {
      final ay = y(average);
      final paint = Paint()
        ..color = _amberLine.withValues(alpha: 0.9 * intro)
        ..strokeWidth = 1.3
        ..strokeCap = StrokeCap.round;
      var x = plot.left;
      while (x < plot.right) {
        canvas.drawLine(Offset(x, ay), Offset(math.min(x + 5, plot.right), ay), paint);
        x += 9;
      }
    }

    if (focusing) _paintTooltip(canvas, size, plot, slot, y);
  }

  void _paintBars(Canvas canvas, Rect plot, double slot, double Function(double) y) {
    final n = values.length;
    final stagger = 0.4 / n;
    final focusing = index != null && hover > 0.001;
    for (var i = 0; i < n; i++) {
      final cx = plot.left + slot * (i + 0.5);
      final isFocus = focusing && index == i;
      final dim = (focusing && !isFocus) ? 1 - 0.5 * hover : 1.0;
      final localT = Curves.easeOutCubic.transform(((intro - i * stagger) / 0.6).clamp(0.0, 1.0));
      final partial = i == n - 1;

      void bar(double? v, double x0, double w, Color c) {
        if (v == null || v <= 0) {
          final stub = RRect.fromRectAndRadius(Rect.fromLTWH(x0, plot.bottom - 3, w, 3), const Radius.circular(2));
          canvas.drawRRect(stub, Paint()..color = DashUi.line);
          return;
        }
        final h = math.max(3.0, (plot.bottom - y(v)) * localT);
        final rect = Rect.fromLTWH(x0, plot.bottom - h, w, h);
        final r = Radius.circular(math.min(8, w / 2));
        final rrect = RRect.fromRectAndCorners(rect, topLeft: r, topRight: r, bottomLeft: const Radius.circular(2), bottomRight: const Radius.circular(2));
        if (isFocus) {
          canvas.drawRRect(
            rrect,
            Paint()
              ..color = c.withValues(alpha: 0.35 * hover)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
          );
        }
        final alpha = dim * (partial ? 0.5 : 1.0);
        canvas.drawRRect(
          rrect,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [c.withValues(alpha: alpha), _light(c).withValues(alpha: alpha)],
            ).createShader(rect),
        );
      }

      final base = math.min(slot * 0.58, 36.0);
      final w = base + (isFocus ? 4 * hover : 0);
      bar(values[i], cx - w / 2, w, color);
      if (peak == i && localT > 0.98 && values[i] != null) {
        final c = Offset(cx, y(values[i]!) - 10);
        final path = Path()
          ..moveTo(c.dx, c.dy - 4)
          ..lineTo(c.dx + 4, c.dy)
          ..lineTo(c.dx, c.dy + 4)
          ..lineTo(c.dx - 4, c.dy)
          ..close();
        canvas.drawPath(path, Paint()..color = _amberLine.withValues(alpha: dim));
      }
    }
  }

  void _paintLine(Canvas canvas, Rect plot, double slot, double Function(double) y) {
    final n = values.length;
    final pts = <int, Offset>{
      for (var i = 0; i < n; i++)
        if (values[i] != null) i: Offset(plot.left + slot * (i + 0.5), y(values[i]!)),
    };
    if (pts.isEmpty) return;

    // Continuous runs of months with data.
    final runs = <List<int>>[];
    for (var i = 0; i < n; i++) {
      if (!pts.containsKey(i)) continue;
      if (runs.isNotEmpty && runs.last.last == i - 1) {
        runs.last.add(i);
      } else {
        runs.add([i]);
      }
    }

    canvas.save();
    canvas.clipRect(Rect.fromLTRB(plot.left, 0, plot.left + (plot.width + right) * intro, plot.bottom + 4));
    for (final run in runs) {
      if (run.length < 2) continue;
      final path = Path()..moveTo(pts[run.first]!.dx, pts[run.first]!.dy);
      for (var k = 1; k < run.length; k++) {
        final a = pts[run[k - 1]]!, b = pts[run[k]]!;
        final cx = (a.dx + b.dx) / 2;
        path.cubicTo(cx, a.dy, cx, b.dy, b.dx, b.dy);
      }
      final area = Path.from(path)
        ..lineTo(pts[run.last]!.dx, plot.bottom)
        ..lineTo(pts[run.first]!.dx, plot.bottom)
        ..close();
      canvas.drawPath(
        area,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0.0)],
          ).createShader(Rect.fromLTRB(plot.left, plot.top, plot.right, plot.bottom)),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
    canvas.restore();

    final focusing = index != null && hover > 0.001;
    for (final e in pts.entries) {
      final isFocus = focusing && index == e.key;
      final progress = ((intro * (n + 1) - e.key) / 1.0).clamp(0.0, 1.0);
      if (progress <= 0) continue;
      if (isFocus) {
        canvas.drawCircle(e.value, 9 * hover, Paint()..color = color.withValues(alpha: 0.2 * hover));
      }
      canvas.drawCircle(e.value, (isFocus ? 6 : 4.5) * progress, Paint()..color = Colors.white);
      canvas.drawCircle(e.value, (isFocus ? 4.5 : 3) * progress, Paint()..color = color);
    }
  }

  void _paintTooltip(Canvas canvas, Size size, Rect plot, double slot, double Function(double) y) {
    final i = index!;
    final partial = i == values.length - 1;
    final title = _text(partial ? '${_monthLetters[i]} so far' : _monthLetters[i], const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800));
    final value = _text(tipFormat(i), const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600));

    TextPainter? delta;
    final cur = values[i];
    if (cur != null && i > 0 && !partial) {
      final prev = values[i - 1];
      if (prev != null && prev > 0) {
        final pct = (cur - prev) / prev * 100;
        final up = pct >= 0;
        delta = _text(
          '${up ? '▲' : '▼'} ${pct.abs().toStringAsFixed(1)}% vs ${_monthLetters[i - 1]}',
          TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: up ? const Color(0xFF34D399) : const Color(0xFFF87171)),
        );
      }
    }

    final rows = [title, value, ?delta];
    final w = rows.map((t) => t.width).reduce(math.max) + 24;
    final h = rows.fold<double>(0, (a, t) => a + t.height) + 18 + (rows.length - 1) * 3;
    final cx = plot.left + slot * (i + 0.5);
    final topV = values[i] ?? 0;
    var tx = cx - w / 2;
    tx = tx.clamp(0.0, math.max(0.0, size.width - w));
    var ty = y(topV) - h - 14;
    if (ty < 0) ty = math.min(y(topV) + 14, size.height - h);
    final box = RRect.fromRectAndRadius(Rect.fromLTWH(tx, ty, w, h), const Radius.circular(10));
    canvas.drawRRect(
      box.shift(const Offset(0, 3)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.18 * hover)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawRRect(box, Paint()..color = DashUi.ink.withValues(alpha: 0.96 * hover));
    var dy = ty + 9;
    for (final t in rows) {
      t.paint(canvas, Offset(tx + 12, dy));
      dy += t.height + 3;
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.intro != intro ||
      old.hover != hover ||
      old.index != index ||
      old.values != values ||
      old.color != color ||
      old.line != line ||
      old.average != average;
}

/// One muted line listing KPIs that have no data source yet.
class _UntrackedNote extends StatelessWidget {
  final List<String> items;
  const _UntrackedNote(this.items);

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(padding: EdgeInsets.only(top: 1), child: Icon(Icons.info_outline_rounded, size: 15, color: _muted)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Not tracked yet: ${items.join(' · ')}',
            style: const TextStyle(fontSize: 12.5, color: _muted),
          ),
        ),
      ],
    );
  }
}

/// Row of metric cards that wraps to two columns on narrow widths.
class _CardRow extends StatelessWidget {
  final List<Widget> cards;
  const _CardRow(this.cards);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth >= 640 ? cards.length : (c.maxWidth >= 420 ? 2 : 1);
        const gap = 8.0;
        final w = (c.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final card in cards) SizedBox(width: w, height: 88, child: card)],
        );
      },
    );
  }
}

/// Chips that switch which metric a chart shows.
class _MetricChips extends StatelessWidget {
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;
  const _MetricChips({required this.labels, required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < labels.length; i++)
          ChoiceChip(
            label: Text(labels[i]),
            selected: selected == i,
            onSelected: (_) => onSelected(i),
            showCheckmark: false,
            labelStyle: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: selected == i ? Colors.white : _slate),
            selectedColor: _ink,
            backgroundColor: Colors.white,
            side: const BorderSide(color: _line),
          ),
      ],
    );
  }
}

/// Technician performance: metric cards with trend lines, then a switchable chart.
class _TechPerformance extends StatefulWidget {
  final _TechKpis tech;

  /// KPIs without a data source yet, listed under the chart.
  final List<String> untracked;

  /// Take all the height the parent offers: the chart grows to fill it.
  final bool fill;


  /// Customer satisfaction, 1-5 (null until it is tracked).
  final _Rating? satisfaction;

  /// Customer comments that name this tech, shown beside the chart.
  final List<_Mention> mentions;

  /// Jobs completed since the last callback (null until tracked).
  final int? streak;

  /// The tech's name (chart legend). Falls back to "This tech".
  final String techName;

  /// Team comparison rows (metric vs the current techs' figure), shown beside the tech-vs-team line chart.
  final List<_ScoreRow> scorecard;

  /// Team average labor per work day by month, and the two rating trends (empty until tracked).
  final List<double?> teamPerDay;
  final List<double?> customerTrend;
  final List<double?> peerTrend;
  const _TechPerformance({
    required this.tech,
    required this.untracked,
    this.fill = false,
    this.satisfaction,
    this.mentions = const [],
    this.streak,
    this.techName = 'This tech',
    this.scorecard = const [],
    this.teamPerDay = const [],
    this.customerTrend = const [],
    this.peerTrend = const [],
  });

  @override
  State<_TechPerformance> createState() => _TechPerformanceState();
}

class _TechPerformanceState extends State<_TechPerformance> {
  static const _labels = ['Labor dollars', 'Per work day', 'Jobs'];
  static const _cycle = Duration(seconds: 8);
  int _metric = 0;
  bool _hovering = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _restartTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Moves to the next metric every 8 seconds, like the other dashboards; holds still while the mouse is on the chart.
  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_cycle, (_) {
      if (!mounted || _hovering) return;
      setState(() => _metric = (_metric + 1) % _labels.length);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tech = widget.tech;
    final now = DateTime.now();
    List<double?> series(double? Function(_MonthPoint) pick) {
      final out = List<double?>.filled(now.month, null);
      for (final m in tech.monthly) {
        if (m.month >= 1 && m.month <= now.month) out[m.month - 1] = pick(m);
      }
      return out;
    }

    final labor = series((m) => m.labor);
    final perDay = series((m) => m.laborPerDay);
    final jobs = series((m) => m.jobs.toDouble());
    // Trend lines leave out the current month: it is still filling in and would show a false dive.
    List<double> trend(List<double?> v) => [for (var i = 0; i < v.length - 1; i++) ?v[i]];

    String axisCount(double v) => '${v.round()}';

    Widget chart;
    switch (_metric) {
      case 0:
        chart = _MonthlyChart(
          expand: widget.fill,
          values: labor,
          color: DashUi.sky,
          axisFormat: _compactMoney,
          tipFormat: (i) => dashMoney(labor[i] ?? 0),
          emptyText: 'No completed jobs in ${now.year}',
        );
      case 1:
        chart = _MonthlyChart(
          expand: widget.fill,
          values: perDay,
          color: DashUi.blue,
          line: true,
          axisFormat: _compactMoney,
          tipFormat: (i) => '${dashMoney(perDay[i] ?? 0)} per work day',
          emptyText: 'No completed jobs in ${now.year}',
        );
      default:
        chart = _MonthlyChart(
          expand: widget.fill,
          values: jobs,
          color: DashUi.indigo,
          axisFormat: axisCount,
          tipFormat: (i) => '${(jobs[i] ?? 0).round()} jobs',
          emptyText: 'No completed jobs in ${now.year}',
        );
    }

    final panelBox = Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      decoration: DashUi.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MetricChips(
            labels: _labels,
            selected: _metric,
            onSelected: (i) {
              setState(() => _metric = i);
              _restartTimer();
            },
          ),
          const SizedBox(height: 12),
          if (widget.fill) Expanded(child: chart) else chart,
          if (widget.untracked.isNotEmpty) ...[
            const SizedBox(height: 10),
            _UntrackedNote(widget.untracked),
          ],
        ],
      ),
    );
    final panel = MouseRegion(
      onEnter: (_) => _hovering = true,
      onExit: (_) => _hovering = false,
      child: panelBox,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CardRow([
          AnimatedMetricCard(
            title: 'Labor dollars',
            value: tech.laborJobs == 0 ? null : tech.laborDollars,
            valueColor: DashUi.sky,
            index: 0,
            format: dashMoney,
            trend: trend(labor),
            sparkMinWidth: 200,
          ),
          AnimatedMetricCard(
            title: 'Labor per day',
            value: tech.laborPerDay,
            valueColor: DashUi.blue,
            index: 1,
            format: dashMoney,
            trend: trend(perDay),
            sparkMinWidth: 200,
          ),
          AnimatedMetricCard(
            title: 'Jobs completed',
            value: tech.jobs.toDouble(),
            valueColor: DashUi.indigo,
            index: 2,
            format: (v) => '${v.round()}',
            trend: trend(jobs),
            sparkMinWidth: 200,
          ),
        ]),
        const SizedBox(height: 8),
        if (widget.fill) Expanded(child: _withSideCards(panel, perDay)) else _withSideCards(panel, perDay),
      ],
    );
  }

  /// Charts on the left (monthly chart on top, tech-vs-team below), the streak, feedback and rating-trend cards in a
  /// column on the right (stacked under the charts on narrow widths).
  Widget _withSideCards(Widget panel, List<double?> perDay) {
    final card = _MentionsCard(mentions: widget.mentions, satisfaction: widget.satisfaction);
    final streak = _StreakCard(streak: widget.streak);
    final trends = _RatingTrendsCard(customer: widget.customerTrend, peer: widget.peerTrend);
    final team = List<double?>.generate(perDay.length, (i) => i < widget.teamPerDay.length ? widget.teamPerDay[i] : null);
    final fill = widget.fill;
    // Bottom row: the tech-vs-team line chart, with the scorecard bars beside it when there are any.
    final bottom = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 1, child: _CompareChart(mine: perDay, team: team, name: widget.techName, expand: true)),
        if (widget.scorecard.isNotEmpty) ...[
          const SizedBox(width: 8),
          Expanded(flex: 1, child: _TeamComparison(rows: widget.scorecard, name: widget.techName)),
        ],
      ],
    );
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 760) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              panel,
              const SizedBox(height: 8),
              _CompareChart(mine: perDay, team: team, name: widget.techName),
              if (widget.scorecard.isNotEmpty) ...[
                const SizedBox(height: 8),
                SizedBox(height: 230, child: _TeamComparison(rows: widget.scorecard, name: widget.techName)),
              ],
              const SizedBox(height: 8),
              SizedBox(height: 118, child: streak),
              const SizedBox(height: 8),
              SizedBox(height: 210, child: card),
              const SizedBox(height: 8),
              SizedBox(height: 150, child: trends),
            ],
          );
        }
        return Row(
          crossAxisAlignment: fill ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (fill) Expanded(flex: 11, child: panel) else panel,
                  const SizedBox(height: 8),
                  if (fill) Expanded(flex: 8, child: bottom) else SizedBox(height: 230, child: bottom),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 240,
              child: Column(
                children: [
                  SizedBox(height: 118, child: streak),
                  const SizedBox(height: 8),
                  SizedBox(height: 226, child: card),
                  const SizedBox(height: 8),
                  if (fill) Expanded(child: trends) else SizedBox(height: 150, child: trends),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Open estimates as a horizontal tube split into on-track / aging / stale, with the stale count up front.
/// Hovering the tube highlights one part and spells out its count; the card lifts on hover.
class _StaleTube extends StatefulWidget {
  final int? stale;
  final int? aging;
  final int? open;
  final String employeeId;
  final String name;
  const _StaleTube({required this.stale, required this.aging, required this.open, required this.employeeId, required this.name});

  @override
  State<_StaleTube> createState() => _StaleTubeState();
}

class _StaleTubeState extends State<_StaleTube> {
  /// 0 on track, 1 aging, 2 stale; null when the cursor is not over the tube.
  int? _part;

  @override
  Widget build(BuildContext context) {
    final total = widget.open ?? 0;
    final st = (widget.stale ?? 0).clamp(0, total);
    final ag = (widget.aging ?? 0).clamp(0, total - st);
    final ok = total - st - ag;
    final counts = [ok, ag, st];
    const colors = [DashUi.emerald, DashUi.amber, DashUi.red];
    const names = ['on track', 'aging', 'stale'];
    final color = widget.stale == null ? DashUi.muted : (st == 0 ? DashUi.emerald : (st <= 5 ? DashUi.amber : DashUi.red));
    final p = _part;
    final shownColor = p == null ? color : colors[p];
    final shownCount = p == null ? st : counts[p];
    final sub = p == null ? 'of $total open' : names[p];

    Widget seg(int k) => counts[k] <= 0
        ? const SizedBox.shrink()
        : Expanded(
            flex: counts[k],
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              color: colors[k].withValues(alpha: p == null || p == k ? 1 : 0.28),
            ),
          );

    // Which part is under the cursor: parts run in order across the bar's width.
    void pick(double dx, double width) {
      if (total == 0 || width <= 0) return;
      final f = (dx / width).clamp(0.0, 0.9999);
      var edge = 0.0;
      for (var k = 0; k < 3; k++) {
        edge += counts[k] / total;
        if (counts[k] > 0 && f < edge) {
          if (_part != k) setState(() => _part = k);
          return;
        }
      }
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showDialog(
          context: context,
          builder: (_) => _LateEstimatesDialog(employeeId: widget.employeeId, name: widget.name, kind: _EstimateListKind.stale),
        ),
        child: HoverLift(
      lift: 2,
      builder: (context, hovering) => Semantics(
        label: widget.stale == null ? 'Stale estimates: not available' : '$st stale, $ag aging, $ok on track, of $total open estimates',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: hovering ? color.withValues(alpha: 0.55) : DashUi.line),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Stale estimates', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.slate)),
              const SizedBox(height: 1),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(widget.stale == null ? '—' : '$shownCount', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, height: 1.1, color: shownColor)),
                  if (widget.stale != null && total > 0) ...[
                    const SizedBox(width: 6),
                    Text(sub, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: p == null ? DashUi.muted : shownColor)),
                  ],
                ],
              ),
              const SizedBox(height: 5),
              LayoutBuilder(
                builder: (context, c) => MouseRegion(
                  hitTestBehavior: HitTestBehavior.opaque,
                  onHover: (e) => pick(e.localPosition.dx, c.maxWidth),
                  onExit: (_) => setState(() => _part = null),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 900),
                    curve: Curves.easeOutCubic,
                    builder: (context, t, _) => ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        height: 10,
                        child: total == 0
                            ? const ColoredBox(color: DashUi.faint)
                            : Align(
                                alignment: Alignment.centerLeft,
                                child: FractionallySizedBox(
                                  widthFactor: t,
                                  heightFactor: 1,
                                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [seg(0), seg(1), seg(2)]),
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
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

/// "Late to send estimates" count card: green up to 15, amber 16-25, red 26 and up. A small clock sits on the right and
/// its hands run faster the worse the count (still at zero, still with reduced motion; faster again on hover).
/// Hovering also lifts the card and points at the click, which opens the list of those estimates.
class _LateCard extends StatefulWidget {
  final int? count;
  final String employeeId;
  final String name;
  const _LateCard({required this.count, required this.employeeId, required this.name});

  @override
  State<_LateCard> createState() => _LateCardState();
}

class _LateCardState extends State<_LateCard> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<double> _turns = ValueNotifier(0); // minute-hand revolutions so far
  Duration _last = Duration.zero;
  bool _hovering = false;
  bool _reduceMotion = false;

  /// Minute-hand revolutions per second for the current tier.
  double get _speed {
    final n = widget.count;
    if (n == null || n == 0 || _reduceMotion) return 0;
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
    })..start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
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
    final color = n == null ? DashUi.muted : (n <= 15 ? DashUi.emerald : (n <= 25 ? DashUi.amber : DashUi.red));
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showDialog(
          context: context,
          builder: (_) => _LateEstimatesDialog(employeeId: widget.employeeId, name: widget.name),
        ),
        child: HoverLift(
          lift: 2,
          builder: (context, hovering) {
            _hovering = hovering; // read by the ticker; no rebuild needed for it
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: hovering ? color.withValues(alpha: 0.55) : DashUi.line),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Late to send estimates', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.slate)),
                        const SizedBox(height: 1),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Text(n == null ? '—' : '$n', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, height: 1.1, color: color)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 140),
                                layoutBuilder: (cur, prev) => Stack(alignment: Alignment.centerLeft, children: [...prev, ?cur]),
                                child: Text(
                                  hovering ? 'see the estimates' : 'this year',
                                  key: ValueKey(hovering),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: hovering ? color : DashUi.muted),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  ExcludeSemantics(
                    child: SizedBox(
                      width: 42,
                      height: 42,
                      child: ValueListenableBuilder<double>(
                        valueListenable: _turns,
                        builder: (context, t, _) => CustomPaint(painter: _ClockPainter(turns: t, color: color)),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A small clock face: ring, twelve ticks, an hour hand and a minute hand. [turns] is the minute hand's revolutions.
class _ClockPainter extends CustomPainter {
  final double turns;
  final Color color;
  const _ClockPainter({required this.turns, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 1.5;
    canvas.drawCircle(c, r, Paint()..color = color.withValues(alpha: 0.08));
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = color.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2,
    );
    final tick = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..strokeCap = StrokeCap.round;
    for (var k = 0; k < 12; k++) {
      final a = k * math.pi / 6;
      final major = k % 3 == 0;
      tick.strokeWidth = major ? 1.8 : 1.0;
      final inner = r - (major ? 6.5 : 4.5);
      canvas.drawLine(c + Offset(math.sin(a), -math.cos(a)) * inner, c + Offset(math.sin(a), -math.cos(a)) * (r - 2.5), tick);
    }
    final minute = turns * 2 * math.pi;
    final hour = minute / 12 + math.pi / 3; // starts near 2 o'clock, then creeps
    void hand(double angle, double len, double w) => canvas.drawLine(
          c,
          c + Offset(math.sin(angle), -math.cos(angle)) * len,
          Paint()
            ..color = color
            ..strokeWidth = w
            ..strokeCap = StrokeCap.round,
        );
    hand(hour, r * 0.45, 2.6);
    hand(minute, r * 0.72, 1.8);
    canvas.drawCircle(c, 2.4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _ClockPainter old) => old.turns != turns || old.color != color;
}

/// One estimate in a drill-down list: the two middle columns are created/provided (late to send) or
/// status/last activity (stale), then the days (late days, or days idle).
class _LateEstimate {
  final String jobId;
  final String customer;
  final String category;
  final String created;
  final String provided;
  final int days;
  final int allowed;
  const _LateEstimate(this.jobId, this.customer, this.category, this.created, this.provided, this.days, this.allowed);
}


enum _EstimateListKind { late, stale }


/// "2026-09-17" -> "Sep 17, 2026" (the backend sends plain dates).
String _prettyDate(String iso) {
  final p = iso.split('-');
  if (p.length != 3 || p[0].length != 4) return iso; // not a plain date (e.g. a status): show as is
  final m = int.tryParse(p[1]) ?? 0;
  if (m < 1 || m > 12) return iso;
  return '${_monthLetters[m - 1]} ${int.tryParse(p[2]) ?? p[2]}, ${p[0]}';
}

/// The estimates behind "Late to send": customer, date created, date provided and the days between.
class _LateEstimatesDialog extends StatefulWidget {
  final String employeeId;
  final String name;
  final _EstimateListKind kind;
  const _LateEstimatesDialog({required this.employeeId, required this.name, this.kind = _EstimateListKind.late});

  @override
  State<_LateEstimatesDialog> createState() => _LateEstimatesDialogState();
}

class _LateEstimatesDialogState extends State<_LateEstimatesDialog> {
  List<_LateEstimate>? _items;
  Map _limits = const {}; // the day limits the backend applied, shown as the helper text
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await http
          .get(
            Uri.parse(
              '$kApiBaseUrl/api/employees/${Uri.encodeComponent(widget.employeeId)}/'
              '${widget.kind == _EstimateListKind.late ? 'late_estimates' : 'stale_estimates'}?year=${DateTime.now().year}',
            ),
            headers: AuthSession.instance.headers(),
          )
          .timeout(const Duration(seconds: 40));
      if (res.statusCode == 401) {
        AuthSession.instance.logout(); // sends the app back to the sign-in screen
        throw Exception('Your session expired. Please sign in again.');
      }
      if (res.statusCode != 200) throw Exception('Server error (${res.statusCode})');
      final body = json.decode(res.body);
      final list = body is Map && body['items'] is List ? body['items'] as List : const [];
      final limits = body is Map && body['limits'] is Map ? body['limits'] as Map : const {};
      final items = [
        for (final e in list)
          if (e is Map)
            _LateEstimate(
              _str(e['jobId']),
              _str(e['customerName']),
              _str(e['category']),
              widget.kind == _EstimateListKind.late ? _str(e['created']) : _str(e['status']),
              widget.kind == _EstimateListKind.late ? _str(e['provided']) : _str(e['lastActivity']),
              int.tryParse(_str(e['days'])) ?? 0,
              int.tryParse(_str(e['allowedDays'])) ?? 3,
            ),
      ];
      if (!mounted) return;
      setState(() {
        _items = items;
        _limits = limits;
        _loading = false;
      });
    } on TimeoutException {
      _fail('The request timed out.');
    } catch (e) {
      _fail(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _fail(String m) {
    if (!mounted) return;
    setState(() {
      _error = m;
      _loading = false;
    });
  }

  int _limit(String key, int fallback) => int.tryParse(_str(_limits[key])) ?? fallback;

  /// The line under the title: how many, and the limit that put them here.
  String _helperText() {
    final n = _items?.length;
    if (widget.kind == _EstimateListKind.late) {
      final rule = 'Sent more than ${_limit('turnaroundDays', 3)} days after creation (${_limit('hardBidDays', 14)} for hard bids)';
      return n == null ? rule : '$n ${n == 1 ? 'estimate' : 'estimates'} · $rule';
    }
    final rule = 'No activity for more than ${_limit('requestedDays', 5)} days before sending (${_limit('requestedHardBidDays', 14)} for hard bids) '
        'or ${_limit('providedDays', 14)} days once sent';
    return n == null ? rule : '$n open ${n == 1 ? 'estimate' : 'estimates'} · $rule';
  }

  @override
  Widget build(BuildContext context) {
    const head = TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _muted, letterSpacing: 0.6);
    Widget body;
    if (_loading) {
      body = const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator(color: Color(0xFFCC0007))));
    } else if (_error != null) {
      body = Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, color: DashUi.muted),
            const SizedBox(height: 8),
            Text("Couldn't load these estimates. $_error", textAlign: TextAlign.center, style: const TextStyle(fontSize: 13.5, color: _slate)),
            const SizedBox(height: 8),
            TextButton.icon(onPressed: _load, icon: const Icon(Icons.refresh_rounded, size: 18), label: const Text('Try again')),
          ],
        ),
      );
    } else if (_items!.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.all(40),
        child: Center(
          child: Text(
            widget.kind == _EstimateListKind.late ? 'No late estimates this year.' : 'No stale estimates. Everything open has had recent activity.',
            style: const TextStyle(fontSize: 14, color: _slate),
          ),
        ),
      );
    } else {
      body = Flexible(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 6),
              child: Row(
                children: [
                  const Expanded(flex: 5, child: Text('CUSTOMER', style: head)),
                  Expanded(flex: 3, child: Text(widget.kind == _EstimateListKind.late ? 'CREATED' : 'STATUS', style: head, textAlign: TextAlign.right)),
                  Expanded(flex: 3, child: Text(widget.kind == _EstimateListKind.late ? 'PROVIDED' : 'LAST ACTIVITY', style: head, textAlign: TextAlign.right)),
                  Expanded(flex: 2, child: Text(widget.kind == _EstimateListKind.late ? 'DAYS' : 'DAYS IDLE', style: head, textAlign: TextAlign.right)),
                ],
              ),
            ),
            for (final e in _items!)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 11),
                decoration: const BoxDecoration(border: Border(top: BorderSide(color: _line))),
                child: Row(
                  children: [
                    Expanded(
                      flex: 5,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.customer, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _ink)),
                          Text(
                            '#${e.jobId}${e.category.isEmpty ? '' : ' · ${e.category}'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, color: _muted),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: widget.kind == _EstimateListKind.stale
                          ? Align(
                              alignment: Alignment.centerRight,
                              child: StatusPill(e.created),
                            )
                          : Text(_prettyDate(e.created), maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right, style: const TextStyle(fontSize: 13.5, color: _slate)),
                    ),
                    Expanded(flex: 3, child: Text(_prettyDate(e.provided), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13.5, color: _slate))),
                    Expanded(
                      flex: 2,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                          decoration: BoxDecoration(color: DashUi.red.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
                          child: Text('${e.days}', style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: DashUi.red)),
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

    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 12, 12),
              child: Row(
                children: [
                  Icon(widget.kind == _EstimateListKind.late ? Icons.schedule_send_rounded : Icons.hourglass_bottom_rounded, size: 20, color: DashUi.red),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${widget.name} · ${widget.kind == _EstimateListKind.late ? 'Late to send estimates' : 'Stale estimates'}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: _ink)),
                        Text(
                          _helperText(),
                          style: const TextStyle(fontSize: 12.5, color: _muted),
                        ),
                      ],
                    ),
                  ),
                  IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close_rounded, size: 20, color: _slate), tooltip: 'Close'),
                ],
              ),
            ),
            body,
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Five stars filled to [value] (0-5, partial stars supported).
class _StarsPainter extends CustomPainter {
  final double value;
  final Color fill;
  const _StarsPainter(this.value, this.fill);

  static Path _star(Offset c, double r) {
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final rad = i.isEven ? r : r * 0.45;
      final a = -math.pi / 2 + i * math.pi / 5;
      final p = Offset(c.dx + rad * math.cos(a), c.dy + rad * math.sin(a));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    return path..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final slot = size.width / 5;
    final r = math.min(slot, size.height) / 2 * 0.92;
    for (var i = 0; i < 5; i++) {
      final c = Offset(slot * (i + 0.5), size.height / 2);
      final star = _star(c, r);
      canvas.drawPath(star, Paint()..color = DashUi.line);
      final frac = (value - i).clamp(0.0, 1.0);
      if (frac > 0) {
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(slot * i, 0, slot * frac, size.height));
        canvas.drawPath(star, Paint()..color = fill);
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(covariant _StarsPainter old) => old.value != value || old.fill != fill;
}

/// Share of service call evals that turned into a service package (the Same Day Service Credit was added to the job).
/// The percentage counts up and the bar fills when the card appears (or the figure changes); still when the OS asks
/// for reduced motion.
class _ConversionCard extends StatelessWidget {
  final ({int evals, int converted})? data;
  const _ConversionCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final d = data;
    final has = d != null && d.evals > 0;
    final rate = has ? d.converted / d.evals : 0.0;
    final target = !has ? DashUi.muted : (rate >= 0.4 ? DashUi.emeraldDeep : (rate >= 0.2 ? DashUi.amber : DashUi.red));
    final still = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      label: has ? 'Service and repair conversion rate: ${(rate * 100).round()} percent' : 'Service and repair conversion rate: no data yet',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: DashUi.panel(),
        child: TweenAnimationBuilder<double>(
          key: ValueKey(rate),
          tween: Tween(begin: still ? rate : 0, end: rate),
          duration: still ? Duration.zero : const Duration(milliseconds: 1600),
          curve: Curves.easeOutCubic,
          builder: (context, v, _) {
            final color = Color.lerp(DashUi.muted, target, (v / (rate == 0 ? 1 : rate)).clamp(0.0, 1.0))!;
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('Service & Repair Conversion Rate', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: _ink, height: 1.15)),
                    ),
                    Text(
                      has ? '${(v * 100).round()}%' : '—',
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: color, height: 1, fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(value: v, minHeight: 5, color: color, backgroundColor: DashUi.faint),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A 1-5 star rating card (customer satisfaction, employee morale). Empty until there is data.
class _RatingCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final _Rating? rating;
  const _RatingCard({required this.title, required this.rating, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final r = rating;
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: DashUi.panel(),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: _ink, height: 1.15)),
                if (subtitle != null)
                  Text(subtitle!, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: DashUi.muted, height: 1.2)),
              ],
            ),
          ),
          Semantics(
            label: r == null ? '$title: not tracked yet' : '$title: ${_fmtNum(r.avg)} out of 5 stars',
            child: SizedBox(width: 82, height: 18, child: CustomPaint(painter: _StarsPainter(r?.avg ?? 0, DashUi.amber))),
          ),
          const SizedBox(width: 8),
          if (r == null)
            const Text('—', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: DashUi.muted, height: 1))
          else
            Text(_fmtNum(r.avg), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _ink, height: 1)),
        ],
      ),
    );
  }
}

/// Tall card of customer comments that name this tech, one at a time, sliding up every few seconds. Stands still
/// while the cursor is over it or when the OS asks for reduced motion. Shows a quiet empty state until comments exist.
class _MentionsCard extends StatefulWidget {
  final List<_Mention> mentions;
  final _Rating? satisfaction;
  const _MentionsCard({required this.mentions, this.satisfaction});

  @override
  State<_MentionsCard> createState() => _MentionsCardState();
}

class _MentionsCardState extends State<_MentionsCard> {
  static const _every = Duration(seconds: 7);
  Timer? _timer;
  int _i = 0;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_every, (_) {
      if (!mounted || _hovered || widget.mentions.length < 2 || MediaQuery.disableAnimationsOf(context)) return;
      setState(() => _i = (_i + 1) % widget.mentions.length);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Average customer stars and how many ratings it is based on.
  Widget _satisfactionRow() {
    final r = widget.satisfaction;
    return Semantics(
      label: r == null ? 'Customer satisfaction: not tracked yet' : 'Customer satisfaction: ${_fmtNum(r.avg)} out of 5 stars from ${r.count} ratings',
      child: Row(
        children: [
          SizedBox(width: 82, height: 18, child: CustomPaint(painter: _StarsPainter(r?.avg ?? 0, DashUi.amber))),
          const SizedBox(width: 8),
          if (r == null)
            const Text('—', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: DashUi.muted, height: 1))
          else ...[
            Text(_fmtNum(r.avg), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _ink, height: 1)),
            const SizedBox(width: 6),
            Text('${r.count} ratings', style: const TextStyle(fontSize: 11, color: DashUi.muted)),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.mentions;
    final idx = list.isEmpty ? 0 : _i % list.length;
    final m = list.isEmpty ? null : list[idx];
    return MouseRegion(
      onEnter: (_) => _hovered = true,
      onExit: (_) => _hovered = false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: DashUi.panel(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('CUSTOMER FEEDBACK', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.8, color: DashUi.muted)),
            const SizedBox(height: 6),
            _satisfactionRow(),
            const SizedBox(height: 4),
            const Align(alignment: Alignment.centerLeft, child: Icon(Icons.format_quote_rounded, size: 28, color: DashUi.amber)),
            Expanded(
              child: ClipRect(
                child: AnimatedSwitcher(
                  duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 450),
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: SlideTransition(position: Tween(begin: const Offset(0, 0.15), end: Offset.zero).animate(anim), child: child),
                  ),
                  layoutBuilder: (cur, prev) => Stack(alignment: Alignment.topLeft, children: [...prev, ?cur]),
                  child: m == null
                      ? const Align(
                          key: ValueKey('empty'),
                          alignment: Alignment.centerLeft,
                          child: Text('No customer mentions yet', style: TextStyle(fontSize: 13, color: DashUi.muted)),
                        )
                      : Semantics(
                          key: ValueKey(idx),
                          label: 'Customer comment from ${m.customer}: ${m.quote}',
                          child: SizedBox.expand(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(m.quote, overflow: TextOverflow.fade, style: const TextStyle(fontSize: 14, fontStyle: FontStyle.italic, color: _ink, height: 1.35)),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(m.customer, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _ink)),
                                if (m.source != null) Text(m.source!, style: const TextStyle(fontSize: 11.5, color: DashUi.muted)),
                              ],
                            ),
                          ),
                        ),
                ),
              ),
            ),
            if (list.length > 1) ...[
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var k = 0; k < list.length; k++)
                    Container(
                      width: k == idx ? 16 : 6,
                      height: 6,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(color: k == idx ? DashUi.amber : DashUi.muted.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(3)),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Jobs completed since a callback last came back on one of this tech's jobs, with a flame that grows (and gets
/// hotter) as the streak does. The flame flickers; it holds still when the OS asks for reduced motion.
class _StreakCard extends StatefulWidget {
  final int? streak;
  const _StreakCard({required this.streak});

  @override
  State<_StreakCard> createState() => _StreakCardState();
}

class _StreakCardState extends State<_StreakCard> with SingleTickerProviderStateMixin {
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
    final n = widget.streak;
    // 0 jobs is a small grey ember; the flame is full size at 40+.
    final size = n == null ? 0.0 : (n.clamp(0, 40) / 40.0);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 16, 10),
      decoration: DashUi.panel(),
      child: Semantics(
        label: n == null ? 'Streak: not tracked yet' : 'Streak: $n ${n == 1 ? 'job' : 'jobs'} completed since the last callback',
        child: Row(
          children: [
            SizedBox(
              width: 62,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: AnimatedBuilder(
                  animation: _c,
                  builder: (_, _) => CustomPaint(
                    size: Size(26 + 34 * size, 44 + 50 * size),
                    painter: _FlamePainter(t: _c.value, heat: size, lit: n != null && n > 0),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('CALLBACK-FREE STREAK', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.7, color: DashUi.muted)),
                  const SizedBox(height: 4),
                  Text(n == null ? '—' : '$n', style: TextStyle(fontSize: 40, fontWeight: FontWeight.w800, color: n == null ? DashUi.muted : _ink, height: 1)),
                  const SizedBox(height: 3),
                  Text(
                    n == null ? 'Not tracked yet' : (n == 1 ? 'job since last callback' : 'jobs since last callback'),
                    style: const TextStyle(fontSize: 11.5, color: DashUi.muted, height: 1.2),
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

/// A flickering flame. [heat] 0..1 shifts the colour from amber to red-orange; [lit] false draws a grey ember.
class _FlamePainter extends CustomPainter {
  final double t; // 0..1 loop
  final double heat;
  final bool lit;
  _FlamePainter({required this.t, required this.heat, required this.lit});

  /// A pointed flame with a small tongue on each side. [w] and [h] are its width and height, sitting on the bottom
  /// edge of [s]; [sway] (-1..1) leans the tips.
  Path _flame(Size s, double w, double h, double sway) {
    final cx = s.width / 2;
    final b = s.height;
    final tx = cx + sway * w * 0.12;
    final ty = b - h;
    return Path()
      ..moveTo(cx, b)
      ..cubicTo(cx - w * 0.58, b, cx - w * 0.62, b - h * 0.28, cx - w * 0.44, b - h * 0.5)
      ..cubicTo(cx - w * 0.36, b - h * 0.6, cx - w * 0.36, b - h * 0.7, cx - w * 0.42 + sway * w * 0.06, b - h * 0.8)
      ..cubicTo(cx - w * 0.22, b - h * 0.68, cx - w * 0.2, b - h * 0.56, cx - w * 0.12, b - h * 0.5)
      ..cubicTo(cx - w * 0.06, b - h * 0.66, tx - w * 0.14, ty + h * 0.3, tx, ty)
      ..cubicTo(tx + w * 0.08, ty + h * 0.3, cx + w * 0.22, b - h * 0.62, cx + w * 0.2, b - h * 0.56)
      ..cubicTo(cx + w * 0.3, b - h * 0.64, cx + w * 0.34, b - h * 0.55, cx + w * 0.4 + sway * w * 0.05, b - h * 0.62)
      ..cubicTo(cx + w * 0.62, b - h * 0.4, cx + w * 0.62, b - h * 0.12, cx + w * 0.3, b - h * 0.03)
      ..cubicTo(cx + w * 0.2, b, cx + w * 0.1, b, cx, b)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final a = t * 2 * math.pi;
    final flick = 0.94 + 0.06 * math.sin(a * 3) + 0.03 * math.sin(a * 5 + 1);
    final sway = math.sin(a * 2);
    if (!lit) {
      canvas.drawPath(_flame(size, size.width * 0.8, size.height * 0.55, 0), Paint()..color = const Color(0xFFCBD5E1));
      return;
    }
    final outer = Color.lerp(const Color(0xFFF59E0B), const Color(0xFFEF4444), heat)!;
    final h = size.height * flick;
    final rect = Rect.fromLTWH(0, size.height - h, size.width, h);
    canvas.drawPath(
      _flame(size, size.width, h, sway),
      Paint()..shader = LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [outer, const Color(0xFFFBBF24)]).createShader(rect),
    );
    canvas.drawPath(_flame(size, size.width * 0.58, h * 0.66, sway * 0.7), Paint()..color = const Color(0xFFFEF3C7).withValues(alpha: 0.95));
  }

  @override
  bool shouldRepaint(covariant _FlamePainter old) => old.t != t || old.heat != heat || old.lit != lit;
}

/// This tech's labor per work day against the rest of the team, month by month. Drawn like the monthly chart above it
/// (same margins, gridlines, smooth line with a soft fill, hover highlight and tooltip) so the two read as a pair; the
/// team is a dashed amber line. Hover a month for both numbers and the gap.
class _CompareChart extends StatefulWidget {
  final List<double?> mine;
  final List<double?> team;

  /// Fill the height the parent gives (otherwise a fixed 220px).
  final bool expand;

  /// The tech's name, for the legend and tooltip.
  final String name;
  const _CompareChart({required this.mine, required this.team, this.name = 'This tech', this.expand = false});

  @override
  State<_CompareChart> createState() => _CompareChartState();
}

class _CompareChartState extends State<_CompareChart> with TickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..forward();
  late final AnimationController _hoverAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 160));
  int? _active;
  int? _painted;

  @override
  void didUpdateWidget(covariant _CompareChart old) {
    super.didUpdateWidget(old);
    // Replay only when the numbers change (the lists are rebuilt each time the chart above changes tab).
    if (!listEquals(old.mine, widget.mine) || !listEquals(old.team, widget.team)) {
      _active = null;
      _painted = null;
      _hoverAnim.value = 0;
      _intro.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    _hoverAnim.dispose();
    super.dispose();
  }

  bool get _hasTeam => widget.team.any((v) => v != null);

  void _setActive(int? i) {
    if (i == _active) return;
    setState(() {
      if (i != null) _painted = i;
      _active = i;
    });
    i != null ? _hoverAnim.forward() : _hoverAnim.reverse();
  }

  int? _indexFor(double dx, double width) {
    final n = widget.mine.length;
    final slot = (width - _ChartPainter.left - _ChartPainter.right) / n;
    if (slot <= 0) return null;
    final i = ((dx - _ChartPainter.left) / slot).floor();
    return i >= 0 && i < n && (widget.mine[i] != null || widget.team[i] != null) ? i : null;
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (reduce) _intro.value = 1;
    final w = widget;
    final empty = w.mine.every((v) => v == null);
    final first = w.name.split(' ').first;

    final summary = [
      for (var i = 0; i < w.mine.length; i++)
        if (w.mine[i] != null) '${_monthLetters[i]} $first ${dashMoney(w.mine[i]!)}${w.team[i] == null ? '' : ', rest of team ${dashMoney(w.team[i]!)}'}',
    ].join('; ');

    Widget legend(Widget swatch, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [swatch, const SizedBox(width: 6), Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: DashUi.slate, fontWeight: FontWeight.w500)))],
        );

    final chart = empty
        ? const Center(child: Text('No completed jobs this year', style: TextStyle(fontSize: 13.5, color: DashUi.muted)))
        : LayoutBuilder(
            builder: (context, c) => Semantics(
              label: 'Chart: $summary',
              child: MouseRegion(
                onHover: (e) => _setActive(_indexFor(e.localPosition.dx, c.maxWidth)),
                onExit: (_) => _setActive(null),
                child: AnimatedBuilder(
                  animation: Listenable.merge([_intro, _hoverAnim]),
                  builder: (context, _) => CustomPaint(
                    size: Size(c.maxWidth, c.maxHeight.isFinite ? c.maxHeight : 190),
                    painter: _ComparePainter(
                      mine: w.mine,
                      team: w.team,
                      name: first,
                      index: _painted,
                      intro: Curves.easeOutCubic.transform(_intro.value),
                      hover: _active == null ? _hoverAnim.value : math.max(_hoverAnim.value, 0.001),
                      fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
                    ),
                  ),
                ),
              ),
            ),
          );

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
      decoration: DashUi.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(child: Text('Labor / day', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: _ink))),
              Flexible(child: legend(Container(width: 14, height: 3, decoration: BoxDecoration(color: DashUi.blue, borderRadius: BorderRadius.circular(2))), first)),
              const SizedBox(width: 14),
              legend(
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [for (var i = 0; i < 3; i++) Container(width: 4, height: 2.5, margin: EdgeInsets.only(right: i == 2 ? 0 : 2), color: _amberLine)],
                ),
                _hasTeam ? 'Rest of team' : 'Rest of team (no data)',
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (w.expand) Expanded(child: chart) else SizedBox(height: 190, child: chart),
        ],
      ),
    );
  }
}

class _ComparePainter extends CustomPainter {
  final List<double?> mine;
  final List<double?> team;
  final String name;
  final int? index;
  final double intro;
  final double hover;
  final String? fontFamily;
  const _ComparePainter({
    required this.mine,
    required this.team,
    required this.name,
    required this.index,
    required this.intro,
    required this.hover,
    required this.fontFamily,
  });

  TextPainter _text(String t, TextStyle style, {double? maxWidth}) => TextPainter(
        text: TextSpan(text: t, style: style.copyWith(fontFamily: fontFamily)),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout(maxWidth: maxWidth ?? double.infinity);

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(_ChartPainter.left, _ChartPainter.top, size.width - _ChartPainter.right, size.height - _ChartPainter.bottom);
    if (plot.width <= 0 || plot.height <= 0) return;
    final n = mine.length;
    final slot = plot.width / n;
    final focusing = index != null && hover > 0.001;
    final maxV = _ChartPainter._niceMax([...mine, ...team].whereType<double>().fold<double>(0, math.max));
    double y(double v) => plot.bottom - (v / maxV).clamp(0.0, 1.0) * plot.height;

    if (focusing) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(plot.left + index! * slot + 2, plot.top, slot - 4, plot.height), const Radius.circular(10)),
        Paint()..color = const Color(0xFFEFF6FF).withValues(alpha: hover),
      );
    }

    for (var i = 0; i <= 4; i++) {
      final v = maxV * i / 4;
      final gy = y(v);
      canvas.drawLine(
        Offset(plot.left, gy),
        Offset(plot.right, gy),
        Paint()
          ..color = i == 0 ? DashUi.line : DashUi.faint
          ..strokeWidth = 1,
      );
      final tp = _text(_compactMoney(v), const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: DashUi.muted));
      tp.paint(canvas, Offset(_ChartPainter.left - 8 - tp.width, gy - tp.height / 2));
    }

    for (var i = 0; i < n; i++) {
      final cx = plot.left + slot * (i + 0.5);
      final focus = focusing && index == i;
      final has = mine[i] != null || team[i] != null;
      final tp = _text(
        _monthLetters[i],
        TextStyle(fontSize: 12.5, fontWeight: focus ? FontWeight.w800 : FontWeight.w600, color: focus ? DashUi.ink : (has ? DashUi.slate : const Color(0xFFCBD5E1))),
        maxWidth: slot,
      );
      tp.paint(canvas, Offset(cx - tp.width / 2, plot.bottom + 8));
      if (i == n - 1 && has) {
        final so = _text('so far', const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: DashUi.muted), maxWidth: slot);
        so.paint(canvas, Offset(cx - so.width / 2, plot.bottom + 8 + tp.height));
      }
    }

    // Team first (dashed, no fill) so the tech's line and dots sit on top.
    _line(canvas, plot, slot, y, team, _amberLine, dashed: true, fill: false);
    _line(canvas, plot, slot, y, mine, DashUi.blue, dashed: false, fill: true);

    if (focusing) _tooltip(canvas, size, plot, slot, y);
  }

  Map<int, Offset> _points(Rect plot, double slot, double Function(double) y, List<double?> v) => {
        for (var i = 0; i < v.length; i++)
          if (v[i] != null) i: Offset(plot.left + slot * (i + 0.5), y(v[i]!)),
      };

  void _line(Canvas canvas, Rect plot, double slot, double Function(double) y, List<double?> values, Color color, {required bool dashed, required bool fill}) {
    final n = values.length;
    final pts = _points(plot, slot, y, values);
    if (pts.isEmpty) return;
    final runs = <List<int>>[];
    for (var i = 0; i < n; i++) {
      if (!pts.containsKey(i)) continue;
      if (runs.isNotEmpty && runs.last.last == i - 1) {
        runs.last.add(i);
      } else {
        runs.add([i]);
      }
    }

    canvas.save();
    canvas.clipRect(Rect.fromLTRB(plot.left, 0, plot.left + (plot.width + _ChartPainter.right) * intro, plot.bottom + 4));
    for (final run in runs) {
      if (run.length < 2) continue;
      final path = Path()..moveTo(pts[run.first]!.dx, pts[run.first]!.dy);
      for (var k = 1; k < run.length; k++) {
        final a = pts[run[k - 1]]!, b = pts[run[k]]!;
        final cx = (a.dx + b.dx) / 2;
        path.cubicTo(cx, a.dy, cx, b.dy, b.dx, b.dy);
      }
      if (fill) {
        final area = Path.from(path)
          ..lineTo(pts[run.last]!.dx, plot.bottom)
          ..lineTo(pts[run.first]!.dx, plot.bottom)
          ..close();
        canvas.drawPath(
          area,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0.0)],
            ).createShader(Rect.fromLTRB(plot.left, plot.top, plot.right, plot.bottom)),
        );
      }
      final stroke = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = dashed ? 2.2 : 2.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      if (dashed) {
        for (final m in path.computeMetrics()) {
          for (var d = 0.0; d < m.length; d += 9) {
            canvas.drawPath(m.extractPath(d, math.min(d + 5, m.length)), stroke);
          }
        }
      } else {
        canvas.drawPath(path, stroke);
      }
    }
    canvas.restore();

    final focusing = index != null && hover > 0.001;
    for (final e in pts.entries) {
      final isFocus = focusing && index == e.key;
      final progress = ((intro * (n + 1) - e.key) / 1.0).clamp(0.0, 1.0);
      if (progress <= 0) continue;
      if (isFocus) canvas.drawCircle(e.value, 9 * hover, Paint()..color = color.withValues(alpha: 0.2 * hover));
      final scale = dashed ? 0.8 : 1.0;
      canvas.drawCircle(e.value, (isFocus ? 6 : 4.5) * progress * scale, Paint()..color = Colors.white);
      canvas.drawCircle(e.value, (isFocus ? 4.5 : 3) * progress * scale, Paint()..color = color);
    }
  }

  void _tooltip(Canvas canvas, Size size, Rect plot, double slot, double Function(double) y) {
    final i = index!;
    final partial = i == mine.length - 1;
    final m = mine[i], t = team[i];
    final title = _text(partial ? '${_monthLetters[i]} so far' : _monthLetters[i], const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800));
    const body = TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600);
    final mineRow = m == null ? null : _text('$name  ${dashMoney(m)}', body);
    final teamRow = t == null ? null : _text('Rest of team  ${dashMoney(t)}', body.copyWith(color: const Color(0xFFFCD34D)));

    TextPainter? delta;
    if (m != null && t != null && t > 0) {
      final pct = (m - t) / t * 100;
      final up = pct >= 0;
      delta = _text(
        '${up ? '▲' : '▼'} ${pct.abs().toStringAsFixed(1)}% vs rest of team',
        TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: up ? const Color(0xFF34D399) : const Color(0xFFF87171)),
      );
    }

    final rows = [title, ?mineRow, ?teamRow, ?delta];
    final w = rows.map((r) => r.width).reduce(math.max) + 24;
    final h = rows.fold<double>(0, (a, r) => a + r.height) + 18 + (rows.length - 1) * 3;
    final cx = plot.left + slot * (i + 0.5);
    final topV = math.max(m ?? 0, t ?? 0);
    final tx = (cx - w / 2).clamp(0.0, math.max(0.0, size.width - w)).toDouble();
    var ty = y(topV) - h - 14;
    if (ty < 0) ty = math.min(y(topV) + 14, size.height - h);
    final box = RRect.fromRectAndRadius(Rect.fromLTWH(tx, ty, w, h), const Radius.circular(10));
    canvas.drawRRect(
      box.shift(const Offset(0, 3)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.18 * hover)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawRRect(box, Paint()..color = DashUi.ink.withValues(alpha: 0.96 * hover));
    var dy = ty + 9;
    for (final r in rows) {
      r.paint(canvas, Offset(tx + 12, dy));
      dy += r.height + 3;
    }
  }

  @override
  bool shouldRepaint(covariant _ComparePainter old) =>
      old.intro != intro ||
      old.hover != hover ||
      old.index != index ||
      old.name != name ||
      old.fontFamily != fontFamily ||
      !listEquals(old.mine, mine) ||
      !listEquals(old.team, team);
}

/// Customer satisfaction and peer rating over the year, as two small stacked trend lines with the latest score.
class _RatingTrendsCard extends StatelessWidget {
  final List<double?> customer;
  final List<double?> peer;
  const _RatingTrendsCard({required this.customer, required this.peer});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: DashUi.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('RATING TRENDS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.8, color: DashUi.muted)),
          const SizedBox(height: 6),
          Expanded(child: _TrendRow(label: 'Customer', values: customer, color: DashUi.amber)),
          const SizedBox(height: 6),
          Expanded(child: _TrendRow(label: 'Peer', values: peer, color: DashUi.indigo)),
        ],
      ),
    );
  }
}

class _TrendRow extends StatelessWidget {
  final String label;
  final List<double?> values;
  final Color color;
  const _TrendRow({required this.label, required this.values, required this.color});

  @override
  Widget build(BuildContext context) {
    final latest = values.whereType<double>().isEmpty ? null : values.lastWhere((v) => v != null)!;
    return Semantics(
      label: latest == null ? '$label rating trend: not tracked yet' : '$label rating trend, latest ${_fmtNum(latest)} out of 5',
      child: Row(
        children: [
          SizedBox(width: 66, child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _slate))),
          Expanded(
            child: latest == null
                ? const Align(alignment: Alignment.centerLeft, child: Text('Not tracked yet', style: TextStyle(fontSize: 11.5, color: DashUi.muted)))
                : CustomPaint(painter: _SparkPainter(values, color), size: Size.infinite),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 32,
            child: Text(latest == null ? '—' : _fmtNum(latest), textAlign: TextAlign.right, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: latest == null ? DashUi.muted : _ink, height: 1)),
          ),
        ],
      ),
    );
  }
}

/// A small line over the months with a dot on the latest point. Scaled to the data (kept within 1-5 stars).
class _SparkPainter extends CustomPainter {
  final List<double?> values;
  final Color color;
  _SparkPainter(this.values, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final vs = values.whereType<double>().toList();
    if (vs.isEmpty) return;
    var lo = math.max(1.0, vs.reduce(math.min) - 0.3);
    var hi = math.min(5.0, vs.reduce(math.max) + 0.3);
    if (hi - lo < 1) {
      lo = math.max(1.0, hi - 1);
      hi = lo + 1;
    }
    const pad = 4.0;
    final n = values.length;
    Offset pt(int i, double v) => Offset(pad + (size.width - pad * 2) * (n == 1 ? 0.5 : i / (n - 1)), pad + (size.height - pad * 2) * (1 - (v - lo) / (hi - lo)));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Path? path;
    Offset? last;
    for (var i = 0; i < n; i++) {
      final v = values[i];
      if (v == null) continue;
      final p = pt(i, v);
      if (path == null) {
        path = Path()..moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
      last = p;
    }
    if (path != null) canvas.drawPath(path, paint);
    if (last != null) canvas.drawCircle(last, 3.4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) => !identical(old.values, values) || old.color != color;
}

enum _Standing { ahead, par, behind, none }

/// One scorecard metric: the tech's number against the current techs' figure. [higherBetter] says which way is good.
class _ScoreRow {
  final String label;
  final double? mine;
  final double? team;
  final String Function(double) format;
  final bool higherBetter;

  /// Fixed top of the bar scale (5 for star ratings). Null scales the row to its larger value.
  final double? scaleMax;
  const _ScoreRow(this.label, this.mine, this.team, this.format, {required this.higherBetter, this.scaleMax});

  /// Within 5% of the team figure counts as on par (equal is always on par, including 0 against 0).
  _Standing get standing {
    final m = mine, t = team;
    if (m == null || t == null) return _Standing.none;
    final diff = higherBetter ? m - t : t - m;
    if (diff.abs() <= t.abs() * 0.05) return _Standing.par;
    return diff > 0 ? _Standing.ahead : _Standing.behind;
  }
}

/// The tech against the current techs, one row per metric: a rounded gradient bar (like the monthly chart's) on a soft
/// track, an amber tick where the team figure sits (like the chart's average line), both numbers on the right, and an
/// ahead / on par / behind word. Each row is scaled to its own larger value (ratings to 5 stars), so compare the bar
/// with the tick, not one row with another.
class _TeamComparison extends StatelessWidget {
  final List<_ScoreRow> rows;
  final String name;
  const _TeamComparison({required this.rows, required this.name});

  static (String, Color) _chip(_Standing s) => switch (s) {
        _Standing.ahead => ('Ahead', DashUi.emeraldDeep),
        _Standing.par => ('On par', DashUi.muted),
        _Standing.behind => ('Behind', DashUi.red),
        _Standing.none => ('', DashUi.muted),
      };

  /// What the hover shows: both numbers and how far apart they are. The ahead / behind wording follows the metric
  /// (a lower callback rate than the rest of the team is "ahead").
  InlineSpan _tip(_ScoreRow r) {
    final first = name.split(' ').first;
    final mine = r.mine, team = r.team;
    const base = TextStyle(fontSize: 11.5, color: Colors.white, fontWeight: FontWeight.w600, height: 1.4);
    TextSpan line(String t, {bool bold = false, Color? color}) =>
        TextSpan(text: '$t\n', style: base.copyWith(fontWeight: bold ? FontWeight.w800 : FontWeight.w600, color: color));
    final String verdict;
    if (mine == null) {
      verdict = 'Not tracked yet';
    } else if (team == null) {
      verdict = 'No team figure yet';
    } else {
      final diff = (mine - team).abs();
      // A percentage metric already is one, so a relative percent on top of it would only confuse.
      final pct = team == 0 || r.format(diff).endsWith('%') ? '' : ' (${_fmtNum(diff / team.abs() * 100)}%)';
      verdict = switch (r.standing) {
        _Standing.par => 'On par with the rest of the team',
        _Standing.ahead => 'Ahead by ${r.format(diff)}$pct',
        _Standing.behind => 'Behind by ${r.format(diff)}$pct',
        _Standing.none => '',
      };
    }
    final vColor = switch (r.standing) {
      _Standing.ahead => const Color(0xFF6EE7B7),
      _Standing.behind => const Color(0xFFFCA5A5),
      _ => const Color(0xFFCBD5E1),
    };
    return TextSpan(children: [
      line(r.label, bold: true),
      line('$first   ${mine == null ? '—' : r.format(mine)}'),
      if (team != null) line('Rest of team   ${r.format(team)}'),
      TextSpan(text: verdict, style: base.copyWith(fontWeight: FontWeight.w800, color: vColor)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    Widget legend(Widget swatch, String t) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            swatch,
            const SizedBox(width: 5),
            Flexible(child: Text(t, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: _slate, fontWeight: FontWeight.w600))),
          ],
        );
    Widget row(_ScoreRow r) {
      final top = [r.mine, r.team].whereType<double>().fold<double>(0, math.max);
      final max = r.scaleMax ?? (top <= 0 ? 1.0 : top * 1.12);
      final (word, color) = _chip(r.standing);
      final mineText = r.mine == null ? '—' : r.format(r.mine!);
      final teamText = r.team == null ? null : r.format(r.team!);
      return Semantics(
        label: '${r.label}: $mineText${teamText == null ? ', no team figure' : ', rest of team $teamText, ${word.toLowerCase()}'}',
        excludeSemantics: true,
        child: Tooltip(
          richMessage: _tip(r),
          waitDuration: Duration.zero,
          preferBelow: false,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: const Color(0xE60F172A), borderRadius: BorderRadius.circular(8)),
          child: Row(
          children: [
            SizedBox(width: 102, child: Text(r.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: _slate))),
            Expanded(
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: 1.0),
                duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 700),
                curve: Curves.easeOutCubic,
                builder: (_, t, _) => CustomPaint(
                  size: Size.infinite,
                  painter: _BulletPainter(mine: r.mine == null ? null : r.mine! / max, team: r.team == null ? null : r.team! / max, progress: t),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 70,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(mineText, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: r.mine == null ? DashUi.muted : _ink, height: 1.05)),
                  if (teamText != null) Text('vs $teamText', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: DashUi.muted, height: 1.05)),
                ],
              ),
            ),
            SizedBox(
              width: 46,
              child: Text(word, textAlign: TextAlign.right, maxLines: 1, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: color)),
            ),
          ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
      decoration: DashUi.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(child: Text('Team comparison', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: _ink))),
              Flexible(
                child: legend(
                  Container(
                    width: 14,
                    height: 7,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), gradient: const LinearGradient(colors: [Color(0xFF7DD3FC), DashUi.blue])),
                  ),
                  name.split(' ').first,
                ),
              ),
              const SizedBox(width: 12),
              legend(Container(width: 2.5, height: 12, decoration: BoxDecoration(color: DashUi.amber, borderRadius: BorderRadius.circular(2))), 'Rest of team'),
            ],
          ),
          const SizedBox(height: 6),
          for (final r in rows) Expanded(child: row(r)),
        ],
      ),
    );
  }
}

/// A soft track with a rounded gradient bar for the tech and an amber tick for the team. [mine] and [team] are 0..1
/// fractions of the track (null draws nothing); [progress] grows the bar in.
class _BulletPainter extends CustomPainter {
  final double? mine;
  final double? team;
  final double progress;
  _BulletPainter({required this.mine, required this.team, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final h = math.min(12.0, size.height * 0.5);
    final cy = size.height / 2;
    final track = RRect.fromRectAndRadius(Rect.fromLTWH(0, cy - h / 2, size.width, h), Radius.circular(h / 2));
    canvas.drawRRect(track, Paint()..color = DashUi.faint);
    final m = mine;
    if (m != null) {
      // A short stub for zero so a real "0" still reads as a bar rather than an empty row.
      final w = math.max(size.width * m.clamp(0.0, 1.0) * progress, h);
      final bar = RRect.fromRectAndRadius(Rect.fromLTWH(0, cy - h / 2, w, h), Radius.circular(h / 2));
      canvas.drawRRect(
        bar,
        Paint()..shader = const LinearGradient(colors: [Color(0xFF7DD3FC), DashUi.blue]).createShader(Rect.fromLTWH(0, 0, math.max(w, 1), h)),
      );
    }
    final t = team;
    if (t != null) {
      final x = (size.width * t.clamp(0.0, 1.0)).clamp(1.5, size.width - 1.5);
      canvas.drawLine(
        Offset(x, cy - h / 2 - 3),
        Offset(x, cy + h / 2 + 3),
        Paint()
          ..color = DashUi.amber
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BulletPainter old) => old.mine != mine || old.team != team || old.progress != progress;
}

/// Loading placeholder: a white card with two grey bars, so it shows on the grey page background (the plain
/// skeleton boxes are the same grey as the page). Pulses like the other skeletons.
class _SkelCard extends StatelessWidget {
  final double h;
  final double r;
  const _SkelCard({required this.h, this.r = 16});

  @override
  Widget build(BuildContext context) {
    return SkeletonPulse(
      child: Container(
        height: h,
        padding: const EdgeInsets.all(16),
        decoration: DashUi.panel(radius: r),
        child: h < 80
            ? const Align(alignment: Alignment.centerLeft, child: SkeletonBox(h: 14, w: 170))
            : const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(h: 12, w: 120),
                  SizedBox(height: 10),
                  SkeletonBox(h: 20, w: 170),
                ],
              ),
      ),
    );
  }
}

/// Employee morale: a hospital-monitor heartbeat trace with the 1-5 score beside it. With no score yet the trace is
/// grey and the card says it isn't tracked, with a button to preview it using sample scores (tap the score to try
/// other values). Stands still when the system asks for reduced motion.
class _MoraleCard extends StatefulWidget {
  final String title;
  final _Rating? rating;
  final bool isSample;

  /// True while there is no real score, so the preview can be switched on.
  final bool canPreview;
  final VoidCallback onTogglePreview;
  final VoidCallback onCycle;
  const _MoraleCard({
    required this.title,
    required this.rating,
    required this.isSample,
    required this.canPreview,
    required this.onTogglePreview,
    required this.onCycle,
  });

  @override
  State<_MoraleCard> createState() => _MoraleCardState();
}

class _MoraleCardState extends State<_MoraleCard> with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(vsync: this, duration: const Duration(milliseconds: 6000));

  @override
  void initState() {
    super.initState();
    _sweep.repeat();
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  Color _tone(double score) => score >= 4 ? DashUi.emerald : (score >= 3 ? DashUi.amber : DashUi.red);

  @override
  Widget build(BuildContext context) {
    final r = widget.rating;
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (reduce) {
      _sweep.stop();
    } else if (!_sweep.isAnimating) {
      _sweep.repeat();
    }
    final color = r == null ? DashUi.muted : _tone(r.avg);

    Widget scoreText({required bool big, CrossAxisAlignment align = CrossAxisAlignment.end}) => Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: align,
          children: [
            Text(r == null ? '—' : _fmtNum(r.avg),
                style: TextStyle(fontSize: big ? 52 : 38, fontWeight: FontWeight.w800, color: color, height: 1)),
            Text(
              r == null ? 'Not tracked yet' : (widget.isSample ? 'out of 5 · sample' : 'out of 5'),
              style: TextStyle(fontSize: 11.5, color: widget.isSample ? DashUi.amber : _muted, fontWeight: r == null ? FontWeight.w600 : FontWeight.w400),
            ),
          ],
        );

    Widget trace() => Semantics(
          label: r == null ? '${widget.title}: not tracked yet' : '${widget.title}: ${_fmtNum(r.avg)} out of 5',
          child: AnimatedBuilder(
            animation: _sweep,
            builder: (context, _) => CustomPaint(
              painter: _HeartbeatPainter(progress: reduce ? 1.0 : _sweep.value, color: color, live: r != null),
              child: const SizedBox.expand(),
            ),
          ),
        );

    Widget tapToCycle(Widget child) => widget.isSample
        ? Tooltip(
            message: 'Tap to try another sample score',
            child: InkWell(borderRadius: BorderRadius.circular(8), onTap: widget.onCycle, child: Padding(padding: const EdgeInsets.all(4), child: child)),
          )
        : child;

    final header = Row(
      children: [
        Expanded(child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _ink))),
        if (r != null && !widget.isSample)
          Text('${r.count} ${r.count == 1 ? 'check-in' : 'check-ins'}', style: const TextStyle(fontSize: 12, color: _muted)),
        if (widget.canPreview)
          TextButton(
            onPressed: widget.onTogglePreview,
            style: TextButton.styleFrom(
              foregroundColor: _slate,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 24),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(widget.isSample ? 'Hide' : 'Preview', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
          ),
      ],
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: DashUi.panel(radius: 18),
      child: LayoutBuilder(
        builder: (context, c) {
          // Tall (the space left under the scorecards): big score on top, the trace fills the rest. Short: score beside it.
          final tall = c.maxHeight >= 150;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              if (tall) ...[
                const SizedBox(height: 4),
                Align(alignment: Alignment.centerLeft, child: tapToCycle(scoreText(big: true, align: CrossAxisAlignment.start))),
                const SizedBox(height: 4),
                Expanded(child: trace()),
              ] else
                Expanded(
                  child: Row(
                    children: [
                      Expanded(child: trace()),
                      const SizedBox(width: 12),
                      tapToCycle(scoreText(big: false)),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// ECG trace: a few beats across the width with a bright head sweeping left to right and a fading tail behind it.
class _HeartbeatPainter extends CustomPainter {
  final double progress; // 0..1, where the bright head is
  final Color color;
  final bool live; // false: a dim, still trace
  const _HeartbeatPainter({required this.progress, required this.color, required this.live});

  static const _beats = 3;

  static double _bump(double x, double c, double w) => math.exp(-math.pow((x - c) / w, 2).toDouble());

  /// One heartbeat, x in 0..1: P wave, Q dip, tall R spike, S dip, T wave.
  static double _beat(double x) =>
      0.10 * _bump(x, 0.14, 0.035) - 0.14 * _bump(x, 0.30, 0.012) + 1.0 * _bump(x, 0.34, 0.011) - 0.30 * _bump(x, 0.385, 0.013) + 0.20 * _bump(x, 0.62, 0.05);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    // The spike height is capped so a tall card gets a longer baseline, not a comically tall spike.
    final amp = math.min(size.height * 0.5, 64.0);
    final mid = size.height / 2 + amp * 0.35;
    const steps = 900; // fine enough that the spikes look smooth, not faceted
    final pts = <Offset>[
      for (var i = 0; i <= steps; i++) Offset(size.width * i / steps, mid - amp * _beat((i / steps * _beats) % 1)),
    ];

    // Faint baseline, like monitor paper.
    canvas.drawLine(
      Offset(0, mid),
      Offset(size.width, mid),
      Paint()
        ..color = DashUi.faint
        ..strokeWidth = 1,
    );

    Path through(int last, [Offset? tip]) {
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (var i = 1; i <= last; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      if (tip != null) path.lineTo(tip.dx, tip.dy);
      return path;
    }

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    // The whole trace, dim.
    canvas.drawPath(through(steps), stroke..color = color.withValues(alpha: live ? 0.2 : 0.35)..strokeWidth = 2);
    if (!live) return;

    // The head moves by fractions of a point (not whole samples), so it glides instead of stepping.
    final f = (progress * steps).clamp(0.0, steps.toDouble());
    final i = f.floor().clamp(0, steps - 1);
    final tip = Offset.lerp(pts[i], pts[i + 1], f - i)!;

    // Bright tail behind the head: one path with a horizontal gradient, so it fades smoothly.
    const tail = 150;
    final from = math.max(0, i - tail);
    final tailPath = Path()..moveTo(pts[from].dx, pts[from].dy);
    for (var k = from + 1; k <= i; k++) {
      tailPath.lineTo(pts[k].dx, pts[k].dy);
    }
    tailPath.lineTo(tip.dx, tip.dy);
    final x0 = pts[from].dx;
    final x1 = math.max(tip.dx, x0 + 1);
    canvas.drawPath(
      tailPath,
      stroke
        ..shader = LinearGradient(colors: [color.withValues(alpha: 0.0), color]).createShader(Rect.fromLTRB(x0, 0, x1, size.height))
        ..strokeWidth = 2.8,
    );
    stroke.shader = null;
    canvas.drawCircle(tip, 7, Paint()..color = color.withValues(alpha: 0.18));
    canvas.drawCircle(tip, 3.2, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _HeartbeatPainter old) => old.progress != progress || old.color != color || old.live != live;
}
