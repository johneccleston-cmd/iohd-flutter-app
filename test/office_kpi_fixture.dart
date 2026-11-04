// Fixtures for the office KPI page (lib/employee_kpi_office.dart): what /users, /api/employees/bella/kpis,
// /api/dashboards/collections and the missed-calls list answer for Bella Hansberger. The receivables and the monthly cash
// are production's (read from the live database 2026-10-20); the call counts are prod's 2026 figures for the main office
// number and Bella's own line (2026-10-27, Monday to Friday 8-5); the last 30 days of calls, the leads and the review
// are made up to be the shape of the real thing.

import 'dart:convert';

import 'package:http/http.dart' as http;

const bella = (username: 'bella', name: 'Bella Hansberger', role: 'Office', title: 'Office', years: 2.0);

/// /users: the KPI list's people (what a direct link to a KPI page loads first).
List<Map<String, dynamic>> offUsersBody() => [
      {
        'id': bella.username,
        'name': bella.name,
        'jobTitle': bella.role,
        'displayTitle': bella.title,
        'avatarUrl': '',
        'integrityScore': 100.0,
        'yearsWorked': bella.years,
      },
      {'id': 'dgray', 'name': 'Dennis Gray', 'jobTitle': 'warehouse', 'displayTitle': 'Warehouse Technician', 'avatarUrl': '', 'integrityScore': 90, 'yearsWorked': 2.0},
    ];

/// Weekdays from Oct 1 to Oct 30, 2026 with a made-up spread of calls and misses (the real ones need the live database).
List<Map<String, Object?>> offRecentDays() {
  const missed = [4, 6, 3, 9, 5, 2, 7, 11, 4, 5, 8, 3, 6, 10, 4, 2, 5, 7, 9, 3, 6, 4];
  const total = [14, 15, 11, 22, 13, 9, 18, 24, 12, 14, 19, 10, 16, 21, 13, 8, 15, 17, 20, 11, 14, 12];
  final out = <Map<String, Object?>>[];
  var k = 0;
  for (var d = DateTime.utc(2026, 10, 1); !d.isAfter(DateTime.utc(2026, 10, 30)); d = d.add(const Duration(days: 1))) {
    if (d.weekday > 5) continue;
    out.add({'date': d.toIso8601String().substring(0, 10), 'missed': missed[k], 'total': total[k]});
    k++;
  }
  return out;
}

/// `missedCalls.callbacks`: what happened after the missed calls of each weekday above (the same days and counts), the
/// shape GET /api/employees/:id/kpis sends: waits in working minutes, the typical (median) wait per day and for the 30
/// days. Mon Oct 12 is the slowest day (1 h 14 min); 3 calls were never called back, 3 callers got through by calling again,
/// and one call this morning is still under an hour old.
Map<String, Object?> offCallbacks() {
  const missed = [4, 6, 3, 9, 5, 2, 7, 11, 4, 5, 8, 3, 6, 10, 4, 2, 5, 7, 9, 3, 6, 4];
  const median = <double>[18, 25, 12, 41, 22, 9, 30, 74, 16, 20, 35, 14, 27, 58, 19, 11, 24, 33, 47, 15, 21, 17];
  const notBack = {7: 2, 13: 1};
  const through = {3: 1, 10: 1, 18: 1};
  const pending = {21: 1};
  final days = (offRecentDays()).map((d) => d['date'] as String).toList();
  final daily = <Map<String, Object?>>[];
  var t = (missed: 0, back: 0, within: 0, notBack: 0, pending: 0, through: 0, me: 0);
  for (var i = 0; i < days.length; i++) {
    final nb = notBack[i] ?? 0, th = through[i] ?? 0, pe = pending[i] ?? 0;
    final back = missed[i] - nb - th - pe;
    final within = median[i] <= 30 ? (back > 2 ? back - 1 : back) : back ~/ 2;
    final me = back - (i % 3 == 0 && back > 0 ? 1 : 0);
    daily.add({
      'date': days[i], 'missed': missed[i], 'calledBack': back, 'within': within, 'notCalledBack': nb, 'pending': pe,
      'gotThrough': th, 'byMe': me, 'medianMinutes': back > 0 ? median[i] : null, 'averageMinutes': back > 0 ? median[i] + 6 : null,
    });
    t = (missed: t.missed + missed[i], back: t.back + back, within: t.within + within, notBack: t.notBack + nb, pending: t.pending + pe,
        through: t.through + th, me: t.me + me);
  }
  return {
    'goalMinutes': 60,
    'daily': daily,
    'totals': {
      'missed': t.missed, 'calledBack': t.back, 'within': t.within, 'notCalledBack': t.notBack, 'pending': t.pending,
      'gotThrough': t.through, 'byMe': t.me, 'medianMinutes': 23.0, 'averageMinutes': 31.4,
    },
  };
}

/// The Collections dashboard's fixture's stages (test/fixtures/dashboards/collections.json): in production both pages read
/// the same query, so the two sets of renders should show the same figures too.
const _stages = [
  ('Final Invoice Sent', 68389.63, 105),
  ('14 Day Notice', 44494.11, 33),
  ('30 Day Notice', 10492.39, 11),
  ('60 Day Notice', 8604.67, 8),
  ('90 Day Notice', 22577.47, 40),
  ('Check on Payment', 83574.56, 12),
];

const _cash = [230676, 195153, 269204, 395785, 326921, 207158, 293602, 362004, 153804, 78272, 0, 0];

/// The `office` part of the KPI answer. Past years have the same live receivables (the server has no past for what is
/// owed) and their own cash and calls.
Map<String, dynamic> officePart({int year = 2026}) => {
      'companyWide': true,
      'outstanding': 238132.83,
      'over90': 22577.47,
      'collected': year == 2026 ? 2512579 : 3110000,
      'collectedMonthly': year == 2026 ? _cash : [210000, 220000, 240000, 260000, 280000, 300000, 310000, 290000, 270000, 250000, 230000, 250000],
      'collectionRatePct': year == 2026 ? 91.3 : 92.9,
      'missedCalls': {
        'missed': year == 2026 ? [3, 5, 77, 98, 88, 91, 134, 91, 103, 101, 0, 0] : [10, 12, 9, 14, 8, 11, 13, 9, 10, 12, 7, 9],
        'total': year == 2026 ? [5, 11, 207, 246, 261, 284, 322, 234, 271, 249, 0, 0] : [100, 110, 90, 120, 105, 99, 130, 98, 101, 116, 90, 95],
        'daily': offRecentDays(),
        'callbacks': offCallbacks(),
      },
      'aging': [for (final s in _stages) {'label': s.$1, 'amount': s.$2, 'jobs': s.$3}],
      'tracking': {},
      'reviews': [
        {'quote': 'Bella responded the same morning that I left a message and set up an appointment for a technician to come out.', 'customer': 'Dana K.', 'source': 'Google · 5★', 'date': '2025-08-13T00:00:00Z'},
      ],
      'satisfaction': {'avg': 5.0, 'count': 1},
    };

/// GET /api/employees/:username/kpis?year=Y for Bella.
Map<String, dynamic> offKpisBody({int year = 2026, bool withOffice = true, Map<String, dynamic>? office}) => {
      'success': true,
      'year': year,
      'employee': {'id': 37, 'role': 'Office', 'inventoryStrikes': 0, 'warehouseStrikes': 0},
      if (withOffice) 'office': office ?? officePart(year: year),
    };

/// GET /api/dashboards/collections?year=Y: the figures the page takes from the Collections dashboard.
Map<String, dynamic> offCollectionsBody({int year = 2026}) => {
      'summary': {'collected': year == 2026 ? 2512579 : 3110000, 'outstanding': 238132.83, 'over90': 22577.47},
      'stages': [
        for (final (i, s) in _stages.indexed) {'stage': '$i', 'label': s.$1, 'amount': s.$2, 'jobCount': s.$3},
      ],
      'monthly': [
        for (final (i, v) in (year == 2026 ? _cash : [210000, 220000, 240000, 260000, 280000, 300000, 310000, 290000, 270000, 250000, 230000, 250000]).indexed)
          {'month_num': i + 1, 'collected': v},
      ],
    };

/// GET /api/employees/:username/missed_calls: the calls behind the graph.
Map<String, dynamic> offMissedListBody() => {
      'success': true,
      'matched': true,
      'count': 3,
      'items': [
        {'id': 'a', 'at': '2026-10-29T08:42:00', 'phone': '4796406178', 'name': null, 'nameFrom': null, 'line': 'Integrity Door', 'status': 'no-answer', 'seconds': 0},
        {'id': 'b', 'at': '2026-10-28T15:47:00', 'phone': '4795315715', 'name': 'Jared T. (Quo)', 'nameFrom': 'Quo contact', 'line': 'Integrity Door', 'status': 'no-answer', 'seconds': 0},
        {'id': 'c', 'at': '2026-10-28T11:15:00', 'phone': '9186886136', 'name': 'Maxwell Barn Company LLC', 'nameFrom': 'Customer', 'line': 'Integrity Door', 'status': 'no-answer', 'seconds': 21},
      ],
    };

/// A JSON answer.
http.Response offJson(Object body, [int status = 200]) =>
    http.Response(json.encode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});
