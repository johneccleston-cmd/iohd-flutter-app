// A fake backend for the job and estimate pages: the record, files, notes and tasks, and a line-items server that
// keeps the same rules as integrity-backend/src/line_items.js (versions, accepted options locked, one accepted option,
// sent to a job once, costs only for people who may see them), plus the catalog search. Used by
// job_page_shots_test.dart and job_page_behavior_test.dart.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/job_detail_screen.dart';
import 'package:iohd_desktop/widgets/page_selection.dart';

import 'dashboard_harness.dart';

const kJobId = '1096183137';
const kEstimateId = '1093839956';
const kOtherJobId = '1097000001';

Map<String, dynamic> jobRecord() => {
  'job': {
    'job_id': kJobId,
    'customer_name': 'Schuber Mitchell Homes',
    'contact_name': 'Dana Whitfield',
    'status': 'Final Invoice Sent',
    'sub_status': '14 Day Notice',
    'is_estimate': false,
    'category': 'Residential Install',
    'location': '1204 W Poplar St, Rogers, AR 72756',
    'description': 'Replace two garage doors, torsion springs and weather seal on lot 14.',
    'notes': 'Gate code 4471. Dog in the backyard.',
    'po_number': '74503920139',
    'techs_assigned': 'Brett Hall, Marcus Lee',
    'opportunity_owner': 'Heather Vera',
    'start_date': '2026-10-06',
    'end_date': '2026-10-07',
    'closed_at': '2026-10-09',
    'sf_created_at': '2026-09-28T15:00:00Z',
    'total_revenue': '1735.97',
    'due_total': '235.97',
    'sf_details': {
      'priority': 'Normal',
      'duration': 5400,
      'time_frame_promised_start': '08:00:00',
      'time_frame_promised_end': '10:00:00',
      'techs': [
        {'name': 'Brett Hall', 'status': 'Scheduled - Full Day'},
        {'name': 'Marcus Lee', 'status': 'Scheduled - Half Day'},
      ],
      'tasks': [
        {'description': 'Confirm the forklift rental for day two', 'is_completed': true},
        {'description': 'Send the final photos to the builder', 'is_completed': false},
      ],
      'notes': [
        {'text': 'Doors are unloaded on site.', 'created_at': '2026-10-02T19:44:00Z'},
      ],
      'pictures': [
        {'name': 'front-of-house.jpg', 'url': 'https://example.invalid/a.jpg', 'comment': 'Before'},
      ],
      'documents': [
        {'name': 'Signed work order.pdf', 'url': 'https://example.invalid/wo.pdf', 'type': 'Work Order', 'created_at': '2026-10-07T15:00:00Z'},
      ],
      'visits': [
        {
          'start_date': '2026-10-06',
          'time_frame_promised_start': '08:00:00',
          'time_frame_promised_end': '10:00:00',
          'duration': 5400,
          'notes_for_techs': 'Bring the 5K forklift.',
          'techs': [
            {'name': 'Brett Hall', 'status': 'Scheduled - Full Day'},
          ],
        },
        {
          'start_date': '2026-10-07',
          'time_frame_promised_start': '13:00:00',
          'time_frame_promised_end': '15:30:00',
          'duration': 3600,
          'techs': [
            {'name': 'Marcus Lee', 'status': 'Scheduled - Half Day'},
          ],
        },
      ],
    },
    // Two doors, stop mold and the install: products taxed at 10.5%, the install not.
    'raw_items': [
      {'item_index': 3, 'name': 'SMH | Gallery Steel | GD5S | Complete Door | Sandtone (Clay)', 'product': 'SMH | Gallery Steel | GD5S | Complete Door | Sandtone (Clay)', 'description': '16x7 GD5S complete door, 1-layer, solid', 'multiplier': 2, 'rate': 527.72, 'total': 1055.44, 'cost': 1014.32, 'tax': 'Sales Tax'},
      {'item_index': 6, 'name': "Stop Mold | 7' Sandtone", 'product': "Weather Seal | Stop Mold | 7' Sandtone", 'multiplier': 4, 'rate': 4.46, 'total': 17.84, 'cost': 17.84, 'tax': 'Sales Tax'},
      {'item_index': 2, 'name': 'SMH Installation | Gallery Steel | 16x7 | Sandtone', 'service': 'SMH Installation | Gallery Steel | 16x7 | Sandtone', 'multiplier': 2, 'rate': 300, 'total': 600, 'cost': 0, 'tax': null},
    ],
    'other_charges': [
      {'name': 'Sales Tax (State, County, & Local Use Tax, Prairie Grove)', 'is_discount': false, 'is_percentage': true, 'rate': 10.5, 'total': 112.6944},
      {'name': 'Builder Relationship Discount', 'is_discount': true, 'is_percentage': false, 'rate': 50, 'total': 50},
    ],
  },
  'customer': {'primary_contact': 'Dana Whitfield', 'phone': '(479) 736-2125', 'email': 'dana@schubermitchell.com'},
  'fromEstimate': kEstimateId,
  'linkConfirmed': false,
  'statusCategory': 'Completed Jobs',
  'invoices': [
    // Shaped like prod's: terms "DUR", no payment_terms (so no due date), a notes line ending in SF's underscore rule.
    {
      'number': 12249,
      'total': 1735.97,
      'is_paid': false,
      'invoice_date': '2026-10-09T09:51:06Z',
      'due_date': null,
      'mail_send_date': '2026-10-09T15:58:09Z',
      'terms': 'DUR',
      'payment_terms': null,
      'customer_contact': 'Accounting',
      'notes': 'Two 16x7 Gallery Steel doors / Stop mold\n____________________________________________________',
      'pay_online_url': 'https://example.invalid/invoiceOnline?id=abc',
      'qbo_invoice_no': 12249,
    },
  ],
  'payments': [
    {'amount': '1500.00', 'received_on': '2026-10-09T15:00:00Z', 'payment_type': 'Check', 'transaction_type': 'Payment', 'reference_number': '4417'},
  ],
  'stripePayments': [
    // As the webhook writes them (stripe_payments.js): a memo naming the payment type, and the payment intent.
    {'id': 'stripe-pi_3Q1abc', 'amount': '250.00', 'received_on': '2026-10-17T15:00:00Z', 'kind': 'payment', 'memo': 'Stripe Deposit - job #1096183137 - Schuber Mitchell Homes', 'payment_intent': 'pi_3Q1abc'},
    {'id': 'stripe-refund-re_1', 'amount': '-50.00', 'received_on': '2026-10-18T15:00:00Z', 'kind': 'refund', 'memo': 'Stripe refund', 'payment_intent': 'pi_3Q1abc'},
  ],
  'history': [
    {'old_status': 'Created', 'new_status': 'Scheduled - Full Day', 'changed_at': '2026-10-01T14:00:00Z'},
    {'old_status': 'Scheduled - Full Day', 'new_status': 'Final Invoice Sent', 'changed_at': '2026-10-09T14:00:00Z'},
  ],
};

/// Estimate 1093839956 as it is in production (2026-11-03): its items, no charges synced, total 907.75 incl. tax.
Map<String, dynamic> estimateRecord() => {
  'job': {
    'job_id': kEstimateId,
    'customer_name': 'Schuber Mitchell Homes',
    'contact_name': 'Dana Whitfield',
    'status': 'Estimate Provided',
    'sub_status': '',
    'is_estimate': true,
    'category': 'Residential Install',
    'location': '1204 W Poplar St, Rogers, AR 72756',
    'description': 'New 16x7 Gallery Steel door in Sandtone, with install.',
    'notes': 'Customer prefers mornings.',
    'po_number': '',
    'techs_assigned': '',
    'opportunity_owner': 'Heather Vera',
    'start_date': '2026-07-31',
    'sf_created_at': '2026-07-28T15:00:00Z',
    'total_revenue': '907.75',
    'due_total': '907.75',
    'sf_details': {'source': 'Builder referral', 'opportunity_rating': '4', 'time_frame_promised_start': '09:00:00', 'time_frame_promised_end': '10:00:00', 'duration': 3600},
    'raw_items': [
      {'item_index': 3, 'name': 'SMH | Gallery Steel | GD5S | Complete Door | Sandtone (Clay)', 'product': 'SMH | Gallery Steel | GD5S | Complete Door | Sandtone (Clay)', 'description': '16x7 GD5S complete door', 'multiplier': 1, 'rate': 527.72, 'total': 527.72, 'cost': 507.16, 'tax': 'Sales Tax'},
      {'item_index': 4, 'name': "Punched Angle | 1-1/4\" x 1-1/4\" | 8'", 'product': 'Punched Angle', 'multiplier': 1, 'rate': 3.16, 'total': 3.16, 'cost': 3.16, 'tax': 'Sales Tax'},
      {'item_index': 5, 'name': "Stop Mold | 16' Sandtone", 'product': "Weather Seal | Stop Mold | 16' Sandtone", 'multiplier': 1, 'rate': 10.2, 'total': 10.2, 'cost': 10.2, 'tax': 'Sales Tax'},
      {'item_index': 6, 'name': "Stop Mold | 7' Sandtone", 'product': "Weather Seal | Stop Mold | 7' Sandtone", 'multiplier': 2, 'rate': 4.46, 'total': 8.92, 'cost': 8.92, 'tax': 'Sales Tax'},
      {'item_index': 2, 'name': 'SMH Installation | Gallery Steel | 16x7 | Sandtone', 'service': 'SMH Installation | Gallery Steel | 16x7 | Sandtone', 'multiplier': 1, 'rate': 300, 'total': 300, 'cost': 0, 'tax': null},
    ],
    'other_charges': null,
  },
  'customer': {'primary_contact': 'Dana Whitfield', 'phone': '(479) 736-2125', 'email': 'dana@schubermitchell.com'},
  'becameJob': kJobId,
  'linkConfirmed': false,
  'statusCategory': 'Open Estimates',
  'payments': [],
  'history': [
    {'old_status': 'Created', 'new_status': 'Estimate Provided', 'changed_at': '2026-07-31T14:00:00Z'},
  ],
};

const kCatalog = <Map<String, dynamic>>[
  {'key': 'inv:7', 'name': 'Torsion Spring | 0.250 x 2" x 32"', 'sku': 'TS-25032', 'category': 'Springs', 'kind': 'product', 'inventoryItemId': 7, 'stock': 14, 'rate': 89.0, 'rateUses': 31, 'rateMin': 79.0, 'rateMax': 89.0, 'cost': 19.5, 'costSource': 'inventory', 'uses': 40, 'taxable': true, 'description': 'Oil-tempered torsion spring'},
  {'key': 'sf:liftmaster 87504', 'name': 'LiftMaster 87504 Smart Opener', 'sku': '', 'category': '', 'kind': 'product', 'rate': 689.0, 'rateUses': 12, 'rateMin': 689.0, 'rateMax': 689.0, 'cost': 401.37, 'costSource': 'service_fusion', 'uses': 12, 'taxable': true, 'description': 'Wi-Fi belt drive opener with battery backup'},
  {'key': 'sf:clopay rolling door', 'name': 'Clopay Rolling Door', 'sku': '', 'category': '', 'kind': 'product', 'rate': null, 'rateUses': 1, 'rateMin': 9500.0, 'rateMax': 15000.0, 'cost': 15000.0, 'costSource': 'service_fusion', 'uses': 3, 'taxable': true, 'description': ''},
  {'key': 'inv:81', 'name': 'Short Lag', 'sku': '0110590', 'category': 'Hardware', 'kind': 'product', 'inventoryItemId': 81, 'stock': 0, 'rate': null, 'rateUses': 0, 'cost': 137.5, 'costSource': 'inventory', 'uses': 0, 'taxable': true, 'description': ''},
  {'key': 'sf:spring replacement', 'name': 'Spring Replacement | Labor', 'sku': '', 'category': 'Service', 'kind': 'service', 'rate': 150.0, 'rateUses': 20, 'rateMin': 150.0, 'rateMax': 150.0, 'cost': null, 'uses': 22, 'taxable': false, 'description': ''},
];

class FakeOption {
  final String id;
  final String jobId;
  final String kind;
  String name;
  int position;
  bool recommended = false;
  double? taxRate;
  String notes = '';
  int version = 1;
  String source;
  String? sourceOptionId;
  String? sourceEstimateId;
  String? acceptedAt;
  String acceptedBy = '';
  String? convertedJobId;
  bool deleted = false;
  List<Map<String, dynamic>> items;
  FakeOption({required this.id, required this.jobId, required this.kind, required this.name, required this.position, required this.source, this.taxRate, required this.items});
}

/// The fake backend. [canEdit] and [canSeeCost] play the signed-in person's permissions.
class FakeJobServer {
  final Map<String, Map<String, dynamic>> records;
  bool canEdit;
  bool canSeeCost;
  final List<String> requests = [];
  final List<Map<String, dynamic>> saves = []; // bodies of PUT .../items
  final List<Map<String, dynamic>> notes = [];
  final List<Map<String, dynamic>> tasks = [];
  final _options = <FakeOption>[];
  List<Map<String, dynamic>> files = [];

  /// Calls and texts the Communications tab (Quo) gets for a job, oldest first.
  List<Map<String, dynamic>> quoActivity = [];

  /// Plays a backend that doesn't have the line-item routes yet (not deployed): they answer 404.
  bool optionsDown = false;
  bool notesDown = false; // saving a note fails with a server error
  bool filesEnabled = true;
  final history = <Map<String, dynamic>>[];
  int _nextId = 1;
  String user = 'Dana Whitfield';

  FakeJobServer({Map<String, Map<String, dynamic>>? records, this.canEdit = true, this.canSeeCost = true})
    : records = records ?? {kJobId: jobRecord(), kEstimateId: estimateRecord()};

  List<FakeOption> optionsOf(String jobId) => _options.where((o) => o.jobId == jobId && !o.deleted).toList()..sort((a, b) => a.position.compareTo(b.position));

  /// Puts an option straight into the store (for screenshots of a record that already has some).
  String addOption(String jobId, String name, List<Map<String, dynamic>> items, {double? taxRate, bool recommended = false, bool accepted = false, String source = 'blank'}) {
    final rec = records[jobId]!['job'] as Map;
    final o = FakeOption(id: '${_nextId++}', jobId: jobId, kind: rec['is_estimate'] == true ? 'estimate' : 'job', name: name, position: optionsOf(jobId).length, source: source, taxRate: taxRate, items: items)
      ..recommended = recommended;
    if (accepted) {
      o.acceptedAt = '2026-11-02T16:00:00Z';
      o.acceptedBy = user;
    }
    _options.add(o);
    return o.id;
  }

  Map<String, dynamic> _item(Map<String, dynamic> i, int pos) {
    final out = Map<String, dynamic>.from(i)..['position'] = pos;
    out['id'] ??= 'li${_nextId++}';
    if (!canSeeCost) {
      out.remove('cost');
      out.remove('catalogCost');
    }
    return out;
  }

  Map<String, dynamic> _state(String jobId) {
    final rec = records[jobId]!['job'] as Map;
    final names = {for (final o in _options) o.id: o.name};
    return {
      'recordKind': rec['is_estimate'] == true ? 'estimate' : 'job',
      'canSeeCost': canSeeCost,
      'canEdit': canEdit,
      'options': [
        for (final o in optionsOf(jobId))
          {
            'id': o.id,
            'kind': o.kind,
            'name': o.name,
            'position': o.position,
            'isRecommended': o.recommended,
            'taxRate': o.taxRate,
            'notes': o.notes,
            'version': o.version,
            'source': o.source,
            'sourceOptionId': o.sourceOptionId,
            'sourceOptionName': o.sourceOptionId == null ? null : names[o.sourceOptionId],
            'sourceEstimateId': o.sourceEstimateId,
            'acceptedAt': o.acceptedAt,
            'acceptedBy': o.acceptedBy,
            'convertedJobId': o.convertedJobId,
            'updatedBy': user,
            'updatedAt': '2026-11-03T15:00:00Z',
            'items': [for (var k = 0; k < o.items.length; k++) _item(o.items[k], k)],
          },
      ],
      'history': [for (final h in history.where((h) => h['jobId'] == jobId).toList().reversed) h],
    };
  }

  void _log(FakeOption o, String action) => history.add({'jobId': o.jobId, 'optionId': o.id, 'version': o.version, 'action': action, 'name': o.name, 'total': null, 'by': user, 'at': '2026-11-03T15:${(history.length % 50).toString().padLeft(2, '0')}:00Z'});

  /// Service Fusion's lines as our lines, the way the real server copies them (unit cost from the extended cost).
  List<Map<String, dynamic>> _seed(Map rec) {
    final raw = [...(rec['raw_items'] as List? ?? const [])]..sort((a, b) => (a['item_index'] as num).compareTo(b['item_index'] as num));
    final out = <Map<String, dynamic>>[
      for (final it in raw)
        {
          'kind': 'item',
          'name': it['name'],
          'description': it['description'] ?? '',
          'quantity': (it['multiplier'] as num).toDouble(),
          'rate': (it['rate'] as num?)?.toDouble(),
          'cost': it['cost'] == null ? null : ((it['cost'] as num) / (it['multiplier'] as num) * 100).round() / 100,
          'taxable': it['tax'] != null,
          'source': 'service_fusion',
        },
    ];
    for (final c in (rec['other_charges'] as List? ?? const [])) {
      if (c['is_discount'] == true) out.add({'kind': 'discount', 'name': c['name'], 'quantity': 1, 'rate': (c['total'] as num).toDouble(), 'taxable': false, 'source': 'service_fusion'});
    }
    return out;
  }

  double? _seedTax(Map rec) {
    for (final c in (rec['other_charges'] as List? ?? const [])) {
      if (c['is_discount'] != true && c['is_percentage'] == true) return (c['rate'] as num).toDouble();
    }
    return rec['is_estimate'] == true ? 10.5 : null; // what the real server works out for estimate 1093839956
  }

  http.Response _ok(Object body, [int status = 200]) => http.Response(json.encode(body), status);
  http.Response _err(int status, String msg, [Map<String, dynamic>? extra]) => http.Response(json.encode({'error': msg, ...?extra}), status);

  http.Client get client => MockClient(handle);

  Future<http.Response> handle(http.Request req) async {
    final path = req.url.path;
    requests.add('${req.method} $path');
    final body = req.body.isEmpty ? const <String, dynamic>{} : (json.decode(req.body) as Map).cast<String, dynamic>();

    if (path == '/api/catalog/search') {
      final q = (req.url.queryParameters['q'] ?? '').toLowerCase();
      final found = [
        for (final e in kCatalog)
          if ('${e['name']} ${e['sku']} ${e['category']}'.toLowerCase().contains(q)) canSeeCost ? e : (Map<String, dynamic>.from(e)..remove('cost')..remove('costSource')),
      ];
      return _ok({'results': found, 'canSeeCost': canSeeCost});
    }
    if (path.startsWith('/api/quo/calls/') && path.endsWith('/transcript')) {
      return _ok({
        'lines': [
          {'speaker': 'Dana Whitfield', 'content': 'Hi, the left door is making a grinding noise again.'},
          {'speaker': 'Heather Vera', 'content': 'Sorry to hear that. We can have Brett out tomorrow morning.'},
          {'speaker': 'Dana Whitfield', 'content': 'Perfect, the gate code is still 4471.'},
        ],
      });
    }
    if (path.startsWith('/api/quo/calls/') && path.endsWith('/details')) return _ok({'ok': true, 'changed': false});
    if (path == '/api/quo/send') return _ok({'ok': true, 'id': 'sent-${_nextId++}'});
    if (path.startsWith('/api/quo/jobs/') && path.endsWith('/activity')) {
      return _ok({'phone': '(479) 736-2125', 'hasPhone': true, 'activity': quoActivity});
    }
    final m = RegExp(r'^/api/jobs/(\d+)(/.*)?$').firstMatch(path);
    if (m == null) return _err(404, 'no route');
    final jobId = m.group(1)!;
    final rest = m.group(2) ?? '';
    final rec = records[jobId];
    if (rest.isEmpty) return rec == null ? _err(404, 'Job not found') : _ok(rec);
    if (rest == '/files') return _ok({'enabled': filesEnabled, 'files': files});
    if (rest.startsWith('/files/') && rest.endsWith('/content')) return http.Response('Gate code 4471. Call before arriving.', 200, headers: {'content-type': 'text/plain'});
    if (rest.startsWith('/files/') && req.method == 'DELETE') {
      files.removeWhere((f) => rest == '/files/${f['id']}');
      return _ok({'success': true});
    }
    if (rest == '/notes-tasks') return _ok({'notes': notes, 'tasks': tasks});
    if (rest == '/notes' && req.method == 'POST') {
      if (notesDown) return _err(500, 'The database is busy');
      notes.insert(0, {'id': '${notes.length + 1}', 'body': body['body'], 'author': user, 'createdAt': '2026-11-03T16:30:00Z'});
      return _ok({'note': notes.first}, 201);
    }
    if (rest == '/tasks' && req.method == 'POST') {
      tasks.insert(0, {'id': '${tasks.length + 1}', 'description': body['description'], 'isCompleted': false, 'createdBy': user, 'createdAt': '2026-11-03T16:31:00Z'});
      return _ok({'task': tasks.first}, 201);
    }
    if (rest.startsWith('/tasks/') && req.method == 'PATCH') {
      final t = tasks.firstWhere((t) => rest.endsWith('/${t['id']}'));
      t['isCompleted'] = body['is_completed'];
      t['completedBy'] = body['is_completed'] == true ? user : '';
      t['completedAt'] = body['is_completed'] == true ? '2026-11-03T17:00:00Z' : null;
      return _ok({'task': t});
    }
    if (rest == '/payment-link') return _ok({'url': 'https://example.invalid/pay/abc', 'amount': body['amount']});
    if (!rest.startsWith('/options')) return _err(404, 'no route');
    if (optionsDown) return http.Response('Cannot GET $path', 404);
    if (rec == null) return _err(404, 'Job not found');
    final job = rec['job'] as Map;

    // ---- the line-items server ----
    final om = RegExp(r'^/options(?:/(\w+))?(?:/(items|accept|unaccept|convert))?$').firstMatch(rest)!;
    final id = om.group(1);
    final verb = om.group(2);
    if (id == null && req.method == 'GET') return _ok(_state(jobId));
    if (!canEdit) return _err(403, 'Admin access required.');
    if (id == null && req.method == 'POST') {
      final existing = optionsOf(jobId);
      final isEst = job['is_estimate'] == true;
      if (!isEst && existing.isNotEmpty) return _err(409, 'This job already has its line items here. Refresh the page.');
      final from = body['from'] ?? 'blank';
      List<Map<String, dynamic>> items = [];
      double? tax;
      String name = (body['name'] ?? '').toString();
      if (from == 'service_fusion') {
        items = _seed(job);
        tax = _seedTax(job);
      } else if (from == 'copy') {
        final src = existing.firstWhere((o) => o.id == body['copyOf']);
        items = [for (final i in src.items) Map<String, dynamic>.from(i)..remove('id')..['source'] = i['source']];
        tax = src.taxRate;
        if (name.isEmpty) name = '${src.name} (copy)';
      }
      if (name.isEmpty) name = isEst ? 'Option ${existing.length + 1}' : 'Job items';
      final newId = addOption(jobId, name, items, taxRate: tax, source: from == 'copy' ? 'copy' : from);
      _log(_options.last, 'created');
      return _ok({..._state(jobId), 'created': newId}, 201);
    }
    final o = optionsOf(jobId).where((x) => x.id == id).firstOrNull;
    if (o == null) return _err(404, 'That option was not found.');
    if (req.method == 'PATCH') {
      if (body['version'] != o.version) return _err(409, 'Changed by someone else.', {'currentVersion': o.version});
      if (o.acceptedAt != null) return _err(409, 'An accepted option is locked. Undo the acceptance first.');
      if (body.containsKey('name')) o.name = body['name'];
      if (body.containsKey('taxRate')) o.taxRate = (body['taxRate'] as num?)?.toDouble();
      if (body.containsKey('notes')) o.notes = (body['notes'] ?? '').toString();
      if (body.containsKey('isRecommended')) {
        if (body['isRecommended'] == true) {
          for (final x in optionsOf(jobId)) {
            x.recommended = false;
          }
        }
        o.recommended = body['isRecommended'] == true;
      }
      o.version++;
      _log(o, 'settings');
      return _ok(_state(jobId));
    }
    if (req.method == 'DELETE') {
      if (o.acceptedAt != null) return _err(409, 'An accepted option can\'t be deleted. Undo the acceptance first.');
      o.deleted = true;
      _log(o, 'deleted');
      return _ok(_state(jobId));
    }
    if (verb == 'items') {
      saves.add(body);
      if (body['version'] != o.version) return _err(409, 'Changed by someone else.', {'currentVersion': o.version});
      if (o.acceptedAt != null) return _err(409, 'An accepted option is locked.');
      o.items = [for (final i in (body['items'] as List)) Map<String, dynamic>.from(i as Map)];
      if (body.containsKey('taxRate')) o.taxRate = (body['taxRate'] as num?)?.toDouble();
      o.version++;
      _log(o, 'saved');
      return _ok(_state(jobId));
    }
    if (verb == 'accept') {
      if (body['version'] != o.version) return _err(409, 'Changed by someone else.', {'currentVersion': o.version});
      final other = optionsOf(jobId).where((x) => x.acceptedAt != null && x.id != o.id).firstOrNull;
      if (other != null) return _err(409, '"${other.name}" is already the accepted option. Undo that first.');
      final unpriced = o.items.where((i) => i['kind'] != 'discount' && i['rate'] == null).length;
      if (unpriced > 0) return _err(400, '${unpriced == 1 ? 'One line has' : '$unpriced lines have'} no price yet. Price every line before accepting.');
      o.acceptedAt = '2026-11-03T16:00:00Z';
      o.acceptedBy = user;
      o.version++;
      _log(o, 'accepted');
      return _ok(_state(jobId));
    }
    if (verb == 'unaccept') {
      if (o.convertedJobId != null) return _err(409, 'This option was sent to job #${o.convertedJobId}, so it stays accepted.');
      o.acceptedAt = null;
      o.version++;
      _log(o, 'unaccepted');
      return _ok(_state(jobId));
    }
    if (verb == 'convert') {
      final target = body['jobId'].toString();
      if (o.acceptedAt == null) return _err(400, 'Accept this option first.');
      if (o.convertedJobId != null) return _ok({..._state(jobId), 'converted': {'jobId': o.convertedJobId, 'alreadyDone': true}});
      final t = records[target];
      if (t == null) return _err(404, 'Job #$target was not found. A job shows up here once Service Fusion creates it and the sync brings it in.');
      if ((t['job'] as Map)['is_estimate'] == true) return _err(400, '#$target is an estimate, not a job.');
      if (optionsOf(target).isNotEmpty) return _err(409, 'Job #$target already has line items edited here.');
      final copy = FakeOption(id: '${_nextId++}', jobId: target, kind: 'job', name: 'Job items', position: 0, source: 'estimate', taxRate: o.taxRate, items: [for (final i in o.items) Map<String, dynamic>.from(i)..remove('id')..['source'] = 'copy'])
        ..sourceOptionId = o.id
        ..sourceEstimateId = jobId;
      _options.add(copy);
      o.convertedJobId = target;
      o.version++;
      _log(o, 'converted');
      return _ok({..._state(jobId), 'converted': {'jobId': target, 'alreadyDone': false}});
    }
    return _err(404, 'no route');
  }
}

/// A Standard / Premium / Commercial-grade estimate, the way the office would build one.
void seedThreeOptions(FakeJobServer s, {bool accepted = false}) {
  final base = <Map<String, dynamic>>[
    {'kind': 'item', 'name': 'SMH | Gallery Steel | GD5S | Complete Door | Sandtone (Clay)', 'description': '16x7 GD5S complete door', 'sku': '', 'quantity': 1, 'rate': 527.72, 'cost': 507.16, 'taxable': true, 'source': 'service_fusion'},
    {'kind': 'item', 'name': "Stop Mold | 7' Sandtone", 'quantity': 2, 'rate': 4.46, 'cost': 4.46, 'taxable': true, 'source': 'service_fusion'},
    {'kind': 'item', 'name': 'SMH Installation | Gallery Steel | 16x7 | Sandtone', 'quantity': 1, 'rate': 300, 'cost': 0, 'taxable': false, 'source': 'service_fusion'},
  ];
  s.addOption(kEstimateId, 'Standard', base, taxRate: 10.5, source: 'service_fusion');
  s.addOption(
    kEstimateId,
    'Upgraded',
    [
      ...base,
      {'kind': 'item', 'name': 'LiftMaster 87504 Smart Opener', 'description': 'Wi-Fi belt drive opener with battery backup', 'quantity': 1, 'rate': 689, 'cost': 401.37, 'taxable': true, 'catalogKey': 'sf:liftmaster 87504', 'catalogRate': 689, 'catalogCost': 401.37, 'source': 'catalog'},
    ],
    taxRate: 10.5,
    recommended: true,
    accepted: accepted,
  );
  s.addOption(
    kEstimateId,
    'Premium',
    [
      ...base,
      {'kind': 'item', 'name': 'LiftMaster 87504 Smart Opener', 'quantity': 1, 'rate': 689, 'cost': 401.37, 'taxable': true, 'source': 'catalog'},
      {'kind': 'item', 'name': 'Torsion Spring | 0.250 x 2" x 32"', 'sku': 'TS-25032', 'quantity': 2, 'rate': 89, 'cost': 19.5, 'taxable': true, 'inventoryItemId': 7, 'catalogKey': 'inv:7', 'catalogRate': 89, 'catalogCost': 19.5, 'source': 'catalog'},
      {'kind': 'discount', 'name': 'Loyal customer discount', 'quantity': 1, 'rate': 75, 'taxable': false, 'source': 'manual'},
    ],
    taxRate: 10.5,
  );
}

final _pageKey = GlobalKey();

/// Overflows reported while the page was on screen.
class PageErrors {
  final messages = <String>[];
  bool get overflowed => messages.isNotEmpty;
}

/// Pumps the job page the way the app shows it: under a 60 px stand-in for the nav bar, Segoe UI, at [size].
/// [body] runs afterwards inside the fake-server zone, so its taps are answered too. The default window is tall so the
/// Line Items panel at the bottom of the page is on screen without scrolling.
Future<PageErrors> pumpJobPage(
  WidgetTester t,
  FakeJobServer server, {
  String id = kJobId,
  Size size = const Size(1500, 2400),
  double textScale = 1,
  Future<void> Function()? body,
  Map<String, dynamic>? initial,

  /// Wraps the page in the app's own select-to-copy layer, as main.dart does (it changes the cursor over text).
  bool appSelection = false,
}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  addTearDown(t.view.reset);
  final errors = PageErrors();
  final previous = FlutterError.onError;
  FlutterError.onError = (d) {
    final text = d.exceptionAsString();
    if (text.contains('overflowed')) {
      final full = d.toString().split('\n');
      final at = full.indexWhere((l) => l.contains('The relevant error-causing widget was'));
      errors.messages.add('${text.split('\n').first}${at >= 0 && at + 1 < full.length ? ' at ${full[at + 1].trim()}' : ''}');
    } else {
      previous?.call(d);
    }
  };
  try {
    await http.runWithClient(() async {
      // A fresh page each time, as when the record is opened again (otherwise the old page's state carries over).
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
          child: RepaintBoundary(
            key: _pageKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
              builder: appSelection ? appSelectionBuilder : null,
              home: Scaffold(
                body: Column(
                  children: [
                    Container(height: 60, color: const Color(0xFF0B1220), alignment: Alignment.center, child: const Text('NAV BAR', style: TextStyle(color: Colors.white24))),
                    Expanded(child: JobDetailScreen(jobId: id, initial: initial)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await settle(t);
      if (body != null) await body();
    }, () => server.client);
  } finally {
    FlutterError.onError = previous;
  }
  return errors;
}

/// The catalog search under the line items.
Finder get catalogSearch => find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Add a line'));

/// Scrolls the page to a section with the jump bar, as a person would ('items', 'visits', 'payments', 'notes',
/// 'files', 'comms', 'activity', and 'details' on a narrow window).
Future<void> jumpTo(WidgetTester t, String section) async {
  await t.tap(find.byKey(ValueKey('jump-$section')));
  await settle(t, frames: 8);
}

Future<void> settle(WidgetTester t, {int frames = 14}) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Saves the screen to build/job_shots/[name].png for review.
Future<void> saveJobShot(WidgetTester t, String name) => saveShotOf(t, _pageKey, name);

Future<void> saveShotOf(WidgetTester t, GlobalKey key, String name) async {
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await t.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/job_shots')..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

/// Fonts and an admin sign-in, for setUpAll.
Future<void> jobPageSetUp({bool admin = true}) async {
  await loadDashFonts();
  await dashSignIn(admin: admin);
}
