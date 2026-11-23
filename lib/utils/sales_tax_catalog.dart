// The Arkansas sales tax catalog: the state, every county and every city with a local sales and use tax, each with its
// rates and the dates they hold, as the Arkansas DFA publishes them (arkansas_sales_tax_data.dart, generated from DFA's
// quarterly tables by tool/tax/ar_tax_import.dart; see docs/arkansas-sales-tax-catalog.md).
//
// A sale in Arkansas pays the state's tax, its county's (when the county levies one) and its city's (when it is in a
// city that levies one). [TaxComposition] puts those together for a place on a day: one county at most, one city at
// most, the state always, so no tax can be counted twice. It is named the way Service Fusion names its tax lines
// ("Sales Tax (State, County, & Local Use Tax, Rogers)"), so a tax picked here is the same tax as Service Fusion's own
// for that place, and a record that already has it isn't given it again.
//
// Rates are kept in thousandths of a percent (1.375% = 1375), so a combined rate adds up exactly.

import 'charge_presets.dart';
import 'line_item_math.dart';

part 'arkansas_sales_tax_data.dart';

enum TaxLevel { state, county, city }

/// A rate and the days it holds. [from] and [to] are ISO days ("2026-10-01"); [to] is the last day, null while the rate
/// is still in force. [announced]: a change DFA has announced but not yet put in a quarterly table.
class TaxPeriod {
  final int milli;
  final String from;
  final String? to;
  final bool announced;
  const TaxPeriod(this.milli, this.from, {this.to, this.announced = false});

  bool covers(String day) => from.compareTo(day) <= 0 && (to == null || day.compareTo(to!) <= 0);
  double get percent => milli / 1000;
}

/// The state, a county or a city, with its DFA code ("04-02" Rogers, "04-00" Benton County) and its rates.
class TaxJurisdiction {
  final String id;
  final TaxLevel level;
  final String name;
  final String code;

  /// A city's counties, by DFA county number ("72", "04" for Springdale), the one its code belongs to first.
  final List<String> counties;
  final List<TaxPeriod> periods;
  const TaxJurisdiction(this.id, this.level, this.name, this.code, this.counties, this.periods);

  TaxPeriod? periodOn(String day) {
    for (final p in periods.reversed) {
      if (p.covers(day)) return p;
    }
    return null;
  }

  /// The next rate in the catalog after [day] (an announced change), if there is one. [ArkansasTax.nextAfter] also
  /// counts the changes typed in on the settings screen.
  TaxPeriod? nextAfter(String day) {
    for (final p in periods) {
      if (p.from.compareTo(day) > 0) return p;
    }
    return null;
  }

  bool get multiCounty => counties.length > 1;
}

/// Where the catalog comes from and when it was last checked against DFA.
class TaxCatalogSource {
  final String publisher, table, firstQuarter, lastQuarter, coversTo, verified, url, changesUrl;
  const TaxCatalogSource({
    required this.publisher,
    required this.table,
    required this.firstQuarter,
    required this.lastQuarter,
    required this.coversTo,
    required this.verified,
    required this.url,
    required this.changesUrl,
  });
}

/// An ISO day ("2026-11-20") for [d], in its own time zone.
String isoDay(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// "Nov 20, 2026" for an ISO day.
String dayText(String iso) {
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final d = DateTime.tryParse(iso);
  return d == null ? iso : '${m[d.month - 1]} ${d.day}, ${d.year}';
}

/// "1.375%", "2%", from thousandths of a percent.
String milliText(int milli) => '${SalesTax.rateText(milli / 1000)}%';

abstract final class ArkansasTax {
  static const source = kArkansasTaxSource;
  static const all = kArkansasJurisdictions;
  static final TaxJurisdiction state = all.first;
  static final Map<String, TaxJurisdiction> _byId = {for (final j in all) j.id: j};
  static final Map<String, TaxJurisdiction> _countyByNumber = {
    for (final j in all)
      if (j.level == TaxLevel.county) j.code.substring(0, 2): j,
  };

  static TaxJurisdiction? byId(String id) => _byId[id];

  /// Rate changes typed in on the Tax, Discounts & Fees screen (ones DFA announced that the catalog doesn't have yet).
  /// Set when the settings load; each holds from its day on, over the catalog's rate from before that day.
  static List<TaxRateChange> changes = const [];

  /// [j]'s rate on [day] and the day it took effect, from the catalog or a typed-in change ([typed]), whichever began
  /// later; null when the place has no rate that day.
  static ({int milli, String from, bool typed})? rateOn(TaxJurisdiction j, String day) {
    final p = j.periodOn(day);
    TaxRateChange? best;
    for (final c in changes) {
      if (c.jurisdictionId == j.id && c.from.compareTo(day) <= 0 && (best == null || c.from.compareTo(best.from) > 0)) best = c;
    }
    if (best != null && (p == null || best.from.compareTo(p.from) >= 0)) return (milli: best.milli, from: best.from, typed: true);
    return p == null ? null : (milli: p.milli, from: p.from, typed: false);
  }

  /// [j]'s rate on [day] in thousandths of a percent, or null when it has none (not yet enacted, rescinded, 0%).
  static int? milliOn(TaxJurisdiction j, String day) {
    final m = rateOn(j, day)?.milli;
    return m == null || m == 0 ? null : m;
  }

  /// The next rate after [day] (an announced change in the catalog, or one typed in), if there is one.
  static (int, String, bool)? nextAfter(TaxJurisdiction j, String day) {
    (int, String, bool)? next;
    final p = j.nextAfter(day);
    if (p != null) next = (p.milli, p.from, false);
    for (final c in changes) {
      if (c.jurisdictionId == j.id && c.from.compareTo(day) > 0 && (next == null || c.from.compareTo(next.$2) < 0)) next = (c.milli, c.from, true);
    }
    return next;
  }

  /// A county by its DFA number ("72").
  static TaxJurisdiction? county(String number) => _countyByNumber[number];

  /// The counties with a tax on [day], by name.
  static List<TaxJurisdiction> counties(String day) =>
      [for (final j in all) if (j.level == TaxLevel.county && milliOn(j, day) != null) j]..sort((a, b) => a.name.compareTo(b.name));

  /// The cities with a tax on [day], by name.
  static List<TaxJurisdiction> cities(String day) =>
      [for (final j in all) if (j.level == TaxLevel.city && milliOn(j, day) != null) j]..sort((a, b) => a.name.compareTo(b.name));

  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'\(city\)'), '').replaceAll(RegExp(r'[^a-z]'), '');

  static TaxJurisdiction? cityNamed(String name) {
    final n = _norm(name);
    for (final j in all) {
      if (j.level == TaxLevel.city && _norm(j.name) == n) return j;
    }
    return null;
  }

  static TaxJurisdiction? countyNamed(String name) {
    final n = _norm(name.replaceFirst(RegExp(r'\s+county$', caseSensitive: false), ''));
    for (final j in all) {
      if (j.level == TaxLevel.county && _norm(j.name.replaceFirst(RegExp(r'\s+County$'), '')) == n) return j;
    }
    return null;
  }

  /// The place a Service Fusion tax name stands for, as a composition on [day]: "Sales Tax (State, County, & Local Use
  /// Tax, Springdale, Washington)" is Springdale in Washington County, "Sales Tax (State & County, Benton)" Benton
  /// County alone. Null for a name that isn't an Arkansas place in the catalog (out of state, exempt, plain "Sales Tax").
  static TaxComposition? fromServiceFusionName(String name, String day) {
    final n = name.trim();
    final local = RegExp(r'^Sales Tax \(State, County,? &? ?Local Use Tax, ([^,]+)(?:, ([^)]+))?\)$').firstMatch(n);
    if (local != null) {
      final city = cityNamed(local.group(1)!);
      if (city == null) return null;
      final countyName = local.group(2);
      TaxJurisdiction? county;
      if (countyName != null) {
        county = countyNamed(countyName);
        if (county == null || !city.counties.contains(county.code.substring(0, 2))) return null;
      } else {
        county = ArkansasTax.county(city.counties.isEmpty ? city.code.substring(0, 2) : city.counties.first);
      }
      return TaxComposition(day: day, county: county, city: city);
    }
    final cty = RegExp(r'^Sales Tax \(State & County, (.+)\)$').firstMatch(n);
    if (cty != null) {
      final county = countyNamed(cty.group(1)!);
      return county == null ? null : TaxComposition(day: day, county: county);
    }
    return null;
  }
}

/// Arkansas's sales tax for one place on one day: the state's, plus a county's and a city's when given (each only while
/// it has a tax that day). A city needs its county: [city] is always in [county].
class TaxComposition {
  final String day;
  final TaxJurisdiction? county;
  final TaxJurisdiction? city;
  TaxComposition({required this.day, this.county, this.city})
    : assert(city == null || county != null, 'a city is always in a county'),
      assert(city == null || city.counties.contains(county!.code.substring(0, 2)), 'the city is in that county');

  /// The parts that tax this place that day, state first, each at its rate then.
  List<SalesTaxPart> get parts => [
    for (final j in [ArkansasTax.state, ?county, ?city])
      if (ArkansasTax.milliOn(j, day) case final milli?)
        SalesTaxPart(
          id: j.id,
          name: j.level == TaxLevel.state ? 'Arkansas state' : j.name,
          level: j.level.name,
          milli: milli,
          from: ArkansasTax.rateOn(j, day)!.from,
          next: switch (ArkansasTax.nextAfter(j, day)) {
            final n? => (n.$1, n.$2),
            null => null,
          },
        ),
  ];

  int get milli => parts.fold(0, (s, p) => s + p.milli);

  /// What Service Fusion calls this tax, so the same place is the same tax: a city in more than one county names its
  /// county ("Springdale, Washington").
  String get serviceFusionName {
    if (city != null) {
      final place = city!.multiCounty ? '${city!.name}, ${county!.name.replaceFirst(RegExp(r'\s+County$'), '')}' : city!.name;
      return 'Sales Tax (State, County, & Local Use Tax, $place)';
    }
    if (county != null) return 'Sales Tax (State & County, ${county!.name.replaceFirst(RegExp(r'\s+County$'), '')})';
    return 'Sales Tax (Arkansas State)';
  }

  /// "Rogers", "Springdale, Washington County", "Benton County", "Arkansas state only".
  String get place {
    if (city != null) return city!.multiCounty ? '${city!.name}, ${county!.name}' : city!.name;
    if (county != null) return county!.name;
    return 'Arkansas state only';
  }

  SalesTax toSalesTax() => SalesTax(serviceFusionName, milli / 1000, parts: parts, asOf: day, kind: SalesTaxKind.arkansas);
}
