// The one formula for a set of line items (an estimate option, or a job's items edited in the app), the same as the
// backend's src/lineItemMath.js: the app recomputes while someone types, the server recomputes what it stores, and
// both are tested against the same cases (test/fixtures/line_item_math_cases.json, scripts/line_item_math_cases.json).
//
// Money is worked in whole cents and quantities in thousandths, so both copies agree to the cent:
//   line amount    = quantity x rate, rounded half away from zero (an unpriced line counts $0 and is flagged)
//   extended cost  = quantity x unit cost, rounded the same way
//   tax            = tax rate x (taxable items - taxable discounts), never below 0
//   total          = items - discounts + tax
//   gross profit   = (items - discounts) - cost. Sales tax goes to the state, so it is never profit.

/// What a line is: something sold, or a discount taken off (entered as a positive amount).
enum LineKind { item, discount }

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
  });

  bool get isDiscount => kind == LineKind.discount;

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
  );

  static double? _d(dynamic v) => v == null || v.toString().trim().isEmpty ? null : double.tryParse(v.toString());

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
  );

  /// What the server's PUT .../items takes (only admins save line items, and they see costs).
  Map<String, dynamic> toJson() => {
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
      inventoryItemId == o.inventoryItemId;
}

int? _cents(double? v) => v == null ? null : (v * 100).round();
int _milli(double v) => (v * 1000).round();

/// [a] / [b] rounded half away from zero, for integers (b > 0). Same as divRound in lineItemMath.js.
int divRound(int a, int b) {
  final sign = a < 0 ? -1 : 1;
  return sign * ((a.abs() * 2 + b) ~/ (2 * b));
}

/// One line's figures, in cents.
class LineFigures {
  final int amountCents;
  final int? extCostCents;
  const LineFigures(this.amountCents, this.extCostCents);
}

/// A set's totals, in cents. [marginPct] is one decimal, or null when there is nothing to divide by.
class LineTotals {
  final int itemsCents;
  final int discountCents;
  final int taxableCents;
  final int taxCents;
  final int totalCents;
  final int netCents;
  final int costCents;
  final int profitCents;
  final double? marginPct;
  final int unpricedLines;
  final int missingCostLines;
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
    required this.lines,
  });

  double get total => totalCents / 100;
}

/// The totals of [lines] with [taxRate] percent (null = no tax). See the formula at the top of this file.
LineTotals computeLineTotals(List<LineDraft> lines, double? taxRate) {
  var items = 0, discounts = 0, taxable = 0, cost = 0, unpriced = 0, missingCost = 0;
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
    final amount = l.rate == null ? 0 : divRound(q * (l.rate! * 100).round(), 1000);
    if (l.rate == null) unpriced++;
    items += amount;
    if (l.taxable) taxable += amount;
    int? ext;
    if (l.cost != null) {
      ext = divRound(q * (l.cost! * 100).round(), 1000);
      cost += ext;
    } else if (q != 0) {
      missingCost++;
    }
    figures.add(LineFigures(amount, ext));
  }
  final base = taxable < 0 ? 0 : taxable;
  final rateU = taxRate == null ? 0 : (taxRate * 10000).round(); // ten-thousandths of a percent
  final tax = rateU > 0 ? divRound(base * rateU, 1000000) : 0;
  final net = items - discounts;
  final profit = net - cost;
  return LineTotals(
    itemsCents: items,
    discountCents: discounts,
    taxableCents: base,
    taxCents: tax,
    totalCents: net + tax,
    netCents: net,
    costCents: cost,
    profitCents: profit,
    // round() in Dart goes half away from zero; the backend does the same on purpose.
    marginPct: net > 0 ? (profit / net * 1000).round() / 10 : null,
    unpricedLines: unpriced,
    missingCostLines: missingCost,
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

/// A quantity the way people write it: "2", "1.5", "2.125".
String qtyText(double q) {
  final s = q.toStringAsFixed(3);
  return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
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
