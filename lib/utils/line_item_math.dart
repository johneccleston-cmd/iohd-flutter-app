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
//   tax            = tax rate x taxable items, never below 0. A discount never lowers it (USER RULE 2026-11-20: tax is
//                    worked out line by line, a discount comes off the total), even one marked taxable.
//   total          = items - discounts + tax
//   gross profit   = (items - discounts) - cost. Sales tax goes to the state, so it is never profit.
// Profit and margin are only worked out when every line's cost is known (Services Catalog Phase 2, 2026-11-18): a line
// with a quantity and no cost makes both null, and missingCostLines says how many lines lack one (an unknown cost read
// as $0 showed a 100% margin on lines nobody had costed). A line at $0.00 with a quantity is a no-charge line:
// zeroUnconfirmedLines counts the ones nobody has confirmed ([LineDraft.zeroPriceConfirmed]), so a silent $0 can't slip
// through. An unpriced line (rate null) is not a $0 line.

/// What a line is: something sold, a discount taken off (entered as a positive amount), or a fee added on (a card fee).
/// A discount or a fee is a dollar amount ([LineDraft.rate]) or a percentage ([LineDraft.percent]).
enum LineKind { item, discount, fee }

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

  /// The service package this line came in with (USER RULE 2026-11-20): a package's rates go on a job or estimate as
  /// separate lines under the package's name. [packageId] is one per time the package was added (the same package added
  /// twice is two groups); [packageName] is the heading over them. Null for any other line. Not saved by the server yet.
  final String? packageId;
  final String? packageName;

  /// What the line is (USER RULE 2026-11-20: every line is marked "S", a service line, or "I", an inventory item):
  /// true a service, false a product, null not known (a saved line; the table then works it out, see
  /// [isServiceLine] in line_items_editor.dart). Not saved by the server yet.
  final bool? service;

  /// A discount or fee worked out as a percentage (20 = 20%), or null for a dollar amount ([rate]). A percentage
  /// discount is taken off the items; a percentage fee is added on the items less discounts, before tax (see
  /// [computeLineTotals]). Not saved by the server yet.
  final double? percent;

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
    this.packageId,
    this.packageName,
    this.service,
    this.percent,
  });

  /// One of a service package's lines.
  bool get inPackage => packageId != null;

  bool get isDiscount => kind == LineKind.discount;
  bool get isFee => kind == LineKind.fee;

  /// A discount or a fee: a charge on the whole set rather than something sold. Never taxed itself (USER RULE
  /// 2026-11-20), no quantity, no cost.
  bool get isCharge => isDiscount || isFee;

  /// A $0 line (the server's rule, src/lineItemMath.js): an item priced at a rate that rounds to $0.00, with a
  /// quantity. It needs someone to confirm it is no charge. A line at quantity 0, or not priced yet, isn't one.
  bool get isZeroPrice => kind == LineKind.item && rate != null && (rate! * 100).round() == 0 && _milli(quantity) != 0;

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
    Object? percent = _keep,
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
    packageId: packageId,
    packageName: packageName,
    service: service,
    percent: identical(percent, _keep) ? this.percent : (percent as num?)?.toDouble(),
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
    kind: switch (j['kind']) {
      'discount' => LineKind.discount,
      'fee' => LineKind.fee,
      _ => LineKind.item,
    },
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
    percent: _d(j['percent']),
  );

  /// What the server's PUT .../items takes (only admins save line items, and they see costs). A saved line carries its
  /// id, so the server can keep a $0 line's original confirmation while the line is unchanged. A fee and a percentage
  /// ('kind': 'fee', 'percent') are not taken by the server yet: line items are a preview (user rule 2026-11-12).
  Map<String, dynamic> toJson() => {
    'id': ?id,
    'kind': kind.name,
    'name': name.trim(),
    'description': description.trim(),
    'sku': sku.trim(),
    'unit': unit.trim(),
    'quantity': isCharge ? 1 : quantity,
    'rate': rate,
    'percent': ?percent,
    'cost': isCharge ? null : cost,
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
      zeroPriceConfirmed == o.zeroPriceConfirmed &&
      _pctU(percent) == _pctU(o.percent);
}

/// A percentage in ten-thousandths of a percent (20% = 200000), the way tax rates are worked.
int? _pctU(double? p) => p == null ? null : (p * 10000).round();

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

  /// The fees added on ([LineKind.fee]): part of [netCents], never taxed.
  final int feeCents;

  /// Each sales tax on its own: what it is charged on and what it comes to, in the order the lines name them (the
  /// set's own rate, [TaxFigure.name] null, first). [taxCents] is their sum.
  final List<TaxFigure> taxes;

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
    this.feeCents = 0,
    this.taxes = const [],
  });

  double get total => totalCents / 100;
}

/// One sales tax in a set's totals: [name] (null: the set's own rate), its [rate] percent, the money of the lines set
/// to it ([baseCents]) and the tax, rounded once to the cent.
class TaxFigure {
  final String? name;
  final double rate;
  final int baseCents;
  final int taxCents;
  const TaxFigure(this.name, this.rate, this.baseCents, this.taxCents);
}

/// [cents] x [percent] / 100, rounded half away from zero (never below 0: a percentage of nothing is nothing).
int percentOf(int cents, double percent) {
  final u = (percent * 10000).round();
  return cents > 0 && u > 0 ? mulDivRound(cents, u, 1000000) : 0;
}

/// The totals of [lines] with [taxRate] percent (null = no tax). See the formula at the top of this file.
///
/// [taxRates] (a sales tax's name to its percent): a taxable line whose [LineDraft.taxName] is in it is taxed at that
/// rate instead, each tax worked out on its own lines and rounded once. Without it (or with no named lines), and with
/// no fees or percentages, the result is exactly the one-rate formula the backend shares.
///
/// Discounts and fees (Tax, discounts & fees redesign, 2026-11-20):
///   a percentage discount  = its percent of the items, before any discount
///   a percentage fee       = its percent of the items less discounts, before tax (the money the work comes to)
///   fees are never taxed (USER RULE 2026-11-20), have no cost and never count as a line with no cost
///   a discount never lowers any tax (USER RULE 2026-11-20): [LineDraft.taxable] on a discount is ignored.
LineTotals computeLineTotals(List<LineDraft> lines, double? taxRate, {Map<String, double>? taxRates}) {
  var items = 0, cost = 0, unpriced = 0, missingCost = 0, zeroUnconfirmed = 0;
  // Taxable cents by tax: '' the set's own rate, then every named tax in [taxRates]'s order (the record's tax lines, so
  // a tax no line is set to yet still shows, at $0.00: adding a tax taxes nothing, USER RULE 2026-11-20).
  final pools = <String, int>{'': 0, for (final k in taxRates?.keys ?? const <String>[]) k: 0};
  final amounts = List<int>.filled(lines.length, 0);
  final exts = List<int?>.filled(lines.length, null);
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    if (l.isCharge) continue;
    final q = _milli(l.quantity);
    final amount = l.rate == null ? 0 : mulDivRound(q, (l.rate! * 100).round(), 1000);
    if (l.rate == null) {
      unpriced++;
    } else if ((l.rate! * 100).round() == 0 && q != 0 && !l.zeroPriceConfirmed) {
      zeroUnconfirmed++;
    }
    items += amount;
    amounts[i] = amount;
    if (l.taxable) {
      final tn = l.taxName;
      final key = tn != null && taxRates != null && taxRates.containsKey(tn) ? tn : '';
      pools[key] = (pools[key] ?? 0) + amount;
    }
    if (l.cost != null) {
      exts[i] = mulDivRound(q, (l.cost! * 100).round(), 1000);
      cost += exts[i]!;
    } else if (q != 0) {
      missingCost++;
    }
  }
  // Discounts: a dollar amount, or a percentage of the items. Off the total, never off the taxed amount.
  var discounts = 0;
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    if (!l.isDiscount) continue;
    final amount = l.percent != null ? percentOf(items, l.percent!.abs()) : (l.rate == null ? 0 : (l.rate! * 100).round().abs());
    discounts += amount;
    amounts[i] = -amount;
  }
  // Fees: a dollar amount, or a percentage of the items less discounts.
  var fees = 0;
  final feeBase = items - discounts;
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    if (!l.isFee) continue;
    final amount = l.percent != null ? percentOf(feeBase, l.percent!.abs()) : (l.rate == null ? 0 : (l.rate! * 100).round().abs());
    fees += amount;
    amounts[i] = amount;
  }

  int taxOn(int cents, double? rate) {
    final rateU = rate == null ? 0 : (rate * 10000).round(); // ten-thousandths of a percent
    return rateU > 0 && cents > 0 ? mulDivRound(cents, rateU, 1000000) : 0;
  }

  var tax = 0, taxable = 0;
  final taxes = <TaxFigure>[];
  for (final e in pools.entries) {
    final base = e.value < 0 ? 0 : e.value;
    final rate = e.key.isEmpty ? taxRate : taxRates![e.key];
    final t = taxOn(base, rate);
    tax += t;
    taxable += base;
    if (rate != null && (e.key.isNotEmpty || base > 0 || t > 0)) taxes.add(TaxFigure(e.key.isEmpty ? null : e.key, rate, base, t));
  }
  final net = items - discounts + fees;
  // Unknown while a line's cost is missing (costCents is then only the costs that are known).
  final profit = missingCost > 0 ? null : net - cost;
  return LineTotals(
    itemsCents: items,
    discountCents: discounts,
    taxableCents: taxable,
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
    lines: [for (var i = 0; i < lines.length; i++) LineFigures(amounts[i], exts[i])],
    feeCents: fees,
    taxes: taxes,
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

/// Whether a Service Fusion line's tax code ([raw_items].tax) is a real sales tax. Service Fusion names the exempt code
/// too ("No Sales Tax Applied", 213 lines on 24 records since 2025-06), so "has a tax code" read exempt lines as taxed,
/// and the record's own tax was then put on them. The backend has the same rule (src/sfTax.js, sfTaxClass).
bool sfTaxed(Object? code) {
  final s = (code ?? '').toString().trim();
  return s.isNotEmpty && !RegExp(r'^no sales tax', caseSensitive: false).hasMatch(s);
}

/// Parses money typed into a field ("1,250", "$89.5", "-10") to dollars, or null when it isn't a number.
double? parseMoney(String text) {
  final t = text.replaceAll(RegExp(r'[\s,$]'), '');
  if (t.isEmpty) return null;
  final v = double.tryParse(t);
  if (v == null || !v.isFinite) return null;
  return (v * 100).round() / 100;
}

/// Parses a percentage typed into a field ("20", "2.5 %", "9.375%") to a percent (up to three decimals, as Arkansas
/// rates have), or null when it isn't a number.
double? parsePercent(String text) {
  final t = text.replaceAll(RegExp(r'[\s,%]'), '');
  if (t.isEmpty) return null;
  final v = double.tryParse(t);
  if (v == null || !v.isFinite) return null;
  return (v * 1000).round() / 1000;
}

/// Parses a quantity (up to three decimals), or null.
double? parseQty(String text) {
  final t = text.replaceAll(RegExp(r'[\s,]'), '');
  if (t.isEmpty) return null;
  final v = double.tryParse(t);
  if (v == null || !v.isFinite) return null;
  return (v * 1000).round() / 1000;
}


/// Where a tax line came from: the record's own (Service Fusion's tax charge), the Arkansas catalog, or a rate typed in
/// for a sale out of state.
enum SalesTaxKind { record, arkansas, outOfState }

/// One part of an Arkansas sales tax (the state's, a county's, a city's) at its rate on the day the tax was built. [id]
/// is the catalog's ("AR-04-02"), [level] "state", "county" or "city", [from] the day that rate took effect, [next] a
/// change DFA has announced after it (rate in thousandths of a percent, and its day).
class SalesTaxPart {
  final String id;
  final String name;
  final String level;
  final int milli;
  final String from;
  final (int, String)? next;
  const SalesTaxPart({required this.id, required this.name, required this.level, required this.milli, required this.from, this.next});

  double get rate => milli / 1000;
}

/// A sales tax a line can carry, as Service Fusion names it, with its rate. [onRecord]: one the record itself charges.
///
/// A tax built from the Arkansas catalog keeps its [parts] and the day its rates were looked up ([asOf]): what was
/// charged stays what it was when rates change later. An out-of-state tax has the rate someone typed and the [display]
/// name they gave it.
class SalesTax {
  final String name;
  final double rate;
  final bool onRecord;
  final SalesTaxKind kind;
  final List<SalesTaxPart> parts;
  final String? asOf;
  final String? display;
  const SalesTax(this.name, this.rate, {this.onRecord = false, this.kind = SalesTaxKind.record, this.parts = const [], this.asOf, this.display});

  factory SalesTax.fromJson(Map<String, dynamic> j) => SalesTax((j['name'] ?? '').toString().trim(), (j['rate'] as num?)?.toDouble() ?? 0);

  SalesTax withRate(double rate, {String? display}) =>
      SalesTax(name, rate, onRecord: onRecord, kind: kind, parts: parts, asOf: asOf, display: display ?? this.display);

  /// The same tax line: same name, same rate to the ten-thousandth of a percent.
  bool sameAs(SalesTax o) => name == o.name && (rate * 10000).round() == (o.rate * 10000).round() && (display ?? '') == (o.display ?? '');

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

  String get short => display ?? shortName(name);

  /// "Bentonville 9.5%".
  String get label => '$short ${rateText(rate)}%';

  /// The tax a taxable line named [name] is charged at, of [options] (the record's own tax lines): the one with that
  /// name, else the record's only tax when it has exactly one (Service Fusion's lines often say just "Sales Tax", or
  /// nothing, while the record's charge names the place). Null when it can't be told. The line's label, its Tax menu
  /// and the totals all use this, so what a line says it is taxed at is what it is taxed at.
  ///
  /// With taxes added beside the record's own (Tax, discounts & fees), a line that names none of them exactly still
  /// goes to the record's own tax when it has exactly one ([onRecord]): adding Rogers to a Bentonville record never
  /// takes the Bentonville tax off its "Sales Tax" lines. A tax that was only ADDED is never a line's by default: adding
  /// a tax taxes nothing until a line picks it (USER RULE 2026-11-20). It used to be, when the record had no tax of its
  /// own and that was the only one: adding Rogers then taxed every taxable line (audit round 2, 2026-11-20).
  static SalesTax? resolve(String? name, List<SalesTax> options) {
    if (options.isEmpty) return null;
    final n = name?.trim();
    final exact = n == null || n.isEmpty ? null : options.where((t) => t.name == n).firstOrNull;
    if (exact != null) return exact;
    final own = options.where((t) => t.onRecord).toList();
    return own.length == 1 ? own.single : null;
  }

  static String rateText(double r) => r.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');
}
