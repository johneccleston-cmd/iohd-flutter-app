// Real-browser / real-desktop harness (the app part; services_harness.dart adds the browser finders,
// services_harness_desktop.dart runs it as a Windows app) for the Services Catalog UX audit (2026-11-19). LOCAL ONLY: never shipped.
//
// Runs the real Services Catalog list and the real service page with the app's own theme (officeTheme), signed in as
// an admin with a fake in-memory session, on the prod-shaped fixture. Every read and save is a fake in this file: no
// request leaves the machine, so it is safe to click Save, bulk-change and export.
//
//   flutter build web --release -t tool/ux_harness/services_harness.dart --output build/ux_harness
//   flutter run -d windows -t tool/ux_harness/services_harness.dart
//
// On the web it exposes window.uxRect(key) / window.uxText(text) so a DevTools-protocol driver can find a widget by its
// ValueKey (or its text) and click it at real coordinates, and window.uxFocus() to say what has the keyboard.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:iohd_desktop/config/auth_session.dart';
import 'package:iohd_desktop/main.dart' show officeTheme;
import 'package:iohd_desktop/service_detail_screen.dart';
import 'package:iohd_desktop/services/line_items_api.dart';
import 'package:iohd_desktop/services_catalog_screen.dart';
import 'package:iohd_desktop/widgets/leave_guard.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test/services_catalog_fixture.dart';

/// The catalog as the fakes keep it (saves land here, so the list and the page agree like the real app).
/// The service with rate lines goes last: the fixture's plain copy of it has the same key.
final Map<String, CatalogEntry> _db = {for (final e in [...kProdLikeServices, kServiceWithRates, kResidentialServicePackage]) e.key: e};

Future<CatalogResult> _load() async {
  await Future<void>.delayed(const Duration(milliseconds: 350)); // a quick server
  return (entries: _db.values.toList(), canSeeCost: true, historyDays: 540);
}

CatalogEntry _with(CatalogEntry e, {Map<String, dynamic> f = const {}, List<ServiceRate>? rates}) {
  final edited = {...e.editedFields, ...f.keys, if (rates != null) 'rates'}.toList();
  String s(String k, String was) => f.containsKey(k) ? (f[k] as String?) ?? was : was;
  return CatalogEntry(
    key: e.key,
    name: s('name', e.name),
    kind: e.kind,
    category: s('category', e.group),
    group: s('category', e.group),
    rate: rates != null && rates.isNotEmpty ? rates.first.rate : e.rate,
    cost: rates != null && rates.isNotEmpty ? rates.first.cost : e.cost,
    uses: e.uses,
    rateUses: e.rateUses,
    lastUsed: e.lastUsed,
    rateMin: e.rateMin,
    rateMax: e.rateMax,
    taxable: f.containsKey('taxable') ? (f['taxable'] as bool?) ?? e.taxable : e.taxable,
    active: f.containsKey('active') ? (f['active'] as bool?) ?? true : e.active,
    description: s('description', e.description),
    editedFields: edited,
    editedBy: 'Harness Admin',
    editedAt: DateTime.now().toUtc().toIso8601String(),
    computed: e.computed ?? {'name': e.name, 'category': e.group, 'description': e.description, 'rate': e.rate, 'cost': e.cost, 'taxable': e.taxable, 'active': e.active},
    rates: rates ?? e.rates,
    commission: f.containsKey('commission') ? f['commission'] as ServiceCommission? : e.commission,
    supersededBy: e.supersededBy,
    replaces: e.replaces,
    products: e.products,
  );
}

Future<CatalogEntry> _save(String key, Map<String, dynamic> fields) async {
  await Future<void>.delayed(const Duration(milliseconds: 450));
  return _db[key] = _with(_db[key]!, f: fields);
}

Future<CatalogEntry> _saveRates(String key, List<ServiceRate> rates) async {
  await Future<void>.delayed(const Duration(milliseconds: 300));
  return _db[key] = _with(_db[key]!, rates: rates);
}

Future<bool> _export(String name, Uint8List bytes) async => true;

/// A product catalog for PRODUCTS USED's search (2026-11-24): enough matches for "lift" to fill the results list.
final List<CatalogEntry> _products = [
  for (final (i, name) in const [
    'LiftMaster 6690L Wall-Mount Operator',
    'LiftMaster 877MAX Keypad',
    'LiftMaster 893MAX Remote',
    'LiftMaster 8500W Jackshaft Operator',
    'LiftMaster 87504 Belt Drive Operator',
    'LiftMaster Safety Sensor Kit',
    'LiftMaster 41A5034 Safety Sensors',
    'LiftMaster Battery Backup 485LM',
    'LiftMaster Wireless Keypad 878MAX',
    'LiftMaster Smart Video Keypad',
    'Torsion Spring 250 x 2 x 32',
    'Lift Cable 1/8 x 8 ft',
  ].indexed)
    CatalogEntry(key: 'inv:h$i', name: name, kind: 'product', sku: 'H-${100 + i}', rate: 25.0 + i * 37, cost: 10.0 + i * 15, stock: 3 + i),
];

Future<List<CatalogEntry>> _productSearch(String q) async {
  await Future<void>.delayed(const Duration(milliseconds: 200));
  final words = q.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  return [for (final e in _products) if (words.every((w) => e.name.toLowerCase().contains(w) || e.sku.toLowerCase().contains(w))) e];
}

Future<CatalogEntry> _saveProducts(String key, List<ServiceProduct> products) async {
  await Future<void>.delayed(const Duration(milliseconds: 300));
  final e = _db[key]!;
  final withEntries = [for (final p in products) ServiceProduct(key: p.key, name: p.name, qty: p.qty, entry: _products.where((x) => x.key == p.key).firstOrNull ?? p.entry)];
  return _db[key] = CatalogEntry(
    key: e.key, name: e.name, kind: e.kind, category: e.category, group: e.group, rate: e.rate, cost: e.cost, uses: e.uses,
    rateUses: e.rateUses, lastUsed: e.lastUsed, taxable: e.taxable, active: e.active, description: e.description,
    editedFields: {...e.editedFields, 'products'}.toList(), editedBy: 'Harness Admin', editedAt: DateTime.now().toUtc().toIso8601String(),
    computed: e.computed, rates: e.rates, products: withEntries, commission: e.commission,
  );
}

final harnessRouter = GoRouter(
  initialLocation: '/inventory/services',
  routes: [
    GoRoute(
      path: '/inventory/services',
      builder: (context, state) => ServicesCatalogScreen(load: _load, saver: _save, exporter: _export, canEdit: true),
      routes: [
        GoRoute(
          path: 'item',
          onExit: (context, state) => LeaveGuard.confirm(),
          builder: (context, state) {
            final key = state.uri.queryParameters['key'] ?? '';
            return ServiceDetailScreen(
              key: ValueKey('service-$key'),
              serviceKey: key,
              initial: state.extra is CatalogEntry ? state.extra as CatalogEntry : null,
              loader: _load,
              saver: _save,
              ratesSaver: _saveRates,
              productsSaver: _saveProducts,
              productSearch: _productSearch,
            );
          },
        ),
      ],
    ),
  ],
);

/// Signs in a fake admin and runs the harness. [beforeRun] adds the browser finders on the web.
Future<void> runServicesHarness({VoidCallback? beforeRun}) async {
  WidgetsFlutterBinding.ensureInitialized();
  // An admin, in memory only (no stored session is read or written).
  final payload = base64Url.encode(utf8.encode(json.encode({'exp': DateTime(2100).millisecondsSinceEpoch})));
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({
    'iohd_auth_session': json.encode({'token': '$payload.sig', 'name': 'Harness Admin', 'role': 'Admin', 'is_admin': true, 'denied': <String>[]}),
  });
  await AuthSession.instance.restore();
  beforeRun?.call();
  runApp(
    MaterialApp.router(
      title: 'UX harness: Services Catalog',
      debugShowCheckedModeBanner: false,
      theme: officeTheme(),
      routerConfig: harnessRouter,
      builder: (context, child) => Column(
        children: [
          // Stands in for the app's 60 px nav bar, so the page has the room it has in the app.
          Container(height: 60, color: const Color(0xFF14213D)),
          Expanded(child: child!),
        ],
      ),
    ),
  );
}

