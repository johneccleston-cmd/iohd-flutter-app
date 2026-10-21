// Renders the Team screen's profile header, scorecard and team overview with fake KPI data, and saves screenshots to
// test/shots/. Run:  flutter test test/team_profile_render_test.dart --update-goldens
//
// The covers and status dots animate forever, so these tests pump fixed amounts of time instead of pumpAndSettle.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/team_admin_screen.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final bytes = File(p).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
  }
  await loader.load();
}

Map<String, dynamic> _user(int id, String name, String role, {Map<String, dynamic> extra = const {}}) => {
  'id': id,
  'name': name,
  'username': name.split(' ').first.toLowerCase(),
  'role': role,
  'status': 'ACTIVE',
  'tech_weight': 1.0,
  'is_commission_eligible': role.toLowerCase().contains('tech'),
  'is_callback_eligible': role.toLowerCase().contains('tech'),
  'has_pin': true,
  'work_days_90': 0,
  'version': '1',
  ...extra,
};

final _users = [
  _user(1, 'Daniel Baty', 'Lead Technician', extra: {
    'tech_weight': 1.5,
    'is_lead': true,
    'no_recalls': true,
    'hire_date': '2024-02-05',
    'work_days_90': 52,
    'last_work_date': '2026-10-17',
    'inventory_strikes': 2,
    'tool_allowance': 500,
  }),
  _user(2, 'Brett Miller', 'Technician', extra: {
    'job_title': 'Residential Technician',
    'work_days_90': 61,
    'last_work_date': '2026-10-19',
    'five_star': true,
    'hire_date': '2021-06-14',
  }),
  _user(3, 'Heather Vera', 'Office Manager', extra: {
    'job_title': 'Sales Account Manager',
    'is_sales_commission_eligible': true,
    'tech_weight': 0.0,
    'sales_rate_pct': 2.0,
    'sales_builder_rate_pct': 2.0,
    'five_star': true,
    'badge_team_favorite': true,
    'hire_date': '2021-03-15',
  }),
  _user(4, 'Zac Clemens', 'Sales Rep', extra: {'job_title': 'Commercial Estimator', 'year_joined': 2026}),
  _user(5, 'Dennis Gray', 'Warehouse', extra: {'job_title': 'Warehouse Technician', 'hire_date': '2023-09-01'}),
  _user(6, 'Bella Hansberger', 'Office', extra: {'hire_date': '2025-01-06'}),
  _user(7, 'John Eccleston', 'ADMIN'),
  _user(8, 'Ryan Schwartz', 'ADMIN', extra: {'work_days_90': 9, 'last_work_date': '2026-10-08'}),
  _user(9, 'Aaron Pendergrass', 'Technician', extra: {'status': 'Inactive', 'has_pin': false}),
  _user(10, 'Nick Smith', 'Lead Technician', extra: {'has_pin': false, 'work_days_90': 0}),
];

List<Map<String, dynamic>> _months(List<double> labor, List<double> perDay) => [
  for (var i = 0; i < labor.length; i++) {'month': i + 1, 'labor': labor[i], 'laborPerDay': perDay[i], 'jobs': 14},
];

final Map<int, Map<String, dynamic>> _kpis = {
  1: {
    'tech': {
      'jobs': 168,
      'laborJobs': 142,
      'laborDollars': 184320.5,
      'laborPerDay': 2614.2,
      'monthly': _months(
        [14100, 15800, 17200, 16900, 18800, 19900, 21000, 20400, 22100, 18100],
        [2100, 2250, 2390, 2310, 2520, 2700, 2810, 2690, 2880, 2614],
      ),
      'team': {'laborPerDay': 2211, 'avgInventoryStrikes': 4.2, 'techs': 4},
      'satisfaction': {'avg': 4.9, 'count': 12},
      'reviews': [],
    },
  },
  2: {
    'tech': {
      'jobs': 733,
      'laborJobs': 690,
      'laborDollars': 194300,
      'laborPerDay': 987,
      'monthly': _months(
        [16000, 17100, 19800, 21000, 18800, 20100, 22300, 21900, 19500, 17800],
        [930, 960, 1010, 1040, 980, 990, 1030, 1000, 970, 987],
      ),
      'team': {'laborPerDay': 2211, 'avgInventoryStrikes': 3.8, 'techs': 4},
      'satisfaction': {'avg': 4.8, 'count': 25},
    },
  },
  3: {
    'sales': {
      'wonCount': 86,
      'lostCount': 41,
      'closeRatePct': 67.7,
      'wonValue': 412500,
      'grossProfit': 171000,
      'marginPct': 41.5,
      'monthlyByType': {
        'residential': [
          for (final r in [28000, 31000, 36500, 41000, 39000, 44500, 47000, 43800, 51200, 50500, 0, 0])
            {'revenue': r, 'profit': r * 0.4},
        ],
      },
      'monthlyClose': [
        for (final (w, l) in [(6, 4), (7, 3), (8, 4), (9, 5), (8, 3), (10, 4), (9, 5), (9, 4), (11, 5), (9, 4), (0, 0), (0, 0)])
          {'won': w, 'lost': l},
      ],
      'pipeline': {
        'requested': {'count': 9, 'value': 38000},
        'provided': {'count': 22, 'value': 96500},
        'staleValue': 12000,
      },
    },
  },
  4: {
    'sales': {
      'wonCount': 3,
      'lostCount': 5,
      'closeRatePct': 37.5,
      'wonValue': 61200,
      'grossProfit': 18800,
      'marginPct': 30.7,
      'monthlyClose': [for (var m = 0; m < 12; m++) {'won': m == 9 ? 3 : 0, 'lost': m == 9 ? 5 : 0}],
    },
  },
  5: {
    'warehouse': {
      'companyWide': true,
      'strikes': 10,
      'zones': [
        {'zone': 'Zone 1', 'status': 'Not started', 'overdue': true},
        {'zone': 'Zone 2', 'status': 'Not started', 'overdue': true},
        {'zone': 'Zone 3', 'status': 'Complete', 'overdue': false},
        {'zone': 'Zone 4', 'status': 'In progress', 'overdue': false},
      ],
      'cycleDone': 3,
      'itemsCounted': 412,
      'lastCycleCount': '2026-10-16T15:00:00Z',
      'lowStockCount': 18,
      'stockValue': 183000,
      'itemCount': 1320,
    },
  },
  6: {
    'office': {
      'companyWide': true,
      'outstanding': 238133,
      'over90': 22577,
      'collected': 2440000,
      'collectionRatePct': 91.1,
      'collectedMonthly': [210000, 198000, 236000, 251000, 244000, 262000, 270000, 255000, 281000, 233000, 0, 0],
      'aging': [],
    },
  },
};

const _techStats = {
  'techs': [
    {'id': 'daniel', 'callbackCount': 1, 'completedJobsYtd': 160, 'jobsSinceCallback': 7},
    {'id': 'brett', 'callbackCount': 0, 'completedJobsYtd': 690, 'jobsSinceCallback': 31},
  ],
};

int _kpiDelayMs = 0;
bool _kpiFail = false;

Future<http.Response> _handle(http.Request r) async {
  final p = r.url.path;
  if (p.endsWith('/history')) return http.Response(jsonEncode({'success': true, 'history': []}), 200);
  if (p.endsWith('/tech_stats')) return http.Response(jsonEncode(_techStats), 200);
  final m = RegExp(r'/api/employees/(\d+)/kpis$').firstMatch(p);
  if (m != null) {
    if (_kpiDelayMs > 0) await Future<void>.delayed(Duration(milliseconds: _kpiDelayMs));
    if (_kpiFail) return http.Response('<html>502 Bad Gateway</html>', 502);
    final id = int.parse(m.group(1)!);
    final u = _users.firstWhere((u) => u['id'] == id);
    return http.Response(
      jsonEncode({
        'success': true,
        'year': 2026,
        'employee': {'id': id, 'name': u['name'], 'role': u['role'], 'inventoryStrikes': u['inventory_strikes'] ?? 0},
        ...?_kpis[id],
      }),
      200,
    );
  }
  return http.Response(
    jsonEncode({
      'success': true,
      'roles': [
        for (final n in ['Technician', 'Lead Technician', 'Sales Rep', 'Warehouse', 'Office', 'Office Manager', 'Admin', 'Owner'])
          {'name': n, 'grantsAdmin': const {'Admin', 'Owner'}.contains(n)},
      ],
      'users': _users,
    }),
    200,
  );
}

Future<void> _pumpFor(WidgetTester t, int ms) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _shot(
  WidgetTester tester,
  String name, {
  Size size = const Size(1440, 1000),
  String? select,
  int settleMs = 2600,
  bool calm = false,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await http.runWithClient(() async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        builder: calm
            ? (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!)
            : null,
        home: const TeamAdminScreen(),
      ),
    );
    await _pumpFor(tester, select == null ? settleMs : 600);
    if (select != null) {
      await tester.tap(find.text(select).first);
      await _pumpFor(tester, settleMs);
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/profile_$name.png'));
  }, () => MockClient(_handle));
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', [
      r'C:\Windows\Fonts\segoeui.ttf',
      r'C:\Windows\Fonts\segoeuib.ttf',
      r'C:\Windows\Fonts\seguisb.ttf',
    ]);
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
    await _loadFont('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
  });

  setUp(() {
    _kpiDelayMs = 0;
    _kpiFail = false;
  });

  testWidgets('team overview', (t) async => _shot(t, 'overview', size: const Size(1440, 900)));
  testWidgets('overview 1024', (t) async => _shot(t, 'overview_1024', size: const Size(1024, 768)));
  testWidgets('tech', (t) async => _shot(t, 'tech', select: 'Daniel Baty'));
  testWidgets('tech behind the team', (t) async => _shot(t, 'tech_behind', select: 'Brett Miller'));
  testWidgets('sales', (t) async => _shot(t, 'sales', select: 'Heather Vera'));
  testWidgets('new sales rep', (t) async => _shot(t, 'sales_new', select: 'Zac Clemens'));
  testWidgets('warehouse', (t) async => _shot(t, 'warehouse', select: 'Dennis Gray'));
  testWidgets('office', (t) async => _shot(t, 'office', select: 'Bella Hansberger'));
  testWidgets('admin', (t) async => _shot(t, 'admin', select: 'John Eccleston'));
  testWidgets('inactive', (t) async => _shot(t, 'inactive', select: 'Aaron Pendergrass'));
  testWidgets('needs attention', (t) async => _shot(t, 'attention', select: 'Nick Smith'));
  testWidgets('tech 1280x720', (t) async => _shot(t, 'tech_1280', size: const Size(1280, 720), select: 'Daniel Baty'));
  testWidgets('tech 1024x768', (t) async => _shot(t, 'tech_1024', size: const Size(1024, 768), select: 'Daniel Baty'));
  testWidgets('tech 1920x1080', (t) async => _shot(t, 'tech_1920', size: const Size(1920, 1080), select: 'Daniel Baty'));
  testWidgets('mid entrance', (t) async => _shot(t, 'tech_mid', select: 'Daniel Baty', settleMs: 350));
  testWidgets('reduced motion', (t) async => _shot(t, 'tech_calm', select: 'Daniel Baty', settleMs: 100, calm: true));
  testWidgets('loading', (t) async {
    _kpiDelayMs = 5000;
    await _shot(t, 'loading', select: 'Daniel Baty', settleMs: 700);
    await _pumpFor(t, 5000);
  });
  testWidgets('hovering a scorecard tile lifts it', (t) async {
    // Tests draw shadows without blur by default; turn the blur on so this shot shows the glow as the app does.
    debugDisableShadows = false;
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1440, 1000);
    addTearDown(t.view.reset);
    await http.runWithClient(() async {
      await t.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
          home: const TeamAdminScreen(),
        ),
      );
      await _pumpFor(t, 600);
      await t.tap(find.text('Daniel Baty').first);
      await _pumpFor(t, 2600);
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(t.getCenter(find.text('Labor per work day')));
      await _pumpFor(t, 400);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/profile_hover.png'));
    }, () => MockClient(_handle));
    debugDisableShadows = true;
  });
  testWidgets('kpi error', (t) async {
    _kpiFail = true;
    await _shot(t, 'error', select: 'Daniel Baty');
  });
}
