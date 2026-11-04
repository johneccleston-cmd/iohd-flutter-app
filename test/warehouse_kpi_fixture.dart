// Fixtures for the warehouse KPI page (lib/employee_kpi_warehouse.dart): what /users and
// /api/employees/dgray/kpis answer for Dennis Gray. The headline figures are production's (read from the live database
// 2026-10-20: strikes, zones, cycle counts, low stock, stock value, jobs); the accuracy weeks, stock gaps, cycle history,
// monthly lines and open purchase orders are made up to be the shape of the real thing.

import 'package:http/http.dart' as http;
import 'dart:convert';

const dennis = (username: 'dgray', name: 'Dennis Gray', role: 'warehouse', title: 'Warehouse Technician', years: 2.0);

/// /users: the KPI list's people (what a direct link to a KPI page loads first). The role is the stored one; the
/// title is only what is printed.
List<Map<String, dynamic>> whUsersBody() => [
      {
        'id': dennis.username,
        'name': dennis.name,
        'jobTitle': dennis.role,
        'displayTitle': dennis.title,
        'avatarUrl': '',
        'integrityScore': 90.0,
        'yearsWorked': dennis.years,
      },
      {'id': 'bhansberger', 'name': 'Bella Hansberger', 'jobTitle': 'Office', 'displayTitle': 'Office', 'avatarUrl': '', 'integrityScore': 100, 'yearsWorked': 2.0},
    ];

/// The `warehouse` part of the KPI answer for [year]. Past years have the same live figures (the server has no past
/// for stock, purchase orders, zones or strikes) and their own counts.
Map<String, dynamic> warehousePart({int year = 2026}) => {
      'companyWide': true,
      'strikes': 10,
      'zones': [
        {'zone': 'Zone 1', 'periodStart': '2026-10-07', 'status': 'Not started', 'counted': 0, 'completedAt': null, 'overdue': true},
        {'zone': 'Zone 2', 'periodStart': '2026-10-14', 'status': 'In progress', 'counted': 31, 'completedAt': null, 'overdue': true},
        {'zone': 'Zone 3', 'periodStart': '2026-09-16', 'status': 'Complete', 'counted': 82, 'completedAt': '2026-10-16T18:41:57Z', 'overdue': false},
        {'zone': 'Zone 4', 'periodStart': '2026-10-28', 'status': 'Not started', 'counted': 0, 'completedAt': null, 'overdue': false},
      ],
      'cycleDone': year == 2026 ? 2 : 11,
      'itemsCounted': year == 2026 ? 159 : 880,
      'lastCycleCount': year == 2026 ? '2026-10-16T18:41:57Z' : '2025-12-12T18:00:00Z',
      'lowStockCount': 132,
      'stockValue': 55199,
      'teamInventoryStrikes': 5,
      'callbackStrikes': year == 2026 ? 0 : 1,
      'jobsCompleted': year == 2026 ? 41 : 63,
      // By the month Dennis worked the job (like the technicians' pages).
      'jobsMonthly': year == 2026 ? [0, 0, 3, 6, 5, 8, 7, 6, 4, 2, 0, 0] : [3, 4, 6, 5, 7, 6, 8, 6, 5, 5, 4, 4],
      'cycleMonthly': year == 2026 ? [0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0] : [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
      'history': {
        'lowStock': [41, 40, 42, 39, 37, 38, 35],
        'teamStrikes': [3, 3, 4, 4, 4, 5, 5],
        // The team card's own figure, the techs' strikes plus Dennis's 15.
        'teamStrikesWithMe': [18, 18, 19, 19, 19, 20, 20],
      },
      'inventoryAccuracy': {'counted': 160, 'matched': 151, 'pct': 94.4},
      'openPos': {
        'count': 7,
        'value': 18420.5,
        'overdue': 2,
        'oldest': '2026-09-14',
        'aging': [
          {'label': '0-7 days', 'count': 2, 'value': 3200.0},
          {'label': '8-14 days', 'count': 1, 'value': 1100.5},
          {'label': '15-30 days', 'count': 3, 'value': 9120.0},
          {'label': '31+ days', 'count': 1, 'value': 5000.0},
        ],
      },
      'accuracyTrend': [
        {'week': '2026-08-03', 'counted': 22, 'pct': 90.9},
        {'week': '2026-08-10', 'counted': 30, 'pct': 93.3},
        {'week': '2026-08-17', 'counted': 18, 'pct': 94.4},
        {'week': '2026-08-24', 'counted': 25, 'pct': 92.0},
        {'week': '2026-09-07', 'counted': 28, 'pct': 96.4},
        {'week': '2026-09-14', 'counted': 20, 'pct': 95.0},
        {'week': '2026-09-21', 'counted': 17, 'pct': 94.1},
      ],
      // Production's gaps of Oct 23, 2026 (Zone 4): every one was stock on the shelf the system didn't have.
      'topMisses': [
        {'name': 'End Bearing Plate | Residential 12GA | LH 3-3/8" × 1"', 'systemQty': 0, 'countedQty': 32, 'cost': 5.94},
        {'name': 'Bottom Bracket | Residential | LH | SRBB-75', 'systemQty': 0, 'countedQty': 31, 'cost': 2.71},
        {'name': 'Bottom Bracket | Residential | RH | SRBB-75', 'systemQty': 0, 'countedQty': 31, 'cost': 2.71},
        {'name': 'Drum RC | SL | RH D400-96', 'systemQty': 11, 'countedQty': 42, 'cost': 4.91},
        {'name': 'Drum RC | SL | LH D400-96', 'systemQty': 13, 'countedQty': 42, 'cost': 4.91},
        {'name': 'End Bearing Plate | Commercial | RH 6"', 'systemQty': 0, 'countedQty': 6, 'cost': 11.17},
        {'name': 'End Bearing Plate | Commercial | LH 6"', 'systemQty': 0, 'countedQty': 5, 'cost': 11.17},
        {'name': 'Bearing RC | Steel | 1"', 'systemQty': 64, 'countedQty': 65, 'cost': 2.42},
      ],
      'stockGaps': {'shortItems': 0, 'extraItems': 8, 'shortUnits': 0, 'extraUnits': 166, 'shortValue': 0, 'extraValue': 778},
      'coverage': {'items': 215, 'value': 55075},
      // Production's stock health of Nov 2, 2026; the records to fix count only items with stock on hand (Nov 3).
      'stockHealth': {
        'empty': 86,
        'low': 46,
        'ok': 62,
        'noReorder': 29,
        'noLocation': 53,
        'noCost': 4,
        'byCategory': [
          {'category': 'Miscellaneous', 'empty': 4, 'low': 12, 'ok': 7},
          {'category': 'Operator Parts', 'empty': 19, 'low': 0, 'ok': 0},
          {'category': 'Weather Seal', 'empty': 2, 'low': 13, 'ok': 12},
          {'category': 'Hardware', 'empty': 14, 'low': 0, 'ok': 0},
          {'category': 'Torsion Spring - RC', 'empty': 9, 'low': 4, 'ok': 2},
          {'category': 'Hinge - Com', 'empty': 4, 'low': 3, 'ok': 3},
        ],
      },
      // Each zone is counted in the week of the Nth Wednesday of the month (Zone 1 the first, and so on). Counts were only
      // recorded from Oct 5, 2026, so May and June are from before; Zone 2 missed two, Zone 4's October week is still open.
      'cycleHistory': [
        for (final n in [1, 2, 3, 4])
          {
            'zone': 'Zone $n',
            'weeks': [
              for (final m in [5, 6, 7, 8, 9, 10])
                {
                  'periodStart': _nthWednesday(2026, m, n),
                  'status': m < 7
                      ? 'Untracked'
                      : (n == 2 && (m == 8 || m == 10))
                          ? 'Missed'
                          : (n == 3 && m == 9)
                              ? 'Missed'
                              : (n == 4 && m == 10)
                                  ? 'Pending'
                                  : 'Complete',
                },
            ],
          },
      ],
      'itemCount': 443,
      'tracking': {'pickAccuracy': false, 'receivingTime': false, 'orderFillRate': false},
    };

/// 'YYYY-MM-DD' of the [n]th Wednesday of [month].
String _nthWednesday(int year, int month, int n) {
  var d = DateTime.utc(year, month, 1);
  while (d.weekday != DateTime.wednesday) {
    d = d.add(const Duration(days: 1));
  }
  return d.add(Duration(days: 7 * (n - 1))).toIso8601String().substring(0, 10);
}

/// GET /api/employees/:username/kpis?year=Y for Dennis.
Map<String, dynamic> whKpisBody({int year = 2026, bool withWarehouse = true, Map<String, dynamic>? warehouse}) => {
      'success': true,
      'year': year,
      'employee': {'id': 31, 'role': 'warehouse', 'inventoryStrikes': 15, 'warehouseStrikes': 0},
      if (withWarehouse) 'warehouse': warehouse ?? warehousePart(year: year),
    };

/// The callback visits behind a person's strikes (/api/employees/:id/callbacks).
Map<String, dynamic> whCallbacksBody(int count) => {
      'success': true,
      'count': count,
      'items': [
        for (var i = 0; i < count; i++)
          {'jobId': '${48100 + i}', 'customerName': 'Sample customer ${i + 1}', 'category': 'Residential Service', 'status': 'Paid in Full', 'statusColor': null, 'date': '2026-10-${19 - i}'},
      ],
    };

/// A JSON answer.
http.Response whJson(Object body, [int status = 200]) =>
    http.Response(json.encode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});
