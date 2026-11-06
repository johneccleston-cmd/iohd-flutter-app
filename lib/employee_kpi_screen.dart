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

/// Open estimates in dollars: by stage, and how much of it has gone quiet (same stale rules as the Stale estimates card).
class _Pipeline {
  final int requestedCount;
  final double requestedValue;
  final int providedCount;
  final double providedValue;
  final double staleValue;
  const _Pipeline(this.requestedCount, this.requestedValue, this.providedCount, this.providedValue, this.staleValue);

  int get count => requestedCount + providedCount;
  double get value => requestedValue + providedValue;
  double get quietValue => staleValue.clamp(0.0, value);
  double get activeValue => value - quietValue;

  static _Pipeline? fromJson(dynamic j) {
    if (j is! Map) return null;
    final r = j['requested'] is Map ? j['requested'] as Map : const {};
    final p = j['provided'] is Map ? j['provided'] as Map : const {};
    return _Pipeline(
      int.tryParse(_str(r['count'])) ?? 0,
      _num(r['value']) ?? 0,
      int.tryParse(_str(p['count'])) ?? 0,
      _num(p['value']) ?? 0,
      _num(j['staleValue']) ?? 0,
    );
  }
}

/// The biggest job of the year the person is an agent on.
class _BigDeal {
  final double amount;
  final String customer;
  final String date; // "2026-09-25", the job's start date
  const _BigDeal(this.amount, this.customer, this.date);

  static _BigDeal? fromJson(dynamic j) {
    if (j is! Map) return null;
    final amount = _num(j['amount']);
    if (amount == null || amount <= 0) return null;
    final who = _str(j['customer']).trim();
    return _BigDeal(amount, who.isEmpty ? 'A customer' : who, _str(j['date']));
  }
}

/// Sales results for the year, from /api/employees/:id/kpis.
class _SalesKpis {
  final int wonCount;
  final int lostCount;
  final double? closeRatePct;
  final double wonValue;
  final double grossProfit;
  final double? markupPct; // profit / cost (not shown; the scorecard uses margin)
  final double? marginPct; // profit / revenue
  /// How many of the agent jobs carry a profit figure (the margin counts only those); null when the server doesn't say.
  final int? wonWithProfit;

  /// The jobs behind [wonValue] and [grossProfit]: the ones this person is an Agent on in Service Fusion. Null from an older
  /// server, which counted won estimates instead (then [wonCount] is the count that goes with those figures).
  final int? jobCount;
  int get jobsWon => jobCount ?? wonCount;
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

  /// Won revenue and profit per month (January first) on the agent jobs, for each bucket (the kind of estimate the job came from): [hard bid, commercial, residential, other].
  /// Empty until the backend sends `monthlyByType`.
  final List<List<double>> monthlyRevenue;
  final List<List<double>> monthlyProfit;

  /// The won revenue on jobs that carry a profit figure, same shape (what a margin divides by); empty from an
  /// older server, which only sends all won revenue.
  final List<List<double>> monthlyRevenueWithProfit;

  /// The salesperson's focus from the backend ("Residential Sales", "Commercial Sales"); empty if not sent.
  final String focus;
  bool get residential => focus.toLowerCase().startsWith('residential');

  // Commercial KPIs the backend can't measure yet (it reports false until real data exists).
  final bool tracksBidTurnaround;
  final bool tracksEstimatingErrors;
  final bool tracksChangeOrders;
  final _Turnaround? turnaround;
  final _Turnaround? bidTurnaround;

  /// "Sep 10": the status log is only trusted from this day, so turnaround and late counts start here, not in January.
  final String? since;

  /// The same day as a date (2026-09-10): a year before it has no turnaround or late figures at all.
  final DateTime? trackedFrom;

  /// Won and lost estimates per month (January first); empty until the backend sends `monthlyClose`.
  final List<int> closeWon;
  final List<int> closeLost;
  final _Pipeline? pipeline;
  final _BigDeal? largestDeal;

  const _SalesKpis({
    this.since,
    this.trackedFrom,
    this.jobCount,
    this.monthlyRevenueWithProfit = const [],
    this.closeWon = const [],
    this.closeLost = const [],
    this.pipeline,
    this.largestDeal,
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
    // revenueWithProfit is newer than the rest of monthlyByType: without it the margins fall back to all won revenue.
    final havePriced = mbt.values.any((l) => l is List && l.any((c) => c is Map && c.containsKey('revenueWithProfit')));
    final mc = j['monthlyClose'] is List ? j['monthlyClose'] as List : const [];
    int closeAt(int m, String key) => m < mc.length && mc[m] is Map ? int.tryParse(_str((mc[m] as Map)[key])) ?? 0 : 0;
    return _SalesKpis(
      closeWon: mc.isEmpty ? const [] : [for (var m = 0; m < 12; m++) closeAt(m, 'won')],
      closeLost: mc.isEmpty ? const [] : [for (var m = 0; m < 12; m++) closeAt(m, 'lost')],
      pipeline: _Pipeline.fromJson(j['pipeline']),
      largestDeal: _BigDeal.fromJson(j['largestDeal']),
      monthlyRevenue: haveMonthly ? [series('hardBid', 'revenue'), series('commercial', 'revenue'), series('residential', 'revenue'), series('other', 'revenue')] : const [],
      monthlyProfit: haveMonthly ? [series('hardBid', 'profit'), series('commercial', 'profit'), series('residential', 'profit'), series('other', 'profit')] : const [],
      monthlyRevenueWithProfit: haveMonthly && havePriced
          ? [series('hardBid', 'revenueWithProfit'), series('commercial', 'revenueWithProfit'), series('residential', 'revenueWithProfit'), series('other', 'revenueWithProfit')]
          : const [],
      staleEstimates: int.tryParse(_str(strikes['staleEstimates'])),
      slowEstimates: int.tryParse(_str(strikes['slowEstimates'])),
      focus: _str(j['focus']),
      since: _shortDay(_str(j['turnaroundSince'])),
      trackedFrom: DateTime.tryParse(_str(j['turnaroundSince'])),
      openEstimates: int.tryParse(_str(strikes['openEstimates'])),
      agingEstimates: int.tryParse(_str(strikes['agingEstimates'])),
      satisfaction: _Rating.fromJson(j['satisfaction']),
      mentions: [
        for (final m in (j['reviews'] is List ? j['reviews'] as List : const []))
          ?_Mention.fromJson(m),
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
      wonWithProfit: cov is Map ? int.tryParse(_str(cov['withProfit'])) : null,
      jobCount: int.tryParse(_str(j['jobCount'])),
    );
  }
}

bool _flag(Map m, String key) => m[key] == true;

/// "2026-09-10" -> "Sep 10"; null for anything else.
String? _shortDay(String iso) {
  final d = DateTime.tryParse(iso);
  return d == null ? null : '${_monthLetters[d.month - 1]} ${d.day}';
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
  final DateTime? date;
  final double? stars; // 1-5 when the source has a rating (Google), else null
  const _Mention(this.quote, this.customer, [this.source, this.date, this.stars]);

  /// "Jul 2026" for the footer; reviews span years, so the date matters.
  String? get when {
    final d = date;
    if (d == null) return null;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[d.month - 1]} ${d.year}';
  }

  static _Mention? fromJson(dynamic j) {
    if (j is! Map) return null;
    final quote = _str(j['quote']).trim();
    if (quote.isEmpty) return null;
    final who = _str(j['customer']).trim();
    final src = _str(j['source']).trim();
    // The numeric field is the source of truth; the "Google · 5★" label is only read for a backend that predates it.
    final rating = j['rating'] is num
        ? (j['rating'] as num).toDouble()
        : double.tryParse(_str(j['rating'])) ?? double.tryParse(RegExp(r'(\d)★').firstMatch(src)?.group(1) ?? '');
    final stars = rating != null && rating >= 1 && rating <= 5 ? rating : null;
    return _Mention(quote, who.isEmpty ? 'A customer' : who, src.isEmpty ? null : src, DateTime.tryParse(_str(j['date']))?.toLocal(), stars);
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
  final _Rating? satisfaction;
  final List<_Mention> mentions;

  /// Cash collected per calendar month, January first (12 entries). Empty until the backend sends it.
  final List<double> collectedMonthly;

  /// New leads and the ones booked as jobs, per calendar month (12 entries each). Empty until the backend sends
  /// `leadToBooked: {leads: [...], booked: [...]}`; nothing records leads yet.
  final List<double> leadsMonthly;
  final List<double> bookedMonthly;

  /// Incoming Quo calls to this person, and how many nobody answered, per calendar month (12 entries each). Empty
  /// when the backend can't match them to a Quo user (or is an older build).
  final List<double> missedMonthly;
  final List<double> callsMonthly;

  /// The same, per weekday for the last 30 days, oldest first (`missedCalls.daily`). Empty on an older backend.
  final List<_MissedDay> missedDaily;

  /// How long the customers behind those missed calls waited for a call back (`missedCalls.callbacks`, from Quo). Null
  /// from an older server, or when the server couldn't work it out.
  final _Callbacks? callbacks;
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
    this.satisfaction,
    this.mentions = const [],
    this.collectedMonthly = const [],
    this.leadsMonthly = const [],
    this.bookedMonthly = const [],
    this.missedMonthly = const [],
    this.callsMonthly = const [],
    this.missedDaily = const [],
    this.callbacks,
  });

  /// The same figures with the Collections dashboard's numbers swapped in (outstanding, over 90, cash, aging stages),
  /// so this page can never disagree with that screen.
  _ReceivablesKpis withCollections(Map body) {
    double d(dynamic v) => _num(v) ?? 0;
    final sum = body['summary'] is Map ? body['summary'] as Map : const {};
    final stages = body['stages'] is List ? body['stages'] as List : const [];
    final monthly = List<double>.filled(12, 0);
    for (final e in (body['monthly'] is List ? body['monthly'] as List : const [])) {
      final m = int.tryParse(_str(e is Map ? e['month_num'] : null)) ?? 0;
      if (m >= 1 && m <= 12) monthly[m - 1] = d((e as Map)['collected']);
    }
    final rows = [
      for (final r in stages)
        if (r is Map) _AgingRow(_str(r['label']), d(r['amount']), int.tryParse(_str(r['jobCount'])) ?? 0),
    ];
    final out = _num(sum['outstanding']) ?? rows.fold<double>(0, (t, a) => t + a.amount);
    final cash = d(sum['collected']);
    return _ReceivablesKpis(
      outstanding: out,
      over90: _num(sum['over90']) ?? over90,
      collected: cash,
      collectionRatePct: cash + out > 0 ? (cash / (cash + out) * 1000).round() / 10 : null,
      aging: rows.isEmpty ? aging : rows,
      tracksCallAnswer: tracksCallAnswer,
      tracksMissedCall: tracksMissedCall,
      tracksLeadToBooked: tracksLeadToBooked,
      tracksCustomerResponse: tracksCustomerResponse,
      satisfaction: satisfaction,
      mentions: mentions,
      collectedMonthly: monthly,
      leadsMonthly: leadsMonthly,
      bookedMonthly: bookedMonthly,
      missedMonthly: missedMonthly,
      callsMonthly: callsMonthly,
      missedDaily: missedDaily,
      callbacks: callbacks,
    );
  }

  factory _ReceivablesKpis.fromJson(Map<String, dynamic> j) {
    final tr = j['tracking'] is Map ? j['tracking'] as Map : const {};
    final rows = j['aging'] is List ? j['aging'] as List : const [];
    final ltb = j['leadToBooked'] is Map ? j['leadToBooked'] as Map : const {};
    List<double> series(dynamic v) => [for (final x in (v is List ? v : const [])) _num(x) ?? 0];
    final mc = j['missedCalls'] is Map ? j['missedCalls'] as Map : const {};
    return _ReceivablesKpis(
      callbacks: _Callbacks.fromJson(mc['callbacks']),
      missedMonthly: series(mc['missed']),
      callsMonthly: series(mc['total']),
      missedDaily: [
        for (final e in (mc['daily'] is List ? mc['daily'] as List : const []))
          if (e is Map && DateTime.tryParse(_str(e['date'])) != null) _MissedDay(DateTime.parse(_str(e['date'])), (_num(e['missed']) ?? 0).round(), (_num(e['total']) ?? 0).round()),
      ],
      leadsMonthly: series(ltb['leads']),
      bookedMonthly: series(ltb['booked']),
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
      collectedMonthly: [for (final v in (j['collectedMonthly'] is List ? j['collectedMonthly'] as List : const [])) _num(v) ?? 0],
      satisfaction: _Rating.fromJson(j['satisfaction']),
      mentions: [
        for (final m in (j['reviews'] is List ? j['reviews'] as List : const []))
          ?_Mention.fromJson(m),
      ],
    );
  }
}

/// One cycle count zone in its current period (the warehouse works a zone Wed-Fri of its week).
class _ZoneCount {
  final String zone;
  final String periodStart; // 'YYYY-MM-DD'
  final String status; // Complete / In progress / Not started
  final int counted;
  final DateTime? completedAt;

  /// The work week is over and the zone isn't complete.
  final bool overdue;
  const _ZoneCount(this.zone, this.periodStart, this.status, this.counted, this.completedAt, this.overdue);

  bool get complete => status == 'Complete';

  factory _ZoneCount.fromJson(Map j) => _ZoneCount(
        _str(j['zone']),
        _str(j['periodStart']),
        _str(j['status']),
        int.tryParse(_str(j['counted'])) ?? 0,
        DateTime.tryParse(_str(j['completedAt']))?.toLocal(),
        j['overdue'] == true,
      );
}

/// Purchase orders still waiting to be received (status Open), from the warehouse part of /api/employees/:id/kpis.
class _OpenPos {
  final int count;
  final double value;

  /// Open POs whose expected date has passed.
  final int overdue;

  /// Order date of the oldest open PO.
  final DateTime? oldest;

  /// Open POs grouped by days since ordered: (label, count, value).
  final List<(String, int, double)> aging;
  const _OpenPos({required this.count, required this.value, required this.overdue, required this.oldest, this.aging = const []});

  factory _OpenPos.fromJson(Map j) => _OpenPos(
        count: int.tryParse(_str(j['count'])) ?? 0,
        value: _num(j['value']) ?? 0,
        overdue: int.tryParse(_str(j['overdue'])) ?? 0,
        oldest: DateTime.tryParse(_str(j['oldest'])),
        aging: [
          for (final a in (j['aging'] is List ? j['aging'] as List : const []))
            if (a is Map) (_str(a['label']), int.tryParse(_str(a['count'])) ?? 0, _num(a['value']) ?? 0),
        ],
      );
}

/// The warehouse team's page from /api/employees/:id/kpis (company-wide: nothing says which person counted what).
/// This year's stock gaps added up: items, units and dollars (at cost) short and extra.
class _GapTotals {
  final int shortItems, extraItems, shortUnits, extraUnits;
  final double shortValue, extraValue;
  const _GapTotals({
    required this.shortItems,
    required this.extraItems,
    required this.shortUnits,
    required this.extraUnits,
    required this.shortValue,
    required this.extraValue,
  });

  factory _GapTotals.fromJson(Map j) {
    int n(String k) => int.tryParse(_str(j[k])) ?? 0;
    return _GapTotals(
      shortItems: n('shortItems'),
      extraItems: n('extraItems'),
      shortUnits: n('shortUnits'),
      extraUnits: n('extraUnits'),
      shortValue: _num(j['shortValue']) ?? 0,
      extraValue: _num(j['extraValue']) ?? 0,
    );
  }

  int get items => shortItems + extraItems;
}

/// The stock as it stands today. Of the items with a reorder point: [empty] (none on hand), [low] (some, at or below
/// the point) and [ok]; then the active items missing a reorder point, a shelf location or a cost.
class _StockHealth {
  final int empty, low, ok, noReorder, noLocation, noCost;

  /// The categories with the most empty or low items, most first: (category, empty, low, ok).
  final List<(String, int, int, int)> byCategory;
  const _StockHealth({
    required this.empty,
    required this.low,
    required this.ok,
    required this.noReorder,
    required this.noLocation,
    required this.noCost,
    required this.byCategory,
  });

  factory _StockHealth.fromJson(Map j) {
    int n(dynamic v) => int.tryParse(_str(v)) ?? 0;
    return _StockHealth(
      empty: n(j['empty']),
      low: n(j['low']),
      ok: n(j['ok']),
      noReorder: n(j['noReorder']),
      noLocation: n(j['noLocation']),
      noCost: n(j['noCost']),
      byCategory: [
        for (final c in (j['byCategory'] is List ? j['byCategory'] as List : const []))
          if (c is Map) (_str(c['category']), n(c['empty']), n(c['low']), n(c['ok'])),
      ],
    );
  }

  /// Items with a reorder point set (the ones that can be low).
  int get tracked => empty + low + ok;
}

class _WarehouseKpis {
  /// All-time strikes on the shared warehouse login, where the 8:30 AM audit records them.
  final int strikes;
  final List<_ZoneCount> zones;
  final int cycleDone;
  final int itemsCounted;
  final DateTime? lastCycleCount;
  final int lowStockCount;

  /// All current techs' inventory strikes added up. Null until the backend sends it.
  final int? teamInventoryStrikes;
  final double stockValue;
  final int itemCount;

  /// Null until the backend sends it.
  final _OpenPos? openPos;

  /// This person's own callback strikes this year (warehouse staff install too). Null until the backend sends it.
  final int? callbackStrikes;

  /// Jobs this person completed this year (warehouse staff install too). Null until the backend sends it.
  final int? jobsCompleted;

  /// Jobs completed and cycle count zones finished per month (January first); empty until the backend sends them.
  final List<double> jobsMonthly;
  final List<double> cycleMonthly;

  /// Daily snapshots, oldest first, of low stock items and the techs' inventory strikes. They fill in as days pass.
  final List<double> lowStockHistory;
  final List<double> strikesHistory;

  /// Daily snapshots, oldest first, of the techs' inventory strikes plus this person's own: the team card's figure.
  /// Empty until the server has days of it.
  final List<double> teamStrikesWithMeHistory;

  /// Share of this year's counted items whose count matched the system quantity (0-100). Null until a count with
  /// quantities has been recorded.
  final double? accuracyPct;
  final int accuracyCounted;

  /// Weekly accuracy, oldest first: (week start 'YYYY-MM-DD', percent, items counted).
  final List<(String, double, int)> accuracyTrend;

  /// The items furthest off this year: (name, system quantity, counted quantity, cost each when known).
  final List<(String, int, int, double?)> topMisses;

  /// Every stock gap this year added up. Null when nothing was off, or from a server that doesn't send it.
  final _GapTotals? stockGaps;

  /// Active items that were on a zone count this year, and the stock value they hold. Null from an older server.
  final int? coverageItems;
  final double? coverageValue;

  /// Today's stock health (items with a reorder point that are empty, low or stocked; records missing a field). Null
  /// from an older server.
  final _StockHealth? stockHealth;

  /// Each zone's last scheduled weeks: zone, then (period start, Complete / Missed / Pending).
  final List<(String, List<(String, String)>)> cycleHistory;
  final bool tracksPickAccuracy;
  final bool tracksReceiving;
  final bool tracksOrderFill;
  const _WarehouseKpis({
    required this.strikes,
    required this.zones,
    required this.cycleDone,
    required this.itemsCounted,
    required this.lastCycleCount,
    required this.lowStockCount,
    this.teamInventoryStrikes,
    required this.stockValue,
    required this.itemCount,
    this.openPos,
    this.callbackStrikes,
    this.jobsCompleted,
    this.jobsMonthly = const [],
    this.cycleMonthly = const [],
    this.lowStockHistory = const [],
    this.strikesHistory = const [],
    this.teamStrikesWithMeHistory = const [],
    this.accuracyPct,
    this.accuracyCounted = 0,
    this.accuracyTrend = const [],
    this.topMisses = const [],
    this.stockGaps,
    this.coverageItems,
    this.coverageValue,
    this.stockHealth,
    this.cycleHistory = const [],
    required this.tracksPickAccuracy,
    required this.tracksReceiving,
    required this.tracksOrderFill,
  });

  factory _WarehouseKpis.fromJson(Map<String, dynamic> j) {
    final tr = j['tracking'] is Map ? j['tracking'] as Map : const {};
    final hist = j['history'] is Map ? j['history'] as Map : const {};
    List<double> numList(dynamic v) => [for (final x in (v is List ? v : const [])) _num(x) ?? 0];
    int n(dynamic v) => int.tryParse(_str(v)) ?? 0;
    return _WarehouseKpis(
      strikes: n(j['strikes']),
      zones: [for (final z in (j['zones'] is List ? j['zones'] as List : const [])) if (z is Map) _ZoneCount.fromJson(z)],
      cycleDone: n(j['cycleDone']),
      itemsCounted: n(j['itemsCounted']),
      lastCycleCount: DateTime.tryParse(_str(j['lastCycleCount']))?.toLocal(),
      lowStockCount: n(j['lowStockCount']),
      teamInventoryStrikes: int.tryParse(_str(j['teamInventoryStrikes'])),
      stockValue: _num(j['stockValue']) ?? 0,
      itemCount: n(j['itemCount']),
      openPos: j['openPos'] is Map ? _OpenPos.fromJson(j['openPos'] as Map) : null,
      callbackStrikes: int.tryParse(_str(j['callbackStrikes'])),
      jobsCompleted: int.tryParse(_str(j['jobsCompleted'])),
      jobsMonthly: numList(j['jobsMonthly']),
      cycleMonthly: numList(j['cycleMonthly']),
      lowStockHistory: numList(hist['lowStock']),
      strikesHistory: numList(hist['teamStrikes']),
      teamStrikesWithMeHistory: numList(hist['teamStrikesWithMe']),
      accuracyPct: j['inventoryAccuracy'] is Map ? _num((j['inventoryAccuracy'] as Map)['pct']) : null,
      accuracyCounted: j['inventoryAccuracy'] is Map ? int.tryParse(_str((j['inventoryAccuracy'] as Map)['counted'])) ?? 0 : 0,
      accuracyTrend: [
        for (final t in (j['accuracyTrend'] is List ? j['accuracyTrend'] as List : const []))
          if (t is Map && _num(t['pct']) != null) (_str(t['week']), _num(t['pct'])!, int.tryParse(_str(t['counted'])) ?? 0),
      ],
      topMisses: [
        for (final m in (j['topMisses'] is List ? j['topMisses'] as List : const []))
          if (m is Map) (_str(m['name']), int.tryParse(_str(m['systemQty'])) ?? 0, int.tryParse(_str(m['countedQty'])) ?? 0, _num(m['cost'])),
      ],
      stockGaps: j['stockGaps'] is Map ? _GapTotals.fromJson(j['stockGaps'] as Map) : null,
      coverageItems: j['coverage'] is Map ? int.tryParse(_str((j['coverage'] as Map)['items'])) : null,
      coverageValue: j['coverage'] is Map ? _num((j['coverage'] as Map)['value']) : null,
      stockHealth: j['stockHealth'] is Map ? _StockHealth.fromJson(j['stockHealth'] as Map) : null,
      cycleHistory: [
        for (final z in (j['cycleHistory'] is List ? j['cycleHistory'] as List : const []))
          if (z is Map)
            (
              _str(z['zone']),
              [for (final k in (z['weeks'] is List ? z['weeks'] as List : const [])) if (k is Map) (_str(k['periodStart']), _str(k['status']))],
            ),
      ],
      tracksPickAccuracy: _flag(tr, 'pickAccuracy'),
      tracksReceiving: _flag(tr, 'receivingTime'),
      tracksOrderFill: _flag(tr, 'orderFillRate'),
    );
  }
}

/// Everything /api/employees/:id/kpis can return for one person that this page shows. Each part is null when it
/// doesn't apply. (Technicians have their own page, employee_kpi_tech.dart.)
class _KpiBundle {
  final _SalesKpis? sales;
  final _ReceivablesKpis? office;
  final _WarehouseKpis? warehouse;

  /// Employee morale, 1-5. Every employee has one.
  final _Rating? morale;
  const _KpiBundle(this.sales, this.office, this.warehouse, this.morale);
}

/// Per-person facts from /api/admin/users (the same source as the Team screen).
class _EmployeeDetails {
  final int? userId;
  final String role;
  final int inventoryStrikes;
  final int warehouseStrikes;
  final int? workDays90; // null when the backend didn't send it
  final String? lastWorkDate;

  _SalesKpis? sales;
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
    throw Exception('The server had a problem (error ${res.statusCode}). Try again in a moment.');
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
    // Best effort: a failure leaves the role's figures out instead of failing the page.
    final k = await _loadKpis(id);
    found.sales = k?.sales;
    found.office = k?.office;
    if (found.office != null) {
      final c = await _loadCollections();
      if (c != null) found.office = found.office!.withCollections(c);
    }
    found.morale = k?.morale;
  }
  return found;
}

/// The Collections dashboard's own response for [year]. Best effort: null if it can't be loaded or the account has no
/// access to that dashboard, and the page keeps the numbers from the KPI request.
Future<Map?> _loadCollections() async {
  try {
    final res = await http
        .get(Uri.parse('$kApiBaseUrl/api/dashboards/collections?year=${DateTime.now().year}'), headers: AuthSession.instance.headers())
        .timeout(const Duration(seconds: 40));
    if (res.statusCode != 200) return null;
    final body = json.decode(res.body);
    return body is Map && body['summary'] is Map && body['stages'] is List ? body : null;
  } catch (_) {
    return null;
  }
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
  final sales = part('sales'), office = part('office'), wh = part('warehouse');
  return _KpiBundle(
    sales == null ? null : _SalesKpis.fromJson(sales),
    office == null ? null : _ReceivablesKpis.fromJson(office),
    wh == null ? null : _WarehouseKpis.fromJson(wh),
    _Rating.fromJson(body['morale']),
  );
}

/// Everything for one person in a single request (by username): GET /api/employees/:username/kpis. Falls back to the
/// older two-step path if the backend doesn't know usernames yet (it answers 400).
Future<_EmployeeDetails> _loadDetails(String username) async {
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
  if (res.statusCode != 200) throw Exception('The server had a problem (error ${res.statusCode}). Try again in a moment.');

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
  details.office = k.office;
  if (details.office != null) {
    final c = await _loadCollections();
    if (c != null) details.office = details.office!.withCollections(c);
  }
  details.morale = k.morale;
  return details;
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
    // Keyed by person: going from one employee's page to another's (a teammate's row) starts afresh.
    return _EmployeeKpiBody(key: ValueKey(employeeId), employeeId: employeeId, initial: initial);
  }
}

class _EmployeeKpiBody extends StatefulWidget {
  final String employeeId;
  final _EmployeeKpiArgs? initial;
  const _EmployeeKpiBody({super.key, required this.employeeId, required this.initial});

  @override
  State<_EmployeeKpiBody> createState() => _EmployeeKpiBodyState();
}

/// The connection hint under a failed load, only when the connection may be what failed (a server error already says
/// what to do).
String? _hint(String? error) =>
    error != null && error.contains('The server had a problem') ? null : 'Check your connection, then try again.';

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

  _Rating? _moraleOf(_EmployeeDetails d) => d.morale ?? (_sample ? _Rating(_sampleMorale[_sampleIdx % _sampleMorale.length], 9) : null);

  @override
  void initState() {
    super.initState();
    _data = widget.initial;
    // A technician's page loads its own figures (by year), so this page's are only fetched for other roles: now when
    // the role is known, or once the person has loaded on a direct link.
    if (_data == null) {
      _load();
    } else if (!_ownsPage) {
      _fetchDetails();
    }
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
      // Now the role is known: a technician's page loads its own figures.
      if (_data != null && !_ownsPage && _details == null) _fetchDetails();
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
    final data = _data;
    // A technician's and the warehouse's pages are dashboards of their own (title bar, year picker), so they bring
    // their own frame.
    if (!_loading && data != null && _looksLikeTech) {
      return _TechKpiPage(key: ValueKey(widget.employeeId), args: data, employeeId: widget.employeeId);
    }
    if (!_loading && data != null && _looksLikeWarehouse) {
      return _WarehouseKpiPage(key: ValueKey(widget.employeeId), args: data, employeeId: widget.employeeId);
    }
    if (!_loading && data != null && _looksLikeSales) {
      return _SalesKpiPage(key: ValueKey(widget.employeeId), args: data, employeeId: widget.employeeId);
    }
    // Whoever owns collections (the server sends the `office` part to no one else) gets the office dashboard. An office
    // role shows that page's frame and skeleton while the details load, so the old page never flashes up first.
    if (!_loading && data != null) {
      final hasOffice = _details?.office != null;
      if (hasOffice || (_detailsLoading && _looksLikeOffice)) {
        return _OfficeKpiPage(key: ValueKey(widget.employeeId), args: data, employeeId: widget.employeeId, pending: !hasOffice);
      }
    }
    if (!_loading && data != null) return _generalPage(data);
    // On a direct link the person is still loading (or wasn't found): the standard ribbon over a spinner or the error.
    return Material(
      color: AppTheme.bgColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageBanner(title: 'Employee KPIs', icon: accessIcon('hr_kpis')),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: DashUi.sky))
                : DashErrorPanel(title: "Couldn't load this employee", message: _error ?? 'Something went wrong.', hint: _hint(_error), onRetry: _load),
          ),
        ],
      ),
    );
  }

  /// A role with no KPI page of its own (an admin): the title bar every person's page has (photo, rank, milestone,
  /// integrity score), the morale card with its Preview, and a plain statement that nothing else is measured for the
  /// role. Nothing on it depends on a year, so there is no year picker. With so little to show, the two cards sit together
  /// in the middle of the page rather than along its top edge, and a failed load is the standard error panel.
  Widget _generalPage(_EmployeeKpiArgs data) {
    final user = data.entry.user;
    final tenure = user.yearsWorked == null ? null : '${_fmtTenure(user.yearsWorked)} at IOHD';
    return DashboardLayout(
      title: user.name,
      heading: user.name.toUpperCase(),
      subtitle: [user.displayTitle, ?tenure].join(' · '),
      leading: _HeaderLead(user: user, rank: data.entry.rank),
      titleTrailing: _HeaderBadges(args: data, ratings: null),
      showYearSelector: false,
      showFreshness: false,
      builder: (context, _) => LayoutBuilder(
        builder: (context, c) {
          if (!_detailsLoading && _details == null) {
            return DashErrorPanel(title: "Couldn't load employee details", message: _detailsError ?? 'Something went wrong.', hint: _hint(_detailsError), onRetry: _fetchDetails);
          }
          final wide = c.maxWidth >= 900;
          final morale = SizedBox(height: 230, child: _moraleCard() ?? const SizedBox.shrink());
          final info = _moreGroups();
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040),
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [SizedBox(width: 340, child: morale), const SizedBox(width: 16), Expanded(child: SizedBox(height: 230, child: info))],
                    )
                  : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [morale, const SizedBox(height: 12), info]),
            ),
          );
        },
      ),
    );
  }

  /// Morale card for the left column, under the profile card.
  Widget? _moraleCard() {
    final d = _details;
    if (d == null) return _detailsLoading ? const _SkelCard(h: 150, r: 18) : null;
    return _MoraleCard(
      title: "$_firstName's morale",
      rating: _moraleOf(d),
      isSample: d.morale == null && _sample,
      canPreview: d.morale == null,
      onTogglePreview: () => setState(() => _sample = !_sample),
      onCycle: () => setState(() => _sampleIdx++),
    );
  }

  /// First name for card titles ("John's Current Morale").
  String get _firstName {
    final n = (_data?.entry.user.name ?? '').trim();
    return n.isEmpty ? 'Employee' : n.split(RegExp(r'\s+')).first;
  }

  /// Whether the person's role says technician (the same test as the server's): they get the technician page. The
  /// stored role, not a title: Dennis is "Warehouse Technician" by title and "warehouse" by role.
  bool get _looksLikeTech => (_data?.entry.user.role ?? '').toLowerCase().contains('tech');

  /// Whether the stored role says office: Bella, and also others who turn out not to own collections.
  bool get _looksLikeOffice => !_looksLikeTech && !_looksLikeSales && (_data?.entry.user.role ?? '').toLowerCase().contains('office');

  /// Whether the role or the job title says sales: Zac (role Sales Rep) and Heather (role Office Manager, titled Sales
  /// Account Manager). They get the sales page, which loads its own figures by year.
  bool get _looksLikeSales {
    final u = _data?.entry.user;
    if (u == null || _looksLikeTech) return false;
    return u.role.toLowerCase().contains('sales') || u.displayTitle.toLowerCase().contains('sales');
  }

  /// Whether the stored role says warehouse (and not tech): they get the warehouse page.
  bool get _looksLikeWarehouse => !_looksLikeTech && (_data?.entry.user.role ?? '').toLowerCase().contains('warehouse');

  /// Whether the person's page loads its own figures (by year) instead of this page's.
  bool get _ownsPage => _looksLikeTech || _looksLikeWarehouse || _looksLikeSales;

  /// Beside the morale card: nothing else is tracked for these roles (the others have pages of their own).
  Widget _moreGroups() {
    if (_detailsLoading) return const _SkelCard(h: 170, r: 18);
    final role = _data?.entry.user.displayTitle ?? 'this';
    return _DetailCard(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('No performance figures for the $role role yet', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _ink)),
          const SizedBox(height: 6),
          Text(
            'KPI pages measure work the system records for a role, like labor billed for technicians or estimates won for sales. '
            "Nothing like that is recorded for this role, so $_firstName's page shows the integrity score, rank and time with IOHD "
            'in the title bar, and morale here.',
            style: const TextStyle(fontSize: 13.5, height: 1.4, color: _slate),
          ),
        ],
      ),
    );
  }
}

/// A white rounded card.
class _DetailCard extends StatelessWidget {
  final Widget child;
  const _DetailCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: DashUi.panel(radius: 18),
      child: child,
    );
  }
}

/// 0 = Commercial hard bid, 1 = other Commercial estimate, 2 = Residential, 3 = everything else, from an estimate category.
int _mixBucket(String category) {
  final c = category.toLowerCase();
  if (c.contains('hard bid')) return 0;
  if (c.contains('commercial')) return 1;
  if (c.contains('residential')) return 2;
  return 3;
}

const _mixLabels = ['Commercial hard bids', 'Commercial estimates', 'Residential', 'Other'];

/// The estimates behind one slice of the Estimate mix donut: customer, job number, status, date and value.
class _MixEstimatesDialog extends StatefulWidget {
  final String employeeId;
  final String name;
  final int bucket;
  final String label;
  final Color color;
  /// Also list the "Other" bucket (a residential rep's other estimates count as residential).
  final bool withOther;
  final int? year;
  const _MixEstimatesDialog({required this.employeeId, required this.name, required this.bucket, required this.label, required this.color, this.withOther = false, this.year});

  @override
  State<_MixEstimatesDialog> createState() => _MixEstimatesDialogState();
}

class _MixEstimate {
  final String jobId;
  final String customer;
  final String category;
  final String status;
  final String created;
  final double value;
  const _MixEstimate(this.jobId, this.customer, this.category, this.status, this.created, this.value);
}

class _MixEstimatesDialogState extends State<_MixEstimatesDialog> {
  List<_MixEstimate>? _items;
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
      Future<List<_MixEstimate>> fetch(int bucket) async {
        final res = await http
            .get(
              Uri.parse(
                '$kApiBaseUrl/api/employees/${Uri.encodeComponent(widget.employeeId)}/mix_estimates'
                '?year=${widget.year ?? DateTime.now().year}&bucket=$bucket',
              ),
              headers: AuthSession.instance.headers(),
            )
            .timeout(const Duration(seconds: 40));
        if (res.statusCode == 401) {
          AuthSession.instance.logout(); // sends the app back to the sign-in screen
          throw Exception('Your session expired. Please sign in again.');
        }
        if (res.statusCode != 200) throw Exception('The server had a problem (error ${res.statusCode}). Try again in a moment.');
        final body = json.decode(res.body);
        final list = body is Map && body['items'] is List ? body['items'] as List : const [];
        return [
          for (final e in list)
            if (e is Map) _MixEstimate(_str(e['jobId']), _str(e['customerName']), _str(e['category']), _str(e['status']), _str(e['created']), _num(e['value']) ?? 0),
        ];
      }

      final parts = await Future.wait([fetch(widget.bucket), if (widget.withOther) fetch(3)]);
      final items = [for (final p in parts) ...p];
      if (parts.length > 1) items.sort((a, b) => b.created.compareTo(a.created)); // newest first across both buckets
      if (!mounted) return;
      setState(() {
        _items = items;
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

  @override
  Widget build(BuildContext context) {
    const head = TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _muted, letterSpacing: 0.6);
    final Widget body;
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
        child: Center(child: Text('No ${widget.label.toLowerCase()} in ${widget.year ?? DashClock.now().year}.', style: const TextStyle(fontSize: 14, color: _slate))),
      );
    } else {
      body = Flexible(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 4, 24, 6),
              child: Row(
                children: [
                  Expanded(flex: 5, child: Text('CUSTOMER', style: head)),
                  Expanded(flex: 3, child: Text('STATUS', style: head, textAlign: TextAlign.right)),
                  Expanded(flex: 3, child: Text('DATE', style: head, textAlign: TextAlign.right)),
                  Expanded(flex: 2, child: Text('VALUE', style: head, textAlign: TextAlign.right)),
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
                          Text(e.customer.isEmpty ? 'Unknown' : e.customer, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _ink)),
                          Text(
                            '#${e.jobId}${e.category.isEmpty ? '' : ' · ${e.category}'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, color: _muted),
                          ),
                        ],
                      ),
                    ),
                    Expanded(flex: 3, child: Align(alignment: Alignment.centerRight, child: e.status.isEmpty ? const Text('—') : StatusPill(e.status))),
                    Expanded(flex: 3, child: Text(_prettyDate(e.created), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13.5, color: _slate))),
                    Expanded(flex: 2, child: Text(dashMoney(e.value), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: _ink))),
                  ],
                ),
              ),
          ],
        ),
      );
    }

    final n = _items?.length;
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
                  Icon(Icons.pie_chart_rounded, size: 20, color: widget.color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${widget.name} · ${widget.label}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: _ink)),
                        Text(
                          '${n == null ? '' : '$n ${n == 1 ? 'estimate' : 'estimates'} · '}${DateTime.now().year} year to date, newest first',
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

/// The callback visits behind a tech's strikes: customer, job, status and the date of the callback visit.
class _CallbackStrikesDialog extends StatefulWidget {
  final String employeeId;
  final String name;

  /// The year to list; this year when not given.
  final int? year;
  const _CallbackStrikesDialog({required this.employeeId, required this.name, this.year});

  @override
  State<_CallbackStrikesDialog> createState() => _CallbackStrikesDialogState();
}

class _CallbackStrikesDialogState extends State<_CallbackStrikesDialog> {
  List<_MixEstimate>? _items; // reuses the estimate row shape: value is unused here
  String? _error;
  bool _loading = true;

  int get _year => widget.year ?? DashClock.now().year;

  /// The stretch the list covers: strikes are counted from callback tracking's start (Oct 5, 2026), so that year's
  /// list is "since Oct 5, 2026", not the year to date.
  String get _period {
    final goLive = DateTime.parse(_callbackGoLive);
    if (_year == goLive.year) return 'since ${dashShortDate(_callbackGoLive)}, ${goLive.year}';
    return _year == DashClock.now().year ? '$_year year to date' : 'all of $_year';
  }

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
            Uri.parse('$kApiBaseUrl/api/employees/${Uri.encodeComponent(widget.employeeId)}/callbacks?year=$_year'),
            headers: AuthSession.instance.headers(),
          )
          .timeout(const Duration(seconds: 40));
      if (res.statusCode == 401) {
        AuthSession.instance.logout(); // sends the app back to the sign-in screen
        throw Exception('Your session expired. Please sign in again.');
      }
      if (res.statusCode != 200) throw Exception('The server had a problem (error ${res.statusCode}). Try again in a moment.');
      final body = json.decode(res.body);
      final list = body is Map && body['items'] is List ? body['items'] as List : const [];
      final items = [
        for (final e in list)
          if (e is Map) _MixEstimate(_str(e['jobId']), _str(e['customerName']), _str(e['category']), _str(e['status']), _str(e['date']), 0),
      ];
      if (!mounted) return;
      setState(() {
        _items = items;
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

  @override
  Widget build(BuildContext context) {
    const head = TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _muted, letterSpacing: 0.6);
    final Widget body;
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
            Text("Couldn't load the callbacks. $_error", textAlign: TextAlign.center, style: const TextStyle(fontSize: 13.5, color: _slate)),
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
            'No callback strikes ${_period.startsWith('since') ? _period : (_year == DashClock.now().year ? 'this year' : 'in $_year')}.',
            style: const TextStyle(fontSize: 14, color: _slate),
          ),
        ),
      );
    } else {
      body = Flexible(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 4, 24, 6),
              child: Row(
                children: [
                  Expanded(flex: 5, child: Text('CUSTOMER', style: head)),
                  Expanded(flex: 3, child: Text('STATUS', style: head, textAlign: TextAlign.right)),
                  Expanded(flex: 3, child: Text('CALLBACK DATE', style: head, textAlign: TextAlign.right)),
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
                          Text(e.customer.isEmpty ? 'Unknown' : e.customer, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _ink)),
                          Text('#${e.jobId}${e.category.isEmpty ? '' : ' · ${e.category}'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: _muted)),
                        ],
                      ),
                    ),
                    Expanded(flex: 3, child: Align(alignment: Alignment.centerRight, child: e.status.isEmpty ? const Text('—') : StatusPill(e.status))),
                    Expanded(flex: 3, child: Text(_prettyDate(e.created), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13.5, color: _slate))),
                  ],
                ),
              ),
          ],
        ),
      );
    }

    final n = _items?.length;
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 12, 12),
              child: Row(
                children: [
                  const Icon(Icons.replay_rounded, size: 20, color: DashUi.red),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${widget.name} · Callback strikes', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: _ink)),
                        Text(
                          '${n == null ? '' : '$n ${n == 1 ? 'callback visit' : 'callback visits'} · '}$_period, newest first',
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

/// Whole dollars for headline figures ("$37,272"); cents add noise at this size.
String _wholeMoney(double v) => dashMoney(v.roundToDouble()).replaceFirst(RegExp(r'\.00$'), '');

const _monthLetters = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _weekdayLetters = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _compactMoney(double v) {
  if (v.abs() >= 1000000) return '\$${_fmtNum(v / 1000000)}M';
  if (v.abs() >= 1000) return '\$${_fmtNum(v / 1000)}k';
  return '\$${v.round()}';
}

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

  /// Fix the top of the axis (100 for a percentage) instead of rounding up from the biggest value.
  final double? maxValue;

  /// Show the "Average" key above the chart (a caller short of height can explain the dashed line in its own header).
  final bool showLegend;

  /// For a chart that isn't by month: the label under each point ('' for none) and the tooltip title for each. With
  /// these there is no "so far" and no change against the previous point.
  final List<String>? labels;
  final List<String>? titles;

  /// A target to draw as a solid green line labelled [goalLabel] at its right end (the comparison point when a chart
  /// has one), and whether to draw the dashed average as well.
  final double? goal;
  final String? goalLabel;
  final bool average;

  /// A point the page's callout talks about (the worst day): once the line has drawn in, a ring pulses out of it a
  /// few times and then stays round it, so the eye goes from the words to the spot.
  final int? highlight;
  const _MonthlyChart({
    this.highlight,
    this.labels,
    this.titles,
    this.goal,
    this.goalLabel,
    this.average = true,
    this.maxValue,
    this.showLegend = true,
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
  late final AnimationController _beacon = AnimationController(vsync: this, duration: const Duration(milliseconds: 2700));
  int? _active;
  int? _painted;

  @override
  void initState() {
    super.initState();
    _intro.addStatusListener((s) {
      if (s == AnimationStatus.completed && widget.highlight != null && mounted && !MediaQuery.disableAnimationsOf(context)) _beacon.forward(from: 0);
    });
    _intro.forward();
  }

  @override
  void didUpdateWidget(covariant _MonthlyChart old) {
    super.didUpdateWidget(old);
    if (!identical(old.values, widget.values) || old.line != widget.line) {
      _active = null;
      _painted = null;
      _hoverAnim.value = 0;
      _beacon.value = 0;
      _intro.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    _hoverAnim.dispose();
    _beacon.dispose();
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
    if (reduce) {
      _intro.value = 1;
      _beacon.value = 1;
    }
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
        if (_has(i)) '${w.titles?[i] ?? _monthLetters[i]} ${w.tipFormat(i)}',
    ].join('; ');

    final legend = <Widget>[
      if (avg > 0 && w.showLegend && w.average)
        _legend(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [for (var i = 0; i < 3; i++) Container(width: 4, height: 2.5, margin: EdgeInsets.only(right: i == 2 ? 0 : 2), color: dashAverageLine)],
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
                        animation: Listenable.merge([_intro, _hoverAnim, _beacon]),
                        builder: (context, _) => CustomPaint(
                          size: Size(c.maxWidth, c.maxHeight),
                          painter: _ChartPainter(
                            values: w.values,
                            color: w.color,
                            line: w.line,
                            axisFormat: w.axisFormat,
                            tipFormat: w.tipFormat,
                            average: w.average ? avg : 0,
                            goal: w.goal,
                            goalLabel: w.goalLabel,
                            peak: w.line ? null : peak,
                            index: _painted,
                            intro: Curves.easeOutCubic.transform(_intro.value),
                            hover: _active == null ? _hoverAnim.value : math.max(_hoverAnim.value, 0.001),
                            fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
                            maxValue: w.maxValue,
                            labels: w.labels,
                            titles: w.titles,
                            highlight: w.highlight,
                            beacon: _beacon.value,
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
  final double? maxValue;
  final List<String>? labels;
  final List<String>? titles;
  final double? goal;
  final String? goalLabel;

  /// The point to ring ([_MonthlyChart.highlight]) and how far its pulses have got (0 not started, 1 done).
  final int? highlight;
  final double beacon;
  const _ChartPainter({
    this.highlight,
    this.beacon = 0,
    this.labels,
    this.titles,
    this.goal,
    this.goalLabel,
    this.maxValue,
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
    final maxV = maxValue ?? _niceMax(values.whereType<double>().fold<double>(0, math.max));
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
      // A narrow plot (a half-width card) has no room for "Feb" without wrapping, so it gets the month's first letter.
      final label = labels != null ? labels![i] : (slot < 28 ? _monthLetters[i][0] : _monthLetters[i]);
      if (label.isEmpty) continue;
      final tp = _text(
        label,
        TextStyle(
          fontSize: 12.5,
          fontWeight: focus ? FontWeight.w800 : FontWeight.w600,
          color: focus ? DashUi.ink : (has ? DashUi.slate : const Color(0xFFCBD5E1)),
        ),
        // A label may be wider than its slot when only some points have one.
        maxWidth: labels != null ? slot * 4 : slot,
      );
      tp.paint(canvas, Offset(cx - tp.width / 2, plot.bottom + 8));
      if (labels == null && i == n - 1 && has && slot >= 34) {
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
        ..color = dashAverageLine.withValues(alpha: 0.9 * intro)
        ..strokeWidth = 1.3
        ..strokeCap = StrokeCap.round;
      var x = plot.left;
      while (x < plot.right) {
        canvas.drawLine(Offset(x, ay), Offset(math.min(x + 5, plot.right), ay), paint);
        x += 9;
      }
    }

    // The goal: a solid green line, named at its right end so it needs no key.
    final target = goal;
    if (target != null && target > 0 && target <= maxV) {
      final gy = y(target);
      canvas.drawLine(Offset(plot.left, gy), Offset(plot.right, gy), Paint()
        ..color = DashUi.emeraldDeep.withValues(alpha: 0.85 * intro)
        ..strokeWidth = 1.5);
      if (goalLabel != null) {
        final tp = _text(goalLabel!, TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: DashUi.emeraldText.withValues(alpha: intro)));
        final box = Rect.fromLTWH(plot.right - tp.width - 8, gy - tp.height - 3, tp.width + 6, tp.height);
        canvas.drawRect(box, Paint()..color = Colors.white.withValues(alpha: 0.85 * intro));
        tp.paint(canvas, Offset(box.left + 3, box.top));
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
        canvas.drawPath(path, Paint()..color = dashBestMark.withValues(alpha: dim));
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
      // A run starting in January carries its fill back to the axis, so the half slot before the first month isn't bare.
      final fromAxis = run.first == 0;
      final area = Path.from(path)
        ..lineTo(pts[run.last]!.dx, plot.bottom)
        ..lineTo(fromAxis ? plot.left : pts[run.first]!.dx, plot.bottom)
        ..lineTo(fromAxis ? plot.left : pts[run.first]!.dx, pts[run.first]!.dy)
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

    final hp = highlight == null ? null : pts[highlight!];
    if (hp != null && beacon > 0) {
      // Three pulses ripple out of the point, then a quiet ring stays.
      if (beacon < 1) {
        final f = (beacon * 3) % 1;
        final fade = Curves.easeOut.transform(f);
        canvas.drawCircle(
          hp,
          6 + 18 * fade,
          Paint()
            ..color = color.withValues(alpha: 0.5 * (1 - fade))
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
      final settle = Curves.easeOut.transform((beacon * 3).clamp(0.0, 1.0));
      canvas.drawCircle(hp, 9, Paint()..color = color.withValues(alpha: 0.14 * settle));
      canvas.drawCircle(
        hp,
        9,
        Paint()
          ..color = color.withValues(alpha: 0.55 * settle)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

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
    final partial = labels == null && i == values.length - 1;
    final title = _text(titles != null ? titles![i] : (partial ? '${_monthLetters[i]} so far' : _monthLetters[i]), const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800));
    final value = _text(tipFormat(i), const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600));

    TextPainter? delta;
    final cur = values[i];
    if (cur != null && i > 0 && !partial && labels == null) {
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
    final rect = Rect.fromLTWH(tx, ty, w, h);
    final box = RRect.fromRectAndRadius(rect, const Radius.circular(12));
    // The scorecard hover card's look: deep shadow, navy gradient, soft white edge.
    canvas.drawRRect(
      box.shift(const Offset(0, 6)),
      Paint()
        ..color = const Color(0xFF0F172A).withValues(alpha: 0.25 * hover)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );
    canvas.drawRRect(box, Paint()..shader = dashTipGradient.createShader(rect)..color = Colors.white.withValues(alpha: hover));
    canvas.drawRRect(
      box.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = dashTipEdge.withValues(alpha: dashTipEdge.a * hover),
    );
    var dy = ty + 9;
    for (final t in rows) {
      t.paint(canvas, Offset(tx + 12, dy));
      dy += t.height + 3;
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.intro != intro ||
      old.beacon != beacon ||
      old.highlight != highlight ||
      old.hover != hover ||
      old.index != index ||
      old.values != values ||
      old.color != color ||
      old.line != line ||
      old.maxValue != maxValue ||
      old.average != average ||
      old.goal != goal;
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

/// One weekday of the missed-calls graph: incoming calls and how many nobody answered.
class _MissedDay {
  final DateTime date;
  final int missed;
  final int total;
  const _MissedDay(this.date, this.missed, this.total);
}

/// One missed call from `/employees/:id/missed_calls`.
class _MissedCall {
  final DateTime? at; // Chicago wall-clock time, as the server sends it
  final String phone; // 10 digits
  final String? name;
  final String? nameFrom; // 'Quo contact' or 'Customer'
  final String line;
  final String status;
  final int seconds;
  const _MissedCall(this.at, this.phone, this.name, this.nameFrom, this.line, this.status, this.seconds);

  String get prettyPhone => phone.length == 10 ? '${phone.substring(0, 3)}-${phone.substring(3, 6)}-${phone.substring(6)}' : phone;
}

/// The calls behind the Missed calls graph, newest first, so they can be checked against Quo. The caller's name is the
/// Quo contact's when there is one, otherwise the customer with that phone number.
class _MissedCallsDialog extends StatefulWidget {
  final String employeeId;
  final String name;
  const _MissedCallsDialog({required this.employeeId, required this.name});

  @override
  State<_MissedCallsDialog> createState() => _MissedCallsDialogState();
}

class _MissedCallsDialogState extends State<_MissedCallsDialog> {
  static const windowDays = 30;
  List<_MissedCall>? _items;
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
            Uri.parse('$kApiBaseUrl/api/employees/${Uri.encodeComponent(widget.employeeId)}/missed_calls?year=${DashClock.now().year}&days=30'),
            headers: AuthSession.instance.headers(),
          )
          .timeout(const Duration(seconds: 40));
      if (res.statusCode == 401) {
        AuthSession.instance.logout(); // sends the app back to the sign-in screen
        throw Exception('Your session expired. Please sign in again.');
      }
      if (res.statusCode != 200) throw Exception('The server had a problem (error ${res.statusCode}). Try again in a moment.');
      final body = json.decode(res.body);
      final list = body is Map && body['items'] is List ? body['items'] as List : const [];
      final items = [
        for (final e in list)
          if (e is Map)
            _MissedCall(
              DateTime.tryParse(_str(e['at'])),
              _str(e['phone']),
              _str(e['name']).isEmpty ? null : _str(e['name']),
              _str(e['nameFrom']).isEmpty ? null : _str(e['nameFrom']),
              _str(e['line']),
              _str(e['status']),
              int.tryParse(_str(e['seconds'])) ?? 0,
            ),
      ];
      if (!mounted) return;
      final today = DashClock.now();
      final cutoff = DateTime(today.year, today.month, today.day).subtract(const Duration(days: _MissedCallsDialogState.windowDays - 1));
      setState(() {
        _items = [for (final c in items) if (c.at != null && !c.at!.isBefore(cutoff)) c];
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

  static const _fullDays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

  /// "11:15 AM"
  static String _clock(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
  }

  /// "Thursday, Oct 29"
  static String _dayTitle(DateTime d) => '${_fullDays[d.weekday - 1]}, ${_monthLetters[d.month - 1]} ${d.day}';

  static String _short(DateTime d) => '${_monthLetters[d.month - 1]} ${d.day}';

  @override
  Widget build(BuildContext context) {
    const head = TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _muted, letterSpacing: 0.6);
    final today = DashClock.now();
    final first = DateTime(today.year, today.month, today.day).subtract(const Duration(days: windowDays - 1));
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
            Text("Couldn't load the missed calls. $_error", textAlign: TextAlign.center, style: const TextStyle(fontSize: 13.5, color: _slate)),
            const SizedBox(height: 8),
            TextButton.icon(onPressed: _load, icon: const Icon(Icons.refresh_rounded, size: 18), label: const Text('Try again')),
          ],
        ),
      );
    } else if (_items!.isEmpty) {
      body = const Padding(
        padding: EdgeInsets.all(40),
        child: Center(child: Text('No missed calls in the last 30 days.', style: TextStyle(fontSize: 14, color: _slate))),
      );
    } else {
      // Newest first, grouped under a heading per day.
      final days = <(DateTime, List<_MissedCall>)>[];
      for (final c in _items!) {
        final d = DateTime(c.at!.year, c.at!.month, c.at!.day);
        if (days.isNotEmpty && days.last.$1 == d) {
          days.last.$2.add(c);
        } else {
          days.add((d, [c]));
        }
      }
      body = Flexible(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 8),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 10, 24, 6),
              child: Row(
                children: [
                  Expanded(flex: 2, child: Text('TIME', style: head)),
                  Expanded(flex: 6, child: Text('CALLER', style: head)),
                  Expanded(flex: 3, child: Text('LINE', style: head)),
                  Expanded(flex: 2, child: Text('RANG', style: head, textAlign: TextAlign.right)),
                ],
              ),
            ),
            for (final day in days) ...[
              Container(
                color: const Color(0xFFF8FAFC),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 7),
                child: Row(
                  children: [
                    Expanded(child: Text(_dayTitle(day.$1), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _ink))),
                    Text('${day.$2.length} missed', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: _slate)),
                  ],
                ),
              ),
              for (final c in day.$2)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                  decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: _line))),
                  child: Row(
                    children: [
                      Expanded(flex: 2, child: Text(_clock(c.at!), style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: _ink))),
                      Expanded(
                        flex: 6,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(c.name ?? 'Unknown caller', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.name == null ? _muted : _ink)),
                            Text('${c.prettyPhone}${c.nameFrom == null ? '' : ' · ${c.nameFrom}'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: _muted)),
                          ],
                        ),
                      ),
                      Expanded(flex: 3, child: Text(c.line, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, color: _slate))),
                      Expanded(flex: 2, child: Text(c.seconds > 0 ? '${c.seconds}s' : '—', textAlign: TextAlign.right, style: const TextStyle(fontSize: 13.5, color: _slate))),
                    ],
                  ),
                ),
            ],
          ],
        ),
      );
    }

    final n = _items?.length;
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 12, 14),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(color: DashUi.red.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
                    child: const Icon(Icons.phone_missed_rounded, size: 21, color: DashUi.red),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Missed calls', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _ink)),
                        Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, color: _slate)),
                      ],
                    ),
                  ),
                  IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close_rounded, size: 20, color: _slate), tooltip: 'Close'),
                ],
              ),
            ),
            // The window these calls cover, with the count.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              decoration: const BoxDecoration(color: Color(0xFFF1F5F9), border: Border.symmetric(horizontal: BorderSide(color: _line))),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today_rounded, size: 15, color: _slate),
                  const SizedBox(width: 8),
                  const Text('Last 30 days', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: _ink)),
                  const SizedBox(width: 8),
                  Text('${_short(first)} – ${_short(today)}', style: const TextStyle(fontSize: 13, color: _slate)),
                  const Spacer(),
                  if (n != null) Text('$n ${n == 1 ? 'missed call' : 'missed calls'}', style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: DashUi.redText)),
                ],
              ),
            ),
            body,
          ],
        ),
      ),
    );
  }
}

/// The estimates behind "Late to send": customer, date created, date provided and the days between.
class _LateEstimatesDialog extends StatefulWidget {
  final String employeeId;
  final String name;
  final _EstimateListKind kind;

  /// The year whose estimates to list; null for this year.
  final int? year;
  const _LateEstimatesDialog({required this.employeeId, required this.name, this.kind = _EstimateListKind.late, this.year});

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
              '${widget.kind == _EstimateListKind.late ? 'late_estimates' : 'stale_estimates'}?year=${widget.year ?? DateTime.now().year}',
            ),
            headers: AuthSession.instance.headers(),
          )
          .timeout(const Duration(seconds: 40));
      if (res.statusCode == 401) {
        AuthSession.instance.logout(); // sends the app back to the sign-in screen
        throw Exception('Your session expired. Please sign in again.');
      }
      if (res.statusCode != 200) throw Exception('The server had a problem (error ${res.statusCode}). Try again in a moment.');
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
      final rule = 'Sent more than ${_limit('turnaroundDays', 3)} days after creation (${_limit('hardBidDays', 14)} for hard bids), with nothing done on '
          'it while it waited (a status change, a note or an edit in Service Fusion)';
      return n == null ? rule : '$n ${n == 1 ? 'estimate' : 'estimates'} · $rule';
    }
    final rule = 'No activity for more than ${_limit('requestedDays', 5)} days before sending (${_limit('requestedHardBidDays', 14)} for hard bids) '
        'or ${_limit('providedDays', 14)} days once sent';
    return n == null ? rule : '$n stale ${n == 1 ? 'estimate' : 'estimates'} · $rule';
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
            widget.kind == _EstimateListKind.late
                ? 'No late estimates in ${widget.year ?? DashClock.now().year}.'
                : 'No stale estimates. Everything open has had recent activity.',
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

/// The year's largest job (one the person is an agent on), dressed up like a win: a gold card with confetti drifting down, a twinkling star or two,
/// a trophy and an amount that counts up. Still (no drift, no twinkle, no count-up) when the OS asks for reduced motion.
class _BigDealCard extends StatefulWidget {
  final _BigDeal deal;
  final int year;
  const _BigDealCard({required this.deal, required this.year});

  @override
  State<_BigDealCard> createState() => _BigDealCardState();
}

class _BigDealCardState extends State<_BigDealCard> with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(vsync: this, duration: const Duration(seconds: 9));
  bool _still = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.disableAnimationsOf(context);
    if (_still) {
      _clock.stop();
      _clock.value = 0.3; // a frozen frame with the confetti spread out
    } else if (!_clock.isAnimating) {
      _clock.repeat();
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final deal = widget.deal;
    final deep = Color.lerp(DashUi.amber, DashUi.ink, 0.45)!;
    final date = deal.date.isEmpty ? null : _prettyDate(deal.date);
    return Semantics(
      label: 'Largest deal of ${widget.year}: ${_wholeMoney(deal.amount)} for ${deal.customer}${date == null ? '' : ', job started $date'}',
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _gold.withValues(alpha: 0.6)),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color.lerp(_gold, Colors.white, 0.86)!, Color.lerp(_gold, Colors.white, 0.62)!],
          ),
          boxShadow: [BoxShadow(color: _gold.withValues(alpha: 0.22), blurRadius: 14, offset: const Offset(0, 4))],
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: ExcludeSemantics(
                child: RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: _clock,
                    builder: (context, _) => CustomPaint(painter: _ConfettiPainter(_clock.value)),
                  ),
                ),
              ),
            ),
            // Laid out for a scorecard's size: one line each for the label, the amount, the customer and the date, the
            // whole width for the words, and the trophy beside the amount when there is room for it.
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
              child: LayoutBuilder(
                builder: (context, c) => Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text('LARGEST DEAL · ${widget.year}', maxLines: 1, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, height: 1.3, letterSpacing: 0.7, color: deep))),
                    const SizedBox(height: 1),
                    Row(
                      children: [
                        Expanded(
                          child: TweenAnimationBuilder<double>(
                            key: ValueKey(deal.amount),
                            tween: Tween(begin: _still ? deal.amount : 0, end: deal.amount),
                            duration: _still ? Duration.zero : const Duration(milliseconds: 1500),
                            curve: Curves.easeOutCubic,
                            builder: (context, v, _) => FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(_wholeMoney(v), style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: deep, height: 1.1, fontFeatures: const [FontFeature.tabularFigures()])),
                            ),
                          ),
                        ),
                        if (c.maxWidth >= 170)
                          Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color.lerp(_gold, Colors.white, 0.25)!, DashUi.amber]),
                              boxShadow: [BoxShadow(color: _gold.withValues(alpha: 0.5), blurRadius: 8)],
                            ),
                            child: const Icon(Icons.emoji_events_rounded, size: 18, color: Colors.white),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Tooltip(
                      message: deal.customer, // commercial names run long
                      child: Text(deal.customer, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: DashUi.ink, height: 1.3)),
                    ),
                    if (date != null) FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text('Job started $date', maxLines: 1, style: const TextStyle(fontSize: 11, height: 1.3, color: DashUi.slate))),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Confetti pieces that drift down and wrap round (every speed is a whole number of loops per cycle, so the loop is
/// seamless), plus a few four-point stars that twinkle. Positions come from a fixed seed so every frame agrees.
class _ConfettiPainter extends CustomPainter {
  final double t; // 0..1 around the loop
  const _ConfettiPainter(this.t);

  static const _colors = [_gold, DashUi.sky, DashUi.emerald, DashUi.indigo, DashUi.red];
  static final _pieces = () {
    final r = math.Random(11);
    return [
      for (var i = 0; i < 26; i++)
        (x: r.nextDouble(), phase: r.nextDouble(), loops: 1 + r.nextInt(2), spin: 1 + r.nextInt(3), size: 3.5 + r.nextDouble() * 3, color: i % _colors.length, round: i % 4 == 0),
    ];
  }();
  static final _stars = () {
    final r = math.Random(5);
    return [for (var i = 0; i < 4; i++) (x: 0.1 + r.nextDouble() * 0.8, y: 0.12 + r.nextDouble() * 0.76, phase: r.nextDouble(), size: 5 + r.nextDouble() * 3)];
  }();

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in _pieces) {
      final f = (p.phase + t * p.loops) % 1.0;
      final y = -8 + f * (size.height + 16);
      final x = p.x * size.width + math.sin((f + p.phase) * 2 * math.pi) * 6;
      final paint = Paint()..color = _colors[p.color].withValues(alpha: 0.55);
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(t * p.spin * 2 * math.pi + p.phase * 6);
      if (p.round) {
        canvas.drawCircle(Offset.zero, p.size * 0.45, paint);
      } else {
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: p.size, height: p.size * 0.55), const Radius.circular(1)), paint);
      }
      canvas.restore();
    }
    for (final s in _stars) {
      final tw = 0.5 + 0.5 * math.sin((t * 2 + s.phase) * 2 * math.pi); // two twinkles per loop
      final r = s.size * (0.55 + 0.45 * tw);
      final c = Offset(s.x * size.width, s.y * size.height);
      final path = Path()
        ..moveTo(c.dx, c.dy - r)
        ..quadraticBezierTo(c.dx, c.dy, c.dx + r, c.dy)
        ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy + r)
        ..quadraticBezierTo(c.dx, c.dy, c.dx - r, c.dy)
        ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy - r);
      canvas.drawPath(path, Paint()..color = Colors.white.withValues(alpha: 0.35 + 0.55 * tw));
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter old) => old.t != t;
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

/// Tall card of customer comments that name this tech, one at a time, sliding up every few seconds. Stands still
/// while the cursor is over it or when the OS asks for reduced motion. Shows a quiet empty state until comments exist.
class _MentionsCard extends StatefulWidget {
  final List<_Mention> mentions;
  final _Rating? satisfaction;

  /// Replaces the "CUSTOMER FEEDBACK" label and star row (the technician page uses the dashboards' panel title).
  final Widget? header;
  final EdgeInsets padding;
  const _MentionsCard({
    required this.mentions,
    this.satisfaction,
    this.header,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 0),
  });

  @override
  State<_MentionsCard> createState() => _MentionsCardState();
}

class _MentionsCardState extends State<_MentionsCard> with SingleTickerProviderStateMixin {
  static const _sizes = [14.0, 13.5, 13.0, 12.5, 12.0, 11.5];
  late final AnimationController _clock = AnimationController(vsync: this, duration: const Duration(seconds: 12));
  int _i = 0;
  int _dir = 1; // which way the last change travelled, so the transition slides the right way
  bool _hovered = false;
  bool _still = false; // reduced motion: no auto-rotate

  @override
  void initState() {
    super.initState();
    _clock.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) _step(1);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.disableAnimationsOf(context);
    _syncClock();
  }

  @override
  void didUpdateWidget(covariant _MentionsCard old) {
    super.didUpdateWidget(old);
    if (!_sameMentions(old.mentions, widget.mentions)) {
      _i = 0;
      _syncClock(restart: true);
    }
  }

  /// Same reviews in the same order; length alone misses a switch between two people with equally many.
  static bool _sameMentions(List<_Mention> a, List<_Mention> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].quote != b[i].quote || a[i].customer != b[i].customer) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  /// Runs while there is something to rotate to, and not under the cursor or with reduced motion.
  void _syncClock({bool restart = false}) {
    if (restart) _clock.value = 0;
    if (widget.mentions.length < 2 || _still || _hovered) {
      _clock.stop();
    } else if (!_clock.isAnimating) {
      _clock.forward();
    }
  }

  void _step(int by) {
    final n = widget.mentions.length;
    if (n < 2) return;
    setState(() {
      _dir = by >= 0 ? 1 : -1;
      _i = ((_i + by) % n + n) % n;
    });
    _clock.value = 0;
    _syncClock();
  }

  /// Slide + fade in the direction of travel, the old review slipping out the other way with a slight scale.
  Widget _swap(Widget child, Animation<double> anim, int shown) {
    final incoming = child.key == ValueKey<int>(shown);
    final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    final slide = Tween<Offset>(begin: Offset(incoming ? 0.22 * _dir : -0.22 * _dir, 0), end: Offset.zero).animate(curved);
    final scale = Tween<double>(begin: 0.96, end: 1).animate(curved);
    return FadeTransition(opacity: curved, child: SlideTransition(position: slide, child: ScaleTransition(scale: scale, child: child)));
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
            Flexible(child: Text('${r.count} ratings', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: DashUi.muted))),
          ],
        ],
      ),
    );
  }

  void _openFull(_Mention m) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          SizedBox(width: 82, height: 18, child: CustomPaint(painter: _StarsPainter(m.stars ?? 0, DashUi.amber))),
          const SizedBox(width: 10),
          Expanded(child: Text(m.customer, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800))),
        ]),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              SelectableText(m.quote, style: const TextStyle(fontSize: 14.5, height: 1.45, color: _ink)),
              const SizedBox(height: 12),
              Text(_footer(m), style: const TextStyle(fontSize: 12, color: DashUi.muted)),
            ]),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  String _footer(_Mention m) => [if (m.source != null) m.source!, ?m.when].join(' · ');

  /// The review text at the largest size that fits; if even the smallest does not, it is cut with a "Read full review" link.
  Widget _quote(_Mention m, BoxConstraints c) {
    const link = 24.0;
    final width = c.maxWidth;
    final base = DefaultTextStyle.of(context).style; // what the Text below inherits, so measuring matches drawing
    final scaler = MediaQuery.textScalerOf(context); // the Text below scales, so the measurement has to as well
    TextStyle style(double size) => TextStyle(fontSize: size, fontStyle: FontStyle.italic, color: _ink, height: 1.35);
    double heightAt(double size) {
      final tp = TextPainter(
        text: TextSpan(text: m.quote, style: base.merge(style(size))),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout(maxWidth: width);
      final h = tp.height;
      tp.dispose();
      return h;
    }

    double? fit;
    for (final size in _sizes) {
      if (heightAt(size) <= c.maxHeight) {
        fit = size;
        break;
      }
    }
    final cut = fit == null;
    final size = fit ?? _sizes.last;
    final lines = cut ? ((c.maxHeight - link) / (scaler.scale(size) * 1.35)).floor().clamp(1, 40) : null;
    return InkWell(
      onTap: cut ? () => _openFull(m) : null,
      borderRadius: BorderRadius.circular(6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Align(
                alignment: Alignment.topLeft,
                child: Text(m.quote, maxLines: lines, overflow: cut ? TextOverflow.ellipsis : TextOverflow.clip, style: style(size)),
              ),
            ),
            if (cut)
              const SizedBox(
                height: link,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Read full review', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.indigo)),
                ),
              ),
          ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.mentions;
    final idx = list.isEmpty ? 0 : _i % list.length;
    final m = list.isEmpty ? null : list[idx];
    final duration = _still ? Duration.zero : const Duration(milliseconds: 520);
    Widget switched(Widget Function(_Mention) build, {AlignmentGeometry align = Alignment.topLeft}) => ClipRect(
          child: AnimatedSwitcher(
            duration: duration,
            transitionBuilder: (child, anim) => _swap(child, anim, idx),
            layoutBuilder: (cur, prev) => Stack(alignment: align, children: [...prev, ?cur]),
            child: KeyedSubtree(key: ValueKey<int>(idx), child: build(m!)),
          ),
        );
    return MouseRegion(
      onEnter: (_) {
        _hovered = true;
        _syncClock();
      },
      onExit: (_) {
        _hovered = false;
        _syncClock();
      },
      child: Container(
        padding: widget.padding,
        decoration: DashUi.panel(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.header != null)
              widget.header!
            else ...[
              const Text('CUSTOMER FEEDBACK', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.8, color: DashUi.muted)),
              const SizedBox(height: 6),
              _satisfactionRow(),
              const SizedBox(height: 10),
            ],
            Expanded(
              child: m == null
                  ? const Align(alignment: Alignment.centerLeft, child: Text('No customer mentions yet', style: TextStyle(fontSize: 13, color: DashUi.muted)))
                  : Semantics(
                      label: 'Customer comment from ${m.customer}: ${m.quote}',
                      child: LayoutBuilder(
                        builder: (context, c) => switched((mm) => SizedBox(width: c.maxWidth, height: c.maxHeight, child: _quote(mm, c))),
                      ),
                    ),
            ),
            if (m != null) ...[
              const SizedBox(height: 8),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                  child: switched(
                    (mm) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(mm.customer, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _ink)),
                      if (_footer(mm).isNotEmpty) Text(_footer(mm), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: DashUi.muted)),
                    ]),
                    align: Alignment.bottomLeft,
                  ),
                ),
                if (list.length > 1) ...[
                  _StepButton(icon: Icons.chevron_left_rounded, tooltip: 'Previous review', onTap: () => _step(-1)),
                  Text('${idx + 1}/${list.length}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: DashUi.muted)),
                  _StepButton(icon: Icons.chevron_right_rounded, tooltip: 'Next review', onTap: () => _step(1)),
                ],
              ]),
            ],
            // Time until the next review: a thin line that fills across the bottom edge and pauses under the cursor.
            const SizedBox(height: 8),
            SizedBox(
              height: 4,
              child: list.length > 1 && !_still
                  ? RepaintBoundary(
                      // Only this 4px line repaints each frame, not the card around it.
                      child: AnimatedBuilder(
                        animation: _clock,
                        builder: (context, _) => DecoratedBox(
                          decoration: BoxDecoration(color: DashUi.muted.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(2)),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: _clock.value.clamp(0.0, 1.0),
                              heightFactor: 1, // without this the empty box collapses to zero height and nothing draws
                              child: DecoratedBox(decoration: BoxDecoration(color: DashUi.amber, borderRadius: BorderRadius.circular(2))),
                            ),
                          ),
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(height: 9),
          ],
        ),
      ),
    );
  }
}

/// A small round arrow for stepping through reviews.
class _StepButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _StepButton({required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 16,
        child: Padding(padding: const EdgeInsets.all(2), child: Icon(icon, size: 20, color: DashUi.muted)),
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
    if (reduce || r == null) {
      _sweep.stop(); // nothing to animate: the grey trace is still, so don't repaint it every frame
    } else if (!_sweep.isAnimating) {
      _sweep.repeat();
    }
    final color = r == null ? DashUi.muted : _tone(r.avg);

    Widget scoreText({required bool big, CrossAxisAlignment align = CrossAxisAlignment.end}) => r == null
        ? const Text('Not tracked yet', style: TextStyle(fontSize: 13, color: DashUi.muted, fontWeight: FontWeight.w600))
        : Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: align,
          children: [
            Text(_fmtNum(r.avg),
                style: TextStyle(fontSize: big ? 52 : 38, fontWeight: FontWeight.w800, color: color, height: 1)),
            Text(
              widget.isSample ? 'out of 5 · sample' : 'out of 5',
              style: TextStyle(fontSize: 11.5, color: widget.isSample ? DashUi.amber : _muted),
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
                      // A short card (a row of cards) shrinks the score to its height rather than spilling out.
                      FittedBox(fit: BoxFit.scaleDown, child: tapToCycle(scoreText(big: false))),
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

  /// The faint baseline line (monitor paper); light on a white card, dark-bar tint in a title bar.
  final Color baseline;
  const _HeartbeatPainter({required this.progress, required this.color, required this.live, this.baseline = DashUi.faint});

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
        ..color = baseline
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


/// Weekly inventory accuracy as a line with a dashed 95% target. The last point is labelled; hover shows any week.
class _AccuracyTrendChart extends StatefulWidget {
  final List<(String, double, int)> points; // week start, percent, items counted
  const _AccuracyTrendChart({required this.points});

  @override
  State<_AccuracyTrendChart> createState() => _AccuracyTrendChartState();
}

class _AccuracyTrendChartState extends State<_AccuracyTrendChart> {
  int? _hover;

  @override
  Widget build(BuildContext context) {
    final pts = widget.points;
    return LayoutBuilder(
      builder: (context, c) => MouseRegion(
        onHover: (e) {
          final plotW = c.maxWidth - _TrendPainter.left - _TrendPainter.right;
          if (plotW <= 0) return;
          final i = (((e.localPosition.dx - _TrendPainter.left) / plotW) * (pts.length - 1)).round();
          final next = i >= 0 && i < pts.length ? i : null;
          if (next != _hover) setState(() => _hover = next);
        },
        onExit: (_) => setState(() => _hover = null),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 900),
          curve: Curves.easeOutCubic,
          builder: (context, t, _) => CustomPaint(size: Size(c.maxWidth, c.maxHeight), painter: _TrendPainter(points: pts, hover: _hover, progress: t, fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily)),
        ),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  static const left = 34.0, right = 12.0, top = 10.0, bottom = 20.0;
  static const target = 95.0;
  final List<(String, double, int)> points;
  final int? hover;
  final double progress;
  final String? fontFamily;
  const _TrendPainter({required this.points, required this.hover, required this.progress, this.fontFamily});

  /// Draws [t] at [at]; with [within] (the canvas width) it is kept inside 0..[within], so an end label isn't cut off.
  void _text(Canvas canvas, String t, Offset at, {Color color = _muted, double size = 11, FontWeight weight = FontWeight.w500, bool rightAlign = false, bool centre = false, double? within}) {
    final tp = TextPainter(text: TextSpan(text: t, style: TextStyle(fontSize: size, color: color, fontWeight: weight, fontFamily: fontFamily)), textDirection: TextDirection.ltr)..layout();
    var dx = rightAlign ? -tp.width : (centre ? -tp.width / 2 : 0.0);
    if (within != null) dx = math.max(-at.dx, math.min(dx, within - at.dx - tp.width));
    tp.paint(canvas, at + Offset(dx, -tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final minV = points.map((p) => p.$2).reduce(math.min);
    final lo = (math.min(minV, target) / 5).floor() * 5.0 - 5;
    final plot = Rect.fromLTRB(left, top, size.width - right, size.height - bottom);
    double y(double v) => plot.bottom - (v - lo) / (100 - lo) * plot.height;
    double x(int i) => plot.left + (points.length == 1 ? 0.5 : i / (points.length - 1)) * plot.width;

    final grid = Paint()
      ..color = DashUi.line
      ..strokeWidth = 1;
    for (final v in [lo, 100.0]) {
      canvas.drawLine(Offset(plot.left, y(v)), Offset(plot.right, y(v)), grid);
      _text(canvas, '${v.round()}%', Offset(plot.left - 6, y(v)), rightAlign: true);
    }
    // Dashed target line.
    final dash = Paint()
      ..color = DashUi.emerald.withValues(alpha: 0.7)
      ..strokeWidth = 1.2;
    for (var dx = plot.left; dx < plot.right; dx += 8) {
      canvas.drawLine(Offset(dx, y(target)), Offset(math.min(dx + 4, plot.right), y(target)), dash);
    }
    _text(canvas, '95% target', Offset(plot.left + 4, y(target) - 8), color: DashUi.emerald, size: 10.5, weight: FontWeight.w700);

    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final o = Offset(x(i), y(points[i].$2));
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    final metric = path.computeMetrics().first;
    final shown = metric.extractPath(0, metric.length * progress);
    final fill = Path.from(shown);
    final endX = metric.getTangentForOffset(metric.length * progress)?.position.dx ?? plot.left;
    fill.lineTo(endX, plot.bottom);
    fill.lineTo(plot.left, plot.bottom);
    fill.close();
    canvas.drawPath(fill, Paint()..color = DashUi.blue.withValues(alpha: 0.08));
    canvas.drawPath(
      shown,
      Paint()
        ..color = DashUi.blue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    for (var i = 0; i < points.length; i++) {
      if (i / math.max(1, points.length - 1) > progress) break;
      final o = Offset(x(i), y(points[i].$2));
      final on = i == hover || i == points.length - 1;
      canvas.drawCircle(o, on ? 4.5 : 3, Paint()..color = Colors.white);
      canvas.drawCircle(
        o,
        on ? 4.5 : 3,
        Paint()
          ..color = DashUi.blue
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    // Month-day labels under the first, middle and last week.
    for (final i in {0, points.length ~/ 2, points.length - 1}) {
      final d = DateTime.tryParse(points[i].$1);
      if (d != null) _text(canvas, '${_monthLetters[d.month - 1]} ${d.day}', Offset(x(i), size.height - 6), centre: true, size: 10.5, within: size.width);
    }
    final h = hover ?? points.length - 1;
    final hp = points[h];
    final label = hover == null ? '${_fmtNum(hp.$2)}%' : '${_fmtNum(hp.$2)}% · ${hp.$3} items';
    final o = Offset(x(h), y(hp.$2));
    final tp = TextPainter(
      text: TextSpan(text: label, style: TextStyle(fontSize: 11.5, color: Colors.white, fontWeight: FontWeight.w700, fontFamily: fontFamily)),
      textDirection: TextDirection.ltr,
    )..layout();
    final box = Rect.fromCenter(center: Offset(o.dx.clamp(tp.width / 2 + 8, size.width - tp.width / 2 - 8), o.dy - 18), width: tp.width + 14, height: 22);
    canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(6)), Paint()..color = DashUi.ink);
    tp.paint(canvas, box.center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) => old.hover != hover || old.progress != progress || !listEquals(old.points, points);
}

// =============================================================================
// CHART PANELS THAT STEP THROUGH THEIR VIEWS (the warehouse and office pages)
// =============================================================================

/// Steps a chart panel through [count] views every 8 seconds on an animation clock. The clock holds while the pointer or the keyboard is on the panel and starts
/// over when a view is picked by hand; with reduced motion it never runs. Off screen (another tab of the app is
/// showing) its ticker is muted, so nothing moves there.
class _ViewCycler {
  static const every = Duration(seconds: 8);
  final int count;
  final VoidCallback onStep;
  final AnimationController clock;
  int view = 0;

  /// Whether the last change went to a later view (the new one comes in from the right).
  bool forward = true;
  bool _held = false;
  bool _still = false;

  _ViewCycler({required TickerProvider vsync, required this.count, required this.onStep})
      : clock = AnimationController(vsync: vsync, duration: every) {
    clock.addStatusListener((s) {
      if (s != AnimationStatus.completed) return;
      view = (view + 1) % count;
      forward = true;
      clock.value = 0;
      onStep();
      _apply();
    });
  }

  /// Called with the page's reduced-motion setting whenever it may have changed.
  void still(bool v) {
    _still = v;
    _apply();
  }

  void hold(bool v) {
    _held = v;
    _apply();
  }

  void pick(int v) {
    forward = v >= view;
    view = v;
    clock.value = 0;
    _apply();
  }

  void _apply() {
    if (_still) {
      clock.stop();
      if (clock.value != 0) clock.value = 0;
    } else if (_held) {
      clock.stop();
    } else if (!clock.isAnimating) {
      clock.forward();
    }
  }

  void dispose() => clock.dispose();
}

/// The views of a stepping chart panel: the new one slides in from the side it lies on (from the right for a later
/// view) while the old one drifts out the other way, both fading.
class _ViewSwitcher extends StatelessWidget {
  final int view;
  final bool forward;
  final Widget child;
  const _ViewSwitcher({required this.view, required this.forward, required this.child});

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    final dir = forward ? 1.0 : -1.0;
    return ClipRect(
      child: AnimatedSwitcher(
        duration: reduce ? Duration.zero : const Duration(milliseconds: 380),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (cur, prev) => Stack(fit: StackFit.expand, children: [...prev, ?cur]),
        transitionBuilder: (child, anim) {
          final incoming = child.key == ValueKey(view);
          final from = Offset((incoming ? dir : -dir) * 0.06, 0);
          return FadeTransition(
            opacity: anim,
            child: SlideTransition(position: Tween(begin: from, end: Offset.zero).animate(anim), child: child),
          );
        },
        child: KeyedSubtree(key: ValueKey(view), child: child),
      ),
    );
  }
}
