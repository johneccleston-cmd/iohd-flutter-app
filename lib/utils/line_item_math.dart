// The one formula for a set of line items (an estimate option, or a job's items edited in the app), the same as the
// backend's src/lineItemMath.js: the app recomputes while someone types, the server recomputes what it stores, and
// both are tested against the same cases (test/fixtures/line_item_math_cases.json, scripts/line_item_math_cases.json).
//
// Money is worked in whole cents and quantities in thousandths, so both copies agree to the cent. Each product
// (thousandths x cents, cents x tax rate) is exact ([mulDivRound]): on the web an int is a JavaScript number, which past
// 2^53 drops its last digits and can move a half cent.
//   line amount    = quantity x rate, rounded half away from zero (an unpriced line counts $0 and is flagged)
//                    A quantity can be negative: Service Fusion keeps returns and credits as -1 x the price.
//   extended cost  = quantity x unit cost, rounded the same way
//   tax            = tax rate x (taxable items - taxable discounts), never below 0
//   total          = items - discounts + tax
//   gross profit   = (items - discounts) - cost. Sales tax goes to the state, so it is never profit.
// Profit and margin are only worked out when every line's cost is known (Services Catalog Phase 2, 2026-11-18): a line
// with a quantity and no cost makes both null, and missingCostLines says how many lines lack one (an unknown cost read
// as $0 showed a 100% margin on lines nobody had costed). A line at $0.00 with a quantity is a no-charge line:
// zeroUnconfirmedLines counts the ones nobody has confirmed ([LineDraft.zeroPriceConfirmed]), so a silent $0 can't slip
// through. An unpriced line (rate null) is not a $0 line.

/// What a line is: something sold, or a discount taken off (entered as a positive amount).
enum LineKind { item, discount }

/// The most a quantity can be, either way (LIMITS.maxQuantity in lineItemMath.js). Service Fusion's percentage lines carry
/// their dollar base as the quantity ("10% Discount": 35,125.3 x -$0.10; the largest on prod is 49,376).
const kMaxLineQuantity = 999999.999;

/// The most a rate or a unit cost can be, either way (LIMITS.maxRate).
const kMaxLineRate = 999999.99;

/// The most one line's quantity x rate can come to, either way (LIMITS.maxLineAmount).
const kMaxLineAmount = 9999999.99;

/// Whether [quantity] x [rate] (an unpriced line always fits) is within [kMaxLineAmount], worked exactly in cents as the
/// totals are, so the app and the server draw the line in the same place.
bool lineAmountFits(double quantity, double? rate) =>
    rate == null || mulDivRound(_milli(quantity), (rate * 100).round(), 1000).abs() <= (kMaxLineAmount * 100).round();

/// One line as the editor holds it. Money is in dollars here; [computeLineTotals] converts to cents.
class LineDraft {
  /// The saved line's id, or null for a line added since the last save.
  final String? id;
  final LineKind kind;
  final String name;
  final String description;
  final String sku;
  final String unit;
  final double quantity;

  /// Selling price per unit. Null = not priced yet.
  final double? rate;

  /// Internal cost per unit. Null = unknown (or hidden from this person).
  final double? cost;
  final bool taxable;
  final int? inventoryItemId;
  final String? catalogKey;

  /// The catalog's price and cost when the line was added, kept so a later catalog change never re-prices it.
  final double? catalogRate;
  final double? catalogCost;

  /// catalog, service_fusion, manual or copy.
  final String source;

  /// The sales tax on a taxable line, by name ("Sales Tax (State, County, & Local Use Tax, Bentonville)"), as Service
  /// Fusion names it. Null on a taxable line: the set's own tax rate. Not saved by the server yet.
  final String? taxName;

  /// Whether the line shows on the customer's copy (Service Fusion's eye icon, its `is_show_rate_items`). A hidden
  /// line is still charged; it only isn't listed for the customer. Not saved by the server yet.
  final bool customerVisible;

  /// Someone confirmed that this $0.00 line is no charge ([isZeroPrice]). From the server, a line with a recorded
  /// confirmer or time; in the preview, the person who confirmed it there. Changing the line's name, quantity or price
  /// takes it off again ([copyWith]): the confirmation was for the line as it was.
  final bool zeroPriceConfirmed;

  /// Who confirmed it and when (the server records both; the preview has only who).
  final String? zeroPriceConfirmedBy;
  final DateTime? zeroPriceConfirmedAt;

  const LineDraft({
    this.id,
    this.kind = LineKind.item,
    required this.name,
    this.description = '',
    this.sku = '',
    this.unit = '',
    this.quantity = 1,
    this.rate,
    this.cost,
    this.taxable = false,
    this.inventoryItemId,
    this.catalogKey,
    this.catalogRate,
    this.catalogCost,
    this.source = 'manual',
    this.customerVisible = true,
    this.taxName,
    this.zeroPriceConfirmed = false,
    this.zeroPriceConfirmedBy,
    this.zeroPriceConfirmedAt,
  });

  bool get isDiscount => kind == LineKind.discount;

  /// A $0 line (the server's rule, src/lineItemMath.js): an item priced at a rate that rounds to $0.00, with a
  /// quantity. It needs someone to confirm it is no charge. A line at quantity 0, or not priced yet, isn't one.
  bool get isZeroPrice => !isDiscount && rate != null && (rate! * 100).round() == 0 && _milli(quantity) != 0;

  /// A $0 line nobody has confirmed yet.
  bool get zeroUnconfirmed => isZeroPrice && !zeroPriceConfirmed;

  static const _keep = Object();

  LineDraft copyWith({
    Object? id = _keep,
    String? name,
    String? description,
    String? sku,
    String? unit,
    double? quantity,
    Object? rate = _keep,
    Object? cost = _keep,
    bool? taxable,
    bool? customerVisible,
    Object? taxName = _keep,
    bool? zeroPriceConfirmed,
    String? zeroPriceConfirmedBy,
  }) => LineDraft(
    id: identical(id, _keep) ? this.id : id as String?,
    kind: kind,
    name: name ?? this.name,
    description: description ?? this.description,
    sku: sku ?? this.sku,
    unit: unit ?? this.unit,
    quantity: quantity ?? this.quantity,
    rate: identical(rate, _keep) ? this.rate : (rate as num?)?.toDouble(),
    cost: identical(cost, _keep) ? this.cost : (cost as num?)?.toDouble(),
    taxable: taxable ?? this.taxable,
    inventoryItemId: inventoryItemId,
    catalogKey: catalogKey,
    catalogRate: catalogRate,
    catalogCost: catalogCost,
    source: source,
    customerVisible: customerVisible ?? this.customerVisible,
    taxName: identical(taxName, _keep) ? this.taxName : taxName as String?,
    // A confirmation given here is taken as given (who: [zeroPriceConfirmedBy]). Otherwise it stays only while the line
    // is still the one that was confirmed (the same name, quantity and price, the server's rule on a save).
    zeroPriceConfirmed: zeroPriceConfirmed ?? (this.zeroPriceConfirmed && _stillSame(name, quantity, rate)),
    zeroPriceConfirmedBy: zeroPriceConfirmed != null
        ? (zeroPriceConfirmed ? zeroPriceConfirmedBy : null)
        : (_stillSame(name, quantity, rate) ? this.zeroPriceConfirmedBy : null),
    zeroPriceConfirmedAt: zeroPriceConfirmed == null && _stillSame(name, quantity, rate) ? zeroPriceConfirmedAt : null,
  );

  /// Whether a [copyWith] of these leaves the line's name, quantity and price as they are.
  bool _stillSame(String? name, double? quantity, Object? rate) =>
      (name == null || name.trim() == this.name.trim()) &&
      (quantity == null || _milli(quantity) == _milli(this.quantity)) &&
      (identical(rate, _keep) || _cents((rate as num?)?.toDouble()) == _cents(this.rate));

  static double? _d(dynamic v) => v == null || v.toString().trim().isEmpty ? null : double.tryParse(v.toString());

  static String? _text(dynamic v) => v == null || v.toString().trim().isEmpty ? null : v.toString().trim();

  /// A $0 line the server has a confirmation for: it recorded who or when (an older server sends neither).
  static bool _confirmedIn(Map<String, dynamic> j) =>
      _text(j['zeroPriceConfirmedBy']) != null || _text(j['zeroPriceConfirmedAt']) != null || j['zeroPriceConfirmed'] == true;

  factory LineDraft.fromJson(Map<String, dynamic> j) => LineDraft(
    id: j['id']?.toString(),
    kind: j['kind'] == 'discount' ? LineKind.discount : LineKind.item,
    name: (j['name'] ?? '').toString(),
    description: (j['description'] ?? '').toString(),
    sku: (j['sku'] ?? '').toString(),
    unit: (j['unit'] ?? '').toString(),
    quantity: _d(j['quantity']) ?? 1,
    rate: _d(j['rate']),
    cost: _d(j['cost']),
    taxable: j['taxable'] == true,
    inventoryItemId: j['inventoryItemId'] is int ? j['inventoryItemId'] as int : int.tryParse('${j['inventoryItemId'] ?? ''}'),
    catalogKey: j['catalogKey']?.toString(),
    catalogRate: _d(j['catalogRate']),
    catalogCost: _d(j['catalogCost']),
    source: (j['source'] ?? 'manual').toString(),
    customerVisible: j['customerVisible'] != false,
    taxName: (j['taxName'] as String?)?.trim().isEmpty ?? true ? null : (j['taxName'] as String).trim(),
    zeroPriceConfirmed: _confirmedIn(j),
    zeroPriceConfirmedBy: _confirmedIn(j) ? _text(j['zeroPriceConfirmedBy']) : null,
    zeroPriceConfirmedAt: _confirmedIn(j) ? DateTime.tryParse(j['zeroPriceConfirmedAt']?.toString() ?? '') : null,
  );

  /// What the server's PUT .../items takes (only admins save line items, and they see costs). A saved line carries its
  /// id, so the server can keep a $0 line's original confirmation while the line is unchanged.
  Map<String, dynamic> toJson() => {
    'id': ?id,
    'kind': isDiscount ? 'discount' : 'item',
    'name': name.trim(),
    'description': description.trim(),
    'sku': sku.trim(),
    'unit': unit.trim(),
    'quantity': isDiscount ? 1 : quantity,
    'rate': rate,
    'cost': isDiscount ? null : cost,
    'taxable': taxable,
    'inventoryItemId': inventoryItemId,
    'catalogKey': catalogKey,
    'catalogRate': catalogRate,
    'catalogCost': catalogCost,
    'source': source,
    'zeroPriceConfirmed': isZeroPrice && zeroPriceConfirmed,
  };

  /// Same content (ignores the id), for "is there anything unsaved".
  bool sameAs(LineDraft o) =>
      kind == o.kind &&
      name.trim() == o.name.trim() &&
      description.trim() == o.description.trim() &&
      sku.trim() == o.sku.trim() &&
      unit.trim() == o.unit.trim() &&
      _milli(quantity) == _milli(o.quantity) &&
      _cents(rate) == _cents(o.rate) &&
      _cents(cost) == _cents(o.cost) &&
      taxable == o.taxable &&
      customerVisible == o.customerVisible &&
      (taxName ?? '') == (o.taxName ?? '') &&
      inventoryItemId == o.inventoryItemId &&
      zeroPriceConfirmed == o.zeroPriceConfirmed;
}

int? _cents(double? v) => v == null ? null : (v * 100).round();
int _milli(double v) => (v * 1000).round();

/// [a] / [b] rounded half away from zero, for integers (b > 0). Same as divRound in lineItemMath.js.
int divRound(int a, int b) {
  final sign = a < 0 ? -1 : 1;
  return sign * ((a.abs() * 2 + b) ~/ (2 * b));
}

/// [a] x [b] / [d] rounded half away from zero, exactly, for integers (d > 0). Same as mulDivRound in lineItemMath.js.
/// Worked in BigInt: on the web an int is a double, so `a * b` past 2^53 would already have lost its last digits
/// (522,990.543 x $989,955.00 came out a cent short).
int mulDivRound(int a, int b, int d) {
  final p = BigInt.from(a) * BigInt.from(b);
  final dd = BigInt.from(d);
  final r = (p.abs() * BigInt.two + dd) ~/ (dd * BigInt.two);
  return (p.isNegative ? -r : r).toInt();
}

/// One line's figures, in cents.
class LineFigures {
  final int amountCents;
  final int? extCostCents;
  const LineFigures(this.amountCents, this.extCostCents);
}

/// A set's totals, in cents. [profitCents] and [marginPct] are null while a line's cost is unknown
/// ([missingCostLines] > 0; [costCents] is then the costs that are known); [marginPct] is one decimal, and also null when
/// there is nothing to divide by.
class LineTotals {
  final int itemsCents;
  final int discountCents;
  final int taxableCents;
  final int taxCents;
  final int totalCents;
  final int netCents;
  final int costCents;
  final int? profitCents;
  final double? marginPct;
  final int unpricedLines;
  final int missingCostLines;

  /// $0 lines nobody has confirmed as no charge ([LineDraft.zeroUnconfirmed]).
  final int zeroUnconfirmedLines;
  final List<LineFigures> lines;

  const LineTotals({
    required this.itemsCents,
    required this.discountCents,
    required this.taxableCents,
    required this.taxCents,
    required this.totalCents,
    required this.netCents,
    required this.costCents,
    required this.profitCents,
    required this.marginPct,
    required this.unpricedLines,
    required this.missingCostLines,
    this.zeroUnconfirmedLines = 0,
    required this.lines,
  });

  double get total => totalCents / 100;
}

/// The totals of [lines] with [taxRate] percent (null = no tax). See the formula at the top of this file.
///
/// [taxRates] (a sales tax's name to its percent): a taxable line whose [LineDraft.taxName] is in it is taxed at that
/// rate instead, each tax worked out on its own lines. Without it (or with no named lines) the result is exactly the
/// one-rate formula the backend shares.
LineTotals computeLineTotals(List<LineDraft> lines, double? taxRate, {Map<String, double>? taxRates}) {
  var items = 0, discounts = 0, taxable = 0, cost = 0, unpriced = 0, missingCost = 0, zeroUnconfirmed = 0;
  final named = <String, int>{}; // tax name -> taxable cents taxed at that tax's rate
  final figures = <LineFigures>[];
  for (final l in lines) {
    if (l.isDiscount) {
      final amount = l.rate == null ? 0 : (l.rate! * 100).round().abs();
      discounts += amount;
      if (l.taxable) taxable -= amount;
      figures.add(LineFigures(-amount, null));
      continue;
    }
    final q = _milli(l.quantity);
    final amount = l.rate == null ? 0 : mulDivRound(q, (l.rate! * 100).round(), 1000);
    if (l.rate == null) {
      unpriced++;
    } else if ((l.rate! * 100).round() == 0 && q != 0 && !l.zeroPriceConfirmed) {
      zeroUnconfirmed++;
    }
    items += amount;
    final tn = l.taxName;
    if (l.taxable && tn != null && taxRates != null && taxRates.containsKey(tn)) {
      named[tn] = (named[tn] ?? 0) + amount;
    } else if (l.taxable) {
      taxable += amount;
    }
    int? ext;
    if (l.cost != null) {
      ext = mulDivRound(q, (l.cost! * 100).round(), 1000);
      cost += ext;
    } else if (q != 0) {
      missingCost++;
    }
    figures.add(LineFigures(amount, ext));
  }
  final base = taxable < 0 ? 0 : taxable;
  int taxOn(int cents, double? rate) {
    final rateU = rate == null ? 0 : (rate * 10000).round(); // ten-thousandths of a percent
    return rateU > 0 && cents > 0 ? mulDivRound(cents, rateU, 1000000) : 0;
  }

  var tax = taxOn(base, taxRate);
  var namedBase = 0;
  for (final e in named.entries) {
    tax += taxOn(e.value, taxRates![e.key]);
    namedBase += e.value;
  }
  final net = items - discounts;
  // Unknown while a line's cost is missing (costCents is then only the costs that are known).
  final profit = missingCost > 0 ? null : net - cost;
  return LineTotals(
    itemsCents: items,
    discountCents: discounts,
    taxableCents: base + namedBase,
    taxCents: tax,
    totalCents: net + tax,
    netCents: net,
    costCents: cost,
    profitCents: profit,
    // round() in Dart goes half away from zero; the backend does the same on purpose.
    marginPct: profit != null && net > 0 ? (profit / net * 1000).round() / 10 : null,
    unpricedLines: unpriced,
    missingCostLines: missingCost,
    zeroUnconfirmedLines: zeroUnconfirmed,
    lines: figures,
  );
}

/// "$1,234.50", "-$30.00".
String centsMoney(int cents) {
  final neg = cents < 0;
  final abs = cents.abs();
  final whole = (abs ~/ 100).toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
  final part = (abs % 100).toString().padLeft(2, '0');
  return '${neg ? '-' : ''}\$$whole.$part';
}

/// A quantity as it is shown everywhere (user rule 2026-11-13): always two decimals, grouped like money: "1.00",
/// "1.50", "0.25", "2,400.00".
///
/// Only the display is rounded, never the value. It is worked from the value's whole thousandths (the precision the
/// server stores and the totals use, see [computeLineTotals]), so a binary slip such as 0.1 + 0.2 still reads "0.30".
/// A quantity that really has a third decimal (the server allows one; none on prod have it) keeps it ("2.125"):
/// rounding it to "2.13" would show a figure that doesn't give the line's amount.
String qtyText(double q) {
  final milli = _milli(q);
  final neg = milli < 0;
  final abs = milli.abs();
  final whole = (abs ~/ 1000).toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
  final frac = abs % 1000;
  final part = frac % 10 == 0 ? (frac ~/ 10).toString().padLeft(2, '0') : frac.toString().padLeft(3, '0');
  return '${neg ? '-' : ''}$whole.$part';
}

/// Parses money typed into a field ("1,250", "$89.5", "-10") to dollars, or null when it isn't a number.
double? parseMoney(String text) {
  final t = text.replaceAll(RegExp(r'[\s,$]'), '');
  if (t.isEmpty) return null;
  final v = double.tryParse(t);
  if (v == null || !v.isFinite) return null;
  return (v * 100).round() / 100;
}

/// Parses a quantity (up to three decimals), or null.
double? parseQty(String text) {
  final t = text.replaceAll(RegExp(r'[\s,]'), '');
  if (t.isEmpty) return null;
  final v = double.tryParse(t);
  if (v == null || !v.isFinite) return null;
  return (v * 1000).round() / 1000;
}


/// A sales tax a line can carry, as Service Fusion names it, with its rate. [onRecord]: one the record itself charges.
class SalesTax {
  final String name;
  final double rate;
  final bool onRecord;
  const SalesTax(this.name, this.rate, {this.onRecord = false});

  factory SalesTax.fromJson(Map<String, dynamic> j) => SalesTax((j['name'] ?? '').toString().trim(), (j['rate'] as num?)?.toDouble() ?? 0);

  /// "Bentonville" from "Sales Tax (State, County, & Local Use Tax, Bentonville)", "Benton County" from
  /// "Sales Tax (State & County, Benton)", "Out of state", "No sales tax"; anything else as it is.
  static String shortName(String name) {
    final n = name.trim();
    final local = RegExp(r'^Sales Tax \(State, County,? &? ?Local Use Tax, (.+)\)$').firstMatch(n);
    if (local != null) return local.group(1)!;
    final county = RegExp(r'^Sales Tax \(State & County, (.+)\)$').firstMatch(n);
    if (county != null) return '${county.group(1)} County';
    if (n.toLowerCase().contains('out of state')) return 'Out of state';
    if (n.toLowerCase() == 'no sales tax applied') return 'No sales tax';
    return n.replaceFirst(RegExp(r'^[-\s]+'), '');
  }

  String get short => shortName(name);

  /// "Bentonville 9.5%".
  String get label => '$short ${rateText(rate)}%';

  /// The tax a taxable line named [name] is charged at, of [options] (the record's own tax lines): the one with that
  /// name, else the record's only tax when it has exactly one (Service Fusion's lines often say just "Sales Tax", or
  /// nothing, while the record's charge names the place). Null when it can't be told. The line's label, its Tax menu
  /// and the totals all use this, so what a line says it is taxed at is what it is taxed at.
  static SalesTax? resolve(String? name, List<SalesTax> options) {
    if (options.isEmpty) return null;
    final n = name?.trim();
    final exact = n == null || n.isEmpty ? null : options.where((t) => t.name == n).firstOrNull;
    return exact ?? (options.length == 1 ? options.single : null);
  }

  static String rateText(double r) => r.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');
}
