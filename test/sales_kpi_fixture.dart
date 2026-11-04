// Fixtures for the sales KPI page (lib/employee_kpi_sales.dart): what /users, /api/employees/:username/kpis and the
// estimate lists answer for Heather Vera (residential) and Zac Clemens (commercial). The figures are the shape of
// production's 2026 numbers as the old page's harness had them (test/zac_kpi_render_test.dart); the review is made up.

import 'dart:convert';

import 'package:http/http.dart' as http;

const heather = (username: 'hvera', name: 'Heather Vera', role: 'Office Manager', title: 'Sales Account Manager', years: 4.0);
const zac = (username: 'zclemens', name: 'Zac Clemens', role: 'Sales Rep', title: 'Commercial Estimator', years: 1.4);

/// /users: the KPI list's people (what a direct link to a KPI page loads first).
List<Map<String, dynamic>> salesUsersBody() => [
      for (final p in [heather, zac])
        {'id': p.username, 'name': p.name, 'jobTitle': p.role, 'displayTitle': p.title, 'avatarUrl': '', 'integrityScore': 100.0, 'yearsWorked': p.years},
      {'id': 'bella', 'name': 'Bella Hansberger', 'jobTitle': 'Office', 'displayTitle': 'Office', 'avatarUrl': '', 'integrityScore': 100.0, 'yearsWorked': 2.0},
    ];

/// monthlyByType cells; revenueWithProfit (won revenue on estimates that carry a profit figure) is all of it unless given.
List<Map<String, num>> _months(List<num> rev, List<num> profit, [List<num>? priced]) =>
    [for (var m = 0; m < 12; m++) {'revenue': rev[m], 'profit': profit[m], 'revenueWithProfit': (priced ?? rev)[m]}];
final _zeros = List<num>.filled(12, 0);

const _limits = {'requestedDays': 5, 'providedDays': 14, 'turnaroundDays': 3, 'hardBidDays': 14};

/// Heather's `sales` part: residential, nothing categorised as commercial. Turnaround and late to send only exist from
/// 2026 (estimates created from Sep 10, 2026): an earlier year has null for them, as the server sends. The open
/// estimates are every estimate open today, the same whatever the year.
Map<String, dynamic> heatherSales({int year = 2026}) {
  final now = year == 2026;
  final tracked = year >= 2026;
  final rev = now ? [31520, 84674, 77961, 87599, 79919, 38780, 87263, 53342, 137118, 24931, 0, 0] : [40000, 52000, 61000, 70000, 66000, 58000, 62000, 59000, 64000, 57000, 41000, 30000];
  final profit = [for (final r in rev) (r * 0.428).round()];
  final close = now
      ? const [(11, 4), (26, 5), (23, 1), (16, 0), (21, 0), (17, 4), (16, 0), (17, 1), (18, 4), (12, 0), (0, 0), (0, 0)]
      : const [(9, 3), (12, 2), (14, 3), (15, 2), (13, 1), (11, 4), (12, 2), (10, 3), (13, 2), (12, 1), (8, 2), (6, 1)];
  return {
    'monthlyByType': {'hardBid': _months(_zeros, _zeros), 'commercial': _months(_zeros, _zeros), 'residential': _months(_zeros, _zeros), 'other': _months(rev, profit)},
    'focus': 'Residential Sales',
    'turnaroundSince': '2026-09-10',
    'monthlyClose': [for (final wl in close) {'won': wl.$1, 'lost': wl.$2}],
    'largestDeal': {'amount': 38608.12, 'customer': 'David and Molli Snell', 'date': now ? '2026-09-25' : '$year-06-11', 'jobId': '1095251088'},
    'pipeline': {
      'requested': {'count': 27, 'value': 11611.59},
      'provided': {'count': 222, 'value': 1510224.69},
      'staleValue': 1390000,
    },
    'wonCount': now ? 177 : 135,
    'lostCount': now ? 19 : 26,
    'closeRatePct': now ? 90.3 : 83.9,
    'wonValue': now ? 703107 : 660000,
    'grossProfit': now ? 300930 : 282480,
    'markupPct': 74.8,
    'marginPct': 42.8,
    'profitCoverage': {'withProfit': now ? 168 : 120, 'won': now ? 177 : 135},
    'turnaround': tracked ? {'count': 80, 'avgDays': 1.9, 'medianDays': 1} : null,
    'tracking': {'bidTurnaround': true},
    'strikes': {'staleEstimates': 232, 'agingEstimates': 4, 'openEstimates': 249, 'slowEstimates': tracked ? 12 : null, 'limits': _limits},
    'byType': [
      {'type': 'Uncategorized', 'estimates': 249 + (now ? 196 : 161), 'wonCount': now ? 177 : 135, 'wonValue': now ? 703107 : 660000, 'grossProfit': 300930},
    ],
    'reviews': [
      {'quote': 'Heather walked us through every option for the new garage door and the quote matched the final bill to the dollar.', 'customer': 'Molli S.', 'source': 'Google · 5★', 'date': '2026-09-30T00:00:00Z'},
      {'quote': 'Fast quote, friendly and no pressure at all.', 'customer': 'Tom R.', 'source': 'Google · 5★', 'date': '2026-08-02T00:00:00Z'},
    ],
    'satisfaction': {'avg': 5.0, 'count': 2},
  };
}

/// Zac's `sales` part: commercial, hard bids apart from other commercial work.
Map<String, dynamic> zacSales({int year = 2026}) => {
      'monthlyByType': {
        'hardBid': _months(const [0, 0, 0, 0, 0, 0, 24000, 0, 6100, 0, 0, 0], const [0, 0, 0, 0, 0, 0, 9100, 0, 2700, 0, 0, 0]),
        'commercial': _months(const [0, 0, 0, 0, 0, 0, 9867, 0, 2926, 478, 0, 0], const [0, 0, 0, 0, 0, 0, 2400, 0, 1576, 381, 0, 0]),
        'residential': _months(_zeros, _zeros),
        'other': _months(_zeros, _zeros),
      },
      'focus': 'Commercial Sales',
      'turnaroundSince': '2026-09-10',
      'largestDeal': {'amount': 24000, 'customer': 'Southern Brothers Construction LLC', 'date': '2026-07-14', 'jobId': '1097413576'},
      'pipeline': {
        'requested': {'count': 4, 'value': 48073.63},
        'provided': {'count': 24, 'value': 1185196.31},
        'staleValue': 351290.33,
      },
      'monthlyClose': [
        for (final wl in const [(0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (2, 0), (0, 0), (1, 0), (1, 1), (0, 0), (0, 0)]) {'won': wl.$1, 'lost': wl.$2},
      ],
      'wonCount': 4,
      'lostCount': 1,
      'closeRatePct': 80,
      'wonValue': 43371,
      'grossProfit': 16157,
      'markupPct': 59.4,
      'marginPct': 37.3,
      'profitCoverage': {'withProfit': 4, 'won': 4},
      'turnaround': {'count': 9, 'avgDays': 2.4, 'medianDays': 2},
      'bidTurnaround': {'count': 3, 'avgDays': 4.0, 'medianDays': 4},
      'bids': {'total': 6, 'wonCount': 2, 'lostCount': 0, 'openCount': 4, 'closeRatePct': 100},
      'tracking': {'bidTurnaround': true},
      'strikes': {'staleEstimates': 17, 'agingEstimates': 6, 'openEstimates': 28, 'slowEstimates': 3, 'limits': _limits},
      'byType': [
        {'type': 'Commercial Hard Bid', 'estimates': 6, 'wonCount': 2, 'wonValue': 30100, 'grossProfit': 11800, 'markupPct': 64.0},
        {'type': 'Commercial Service', 'estimates': 14, 'wonCount': 2, 'wonValue': 13271, 'grossProfit': 4357, 'markupPct': 50.9},
        {'type': 'Uncategorized', 'estimates': 8, 'wonCount': 0, 'wonValue': 0, 'grossProfit': 0},
      ],
      'reviews': <Object>[],
      'satisfaction': null,
    };

/// GET /api/employees/:username/kpis?year=Y. Zac has no estimates before 2026 (he started in 2025 on installs).
Map<String, dynamic> salesKpisBody(String username, {int year = 2026}) {
  final isZac = username == zac.username;
  return {
    'success': true,
    'year': year,
    'employee': {'id': isZac ? 7 : 8, 'role': isZac ? zac.role : heather.role, 'jobTitle': isZac ? zac.title : heather.title, 'inventoryStrikes': isZac ? 2 : 0, 'warehouseStrikes': 0},
    'sales': isZac ? (year == 2026 ? zacSales(year: year) : null) : heatherSales(year: year),
    'tech': null,
    'office': null,
    'warehouse': null,
    'morale': null,
  };
}

/// The stale and late-to-send lists.
Map<String, dynamic> salesListBody(String kind) => kind == 'stale_estimates'
    ? {
        'success': true,
        'count': 2,
        'limits': {'requestedDays': 5, 'requestedHardBidDays': 14, 'providedDays': 14},
        'items': [
          {'jobId': '1096788101', 'customerName': 'DC Sparks Construction', 'category': 'Commercial Hard Bid', 'status': 'Estimate Provided', 'statusColor': '#5f0069', 'lastActivity': '2026-09-10', 'days': 50, 'allowedDays': 14},
          {'jobId': '1097001234', 'customerName': 'JBurr Construction', 'category': '', 'status': 'Estimate Requested', 'statusColor': '#eb36ff', 'lastActivity': '2026-10-01', 'days': 29, 'allowedDays': 5},
        ],
      }
    : {
        'success': true,
        'count': 1,
        'limits': {'turnaroundDays': 3, 'hardBidDays': 14},
        'items': [
          {'jobId': '1097413576', 'customerName': 'Southern Brothers Construction LLC', 'category': 'Commercial Hard Bid', 'created': '2026-09-17', 'provided': '2026-10-07', 'days': 20, 'allowedDays': 14},
        ],
      };

/// One slice of the estimate mix.
Map<String, dynamic> salesMixBody() => {
      'success': true,
      'items': [
        {'jobId': '1097413576', 'customerName': 'Southern Brothers Construction LLC', 'category': 'Commercial Hard Bid', 'status': 'Won', 'created': '2026-07-14', 'value': 24000},
      ],
    };

/// A JSON answer.
http.Response salesJson(Object body, [int status = 200]) =>
    http.Response(json.encode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});
