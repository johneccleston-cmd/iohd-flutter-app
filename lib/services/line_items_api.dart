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

  /// The server's reason code, when it gives one: `DUPLICATE` (another product has that name or part number),
  /// `CHANGED` (someone else saved first), `NOT_LOADED` (the price list is not loaded yet).
  final String? code;

  /// With `DUPLICATE`: the other products that already have the name or part number.
  final List<({int id, String name, String? partNumber})> duplicates;
  const LineItemsException(this.message, {this.status = 0, this.currentVersion, this.code, this.duplicates = const []});

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

/// A billed (or quoted) price on a date, as the Services Catalog reports it.
typedef CatalogPrice = ({String date, double price});

/// A service's newest billed prices all sit well away from its 18-month median (Services Catalog Phase 2): no price is
/// filled in, and the median and the recent prices are shown apart, with the server's [warning].
class CatalogPriceChange {
  final double median;
  final List<CatalogPrice> prices; // newest first
  final String direction; // up | down | mixed
  final String? since;
  final String warning;
  const CatalogPriceChange({required this.median, this.prices = const [], this.direction = 'mixed', this.since, this.warning = ''});

  static CatalogPriceChange? fromJson(Object? v) {
    if (v is! Map || v['median'] is! num) return null;
    return CatalogPriceChange(
      median: (v['median'] as num).toDouble(),
      prices: CatalogEntry._prices(v['prices']),
      direction: (v['direction'] ?? 'mixed').toString(),
      since: v['since']?.toString(),
      warning: (v['warning'] ?? '').toString(),
    );
  }
}

/// One rate line of a service (2026-11-19, backend service_rates): like Service Fusion's rate editor, a name, an optional
/// description, a quantity, the regular rate and (with Line Items & Costs > View) the internal cost and the commission it
/// pays: a fixed amount or a percentage. Totals are quantity times rate or cost.
class ServiceRate {
  final String name;
  final String description;
  final double qty;
  final double? rate;
  final double? cost;
  final bool paysCommission;
  final String? commissionType; // fixed | percent
  final double? commissionValue;

  const ServiceRate({
    required this.name,
    this.description = '',
    this.qty = 1,
    this.rate,
    this.cost,
    this.paysCommission = false,
    this.commissionType,
    this.commissionValue,
  });

  double? get total => rate == null ? null : ((qty * rate!) * 100).round() / 100;
  double? get totalCost => cost == null ? null : ((qty * cost!) * 100).round() / 100;

  factory ServiceRate.fromJson(Map<String, dynamic> j) => ServiceRate(
    name: (j['name'] ?? '').toString(),
    description: (j['description'] ?? '').toString(),
    qty: (j['qty'] as num?)?.toDouble() ?? 1,
    rate: (j['rate'] as num?)?.toDouble(),
    cost: (j['cost'] as num?)?.toDouble(),
    paysCommission: j['paysCommission'] == true,
    commissionType: j['commissionType']?.toString(),
    commissionValue: (j['commissionValue'] as num?)?.toDouble(),
  );

  /// What is sent to save it. Without [withCost] the cost and commission are left out (the server keeps the saved ones).
  Map<String, dynamic> toJson({required bool withCost}) => {
    'name': name,
    'description': description,
    'qty': qty,
    'rate': rate,
    if (withCost) ...{
      'cost': cost,
      'paysCommission': paysCommission,
      'commissionType': paysCommission ? commissionType : null,
      'commissionValue': paysCommission ? commissionValue : null,
    },
  };

  @override
  bool operator ==(Object other) =>
      other is ServiceRate &&
      other.name == name &&
      other.description == description &&
      other.qty == qty &&
      other.rate == rate &&
      other.cost == cost &&
      other.paysCommission == paysCommission &&
      (!paysCommission || (other.commissionType == commissionType && other.commissionValue == commissionValue));

  @override
  int get hashCode => Object.hash(name, description, qty, rate, cost, paysCommission);
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
  final String? costSource; // catalog | inventory | service_fusion
  final int uses;
  final String? lastUsed;
  final bool taxable;
  final String description;

  // From the office price list (catalog_products) only; empty for Service Fusion services.
  final double? memberPrice;
  final String model;
  final String purchaseNote;

  /// Where it is bought and for how much (purchase prices are costs, so empty without the cost switch).
  final List<({String name, double? price})> vendors;

  /// The price list's Active? flag. Only the Product Catalog page asks for inactive products; everywhere else they never arrive.
  final bool active;

  /// The price list's Inventory Item? flag. Null when the catalog has no such flag (services, the old sources).
  final bool? inventoryItem;

  /// Why no stock is shown because a person has to sort out which inventory row is this product's (`duplicate_name`,
  /// `name_row_linked_elsewhere`, `shared_link`, `linked_row_missing`, `ambiguous_name`). Null when there is nothing to review.
  final String? inventoryConflict;

  /// How its stock is found: `id` (its own inventory row), `name` (by name, until the link backfill runs), or null.
  final String? inventoryLink;

  /// When it last changed or was imported (the server's own text). A change to several products at once sends it back,
  /// so a product someone else changed in the meantime is noticed. Null from a server older than Phase 3.
  final String? updatedAt;

  // Services only (the Services Catalog, Phase 2). A server older than that sends none of these: null / empty.

  /// How sure its price is: `settled` ([rate] is filled in), `recent_change` (the newest prices moved: not filled in,
  /// [recentChange] says how), `varies`, `single` (billed once), `quote_only` (only ever quoted) or `none`.
  final String? priceStatus;

  /// The 18-month billed median, given whenever it was billed at all (shown even when it isn't filled in).
  final double? medianPrice;
  final CatalogPrice? lastBilled;

  /// Up to the 3 newest billed prices, newest first.
  final List<CatalogPrice> recentPrices;
  final CatalogPriceChange? recentChange;

  /// What it was quoted at on estimates, kept apart from what was billed.
  final double? quoteMedian;
  final int quoteCount;

  /// `taxed`, `untaxed` or `mixed` on its billed lines (null: not known). [taxable] is true only for `taxed`; for
  /// `mixed`, [taxWarning] says so in words.
  final String? taxDefault;
  final String? taxWarning;

  /// The Service Fusion service type ("Residential Service"), the same as [category].
  final String group;

  /// Other names seen on the same Service Fusion item.
  final List<String> aliases;

  /// Service Fusion's service_rate_id, for tracing it back.
  final String? rateId;

  /// A renamed line with its own price: the item it was split from. Null on an item.
  final ({String key, String name})? variantOf;

  /// On an item: its priced variants.
  final List<({String key, String name})> variants;

  /// A service a renamed line of the same Service Fusion item has taken over from (2026-11-19): the entry that replaced
  /// it. Such a service is inactive, so the picker never offers it; the Services Catalog page keeps it, with its history.
  final ({String key, String name})? supersededBy;

  /// The services this one has taken over from (they are no longer offered; their names still find this one).
  final List<({String key, String name})> replaces;

  /// A service the office has edited (2026-11-19, saved in our own database, never in Service Fusion): which of `name`,
  /// `description`, `rate`, `cost`, `taxable` and `active` were set by a person, who and when, and what the job lines
  /// said before ([computed]: name, description, rate, cost, taxable, active). Empty / null for a service nobody edited.
  final List<String> editedFields;
  final String? editedBy;
  final String? editedAt;
  final Map<String, dynamic>? computed;

  /// A service's own rate lines, in order (empty: none saved). The first sets the [rate] and [cost] shown.
  final List<ServiceRate> rates;

  /// A service's commission, for the service as a whole (USER RULE 2026-11-19: not per rate): a percentage of its price
  /// or a fixed amount each time it is sold. Null: none (Service Fusion's lines carry none). Only for people who may see
  /// costs.
  final ServiceCommission? commission;

  bool get isEdited => editedFields.isNotEmpty;

  /// Kept in inventory: the price list says so, or (without the flag) it has an inventory row.
  bool get inInventory => inventoryItem ?? (inventoryItemId != null);

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
    this.memberPrice,
    this.model = '',
    this.purchaseNote = '',
    this.vendors = const [],
    this.active = true,
    this.inventoryItem,
    this.inventoryConflict,
    this.inventoryLink,
    this.updatedAt,
    this.priceStatus,
    this.medianPrice,
    this.lastBilled,
    this.recentPrices = const [],
    this.recentChange,
    this.quoteMedian,
    this.quoteCount = 0,
    this.taxDefault,
    this.taxWarning,
    this.group = '',
    this.aliases = const [],
    this.rateId,
    this.variantOf,
    this.variants = const [],
    this.supersededBy,
    this.replaces = const [],
    this.editedFields = const [],
    this.editedBy,
    this.editedAt,
    this.computed,
    this.rates = const [],
    this.commission,
  });

  bool get isService => kind == 'service';

  /// The catalog_products row behind it (`cat:<id>`), or null for services and the old sources.
  int? get productId => kind == 'product' && key.startsWith('cat:') ? int.tryParse(key.substring(4)) : null;

  /// The cost came from somewhere other than the catalog (the server falls back to the inventory row's or Service Fusion's).
  bool get hasBorrowedCost => cost != null && costSource != null && costSource != 'catalog';

  /// The same product with its category and status as a change to several products left them. [dropBorrowedCost] also
  /// clears a cost the catalog does not have of its own.
  CatalogEntry withChange({String? category, bool? active, String? updatedAt, bool dropBorrowedCost = false}) => CatalogEntry(
    key: key,
    name: name,
    sku: sku,
    category: category ?? this.category,
    kind: kind,
    inventoryItemId: inventoryItemId,
    stock: stock,
    rate: rate,
    rateUses: rateUses,
    rateMin: rateMin,
    rateMax: rateMax,
    cost: dropBorrowedCost && hasBorrowedCost ? null : cost,
    costSource: dropBorrowedCost && hasBorrowedCost ? null : costSource,
    uses: uses,
    lastUsed: lastUsed,
    taxable: taxable,
    description: description,
    memberPrice: memberPrice,
    model: model,
    purchaseNote: purchaseNote,
    vendors: vendors,
    active: active ?? this.active,
    inventoryItem: inventoryItem,
    inventoryConflict: inventoryConflict,
    inventoryLink: inventoryLink,
    updatedAt: updatedAt ?? this.updatedAt,
    priceStatus: priceStatus,
    medianPrice: medianPrice,
    lastBilled: lastBilled,
    recentPrices: recentPrices,
    recentChange: recentChange,
    quoteMedian: quoteMedian,
    quoteCount: quoteCount,
    taxDefault: taxDefault,
    taxWarning: taxWarning,
    group: group,
    aliases: aliases,
    rateId: rateId,
    variantOf: variantOf,
    variants: variants,
    supersededBy: supersededBy,
    replaces: replaces,
    editedFields: editedFields,
    editedBy: editedBy,
    editedAt: editedAt,
    computed: computed,
    rates: rates,
    commission: commission,
  );

  /// The price a service's new line starts at: the catalog's, only once it is settled (a server older than Phase 2 sends
  /// no status, and its rate is its usual price), and never $0.00, so a line can't come in as a silent no-charge line.
  double? get _serviceRate {
    final r = rate;
    if (r == null || (r * 100).round() == 0) return null;
    return priceStatus == null || priceStatus == 'settled' ? r : null;
  }

  /// The new line this entry becomes: quantity 1, the catalog's price and cost as the starting values (and kept as
  /// the record of what the catalog said), nothing filled in that the catalog doesn't have.
  ///
  /// A service (Services Catalog Phase 2): its price only when settled (otherwise the line starts unpriced, never at
  /// $0), its cost only when known, no unit, and taxed only when its billed lines all were (`taxed`).
  LineDraft toLine() => isService ? _serviceLine() : LineDraft(
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
    service: false,
  );

  LineDraft _serviceLine() {
    final r = _serviceRate;
    return LineDraft(
      name: name,
      description: description,
      sku: sku,
      quantity: 1,
      rate: r,
      cost: cost,
      taxable: taxDefault == null ? taxable : taxDefault == 'taxed',
      inventoryItemId: inventoryItemId,
      catalogKey: key,
      catalogRate: r,
      catalogCost: cost,
      source: 'catalog',
      service: true,
    );
  }

  /// Whether picking this adds a service package: a service with rates of its own.
  bool get isPackage => isService && rates.isNotEmpty;

  /// A service package's lines (USER RULE 2026-11-20): one per rate, in the package's order, each at its own starting
  /// quantity (usually 0, raised when the job needs it), price and cost, taxed as the service is, all carrying
  /// [packageId] and the package's name for the heading over them. None of them is a "main" line.
  List<LineDraft> toPackageLines(String packageId) => [
    for (final r in rates)
      LineDraft(
        name: r.name,
        description: r.description,
        quantity: r.qty,
        rate: r.rate,
        cost: r.cost,
        taxable: taxDefault == null ? taxable : taxDefault == 'taxed',
        catalogKey: key,
        catalogRate: r.rate,
        catalogCost: r.cost,
        source: 'catalog',
        packageId: packageId,
        packageName: name,
        service: true,
      ),
  ];

  static List<CatalogPrice> _prices(Object? v) => [
    for (final p in (v is List ? v : const []).whereType<Map>())
      if (p['price'] is num) (date: (p['date'] ?? '').toString(), price: (p['price'] as num).toDouble()),
  ];

  static ({String key, String name})? _ref(Object? v) =>
      v is Map && v['key'] != null ? (key: v['key'].toString(), name: (v['name'] ?? '').toString()) : null;

  /// What a service package comes to at its rates' starting quantities, as its page says ("Starts at"): the lines at 0
  /// add nothing until a job needs them. Null when none of its rates has a price ([cost]: a cost).
  static double? startsAt(List<ServiceRate> rates, {bool cost = false}) {
    final known = [for (final r in rates) if ((cost ? r.cost : r.rate) != null) r];
    if (known.isEmpty) return null;
    return known.fold<int>(0, (sum, r) => sum + (((cost ? r.totalCost : r.total) ?? 0) * 100).round()) / 100;
  }

  factory CatalogEntry.fromJson(Map<String, dynamic> j) {
    final rates = [for (final x in (j['rates'] as List? ?? const []).whereType<Map>()) ServiceRate.fromJson(Map<String, dynamic>.from(x))];
    // A service package has no main rate (USER RULE 2026-11-20): the list, its sort and filters, the CSV and the picker
    // show what its page shows, the sum at its starting quantities. The server set its price from its FIRST rate, so a
    // package whose first line starts at 0 showed that line's price on the list and another on its page (audit round 2).
    final package = (j['kind'] ?? 'product') == 'service' && rates.isNotEmpty;
    final rate = package ? startsAt(rates) : (j['rate'] as num?)?.toDouble();
    final cost = package ? startsAt(rates, cost: true) : (j['cost'] as num?)?.toDouble();
    return CatalogEntry._fromJson(j, rates, rate, cost);
  }

  factory CatalogEntry._fromJson(Map<String, dynamic> j, List<ServiceRate> rates, double? rate, double? cost) => CatalogEntry(
    key: j['key'].toString(),
    name: (j['name'] ?? '').toString(),
    sku: (j['sku'] ?? '').toString(),
    category: (j['category'] ?? '').toString(),
    kind: (j['kind'] ?? 'product').toString(),
    inventoryItemId: (j['inventoryItemId'] as num?)?.toInt(),
    stock: (j['stock'] as num?)?.toInt(),
    rate: rate,
    rateUses: (j['rateUses'] as num?)?.toInt() ?? 0,
    rateMin: (j['rateMin'] as num?)?.toDouble(),
    rateMax: (j['rateMax'] as num?)?.toDouble(),
    cost: cost,
    costSource: j['costSource']?.toString(),
    uses: (j['uses'] as num?)?.toInt() ?? 0,
    lastUsed: j['lastUsed']?.toString(),
    taxable: j['taxable'] == true,
    description: (j['description'] ?? '').toString(),
    memberPrice: (j['memberPrice'] as num?)?.toDouble(),
    model: (j['model'] ?? '').toString(),
    purchaseNote: (j['purchaseNote'] ?? '').toString(),
    vendors: [
      for (final v in (j['vendors'] as List? ?? const []).whereType<Map>())
        if ((v['name'] ?? '').toString().trim().isNotEmpty) (name: v['name'].toString().trim(), price: (v['price'] as num?)?.toDouble()),
    ],
    active: j['active'] != false,
    inventoryItem: j['inventoryItem'] is bool ? j['inventoryItem'] as bool : null,
    inventoryConflict: j['inventoryConflict']?.toString(),
    inventoryLink: j['inventoryLink']?.toString(),
    updatedAt: j['updatedAt']?.toString(),
    priceStatus: j['priceStatus']?.toString(),
    medianPrice: (j['medianPrice'] as num?)?.toDouble(),
    lastBilled: j['lastBilled'] is Map && (j['lastBilled'] as Map)['price'] is num
        ? (date: ((j['lastBilled'] as Map)['date'] ?? '').toString(), price: ((j['lastBilled'] as Map)['price'] as num).toDouble())
        : null,
    recentPrices: _prices(j['recentPrices']),
    recentChange: CatalogPriceChange.fromJson(j['recentChange']),
    quoteMedian: (j['quoteMedian'] as num?)?.toDouble(),
    quoteCount: (j['quoteCount'] as num?)?.toInt() ?? 0,
    taxDefault: j['taxDefault']?.toString(),
    taxWarning: (j['taxWarning'] ?? '').toString().trim().isEmpty ? null : j['taxWarning'].toString().trim(),
    group: (j['group'] ?? j['category'] ?? '').toString(),
    aliases: [
      for (final a in (j['aliases'] as List? ?? const []))
        if (a != null && a.toString().trim().isNotEmpty) a.toString().trim(),
    ],
    rateId: j['rateId']?.toString(),
    variantOf: _ref(j['variantOf']),
    variants: [
      for (final v in (j['variants'] as List? ?? const [])) ?_ref(v),
    ],
    supersededBy: _ref(j['supersededBy']),
    replaces: [
      for (final v in (j['replaces'] as List? ?? const [])) ?_ref(v),
    ],
    editedFields: [for (final f in (j['editedFields'] as List? ?? const [])) f.toString()],
    editedBy: j['editedBy']?.toString(),
    editedAt: j['editedAt']?.toString(),
    computed: j['computed'] is Map ? Map<String, dynamic>.from(j['computed'] as Map) : null,
    rates: rates,
    commission: ServiceCommission.fromJson(j['commission']),
  );
}

/// A service's commission (backend service_overrides commission_type / commission_value): a percentage of the service's
/// price, or a fixed amount each time it is sold. [value] null: the kind is chosen, the amount not entered yet.
class ServiceCommission {
  final String type; // percent | fixed
  final double? value;
  const ServiceCommission(this.type, this.value);

  bool get isPercent => type == 'percent';

  static ServiceCommission? fromJson(Object? j) {
    if (j is! Map || (j['type'] != 'percent' && j['type'] != 'fixed')) return null;
    return ServiceCommission(j['type'] as String, (j['value'] as num?)?.toDouble());
  }

  Map<String, dynamic> toJson() => {'type': type, 'value': value};

  @override
  bool operator ==(Object other) => other is ServiceCommission && other.type == type && other.value == value;

  @override
  int get hashCode => Object.hash(type, value);
}

/// One category of the price list (backend /api/catalog/categories): its products' own category text, plus the saved
/// row that gives it a description (and lets it exist with no products yet).
class CatalogCategory {
  final String name;
  final int products;
  final int active;
  final List<int> productIds;
  final String description;

  /// Has a saved row (created here, or described). A category only on products has none until it is described.
  final bool saved;
  final String? updatedAt;
  final String? updatedBy;

  const CatalogCategory({
    required this.name,
    this.products = 0,
    this.active = 0,
    this.productIds = const [],
    this.description = '',
    this.saved = false,
    this.updatedAt,
    this.updatedBy,
  });

  int get inactive => products - active;
  bool get isEmpty => products == 0;

  factory CatalogCategory.fromJson(Map<String, dynamic> j) => CatalogCategory(
    name: (j['name'] ?? '').toString(),
    products: (j['products'] as num?)?.toInt() ?? 0,
    active: (j['active'] as num?)?.toInt() ?? 0,
    productIds: [
      for (final i in (j['productIds'] as List? ?? const []))
        if (i is num) i.toInt(),
    ],
    description: (j['description'] ?? '').toString(),
    saved: j['saved'] == true,
    updatedAt: j['updatedAt']?.toString(),
    updatedBy: j['updatedBy']?.toString(),
  );
}

/// A mark on a Cleanup finding: a possible-duplicate group, or one product under one check (`no_cost:123`). [status] is
/// `reviewed` (fine as it is) or `follow_up` (still a question; someone is on it). It applies only while the finding
/// still has exactly the products it had ([signature]: their ids, comma-separated) and, for one product, the values the
/// check looked at ([basis], e.g. its price and cost).
class CatalogReview {
  final String issueKey;
  final String signature;
  final String status;
  final String? basis;
  final String note;
  final String? reviewedBy;
  final DateTime? reviewedAt;

  /// [reviewedAt] as the server sent it: sent back when the mark is changed, so a newer mark is never overwritten.
  final String? stamp;
  const CatalogReview({
    required this.issueKey,
    required this.signature,
    this.status = 'reviewed',
    this.basis,
    this.note = '',
    this.reviewedBy,
    this.reviewedAt,
    this.stamp,
  });

  bool get followUp => status == 'follow_up';

  factory CatalogReview.fromJson(Map<String, dynamic> j) => CatalogReview(
    issueKey: (j['issueKey'] ?? '').toString(),
    signature: (j['signature'] ?? '').toString(),
    status: (j['status'] ?? 'reviewed').toString(),
    basis: j['basis']?.toString(),
    note: (j['note'] ?? '').toString(),
    reviewedBy: j['reviewedBy']?.toString(),
    reviewedAt: DateTime.tryParse((j['reviewedAt'] ?? '').toString())?.toLocal(),
    stamp: j['reviewedAt']?.toString(),
  );
}

/// One product's sales in all of Service Fusion's history (not only the catalog's window), and the stock row the list
/// links it to (null when it has none).
class CatalogSale {
  final int id;
  final DateTime? lastJobAt;
  final String? lastJob;
  final int jobs;
  final DateTime? lastEstimateAt;
  final String? lastEstimate;
  final int estimates;
  final ({int itemId, int? qty, String? location, int? reorderPoint, DateTime? updatedAt})? stock;
  const CatalogSale({
    required this.id,
    this.lastJobAt,
    this.lastJob,
    this.jobs = 0,
    this.lastEstimateAt,
    this.lastEstimate,
    this.estimates = 0,
    this.stock,
  });

  factory CatalogSale.fromJson(Map<String, dynamic> j) {
    final s = j['stock'] is Map ? Map<String, dynamic>.from(j['stock'] as Map) : null;
    DateTime? at(Object? v) => DateTime.tryParse((v ?? '').toString())?.toLocal();
    return CatalogSale(
      id: (j['id'] as num?)?.toInt() ?? 0,
      lastJobAt: at(j['lastJobAt']),
      lastJob: j['lastJob']?.toString(),
      jobs: (j['jobs'] as num?)?.toInt() ?? 0,
      lastEstimateAt: at(j['lastEstimateAt']),
      lastEstimate: j['lastEstimate']?.toString(),
      estimates: (j['estimates'] as num?)?.toInt() ?? 0,
      stock: s == null || s['itemId'] is! num
          ? null
          : (
              itemId: (s['itemId'] as num).toInt(),
              qty: (s['qty'] as num?)?.toInt(),
              location: s['location']?.toString(),
              reorderPoint: (s['reorderPoint'] as num?)?.toInt(),
              updatedAt: at(s['updatedAt']),
            ),
    );
  }
}

/// The History view's filters: who, from (inclusive) and to (exclusive), one product, and kinds of change (a family like
/// `category` or one action like `products.bulk`). Empty = everything.
class CatalogAuditFilter {
  final String? by;
  final DateTime? from;
  final DateTime? to;
  final int? productId;
  final List<String> actions;
  const CatalogAuditFilter({this.by, this.from, this.to, this.productId, this.actions = const []});

  bool get isEmpty => by == null && from == null && to == null && productId == null && actions.isEmpty;

  Map<String, String> get query => {
    'by': ?by,
    if (from != null) 'from': from!.toUtc().toIso8601String(),
    if (to != null) 'to': to!.toUtc().toIso8601String(),
    if (productId != null) 'productId': '$productId',
    if (actions.isNotEmpty) 'actions': actions.join(','),
  };

  /// The same rule as the server, so an older server that ignores the filters still shows only what was asked.
  bool matches(CatalogAuditEntry e) {
    if (by != null && e.by != by) return false;
    final at = e.at;
    if (from != null && (at == null || at.isBefore(from!))) return false;
    if (to != null && (at == null || !at.isBefore(to!))) return false;
    if (productId != null && !e.productIds.contains(productId)) return false;
    if (actions.isNotEmpty && !actions.any((a) => e.action == a || e.action.split('.').first == a)) return false;
    return true;
  }
}

/// One line of the catalog's change log. A cost value the person may not see comes back as null.
class CatalogAuditEntry {
  final int id;
  final DateTime? at;
  final String by;

  /// category.create|rename|update|merge|delete, products.bulk, product.create|update|delete, review.mark|clear
  final String action;
  final String summary;
  final List<int> productIds;
  final Map<String, dynamic> details;
  const CatalogAuditEntry({
    required this.id,
    this.at,
    this.by = '',
    required this.action,
    required this.summary,
    this.productIds = const [],
    this.details = const {},
  });

  factory CatalogAuditEntry.fromJson(Map<String, dynamic> j) => CatalogAuditEntry(
    id: (j['id'] as num?)?.toInt() ?? 0,
    at: DateTime.tryParse((j['at'] ?? '').toString())?.toLocal(),
    by: (j['by'] ?? '').toString(),
    action: (j['action'] ?? '').toString(),
    summary: (j['summary'] ?? '').toString(),
    productIds: [
      for (final i in (j['productIds'] as List? ?? const []))
        if (i is num) i.toInt(),
    ],
    details: j['details'] is Map ? Map<String, dynamic>.from(j['details'] as Map) : const {},
  );
}

/// What a change to several products did: how many changed, how many already were as asked, and each changed
/// product's new category, status and change time.
typedef CatalogBulkResult = ({int changed, int skipped, List<({int id, String category, bool active, String? updatedAt})> products});

/// One product on the price list, as its own page edits it (backend /api/catalog/products/:id). The cost, vendor and pay
/// fields are null for someone without the Line Items & Costs view switch.
class ProductRecord {
  final int? id; // null for a product not saved yet
  final String name;
  final String category;
  final String partNumber;
  final String model;
  final String sku;
  final String productType;
  final double? unitPrice;
  final double? memberPrice;
  final double? avgUnitCost;
  final bool isActive;
  final bool isInventoryItem;
  final String relatedProducts;
  final String purchaseDescription;
  final String description;
  final bool paysCommission;
  final double? fixedCommission;
  final double? percentCommission;
  final bool paysBonus;
  final double? fixedBonus;
  final double? percentBonus;
  final double? paysHours;
  final List<({String name, double? price})> vendors;

  /// When it was last saved (the server's own text): sent back with an edit so a change made by someone else is noticed.
  final String? updatedAt;
  final String? updatedBy;

  const ProductRecord({
    this.id,
    this.name = '',
    this.category = '',
    this.partNumber = '',
    this.model = '',
    this.sku = '',
    this.productType = '',
    this.unitPrice,
    this.memberPrice,
    this.avgUnitCost,
    this.isActive = true,
    this.isInventoryItem = false,
    this.relatedProducts = '',
    this.purchaseDescription = '',
    this.description = '',
    this.paysCommission = false,
    this.fixedCommission,
    this.percentCommission,
    this.paysBonus = false,
    this.fixedBonus,
    this.percentBonus,
    this.paysHours,
    this.vendors = const [],
    this.updatedAt,
    this.updatedBy,
  });

  factory ProductRecord.fromJson(Map<String, dynamic> j) {
    String t(String k) => (j[k] ?? '').toString();
    double? n(String k) => (j[k] as num?)?.toDouble();
    return ProductRecord(
      id: (j['id'] as num?)?.toInt(),
      name: t('name'),
      category: t('category'),
      partNumber: t('partNumber'),
      model: t('model'),
      sku: t('sku'),
      productType: t('productType'),
      unitPrice: n('unitPrice'),
      memberPrice: n('memberPrice'),
      avgUnitCost: n('avgUnitCost'),
      isActive: j['isActive'] != false,
      isInventoryItem: j['isInventoryItem'] == true,
      relatedProducts: t('relatedProducts'),
      purchaseDescription: t('purchaseDescription'),
      description: t('description'),
      paysCommission: j['paysCommission'] == true,
      fixedCommission: n('fixedCommission'),
      percentCommission: n('percentCommission'),
      paysBonus: j['paysBonus'] == true,
      fixedBonus: n('fixedBonus'),
      percentBonus: n('percentBonus'),
      paysHours: n('paysHours'),
      vendors: [
        for (final v in (j['vendors'] as List? ?? const []).whereType<Map>())
          if ((v['name'] ?? '').toString().trim().isNotEmpty) (name: v['name'].toString().trim(), price: (v['price'] as num?)?.toDouble()),
      ],
      updatedAt: j['updatedAt']?.toString(),
      updatedBy: j['updatedBy']?.toString(),
    );
  }
}

/// A product with what the page needs around it: what is in stock, and what this person may see and do.
/// [inventoryConflict] says why no stock is shown when its inventory row needs a person to sort it out (see CatalogEntry).
typedef ProductPage = ({ProductRecord product, int? stock, bool canSeeCost, bool canEdit, String? inventoryConflict});

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
        code: data['code']?.toString(),
        duplicates: [
          for (final d in (data['duplicates'] as List? ?? const []).whereType<Map>())
            if (d['id'] is num)
              (id: (d['id'] as num).toInt(), name: (d['name'] ?? '').toString(), partNumber: d['partNumber']?.toString()),
        ],
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
      body: {
        'version': version,
        'items': [for (final i in items) i.toJson()],
        'taxRate': taxRate,
      },
    ),
  );

  Future<LineItemsState> delete(String id) async => LineItemsState.fromJson(await _call('DELETE', Uri.parse('$_base/${Uri.encodeComponent(id)}')));

  Future<LineItemsState> accept(String id, int version) async =>
      LineItemsState.fromJson(await _call('POST', Uri.parse('$_base/${Uri.encodeComponent(id)}/accept'), body: {'version': version}));

  /// Records that line [itemId] of option [optionId], a $0.00 line, is no charge (the signed-in person and the time are
  /// the server's). It changes nothing else on the line. Refused while the option is accepted or [version] is stale
  /// (409), when the line isn't in the option (404) or isn't a $0 line (400).
  Future<LineItemsState> confirmZero(String optionId, String itemId, int version) async => LineItemsState.fromJson(
    await _call(
      'POST',
      Uri.parse('$_base/${Uri.encodeComponent(optionId)}/items/${Uri.encodeComponent(itemId)}/confirm-zero'),
      body: {'version': version},
    ),
  );

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

  /// The whole price list for the catalog pages (backend /api/catalog/list), optionally one [kind] (product | service),
  /// most-used first. [includeInactive] adds the products the price list marks inactive. [canSeeCost] is false when the person's Line Items & Costs > View switch is off (cost is then null).
  static Future<({List<CatalogEntry> entries, bool canSeeCost, int historyDays})> listCatalog({String? kind, bool includeInactive = false}) async {
    final d = await _call(
      'GET',
      Uri.parse('$kApiBaseUrl/api/catalog/list').replace(queryParameters: {'kind': ?kind, if (includeInactive) 'includeInactive': '1'}),
    );
    return (
      entries: [for (final e in (d['results'] as List? ?? const []).whereType<Map>()) CatalogEntry.fromJson(Map<String, dynamic>.from(e))],
      canSeeCost: d['canSeeCost'] == true,
      historyDays: (d['historyDays'] as num?)?.toInt() ?? 540,
    );
  }

  /// Saves the office's edit of a service (backend PUT /api/catalog/services/override): only the [fields] sent change;
  /// a field sent as null goes back to what the job lines say. Returns the service as it now reads. Needs Line Items &
  /// Costs > Update and the Services Catalog page; a server older than 2026-11-19 answers 404/405.
  static Future<CatalogEntry> saveService(String key, Map<String, dynamic> fields) async {
    final d = await _call('PUT', Uri.parse('$kApiBaseUrl/api/catalog/services/override'), body: {'key': key, ...fields});
    return CatalogEntry.fromJson(Map<String, dynamic>.from(d['service'] as Map));
  }

  /// Saves a service's rate lines as a whole set, in order (an empty list removes them). Returns the service as it now reads.
  static Future<CatalogEntry> saveServiceRates(String key, List<ServiceRate> rates, {required bool withCost}) async {
    final d = await _call(
      'PUT',
      Uri.parse('$kApiBaseUrl/api/catalog/services/rates'),
      body: {
        'key': key,
        'rates': [for (final r in rates) r.toJson(withCost: withCost)],
      },
    );
    return CatalogEntry.fromJson(Map<String, dynamic>.from(d['service'] as Map));
  }

  static ProductPage _productPage(Map<String, dynamic> d, {bool? canSeeCost}) => (
    product: ProductRecord.fromJson(Map<String, dynamic>.from(d['product'] as Map)),
    stock: (d['stock'] as num?)?.toInt(),
    canSeeCost: canSeeCost ?? d['canSeeCost'] == true,
    canEdit: d['canEdit'] == true,
    inventoryConflict: (d['inventory'] is Map ? (d['inventory'] as Map)['conflict'] : null)?.toString(),
  );

  /// One product for its own page. Throws [LineItemsException] (status 404 when it is gone).
  static Future<ProductPage> getProduct(int id) async => _productPage(await _call('GET', Uri.parse('$kApiBaseUrl/api/catalog/products/$id')));

  /// Adds a product to the price list; [fields] are the request's camelCase fields (name is required). Returns it as saved.
  /// A name or part number another product already has is refused (409 `DUPLICATE`) unless [confirmDuplicate].
  static Future<ProductRecord> createProduct(Map<String, dynamic> fields, {bool confirmDuplicate = false}) async {
    final d = await _call('POST', Uri.parse('$kApiBaseUrl/api/catalog/products'), body: {...fields, if (confirmDuplicate) 'confirmDuplicate': true});
    return ProductRecord.fromJson(Map<String, dynamic>.from(d['product'] as Map));
  }

  /// Saves [fields] (only the ones that changed) over a product. [expectedUpdatedAt] is its `updatedAt` when the page
  /// loaded: if someone else saved since, the server answers 409 and nothing is overwritten. A name or part number
  /// another product already has is refused (409 `DUPLICATE`) unless [confirmDuplicate].
  static Future<ProductRecord> updateProduct(int id, Map<String, dynamic> fields, {String? expectedUpdatedAt, bool confirmDuplicate = false}) async {
    final d = await _call(
      'PATCH',
      Uri.parse('$kApiBaseUrl/api/catalog/products/$id'),
      body: {...fields, 'expectedUpdatedAt': ?expectedUpdatedAt, if (confirmDuplicate) 'confirmDuplicate': true},
    );
    return ProductRecord.fromJson(Map<String, dynamic>.from(d['product'] as Map));
  }

  static Future<void> deleteProduct(int id) async {
    await _call('DELETE', Uri.parse('$kApiBaseUrl/api/catalog/products/$id'));
  }

  // ---- managing the catalog (backend src/catalogManage.js) ---------------------------------------------------------
  // A server older than Phase 3 answers these with 404: the pages then show what they can from the product list.

  /// Every category with its products' ids and description; [uncategorized] products have none. [canEdit] follows the
  /// Line Items & Costs > Update switch.
  static Future<({List<CatalogCategory> categories, int uncategorized, bool canEdit})> listCategories() async {
    final d = await _call('GET', Uri.parse('$kApiBaseUrl/api/catalog/categories'));
    return (
      categories: [for (final c in (d['categories'] as List? ?? const []).whereType<Map>()) CatalogCategory.fromJson(Map<String, dynamic>.from(c))],
      uncategorized: (d['uncategorized'] as num?)?.toInt() ?? 0,
      canEdit: d['canEdit'] == true,
    );
  }

  static Future<CatalogCategory> createCategory(String name, {String? description}) async {
    final d = await _call('POST', Uri.parse('$kApiBaseUrl/api/catalog/categories'), body: {'name': name, 'description': ?description});
    return CatalogCategory.fromJson(Map<String, dynamic>.from(d['category'] as Map));
  }

  /// Renames [name] (to [newName]) and/or sets its description ([setDescription]). A rename sends the product ids the
  /// page showed in it ([expectedProductIds]): if products came or went since, nothing changes (409 `CHANGED`).
  /// Another category with the new name is refused (409 `CATEGORY_EXISTS`: use [mergeCategories]).
  static Future<({CatalogCategory category, int moved})> updateCategory(
    String name, {
    String? newName,
    bool setDescription = false,
    String? description,
    List<int>? expectedProductIds,
    String? expectedUpdatedAt,
  }) async {
    final d = await _call(
      'PATCH',
      Uri.parse('$kApiBaseUrl/api/catalog/categories'),
      body: {
        'name': name,
        'newName': ?newName,
        if (setDescription) 'description': description,
        'expectedProductIds': ?expectedProductIds,
        if (setDescription) 'expectedUpdatedAt': expectedUpdatedAt,
      },
    );
    return (category: CatalogCategory.fromJson(Map<String, dynamic>.from(d['category'] as Map)), moved: (d['moved'] as num?)?.toInt() ?? 0);
  }

  /// Moves every product of [sources] into [target] (an existing category, or a new one) and drops the sources.
  static Future<({CatalogCategory category, int moved})> mergeCategories(List<String> sources, String target, {required List<int> expectedProductIds}) async {
    final d = await _call(
      'POST',
      Uri.parse('$kApiBaseUrl/api/catalog/categories/merge'),
      body: {'sources': sources, 'target': target, 'expectedProductIds': expectedProductIds},
    );
    return (category: CatalogCategory.fromJson(Map<String, dynamic>.from(d['category'] as Map)), moved: (d['moved'] as num?)?.toInt() ?? 0);
  }

  /// Deletes an empty category (one with products is refused: 409 `CATEGORY_NOT_EMPTY`).
  static Future<void> deleteCategory(String name) async {
    await _call('DELETE', Uri.parse('$kApiBaseUrl/api/catalog/categories').replace(queryParameters: {'name': name}));
  }

  /// Sets the category and/or Active on several products. [expected] is each product's `updatedAt` as the list showed
  /// it: if any changed since, nothing is written (409 `CHANGED`, see [LineItemsException.code]).
  static Future<CatalogBulkResult> bulkUpdateProducts(Map<int, String> expected, {String? category, bool? active}) async {
    final d = await _call(
      'POST',
      Uri.parse('$kApiBaseUrl/api/catalog/products/bulk'),
      body: {
        'ids': expected.keys.toList(),
        'set': {'category': ?category, 'isActive': ?active},
        'expected': {for (final e in expected.entries) '${e.key}': e.value},
      },
    );
    return (
      changed: (d['changed'] as num?)?.toInt() ?? 0,
      skipped: (d['skipped'] as num?)?.toInt() ?? 0,
      products: [
        for (final p in (d['products'] as List? ?? const []).whereType<Map>())
          if (p['id'] is num)
            (id: (p['id'] as num).toInt(), category: (p['category'] ?? '').toString(), active: p['active'] != false, updatedAt: p['updatedAt']?.toString()),
      ],
    );
  }

  static Future<({List<CatalogReview> reviews, bool canEdit})> listReviews() async {
    final d = await _call('GET', Uri.parse('$kApiBaseUrl/api/catalog/reviews'));
    return (
      reviews: [for (final r in (d['reviews'] as List? ?? const []).whereType<Map>()) CatalogReview.fromJson(Map<String, dynamic>.from(r))],
      canEdit: d['canEdit'] == true,
    );
  }

  /// Marks a finding [status] `reviewed` or `follow_up`. With [checkExpected], [expectedStamp] is the mark the page showed
  /// (null: none): if someone changed the mark since, nothing is saved (409 `CHANGED`). Returns the saved mark (null from
  /// a server older than 11-18).
  static Future<CatalogReview?> markReviewed(
    String issueKey,
    String signature, {
    String? note,
    String? label,
    String status = 'reviewed',
    String? basis,
    bool checkExpected = false,
    String? expectedStamp,
  }) async {
    final d = await _call(
      'PUT',
      Uri.parse('$kApiBaseUrl/api/catalog/reviews'),
      body: {
        'issueKey': issueKey,
        'signature': signature,
        'note': ?note,
        'label': ?label,
        'status': status,
        'basis': ?basis,
        if (checkExpected) 'expectedReviewedAt': expectedStamp,
      },
    );
    return d['review'] is Map ? CatalogReview.fromJson(Map<String, dynamic>.from(d['review'] as Map)) : null;
  }

  /// Takes a mark off. [expectedStamp] (the mark the page showed) makes it refuse when someone changed the mark since.
  static Future<void> clearReview(String issueKey, {String? expectedStamp}) async {
    await _call(
      'DELETE',
      Uri.parse('$kApiBaseUrl/api/catalog/reviews').replace(queryParameters: {'issueKey': issueKey, 'expectedReviewedAt': ?expectedStamp}),
    );
  }

  /// Every mark, follow-up and undo of one finding, newest first.
  static Future<List<CatalogAuditEntry>> reviewHistory(String issueKey) async {
    final d = await _call('GET', Uri.parse('$kApiBaseUrl/api/catalog/reviews/history').replace(queryParameters: {'issueKey': issueKey}));
    return [for (final e in (d['entries'] as List? ?? const []).whereType<Map>()) CatalogAuditEntry.fromJson(Map<String, dynamic>.from(e))];
  }

  /// The change log, newest first; [before] continues from an entry's id. [more] says there are older ones.
  static Future<({List<CatalogAuditEntry> entries, bool more})> listCatalogAudit({
    int limit = 100,
    int? before,
    int? productId,
    CatalogAuditFilter filter = const CatalogAuditFilter(),
  }) async {
    final d = await _call(
      'GET',
      Uri.parse('$kApiBaseUrl/api/catalog/audit').replace(
        queryParameters: {
          'limit': '$limit',
          if (before != null) 'before': '$before',
          if (productId != null) 'productId': '$productId',
          ...filter.query,
        },
      ),
    );
    return (
      entries: [for (final e in (d['entries'] as List? ?? const []).whereType<Map>()) CatalogAuditEntry.fromJson(Map<String, dynamic>.from(e))],
      more: d['more'] == true,
    );
  }

  /// Who appears in the change log, most recent first (the History view's Who filter).
  static Future<List<({String name, int changes})>> catalogAuditPeople() async {
    final d = await _call('GET', Uri.parse('$kApiBaseUrl/api/catalog/audit/people'));
    return [
      for (final p in (d['people'] as List? ?? const []).whereType<Map>())
        if ((p['name'] ?? '').toString().isNotEmpty) (name: p['name'].toString(), changes: (p['changes'] as num?)?.toInt() ?? 0),
    ];
  }

  /// [ids]' sales in all of Service Fusion's history, and their stock rows. [since] is the oldest job on record.
  static Future<({DateTime? since, Map<int, CatalogSale> sales})> productSales(List<int> ids) async {
    final d = await _call('POST', Uri.parse('$kApiBaseUrl/api/catalog/products/sales'), body: {'ids': ids});
    return (
      since: DateTime.tryParse((d['since'] ?? '').toString())?.toLocal(),
      sales: {
        for (final s in (d['sales'] as List? ?? const []).whereType<Map>())
          if (s['id'] is num) (s['id'] as num).toInt(): CatalogSale.fromJson(Map<String, dynamic>.from(s)),
      },
    );
  }
}
