// Fixtures for the technician KPI page (lib/employee_kpi_tech.dart): what /users, /api/employees/:username/kpis and
// /api/tech_stats answer for Andrew Johnson and Nick Smith. The 2026 figures are production's on Oct 30, 2026 (labor,
// work days, jobs and callbacks reconciled with read-only queries that day; callback jobs as the corrected server
// counts them), and Nick's 2025 months are production's too. Review text and reviewer names are made up.

import 'package:http/http.dart' as http;
import 'dart:convert';

/// One month: jobs, labor, labor days.
typedef TechMonth = (int jobs, double labor, int days);

double _round2(double v) => (v * 100).round() / 100;

const _andrew2026 = <int, TechMonth>{
  7: (4, 3225.36, 2),
  8: (31, 16249.86, 15),
  9: (36, 7350.36, 18),
  10: (26, 7902.90, 11),
};

const _nick2026 = <int, TechMonth>{
  1: (10, 17652.63, 7),
  2: (11, 13341.51, 7),
  3: (19, 17066.52, 12),
  4: (21, 27290.66, 14),
  5: (14, 15006.75, 9),
  6: (18, 38393.66, 12),
  7: (17, 36805.44, 12),
  8: (17, 27525.69, 13),
  9: (11, 31209.39, 8),
  10: (13, 46849.81, 14),
};

const _nick2025 = <int, TechMonth>{
  1: (13, 18697.96, 10),
  2: (10, 17310.77, 8),
  3: (16, 25521.59, 16),
  4: (17, 25054.49, 9),
  5: (10, 14079.36, 9),
  6: (16, 12713.18, 8),
  7: (30, 16091.14, 16),
  8: (26, 17604.06, 13),
  9: (23, 23583.97, 10),
  10: (17, 18833.38, 13),
  11: (26, 19255.61, 17),
  12: (23, 21193.98, 13),
};

// Every current tech's labor and labor days by month (the rows the server pools the rest of the team from).
const _brett2026 = <int, (double, int)>{
  1: (16565.59, 19), 2: (19110.06, 20), 3: (13825.17, 20), 4: (24135.36, 21), 5: (22589.94, 19),
  6: (27052.03, 23), 7: (25992.58, 27), 8: (18994.13, 20), 9: (18656.53, 20), 10: (17518.92, 18),
};
const _daniel2026 = <int, (double, int)>{
  1: (19528.25, 12), 2: (14200.13, 10), 3: (60886.02, 14), 4: (21614.55, 11), 5: (13580.57, 10),
  6: (33525.66, 11), 7: (45207.56, 13), 8: (36304.28, 15), 9: (16018.28, 10), 10: (15417.28, 12),
};
const _brett2025 = <int, (double, int)>{
  1: (4958.42, 16), 2: (8554.76, 14), 3: (12192.23, 18), 4: (10785.41, 18), 5: (5081.02, 13), 6: (9098.09, 16),
  7: (8963.19, 17), 8: (11614.98, 14), 9: (12615.96, 17), 10: (25998.94, 23), 11: (13534.83, 12), 12: (21258.97, 18),
};
const _daniel2025 = <int, (double, int)>{
  1: (19564.46, 8), 2: (11738.67, 8), 3: (24444.57, 12), 4: (81382.77, 20), 5: (27257.97, 13), 6: (22958.51, 11),
  7: (24564.62, 16), 8: (20673.38, 14), 9: (34599.10, 16), 10: (42285.79, 17), 11: (15622.59, 10), 12: (25869.70, 15),
};

/// A current tech: username, name, role, years with the company (Oct 30, 2026), inventory strikes (all time).
typedef TechPerson = ({String username, String name, String role, double years, int strikes});

const andrew = (username: 'AndrewJohnson', name: 'Andrew Johnson', role: 'Technician', years: 0.2601, strikes: 29);
const nick = (username: 'nsmith', name: 'Nick Smith', role: 'Lead Technician', years: 2.3792, strikes: 25);
const brett = (username: 'bmiller', name: 'Brett Miller', role: 'Technician', years: 1.6564, strikes: 29);
const daniel = (username: 'gbaty', name: 'Daniel Baty', role: 'Lead Technician', years: 2.7324, strikes: 27);
const techPeople = [andrew, nick, brett, daniel];

Map<int, (double, int)> _laborDays(TechPerson p, int year) => switch ((p.username, year)) {
      ('AndrewJohnson', 2026) => {for (final e in _andrew2026.entries) e.key: (e.value.$2, e.value.$3)},
      ('nsmith', 2026) => {for (final e in _nick2026.entries) e.key: (e.value.$2, e.value.$3)},
      ('nsmith', 2025) => {for (final e in _nick2025.entries) e.key: (e.value.$2, e.value.$3)},
      ('bmiller', 2026) => _brett2026,
      ('bmiller', 2025) => _brett2025,
      ('gbaty', 2026) => _daniel2026,
      ('gbaty', 2025) => _daniel2025,
      _ => const {},
    };

Map<int, TechMonth> _months(TechPerson p, int year) => switch ((p.username, year)) {
      ('AndrewJohnson', 2026) => _andrew2026,
      ('nsmith', 2026) => _nick2026,
      ('nsmith', 2025) => _nick2025,
      // Brett's and Daniel's pages only need their labor and days here; their job counts are left as one a day.
      _ => {for (final e in _laborDays(p, year).entries) e.key: (e.value.$2, e.value.$1, e.value.$2)},
    };

/// The year's distinct jobs (a job worked in two months counts once): production's totals for Andrew's and Nick's
/// 2026; otherwise the months added up, which is close enough for a fixture.
int _yearJobs(TechPerson p, int year) => switch ((p.username, year)) {
      ('AndrewJohnson', 2026) => 97,
      ('nsmith', 2026) => 134,
      _ => _months(p, year).values.fold(0, (s, m) => s + m.$1),
    };

int _yearLaborJobs(TechPerson p, int year) => switch ((p.username, year)) {
      ('AndrewJohnson', 2026) => 95,
      ('nsmith', 2026) => 125,
      ('nsmith', 2025) => 168,
      _ => _months(p, year).values.fold(0, (s, m) => s + m.$1),
    };

/// /users: the KPI list's people (what a direct link to a KPI page loads first).
List<Map<String, dynamic>> usersBody() => [
      for (final p in techPeople)
        {
          'id': p.username,
          'name': p.name,
          'jobTitle': p.role,
          'displayTitle': p.role,
          'avatarUrl': '',
          'integrityScore': 100,
          'missedCompletions': 0,
          'yearsWorked': p.years,
        },
      {'id': 'bhansberger', 'name': 'Bella Hansberger', 'jobTitle': 'Office', 'displayTitle': 'Office', 'avatarUrl': '', 'integrityScore': 100, 'yearsWorked': 2.0},
    ];

/// GET /api/employees/:username/kpis?year=Y for [who]. [newServer] false answers like the server before Oct 30, 2026:
/// no `laborDays` (year or month) and no `teamMembers`.
Map<String, dynamic> kpisBody(
  TechPerson who, {
  int year = 2026,
  bool newServer = true,
  List<Map<String, dynamic>>? reviews,
  ({int evals, int converted}) evalConversion = (evals: 0, converted: 0),
  bool supervisor = false,
}) {
  final mine = _months(who, year);
  var labor = 0.0, days = 0;
  for (final m in mine.values) {
    labor += m.$2;
    days += m.$3;
  }
  final myMonths = {for (final e in mine.entries) if (e.value.$3 > 0) e.key};
  // The rest of the team: every other current tech's rows pooled, month by month and for the year.
  final others = [for (final p in techPeople) if (p.username != who.username) p];
  final pooled = <int, (double, int)>{};
  var restLabor = 0.0, restDays = 0;
  for (final p in others) {
    for (final e in _laborDays(p, year).entries) {
      final cur = pooled[e.key] ?? (0.0, 0);
      pooled[e.key] = (cur.$1 + e.value.$1, cur.$2 + e.value.$2);
      restLabor += e.value.$1;
      restDays += e.value.$2;
    }
  }
  // The rest of the team over only the months this tech worked (the server's `team.sameMonths`, since Nov 2026).
  final same = [for (final e in pooled.entries) if (myMonths.contains(e.key)) e.value];
  final sameLabor = same.fold<double>(0, (s, m) => s + m.$1);
  final sameDays = same.fold<int>(0, (s, m) => s + m.$2);
  return {
    'success': true,
    'year': year,
    'generatedAt': '2026-10-30T14:28:00Z',
    'employee': {'id': 0, 'name': who.name, 'username': who.username, 'role': who.role, 'jobTitle': who.role, 'inventoryStrikes': who.strikes, 'warehouseStrikes': 0},
    'sales': null,
    'tech': {
      'jobs': _yearJobs(who, year),
      'laborJobs': _yearLaborJobs(who, year),
      'workDays': mine.values.fold<int>(0, (s, m) => s + m.$1),
      'laborDays': ?(newServer ? days : null),
      'laborDollars': _round2(labor),
      'laborPerDay': days > 0 ? _round2(labor / days) : null,
      'monthly': [
        for (final e in mine.entries)
          {
            'month': e.key,
            'jobs': e.value.$1,
            'labor': e.value.$2,
            if (newServer) 'laborDays': e.value.$3,
            'laborPerDay': e.value.$3 > 0 ? _round2(e.value.$2 / e.value.$3) : null,
          },
      ],
      'teamMonthly': [
        for (final e in (pooled.entries.toList()..sort((a, b) => a.key.compareTo(b.key))))
          if (e.value.$2 > 0)
            {
              'month': e.key,
              'laborPerDay': _round2(e.value.$1 / e.value.$2),
              if (newServer) 'labor': _round2(e.value.$1),
              if (newServer) 'days': e.value.$2,
            },
      ],
      'team': {
        'laborPerDay': restDays > 0 ? _round2(restLabor / restDays) : null,
        'avgInventoryStrikes': _round2(others.fold<int>(0, (s, p) => s + p.strikes) / others.length),
        'techs': others.length,
        if (newServer && pooled.isNotEmpty)
          'sameMonths': {
            'months': myMonths.toList()..sort(),
            'allMonths': pooled.entries.where((e) => e.value.$2 > 0).every((e) => myMonths.contains(e.key)),
            'laborPerDay': sameDays > 0 ? _round2(sameLabor / sameDays) : null,
            'labor': _round2(sameLabor),
            'days': sameDays,
          },
      },
      if (newServer)
        'teamMembers': [
          for (final p in techPeople)
            () {
              final rows = _laborDays(p, year).values;
              final l = rows.fold<double>(0, (s, r) => s + r.$1);
              final d = rows.fold<int>(0, (s, r) => s + r.$2);
              return {
                'username': p.username,
                'name': p.name,
                'labor': _round2(l),
                'laborDays': d,
                'laborPerDay': d > 0 ? _round2(l / d) : null,
                'inventoryStrikes': p.strikes,
              };
            }(),
        ],
      'satisfaction': (reviews ?? const []).isEmpty ? null : {'avg': 5.0, 'count': reviews!.length},
      'satisfactionMonthly': const [],
      'reviews': reviews ?? const [],
      'employeeRating': null,
      'evalConversion': {'evals': evalConversion.evals, 'converted': evalConversion.converted},
      'tracking': {'servicePackageCloseRate': true, 'jobCompletionEfficiency': false},
    },
    'supervisor': supervisor ? {'tracking': {'overtimeEfficiency': false, 'techImprovement': false}} : null,
    'office': null,
    'warehouse': null,
    'morale': null,
  };
}

/// A made-up review for [name] (the real ones name customers).
List<Map<String, dynamic>> reviewsFor(String first, {int count = 1}) => [
      for (var i = 0; i < count; i++)
        {
          'quote': i == 0
              ? '$first was on time, walked us through what was wrong with the opener and had the door running smoothly '
                  'before lunch. Friendly, careful and tidy. We will ask for $first again.'
              : '$first replaced both springs and explained how to keep the rollers in shape. Great service.',
          'customer': ['Sample customer A.', 'Sample customer B.'][i % 2],
          'source': 'Google · 5★',
          'rating': 5,
          'date': i == 0 ? '2025-05-09T00:00:00Z' : '2024-11-02T00:00:00Z',
        },
    ];

/// Production's callback figures on Nov 2, 2026 (strikes, callback jobs (corrected, old), completed jobs this year,
/// jobs since the last callback): Daniel's 2 of 18 and Nick's 1 of 9 are the same 11.1%.
const techStatsNov2 = {
  'bmiller': (3, 62, 62, 830, 9),
  'gbaty': (2, 18, 18, 197, 4),
  'nsmith': (1, 9, 9, 146, 3),
  'AndrewJohnson': (2, 29, 29, 150, 6),
};

/// GET /api/tech_stats?year=Y. [corrected] false gives the callback jobs as the server counted them before Oct 30,
/// 2026 (callback visits and visits with no day weight included). [figures] replaces the Oct 30 ones, and [company] the
/// company rate's callback visits and completed jobs (the Technicians dashboard's figure).
Map<String, dynamic> techStatsBody({
  int year = 2026,
  bool corrected = true,
  Map<String, (int, int, int, int, int)>? figures,
  ({int callbacks, int jobs})? company,
}) {
  final live = year >= 2026;
  // username: strikes, callback jobs (corrected, old), completed jobs this year, jobs since the last callback
  final all = figures ?? const {
    'bmiller': (3, 54, 61, 816, 14),
    'gbaty': (1, 16, 18, 193, 15),
    'nsmith': (0, 8, 10, 143, 8),
    'AndrewJohnson': (1, 22, 48, 137, 16),
  };
  final techs = [
    for (final p in techPeople)
      () {
        final f = all[p.username]!;
        return {
          'id': p.username,
          'name': p.name,
          'jobTitle': p.role,
          'avatarUrl': '',
          'completedJobsYtd': live ? f.$4 : 0,
          'callbackJobs': live ? (corrected ? f.$2 : f.$3) : 0,
          'callbackCount': live ? f.$1 : 0,
          'jobsSinceCallback': f.$5,
          'revenue': 0,
          'revenueGenerated': r'$0.00',
          'totalPenalties': r'$0.00',
        };
      }(),
  ];
  final strikes = live ? (company?.callbacks ?? all.values.fold<int>(0, (s, f) => s + f.$1)) : 0;
  final jobs = company?.jobs ?? 94;
  return {
    'generatedAt': '2026-10-30T14:25:00Z',
    'summary': {
      'metrics': {
        'year': year,
        'callbackRatePct': live ? strikes / jobs * 100 : null,
        'callbacks': strikes,
        'callbackJobs': live ? jobs : 0,
        'callbackPeriod': live ? {'from': '2026-10-05', 'to': '2026-10-30'} : null,
        'techCount': 4,
      },
      'chartData': const [],
    },
    'techs': techs,
  };
}

/// The callback visits behind a tech's strikes (/api/employees/:id/callbacks).
Map<String, dynamic> callbacksBody(int count) => {
      'success': true,
      'count': count,
      'items': [
        for (var i = 0; i < count; i++)
          {'jobId': '${48100 + i}', 'customerName': 'Sample customer ${i + 1}', 'category': 'Residential Service', 'status': 'Paid in Full', 'statusColor': null, 'date': '2026-10-${19 - i}'},
      ],
    };

/// A JSON answer.
http.Response jsonResponse(Object body, [int status = 200]) =>
    http.Response(json.encode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});
