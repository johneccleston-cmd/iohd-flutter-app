// A fake purchase orders backend for the PO list and PO page tests: the same routes and answers as
// integrity-backend/src/purchase_orders.js (totals worked out in whole cents per line, blank PO numbers numbered, a
// stale edit refused with 409), held in memory. Dates are set relative to today, so "5 days late" stays true.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/purchase_orders_api.dart';
import 'package:iohd_desktop/services/line_items_api.dart';

/// Today plus [days], as the server writes dates.
String poDayFromToday(int days) {
  final t = poToday();
  return poIso(DateTime(t.year, t.month, t.day + days)); // calendar days: safe across daylight saving
}

class FakePoServer {
  final Map<int, Map<String, dynamic>> orders = {};
  final List<http.Request> requests = [];

  /// False: a server from before line items (no `features`, no single-PO route).
  bool features = true;

  /// The next save answers 409 (someone else changed the PO).
  bool conflictNext = false;

  /// Every request answers this status (a server error) until cleared.
  int? failWith;
  int _stamp = 0;

  late final http.Client client = MockClient(_handle);

  FakePoServer({bool seed = true}) {
    if (seed) _seed();
  }

  Map<String, dynamic> get lastBody => json.decode(requests.lastWhere((r) => r.method == 'PUT' || r.method == 'POST').body) as Map<String, dynamic>;
  List<http.Request> sent(String method) => [for (final r in requests) if (r.method == method) r];

  void _seed() {
    add({
      'id': 1, 'poNumber': 'PO-2026-1001', 'vendor': 'Clopay', 'status': 'Open', //
      'orderDate': poDayFromToday(-12), 'expectedDate': poDayFromToday(-5), 'shipping': 25, 'vendorRef': 'SO-88123',
      'lines': [
        {'name': 'Torsion spring | 250 x 2 x 32', 'sku': 'TS-250', 'productId': 12, 'qty': 2, 'unitCost': 48.75, 'received': 0},
        {'name': 'Lift cable | 8 ft', 'sku': 'LC-8', 'productId': 13, 'qty': 4, 'unitCost': 12.5, 'received': 0},
      ],
    });
    add({
      'id': 2, 'poNumber': 'PO-2026-1002', 'vendor': 'LiftMaster', 'status': 'Open', //
      'orderDate': poDayFromToday(-3), 'expectedDate': poDayFromToday(3), 'jobNumber': '1096183137',
      'lines': [
        {'name': 'Opener | 8500W Wall Mount', 'sku': '8500W', 'productId': 20, 'qty': 2, 'unitCost': 310, 'received': 1},
        {'name': 'Remote | 893MAX', 'sku': '893MAX', 'productId': 21, 'qty': 6, 'unitCost': 22.5, 'received': 0},
      ],
      'notes': 'Second opener is on backorder until next week.',
    });
    add({
      'id': 3, 'poNumber': 'PO-2026-1003', 'vendor': 'Amarr', 'status': 'Received', //
      'orderDate': poDayFromToday(-40), 'expectedDate': poDayFromToday(-31), 'receivedDate': poDayFromToday(-30),
      'lines': [
        {'name': 'Section | 16x7 Stratford', 'sku': 'AM-STR', 'productId': 30, 'qty': 1, 'unitCost': 480, 'received': 1},
      ],
    });
    add({
      'id': 4, 'poNumber': 'PO-2026-1004', 'vendor': 'Clopay', 'status': 'Draft', //
      'orderDate': poDayFromToday(-1), 'jobNumber': '1099563432',
      'lines': [
        {'name': 'Weather seal | 9 ft', 'sku': 'WS-9', 'productId': 40, 'qty': 3, 'unitCost': 19.99, 'received': 0},
      ],
    });
    add({'id': 5, 'poNumber': 'PO-2026-1005', 'vendor': 'Windsor Door', 'status': 'Canceled', 'orderDate': poDayFromToday(-20), 'total': 1200});
    add({'id': 6, 'poNumber': 'PO-2026-1006', 'vendor': 'DH Pace', 'status': 'Open', 'orderDate': poDayFromToday(-2), 'total': 860});
  }

  void add(Map<String, dynamic> po) {
    final p = {
      'notes': '', 'vendorRef': '', 'jobNumber': '', 'shipping': 0, 'lines': <dynamic>[], 'total': 0, //
      'createdBy': 'Heather Vera', 'updatedBy': 'Heather Vera', 'createdAt': '2026-11-20T15:00:00.000Z',
      ...po,
    };
    p['total'] = _total(p);
    p['updatedAt'] = _nextStamp();
    orders[p['id'] as int] = p;
  }

  String _nextStamp() => DateTime.utc(2026, 11, 21, 12).add(Duration(seconds: ++_stamp)).toIso8601String();

  static double _total(Map<String, dynamic> p) {
    final lines = (p['lines'] as List? ?? const []).cast<Map>();
    if (lines.isEmpty) return (p['total'] as num?)?.toDouble() ?? 0;
    final cents = lines.fold<int>(0, (s, l) => s + ((l['qty'] as num) * (l['unitCost'] as num) * 100).round());
    return (cents + (((p['shipping'] as num?) ?? 0) * 100).round()) / 100;
  }

  http.Response _json(Object body, [int status = 200]) =>
      http.Response(json.encode(body), status, headers: {'content-type': 'application/json'});

  Future<http.Response> _handle(http.Request req) async {
    requests.add(req);
    if (failWith != null) return _json({'success': false, 'error': 'Could not reach the purchase orders. Try again.'}, failWith!);
    final path = req.url.path;
    final m = RegExp(r'^/api/purchase-orders(?:/(\d+))?$').firstMatch(path);
    if (m == null) return http.Response('not found', 404);
    final id = m[1] == null ? null : int.parse(m[1]!);
    final featureList = features ? ['lines', 'drafts', 'versions'] : null;
    switch (req.method) {
      case 'GET' when id == null:
        final list = orders.values.toList()..sort((a, b) => '${b['orderDate']}'.compareTo('${a['orderDate']}'));
        return _json({'success': true, 'features': ?featureList, 'purchaseOrders': list});
      case 'GET':
        if (!features) return http.Response('<pre>Cannot GET $path</pre>', 404);
        final po = orders[id];
        return po == null
            ? _json({'success': false, 'error': 'That PO is not on file. It may have been deleted.'}, 404)
            : _json({'success': true, 'features': featureList, 'purchaseOrder': po});
      case 'POST':
        final b = json.decode(req.body) as Map<String, dynamic>;
        final newId = orders.keys.fold(0, (a, b) => a > b ? a : b) + 1;
        final number = '${b['poNumber'] ?? ''}'.trim().isEmpty ? 'PO-2026-${1000 + newId}' : b['poNumber'];
        add({...b, 'id': newId, 'poNumber': number, 'createdAt': DateTime.now().toUtc().toIso8601String()});
        return _json({'success': true, 'purchaseOrder': orders[newId]}, 201);
      case 'PUT':
        if (conflictNext) {
          conflictNext = false;
          return _json({
            'success': false,
            'conflict': true,
            'error': 'Someone else changed this PO after you opened it. Reload it to see their changes, then make yours again.',
          }, 409);
        }
        final old = orders[id];
        if (old == null) return _json({'success': false, 'error': 'That PO no longer exists.'}, 404);
        final b = json.decode(req.body) as Map<String, dynamic>..remove('updatedAt');
        if (!features) {
          for (final k in ['lines', 'shipping', 'vendorRef', 'jobNumber']) {
            b.remove(k);
          }
        }
        final next = {...old, ...b, 'id': id, 'updatedBy': 'Heather Vera'};
        if (b['status'] != 'Received') next['receivedDate'] = null;
        next['total'] = _total(next);
        next['updatedAt'] = _nextStamp();
        orders[id!] = next;
        return _json({'success': true, 'purchaseOrder': next});
      case 'DELETE':
        if (orders.remove(id) == null) return _json({'success': false, 'error': 'That PO no longer exists.'}, 404);
        return _json({'success': true});
    }
    return http.Response('bad method', 405);
  }
}

/// A catalog search that finds one torsion spring sold by two vendors, and a remote with only a catalog cost.
Future<List<CatalogEntry>> fakeCatalogSearch(String q) async => [
  if ('torsion spring 250'.contains(q.toLowerCase()) || q.toLowerCase().contains('spring'))
    CatalogEntry.fromJson({
      'key': 'cat:12',
      'name': 'Torsion spring | 250 x 2 x 32',
      'sku': 'TS-250',
      'kind': 'product',
      'cost': 44.0,
      'vendors': [
        {'name': 'iStore', 'price': 52.0},
        {'name': 'Clopay', 'price': 48.75},
      ],
    }),
  if (q.toLowerCase().contains('remote'))
    CatalogEntry.fromJson({'key': 'cat:21', 'name': 'Remote | 893MAX', 'sku': '893MAX', 'kind': 'product', 'cost': 21.0, 'vendors': []}),
];

/// The view a test draws in: big enough for the two-column page unless a test says otherwise.
void poView(WidgetTester t, [Size size = const Size(1440, 1000)]) {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}
