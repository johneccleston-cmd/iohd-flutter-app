import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../config/auth_session.dart';
import '../utils/line_item_math.dart';

// The job screen's line items and estimate options (backend: src/line_items.js) and the catalog search
// (src/catalog.js). Everything is saved to our own database; Service Fusion is never written to.

/// A refused or failed call, with the server's own message when it sent one.
class LineItemsException implements Exception {
  final String message;
  final int status;

  /// The option's version on the server, when a save was refused because someone else changed it first (409).
  final int? currentVersion;
  const LineItemsException(this.message, {this.status = 0, this.currentVersion});

  bool get isConflict => status == 409;

  @override
  String toString() => message;
}

/// One set of line items: an estimate option ("Option 2 · Premium"), or a job's items.
class LineOption {
  final String id;
  final String kind; // estimate | job
  final String name;
  final int position;
  final bool isRecommended;
  final double? taxRate;
  final String notes;
  final int version;
  final String source; // blank | service_fusion | copy | estimate
  final String? sourceOptionId;
  final String? sourceOptionName;
  final String? sourceEstimateId;
  final DateTime? acceptedAt;
  final String acceptedBy;
  final String? convertedJobId;
  final DateTime? convertedAt;
  final String convertedBy;
  final String updatedBy;
  final DateTime? updatedAt;
  final List<LineDraft> items;

  const LineOption({
    required this.id,
    required this.kind,
    required this.name,
    required this.position,
    required this.isRecommended,
    required this.taxRate,
    required this.notes,
    required this.version,
    required this.source,
    required this.sourceOptionId,
    required this.sourceOptionName,
    required this.sourceEstimateId,
    required this.acceptedAt,
    required this.acceptedBy,
    required this.convertedJobId,
    required this.convertedAt,
    required this.convertedBy,
    required this.updatedBy,
    required this.updatedAt,
    required this.items,
  });

  bool get accepted => acceptedAt != null;
  bool get converted => convertedJobId != null;

  /// Accepted options are locked so the agreed price stays as it was.
  bool get locked => accepted;

  LineTotals get totals => computeLineTotals(items, taxRate);

  static DateTime? _when(dynamic v) => DateTime.tryParse(v?.toString() ?? '');

  factory LineOption.fromJson(Map<String, dynamic> j) => LineOption(
    id: j['id'].toString(),
    kind: (j['kind'] ?? 'estimate').toString(),
    name: (j['name'] ?? '').toString(),
    position: (j['position'] as num?)?.toInt() ?? 0,
    isRecommended: j['isRecommended'] == true,
    taxRate: (j['taxRate'] as num?)?.toDouble(),
    notes: (j['notes'] ?? '').toString(),
    version: (j['version'] as num?)?.toInt() ?? 1,
    source: (j['source'] ?? 'blank').toString(),
    sourceOptionId: j['sourceOptionId']?.toString(),
    sourceOptionName: j['sourceOptionName']?.toString(),
    sourceEstimateId: j['sourceEstimateId']?.toString(),
    acceptedAt: _when(j['acceptedAt']),
    acceptedBy: (j['acceptedBy'] ?? '').toString(),
    convertedJobId: j['convertedJobId']?.toString(),
    convertedAt: _when(j['convertedAt']),
    convertedBy: (j['convertedBy'] ?? '').toString(),
    updatedBy: (j['updatedBy'] ?? '').toString(),
    updatedAt: _when(j['updatedAt']),
    items: [for (final i in (j['items'] as List? ?? const []).whereType<Map>()) LineDraft.fromJson(Map<String, dynamic>.from(i))],
  );
}

/// One entry of an option's history: created, saved, settings, accepted, unaccepted, converted, deleted.
class OptionEvent {
  final String optionId;
  final int version;
  final String action;
  final String name;
  final double? total;
  final String by;
  final DateTime? at;
  const OptionEvent({required this.optionId, required this.version, required this.action, required this.name, this.total, required this.by, this.at});

  factory OptionEvent.fromJson(Map<String, dynamic> j) => OptionEvent(
    optionId: j['optionId'].toString(),
    version: (j['version'] as num?)?.toInt() ?? 0,
    action: (j['action'] ?? '').toString(),
    name: (j['name'] ?? '').toString(),
    total: (j['total'] as num?)?.toDouble(),
    by: (j['by'] ?? '').toString(),
    at: DateTime.tryParse(j['at']?.toString() ?? ''),
  );
}

/// Everything the server keeps for one record's line items.
class LineItemsState {
  final String recordKind; // estimate | job
  final bool canSeeCost;
  final bool canEdit;
  final List<LineOption> options;
  final List<OptionEvent> history;
  const LineItemsState({required this.recordKind, required this.canSeeCost, required this.canEdit, required this.options, required this.history});

  static const empty = LineItemsState(recordKind: 'job', canSeeCost: false, canEdit: false, options: [], history: []);

  LineOption? byId(String? id) => id == null ? null : options.where((o) => o.id == id).firstOrNull;
  LineOption? get accepted => options.where((o) => o.accepted).firstOrNull;

  factory LineItemsState.fromJson(Map<String, dynamic> j) => LineItemsState(
    recordKind: (j['recordKind'] ?? 'job').toString(),
    canSeeCost: j['canSeeCost'] == true,
    canEdit: j['canEdit'] == true,
    options: [for (final o in (j['options'] as List? ?? const []).whereType<Map>()) LineOption.fromJson(Map<String, dynamic>.from(o))],
    history: [for (final h in (j['history'] as List? ?? const []).whereType<Map>()) OptionEvent.fromJson(Map<String, dynamic>.from(h))],
  );
}

/// What "send to job" did: the job it went to, whether it had already been done, and a heads-up when the job's
/// customer isn't the estimate's.
class ConvertResult {
  final String jobId;
  final bool alreadyDone;
  final bool customerDiffers;
  const ConvertResult(this.jobId, {this.alreadyDone = false, this.customerDiffers = false});
}

/// One product or service the office can add. Rate and cost are null when the data doesn't support a default.
class CatalogEntry {
  final String key;
  final String name;
  final String sku;
  final String category;
  final String kind; // product | service
  final int? inventoryItemId;
  final int? stock;
  final double? rate;
  final int rateUses;
  final double? rateMin;
  final double? rateMax;
  final double? cost;
  final String? costSource; // inventory | service_fusion
  final int uses;
  final String? lastUsed;
  final bool taxable;
  final String description;

  const CatalogEntry({
    required this.key,
    required this.name,
    this.sku = '',
    this.category = '',
    this.kind = 'product',
    this.inventoryItemId,
    this.stock,
    this.rate,
    this.rateUses = 0,
    this.rateMin,
    this.rateMax,
    this.cost,
    this.costSource,
    this.uses = 0,
    this.lastUsed,
    this.taxable = false,
    this.description = '',
  });

  /// The new line this entry becomes: quantity 1, the catalog's price and cost as the starting values (and kept as
  /// the record of what the catalog said), nothing filled in that the catalog doesn't have.
  LineDraft toLine() => LineDraft(
    name: name,
    description: description,
    sku: sku,
    quantity: 1,
    rate: rate,
    cost: cost,
    taxable: taxable,
    inventoryItemId: inventoryItemId,
    catalogKey: key,
    catalogRate: rate,
    catalogCost: cost,
    source: 'catalog',
  );

  factory CatalogEntry.fromJson(Map<String, dynamic> j) => CatalogEntry(
    key: j['key'].toString(),
    name: (j['name'] ?? '').toString(),
    sku: (j['sku'] ?? '').toString(),
    category: (j['category'] ?? '').toString(),
    kind: (j['kind'] ?? 'product').toString(),
    inventoryItemId: (j['inventoryItemId'] as num?)?.toInt(),
    stock: (j['stock'] as num?)?.toInt(),
    rate: (j['rate'] as num?)?.toDouble(),
    rateUses: (j['rateUses'] as num?)?.toInt() ?? 0,
    rateMin: (j['rateMin'] as num?)?.toDouble(),
    rateMax: (j['rateMax'] as num?)?.toDouble(),
    cost: (j['cost'] as num?)?.toDouble(),
    costSource: j['costSource']?.toString(),
    uses: (j['uses'] as num?)?.toInt() ?? 0,
    lastUsed: j['lastUsed']?.toString(),
    taxable: j['taxable'] == true,
    description: (j['description'] ?? '').toString(),
  );
}

class LineItemsApi {
  final String jobId;
  const LineItemsApi(this.jobId);

  String get _base => '$kApiBaseUrl/api/jobs/${Uri.encodeComponent(jobId)}/options';

  static Future<Map<String, dynamic>> _call(String method, Uri uri, {Map<String, dynamic>? body}) async {
    http.Response res;
    try {
      final req = http.Request(method, uri)..headers.addAll(AuthSession.instance.headers());
      if (body != null) req.body = json.encode(body);
      res = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 30)));
    } on TimeoutException {
      throw const LineItemsException('The server took too long to answer. Try again.');
    } catch (_) {
      throw const LineItemsException('Could not reach the server.');
    }
    if (res.statusCode == 401) {
      AuthSession.instance.logout(); // sends the app back to the sign-in screen
      throw const LineItemsException('Your session expired. Please sign in again.', status: 401);
    }
    Map<String, dynamic> data = const {};
    try {
      final d = json.decode(res.body);
      if (d is Map) data = Map<String, dynamic>.from(d);
    } catch (_) {}
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw LineItemsException(
        (data['error'] ?? 'Server error (${res.statusCode}).').toString(),
        status: res.statusCode,
        currentVersion: (data['currentVersion'] as num?)?.toInt(),
      );
    }
    return data;
  }

  Future<LineItemsState> load() async => LineItemsState.fromJson(await _call('GET', Uri.parse(_base)));

  /// A new set: blank, a copy of [copyOf], or Service Fusion's items as the starting point. Returns the new state and
  /// the new option's id.
  Future<(LineItemsState, String?)> create({required String from, String? copyOf, String? name}) async {
    final d = await _call('POST', Uri.parse(_base), body: {'from': from, 'copyOf': ?copyOf, 'name': ?name});
    return (LineItemsState.fromJson(d), d['created']?.toString());
  }

  Future<LineItemsState> update(String id, int version, Map<String, dynamic> fields) async =>
      LineItemsState.fromJson(await _call('PATCH', Uri.parse('$_base/${Uri.encodeComponent(id)}'), body: {'version': version, ...fields}));

  /// Replaces the set's lines (edits, additions, removals and order in one go), with its tax rate.
  Future<LineItemsState> saveItems(String id, int version, List<LineDraft> items, double? taxRate) async => LineItemsState.fromJson(
    await _call(
      'PUT',
      Uri.parse('$_base/${Uri.encodeComponent(id)}/items'),
      body: {'version': version, 'items': [for (final i in items) i.toJson()], 'taxRate': taxRate},
    ),
  );

  Future<LineItemsState> delete(String id) async => LineItemsState.fromJson(await _call('DELETE', Uri.parse('$_base/${Uri.encodeComponent(id)}')));

  Future<LineItemsState> accept(String id, int version) async =>
      LineItemsState.fromJson(await _call('POST', Uri.parse('$_base/${Uri.encodeComponent(id)}/accept'), body: {'version': version}));

  Future<LineItemsState> unaccept(String id) async =>
      LineItemsState.fromJson(await _call('POST', Uri.parse('$_base/${Uri.encodeComponent(id)}/unaccept'), body: const {}));

  Future<(LineItemsState, ConvertResult)> convert(String id, String toJob) async {
    final d = await _call('POST', Uri.parse('$_base/${Uri.encodeComponent(id)}/convert'), body: {'jobId': toJob});
    final c = d['converted'] is Map ? Map<String, dynamic>.from(d['converted'] as Map) : const <String, dynamic>{};
    return (
      LineItemsState.fromJson(d),
      ConvertResult((c['jobId'] ?? toJob).toString(), alreadyDone: c['alreadyDone'] == true, customerDiffers: c['customerDiffers'] == true),
    );
  }

  static Future<List<CatalogEntry>> searchCatalog(String q, {int limit = 25}) async {
    final d = await _call('GET', Uri.parse('$kApiBaseUrl/api/catalog/search').replace(queryParameters: {'q': q, 'limit': '$limit'}));
    return [for (final e in (d['results'] as List? ?? const []).whereType<Map>()) CatalogEntry.fromJson(Map<String, dynamic>.from(e))];
  }
}
