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

  // Commercial KPIs the backend can't measure yet (it reports false until real data exists).
  final bool tracksBidTurnaround;
  final bool tracksEstimatingErrors;
  final bool tracksChangeOrders;
  final _Turnaround? turnaround;
  final _Turnaround? bidTurnaround;

  const _SalesKpis({
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
    return _SalesKpis(
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
class _TechKpis {
  final int jobs;
  final int laborJobs;
  final double laborDollars;
  final double? laborPerDay;
  final bool tracksPackages;
  final bool tracksEfficiency;
  const _TechKpis({
    required this.jobs,
    required this.laborJobs,
    required this.laborDollars,
    required this.laborPerDay,
    required this.tracksPackages,
    required this.tracksEfficiency,
  });

  factory _TechKpis.fromJson(Map<String, dynamic> j) {
    final tr = j['tracking'] is Map ? j['tracking'] as Map : const {};
    return _TechKpis(
      jobs: int.tryParse(_str(j['jobs'])) ?? 0,
      laborJobs: int.tryParse(_str(j['laborJobs'])) ?? 0,
      laborDollars: _num(j['laborDollars']) ?? 0,
      laborPerDay: _num(j['laborPerDay']),
      tracksPackages: _flag(tr, 'servicePackageCloseRate'),
      tracksEfficiency: _flag(tr, 'jobCompletionEfficiency'),
    );
  }
}

/// Field supervisor results (team level).
class _SupervisorKpis {
  final int scheduled;
  final int completed;
  final double? completionRatePct;
  final bool tracksOvertime;
  final bool tracksImprovement;
  const _SupervisorKpis({
    required this.scheduled,
    required this.completed,
    required this.completionRatePct,
    required this.tracksOvertime,
    required this.tracksImprovement,
  });

  factory _SupervisorKpis.fromJson(Map<String, dynamic> j) {
    final tr = j['tracking'] is Map ? j['tracking'] as Map : const {};
    return _SupervisorKpis(
      scheduled: int.tryParse(_str(j['scheduled'])) ?? 0,
      completed: int.tryParse(_str(j['completed'])) ?? 0,
      completionRatePct: _num(j['completionRatePct']),
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
  const _KpiBundle(this.sales, this.tech, this.supervisor, this.office);
}

/// From /api/tech_stats: this year's callbacks and completed jobs for one tech, plus the team's callback rate.
class _TechStats {
  final int callbacks;
  final int completedJobs;
  final double? teamCallbackRatePct;
  const _TechStats(this.callbacks, this.completedJobs, this.teamCallbackRatePct);

  double? get callbackRatePct => completedJobs > 0 ? callbacks / completedJobs * 100 : null;
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
  _TechKpis? tech;
  _SupervisorKpis? supervisor;
  _ReceivablesKpis? office;

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

Future<_EmployeeDetails> _loadDetails(String username) async {
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
    if (body is! Map) return null;
    Map<String, dynamic>? part(String key) => body[key] is Map ? Map<String, dynamic>.from(body[key] as Map) : null;
    final sales = part('sales'), tech = part('tech'), sup = part('supervisor'), office = part('office');
    return _KpiBundle(
      sales == null ? null : _SalesKpis.fromJson(sales),
      tech == null ? null : _TechKpis.fromJson(tech),
      sup == null ? null : _SupervisorKpis.fromJson(sup),
      office == null ? null : _ReceivablesKpis.fromJson(office),
    );
  } catch (_) {
    return null;
  }
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
    final metrics = body['summary'] is Map && (body['summary'] as Map)['metrics'] is Map
        ? (body['summary'] as Map)['metrics'] as Map
        : const {};
    for (final t in techs) {
      if (t is Map && _str(t['id']).toLowerCase() == username.toLowerCase()) {
        return _TechStats(
          int.tryParse(_str(t['callbackCount'])) ?? 0,
          int.tryParse(_str(t['completedJobsYtd'])) ?? 0,
          _num(metrics['callbackRatePct']),
        );
      }
    }
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
    final initial = extra is _EmployeeKpiArgs
        ? extra as _EmployeeKpiArgs
        : null;
    final user = initial?.entry.user;
    return DashboardLayout(
      title: 'Employee KPI',
      subtitle: user == null ? null : '${user.name} · ${user.jobTitle}',
      showYearSelector: false,
      actions: [
        TextButton.icon(
          onPressed: () => context.go('/hr/kpis'),
          icon: const Icon(Icons.arrow_back_rounded),
          label: const Text('All employees'),
          style: TextButton.styleFrom(foregroundColor: Colors.white),
        ),
      ],
      builder: (context, _) =>
          _EmployeeKpiBody(employeeId: employeeId, initial: initial),
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

  @override
  void initState() {
    super.initState();
    _data = widget.initial;
    if (_data == null) _load();
    _fetchDetails();
  }

  Future<void> _fetchDetails() async {
    setState(() {
      _detailsLoading = true;
      _detailsError = null;
    });
    try {
      final d = await _loadDetails(widget.employeeId);
      if (!mounted) return;
      setState(() {
        _details = d;
        _detailsLoading = false;
      });
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
      padding: 24,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: DashAvatar(
              name: user.name,
              imageUrl: user.avatarUrl,
              size: 120,
              ringColor: rank == 1 ? _gold : null,
              ringWidth: rank == 1 ? 3 : 0,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            user.name,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: _ink),
          ),
          const SizedBox(height: 2),
          Text(
            user.jobTitle,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14.5, color: _slate),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              if (rank != null) _Pill(icon: Icons.emoji_events_rounded, text: 'Rank #$rank', color: rank == 1 ? _gold : _slate),
              if (milestone != null) _Pill(icon: Icons.workspace_premium_rounded, text: milestone, color: DashUi.indigo),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: scoreColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: scoreColor.withValues(alpha: 0.25)),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 54,
                  height: 54,
                  child: CustomPaint(
                    painter: _RingPainter(progress: score == null ? 0 : (score / 100).clamp(0.0, 1.0), color: scoreColor),
                    child: Center(child: Icon(Icons.verified_rounded, size: 19, color: scoreColor)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'INTEGRITY SCORE',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _slate, letterSpacing: 0.8),
                      ),
                      Text(
                        score == null ? '—' : '${_fmtNum(score)}%',
                        style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: scoreColor, height: 1.1),
                      ),
                      if (delta != null)
                        Text(
                          delta.abs() < 0.05
                              ? 'At team average'
                              : '${delta >= 0 ? '▲' : '▼'} ${delta.abs().toStringAsFixed(1)} vs team avg',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: delta.abs() < 0.05 ? _slate : (delta >= 0 ? DashUi.emeraldDeep : DashUi.amber),
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

    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 900;
        return SingleChildScrollView(
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 300, child: profile),
                    const SizedBox(width: 16),
                    Expanded(child: _moreGroups()),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [profile, const SizedBox(height: 16), _moreGroups()],
                ),
        );
      },
    );
  }

  /// One card per topic under the header card. Every employee gets the same cards; which ones show depends on the role.
  Widget _moreGroups() {
    if (_detailsLoading) {
      return const SkeletonPulse(child: SkeletonBox(h: 170, r: 18));
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

    final ts = d.techStats;
    final strikes = <_InfoRow>[
      if (d.isTech) _InfoRow('Inventory strikes (all-time)', '${d.inventoryStrikes}', strikeColor(d.inventoryStrikes)),
      if (d.isTech)
        ts == null
            ? const _InfoRow('Callback strikes (this year)', '—')
            : _InfoRow('Callback strikes (this year)', '${ts.callbacks}', strikeColor(ts.callbacks)),
      if (d.isWarehouse) _InfoRow('Warehouse strikes (all-time)', '${d.warehouseStrikes}', strikeColor(d.warehouseStrikes)),
    ];

    final sales = d.sales;
    final bids = sales?.bids;
    final showTypes = sales != null &&
        (sales.byType.length > 1 || (sales.byType.length == 1 && sales.byType.first.type != 'Uncategorized'));
    final commercial = <Widget>[
      if (sales != null && bids != null)
        _DetailCard(
          title: 'Bidding',
          icon: Icons.gavel_rounded,
          child: _InfoGroup(
            title: '',
            rows: [
              _InfoRow(
                'Bid close rate (${bids.wonCount} won · ${bids.lostCount} lost · ${bids.openCount} open)',
                bids.closeRatePct == null ? '—' : '${_fmtNum(bids.closeRatePct!)}%',
              ),
              sales.bidTurnaround != null
                  ? _InfoRow(
                      'Bid turnaround, creation to provided (${sales.bidTurnaround!.count} bids, median ${_fmtNum(sales.bidTurnaround!.medianDays)})',
                      sales.bidTurnaround!.avgText,
                    )
                  : untracked('Bid turnaround time', sales.tracksBidTurnaround),
              untracked('Estimating errors / missed scope', sales.tracksEstimatingErrors),
              untracked('Change-order opportunities identified', sales.tracksChangeOrders),
            ],
          ),
        ),
      if (sales != null && showTypes)
        _DetailCard(
          title: 'Gross profit and markup by project type',
          icon: Icons.category_rounded,
          trailing: 'Won estimates',
          child: _TypeTable(types: sales.byType),
        ),
    ];

    // Technician performance (every tech, including the supervisor).
    final tech = d.tech;
    final techCard = tech == null
        ? null
        : _DetailCard(
            title: 'Technician performance',
            icon: Icons.build_rounded,
            trailing: '${DateTime.now().year} year to date',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _FigureRow([
                  _BigStat('LABOR DOLLARS PRODUCED', tech.laborJobs == 0 ? '—' : dashMoney(tech.laborDollars), DashUi.sky,
                      sub: tech.jobs == 0
                          ? 'No verified work days yet'
                          : 'On ${tech.laborJobs} of ${tech.jobs} jobs with labor data'),
                  _BigStat('LABOR PER DAY', tech.laborPerDay == null ? '—' : dashMoney(tech.laborPerDay!), DashUi.blue,
                      sub: 'Per day on those jobs'),
                  _BigStat(
                    'CALLBACK RATE',
                    ts?.callbackRatePct == null ? '—' : '${_fmtNum(ts!.callbackRatePct!)}%',
                    ts?.callbackRatePct == null ? _ink : _callbackColor(ts!.callbackRatePct!),
                    sub: ts == null ? 'Could not load' : '${ts.callbacks} callbacks · ${ts.completedJobs} jobs',
                  ),
                ]),
                const SizedBox(height: 16),
                _InfoGroup(title: '', rows: [
                  untracked('Service package close rate', tech.tracksPackages),
                  untracked('Job completion efficiency', tech.tracksEfficiency),
                ]),
              ],
            ),
          );

    final sup = d.supervisor;
    final supCard = sup == null
        ? null
        : _DetailCard(
            title: 'Field supervision',
            icon: Icons.groups_rounded,
            trailing: 'Whole team, ${DateTime.now().year} year to date',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _FigureRow([
                  _BigStat(
                    'TEAM CALLBACK RATE',
                    ts?.teamCallbackRatePct == null ? '—' : '${_fmtNum(ts!.teamCallbackRatePct!)}%',
                    ts?.teamCallbackRatePct == null ? _ink : _callbackColor(ts!.teamCallbackRatePct!),
                    sub: 'Callbacks over jobs, all techs',
                  ),
                  _BigStat(
                    'JOBS COMPLETED VS SCHEDULED',
                    '${sup.completed} of ${sup.scheduled}',
                    _ink,
                    sub: sup.completionRatePct == null ? null : '${_fmtNum(sup.completionRatePct!)}% completed',
                  ),
                ]),
                const SizedBox(height: 16),
                _InfoGroup(title: '', rows: [
                  untracked('Overtime / production efficiency', sup.tracksOvertime),
                  untracked('Technician performance improvement', sup.tracksImprovement),
                ]),
              ],
            ),
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
                _InfoGroup(title: '', rows: [
                  untracked('Call answer rate', off.tracksCallAnswer),
                  untracked('Missed-call response time', off.tracksMissedCall),
                  untracked('Lead-to-booked-job rate', off.tracksLeadToBooked),
                  untracked('Customer response time', off.tracksCustomerResponse),
                ]),
              ],
            ),
          );

    final smaller = <Widget>[
      if (strikes.isNotEmpty)
        _DetailCard(title: 'Strikes', icon: Icons.warning_amber_rounded, child: _InfoGroup(title: '', rows: strikes)),
      if (d.isTech)
        _DetailCard(
          title: 'Activity',
          icon: Icons.event_note_rounded,
          child: _InfoGroup(
            title: '',
            rows: [
              _InfoRow('Work days, last 90 days', d.workDays90?.toString() ?? '—'),
              _InfoRow('Last worked', d.lastWorkDate ?? '—'),
            ],
          ),
        ),
    ];

    final wideCards = <Widget>[
      if (sales != null) _salesCard(sales),
      ?techCard,
      ?supCard,
      ?officeCard,
    ];

    if (wideCards.isEmpty && smaller.isEmpty && commercial.isEmpty) {
      return const _DetailCard(
        child: Text('No further KPIs are tracked for this role yet.', style: TextStyle(fontSize: 13.5, color: _slate)),
      );
    }

    Widget gap = const SizedBox(height: 16);
    Widget pair(List<Widget> items, {List<int>? flex, double breakpoint = 700}) => LayoutBuilder(
          builder: (context, c) {
            if (c.maxWidth < breakpoint) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (var i = 0; i < items.length; i++) ...[if (i > 0) gap, items[i]]],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const SizedBox(width: 16),
                  Expanded(flex: flex == null ? 1 : flex[i], child: items[i]),
                ],
              ],
            );
          },
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < wideCards.length; i++) ...[if (i > 0) gap, wideCards[i]],
        if (commercial.isNotEmpty) ...[
          if (wideCards.isNotEmpty) gap,
          pair(commercial, flex: commercial.length == 2 ? const [2, 3] : null, breakpoint: 900),
        ],
        if (smaller.isNotEmpty) ...[
          if (wideCards.isNotEmpty || commercial.isNotEmpty) gap,
          pair(smaller),
        ],
      ],
    );
  }

  Widget _salesCard(_SalesKpis s) {
    final closed = s.wonCount + s.lostCount;
    final partial = s.wonWithProfit < s.wonCount;
    final figures = [
      _BigStat(
        'ESTIMATE CLOSE RATE',
        s.closeRatePct == null ? '—' : '${_fmtNum(s.closeRatePct!)}%',
        _ink,
        sub: '${s.wonCount} won · ${s.lostCount} lost',
      ),
      _BigStat(
        'SALES DOLLARS WON',
        dashMoney(s.wonValue),
        DashUi.sky,
        sub: '${s.wonCount} estimates',
      ),
      _BigStat(
        'GROSS PROFIT',
        dashMoney(s.grossProfit),
        DashUi.blue,
        sub: s.marginPct == null ? null : '${_fmtNum(s.marginPct!)}% of sales',
      ),
      _BigStat(
        'MARKUP',
        s.markupPct == null ? '—' : '${_fmtNum(s.markupPct!)}%',
        DashUi.blue,
        sub: partial
            ? 'On ${s.wonWithProfit} of ${s.wonCount} won (rest have no profit)'
            : 'Profit over cost',
      ),
    ];

    return _DetailCard(
      title: 'Sales performance',
      icon: Icons.trending_up_rounded,
      trailing: '${DateTime.now().year} year to date',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, c) {
              if (c.maxWidth < 700) {
                return Wrap(
                  spacing: 24,
                  runSpacing: 16,
                  children: [
                    for (final f in figures)
                      SizedBox(width: (c.maxWidth - 24) / 2, child: f),
                  ],
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
          ),
          if (s.turnaround != null) ...[
            const SizedBox(height: 16),
            _InfoGroup(
              title: '',
              rows: [
                _InfoRow(
                  'Estimate turnaround, creation to provided (${s.turnaround!.count} estimates, median ${_fmtNum(s.turnaround!.medianDays)})',
                  s.turnaround!.avgText,
                ),
              ],
            ),
          ],
          if (closed > 0) ...[
            const SizedBox(height: 20),
            Semantics(
              label: '${s.wonCount} estimates won, ${s.lostCount} lost',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  height: 8,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        flex: s.wonCount,
                        child: const ColoredBox(color: DashUi.emerald),
                      ),
                      if (s.lostCount > 0)
                        Expanded(
                          flex: s.lostCount,
                          child: const ColoredBox(color: DashUi.red),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  '${s.wonCount} won',
                  style: const TextStyle(fontSize: 12, color: _slate),
                ),
                const Spacer(),
                Text(
                  '${s.lostCount} lost',
                  style: const TextStyle(fontSize: 12, color: _slate),
                ),
              ],
            ),
          ],
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
  final Widget child;
  const _DetailCard({
    this.title,
    this.icon,
    this.trailing,
    this.padding = 22,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(padding),
      decoration: DashUi.panel(radius: 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
          child,
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

/// Per project type: how many estimates, how many won, dollars won, gross profit and markup.
class _TypeTable extends StatelessWidget {
  final List<_TypeKpis> types;
  const _TypeTable({required this.types});

  @override
  Widget build(BuildContext context) {
    const head = TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _muted, letterSpacing: 0.6);
    const cell = TextStyle(fontSize: 13.5, color: _ink);

    Widget row(List<String> v, {bool header = false, bool muted = false}) {
      final style = header ? head : cell.copyWith(color: muted ? _muted : _ink);
      return Container(
        padding: EdgeInsets.symmetric(vertical: header ? 6 : 10),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: _line))),
        child: Row(
          children: [
            Expanded(flex: 5, child: Text(header ? v[0].toUpperCase() : v[0], style: style.copyWith(fontWeight: header ? null : FontWeight.w600))),
            for (var i = 1; i < v.length; i++)
              Expanded(
                flex: i == 3 || i == 4 ? 4 : 3,
                child: Text(header ? v[i].toUpperCase() : v[i], textAlign: TextAlign.right, style: style),
              ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, c) {
        final table = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            row(['Project type', 'Estimates', 'Won', 'Dollars won', 'Gross profit', 'Markup'], header: true),
            for (final t in types)
              row(
                [
                  t.type,
                  '${t.estimates}',
                  '${t.wonCount}',
                  t.wonCount == 0 ? '—' : dashMoney(t.wonValue),
                  t.wonCount == 0 ? '—' : dashMoney(t.grossProfit),
                  t.markupPct == null ? '—' : '${_fmtNum(t.markupPct!)}%',
                ],
                muted: t.wonCount == 0,
              ),
          ],
        );
        if (c.maxWidth >= 480) return table;
        return SingleChildScrollView(scrollDirection: Axis.horizontal, child: SizedBox(width: 480, child: table));
      },
    );
  }
}

/// Callback rate colour: low is good. Thresholds are a judgement call, kept in one place.
Color _callbackColor(double pct) => pct <= 2 ? DashUi.emerald : (pct <= 5 ? DashUi.amber : DashUi.red);

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
