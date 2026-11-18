// The Product Catalog's API calls (lib/services/line_items_api.dart) against a fake server: what they send and what they
// read back, for the data-safety rules (only changed fields, duplicates confirmed, stock links that need review).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/services/line_items_api.dart';

void main() {
  test('a catalog entry carries why its stock needs review', () {
    final e = CatalogEntry.fromJson({'key': 'cat:16', 'name': 'Sure-Stop LH', 'stock': null, 'inventoryConflict': 'duplicate_name'});
    expect(e.inventoryConflict, 'duplicate_name');
    expect(e.stock, isNull);
    expect(CatalogEntry.fromJson({'key': 'cat:2', 'name': 'Bearing', 'stock': 65}).inventoryConflict, isNull);
  });

  test('a product page reads the stock link: a conflict comes back with no stock', () async {
    final page = await http.runWithClient(
      () => LineItemsApi.getProduct(16),
      () => MockClient((req) async => http.Response(
            jsonEncode({
              'product': {'id': 16, 'name': 'Sure-Stop LH', 'unitPrice': 471.55, 'avgUnitCost': 94.31},
              'stock': null,
              'inventory': {'itemId': null, 'link': null, 'conflict': 'duplicate_name'},
              'canSeeCost': true,
              'canEdit': true,
            }),
            200,
          )),
    );
    expect(page.stock, isNull);
    expect(page.inventoryConflict, 'duplicate_name');
  });

  test('a 409 DUPLICATE becomes an error that names the other products', () async {
    Object? error;
    await http.runWithClient(
      () async {
        try {
          await LineItemsApi.updateProduct(158, {'name': 'Sure-Stop LH'}, expectedUpdatedAt: '2026-11-16T15:52:00.045Z');
        } catch (e) {
          error = e;
        }
      },
      () => MockClient((req) async => http.Response(
            jsonEncode({
              'code': 'DUPLICATE',
              'error': 'Another product already has this name: Sure-Stop LH.',
              'duplicates': [
                {'id': 16, 'name': 'Sure-Stop LH', 'partNumber': '120420', 'matches': ['name']},
              ],
            }),
            409,
          )),
    );
    final e = error as LineItemsException;
    expect(e.status, 409);
    expect(e.code, 'DUPLICATE');
    expect(e.duplicates.single, (id: 16, name: 'Sure-Stop LH', partNumber: '120420'));
  });

  test('saving after the person confirmed a duplicate says so; otherwise it does not', () async {
    final bodies = <Map<String, dynamic>>[];
    await http.runWithClient(
      () async {
        await LineItemsApi.updateProduct(158, {'name': 'X'}, expectedUpdatedAt: 't');
        await LineItemsApi.updateProduct(158, {'name': 'X'}, expectedUpdatedAt: 't', confirmDuplicate: true);
        await LineItemsApi.createProduct({'name': 'Y'}, confirmDuplicate: true);
      },
      () => MockClient((req) async {
        bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response(jsonEncode({'product': {'id': 158, 'name': 'X'}}), 200);
      }),
    );
    expect(bodies[0], {'name': 'X', 'expectedUpdatedAt': 't'});
    expect(bodies[1], {'name': 'X', 'expectedUpdatedAt': 't', 'confirmDuplicate': true});
    expect(bodies[2], {'name': 'Y', 'confirmDuplicate': true});
  });
}
