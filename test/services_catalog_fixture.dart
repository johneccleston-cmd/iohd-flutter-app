// A Services Catalog as it looks in production on 2026-11-19 (read-only probe of the live list): 117 services, every one
// still in Service Fusion's single "Service" group, long "A | B | C" names (median 46 characters), 13 used once, 47 not
// used for 6 months, 10 switched off by the office. The names and prices below follow that shape; the figures are made up.
//
// Used by test/services_catalog_shots_test.dart (before/after pictures) and test/services_catalog_test.dart.

import 'package:iohd_desktop/services/line_items_api.dart';

typedef CatalogResult = ({List<CatalogEntry> entries, bool canSeeCost, int historyDays});

CatalogEntry _svc(
  String name, {
  double? rate,
  double? cost,
  int uses = 10,
  String last = '2026-11-12',
  double? min,
  double? max,
  String group = 'Service',
  bool active = true,
  String description = '',
  List<String> edited = const [],
  List<ServiceRate> rates = const [],
  List<ServiceProduct> products = const [],
  ServiceCommission? commission,
}) {
  final key = 'sf:${name.toLowerCase().replaceAll(RegExp(r'\s+'), ' ')}';
  return CatalogEntry(
    key: key,
    name: name,
    kind: 'service',
    category: group,
    group: group,
    rate: rate,
    cost: cost,
    uses: uses,
    rateUses: uses,
    lastUsed: last,
    rateMin: min ?? rate,
    rateMax: max ?? rate,
    active: active,
    description: description,
    editedFields: edited,
    editedBy: edited.isEmpty ? null : 'Test Admin',
    editedAt: edited.isEmpty ? null : '2026-11-19T18:55:00Z',
    computed: edited.isEmpty
        ? null
        : {'name': name, 'category': 'Service', 'description': description, 'rate': rate, 'cost': cost, 'taxable': false, 'active': true},
    rates: rates,
    products: products,
    commission: commission,
  );
}

final List<CatalogEntry> kProdLikeServices = [
  _svc('Residential Installation | Complete Overhead Door', rate: 59, cost: 18, uses: 1075, last: '2026-11-18', description: 'Remove and haul away the old door, install the new door, track and springs, balance and test.'),
  _svc('Commercial Service', rate: 99, cost: 24, uses: 1002, last: '2026-11-17', description: 'Diagnose and repair commercial doors and operators.'),
  _svc('Operator Installation | LiftMaster | 8\' 6690L', rate: 395, cost: 140, uses: 82, last: '2026-11-17', group: 'Operator Installations', edited: const ['category']),
  _svc('LENNAR Installation | 16x7 Standard Color*', rate: 300, cost: 95, uses: 68, last: '2026-07-24', group: 'High Volume Builders', edited: const ['category']),
  _svc('LENNAR Installation | 8x7 Standard Color*', rate: 300, cost: 95, uses: 51, last: '2026-02-11', group: 'High Volume Builders', edited: const ['category']),
  _svc('Operator Installation | LiftMaster | 7\' 6690L', rate: 365, cost: 130, uses: 49, last: '2026-11-18', group: 'Operator Installations', edited: const ['category']),
  _svc('2-10 Warranty Company Service', rate: 100, cost: 20, uses: 49, last: '2026-11-18', description: 'Repair or replacement of any mechanical or electrical component for a 3rd party warranty company.'),
  _svc('Residential Service Package | Residential Diagnostic Visit', rate: 49, cost: 12, uses: 43, last: '2026-10-07'),
  _svc('SMH Installation | Garage Door (Black)', rate: 300, uses: 39, last: '2026-07-27'),
  _svc('SMH Installation | Gallery Steel | 16x7 | White', rate: 300, uses: 31, last: '2026-10-02'),
  _svc('Commercial Installation | Labor Only | Materials Not Included', min: 0, max: 4200, uses: 26, last: '2026-10-26'),
  _svc('Operator Installation | LiftMaster | 7\' 87504', rate: 351.06, cost: 128, uses: 19, last: '2026-04-20'),
  _svc('Dock Leveler Installation', rate: 7000, cost: 4100, uses: 17, last: '2026-11-17', group: 'Commercial Installations', edited: const ['category']),
  _svc('Commercial Installation | Sectional Manual Chain Hoist Installation', rate: 349, cost: 110, uses: 13, last: '2026-11-19'),
  _svc('Operator Installation | LiftMaster | 10\' 85870', rate: 457.64, cost: 160, uses: 10, last: '2026-10-09'),
  _svc('Operator Installation | LiftMaster | 8\' 85870', rate: 355, cost: 124, uses: 10, last: '2026-11-05'),
  _svc('Operator Installation | LiftMaster | 12\' 4690L', rate: 480, cost: 172, uses: 9, last: '2026-10-21'),
  _svc('Residential Service | Spring Replacement | Torsion Pair', min: 249, max: 325, uses: 8, last: '2026-11-11'),
  _svc('SMH Installation | Gallery Steel | 9x7 | White', rate: 300, uses: 5, last: '2026-09-22'),
  _svc('SMH Installation | Gallery Steel | 8x7 | Black', rate: 300, uses: 4, last: '2026-09-08'),
  _svc('Commercial Service | Call | After Hours', rate: 99, uses: 4, last: '2025-08-08'),
  _svc('Operator Installation | LiftMaster | 12\' TDC12S1BMC', rate: 275, uses: 4, last: '2026-11-03'),
  _svc('SMH Installation | Gallery Steel | 18x7 | White', rate: 300, uses: 3, last: '2026-09-08'),
  _svc('Overhead Door Installation - Mounting To Steel', min: 6200, max: 7480.44, uses: 2, last: '2025-11-12'),
  _svc('Residential Service Package | Deluxe | \$499', rate: 429.91, uses: 2, last: '2025-06-24'),
  _svc('Operator Service | Call | Emergency Service', rate: 150, uses: 1, last: '2026-02-10'),
  _svc('Commercial Service | Spring Cycle Upgrade | High Cycle', rate: 1180, cost: 610, uses: 1, last: '2025-07-15'),
  _svc('Residential Service | Weather Seal | Bottom Retainer and Astragal', rate: 145, cost: 38, uses: 6, last: '2026-08-30'),
  _svc('Commercial Service | Preventive Maintenance | Per Door', rate: 85, cost: 22, uses: 22, last: '2026-11-14'),
  _svc('Residential Service | Opener Safety Sensors | Replace Pair', rate: 165, cost: 41, uses: 18, last: '2026-11-16'),
  // Switched off by the office (2026-11-19): kept with their history, never offered on new lines.
  _svc('Commercial Door Removal', rate: 250, uses: 2, last: '2025-06-12', active: false, edited: const ['active']),
  _svc('Commercial Overhead Door Installation | Taxable', rate: 1450, uses: 3, last: '2025-09-02', active: false, edited: const ['active']),
  _svc('LiftMaster | 7\' 81650 Operator Installation | Taxable', rate: 0, uses: 1, last: '2025-05-29', active: false, edited: const ['active']),
  _svc('LiftMaster | 7\' 84505 Operator Installation | Taxable', rate: 305.74, uses: 1, last: '2025-05-28', active: false, edited: const ['active']),
  _svc('LiftMaster | 98022 Sidemount Operator Installation | Taxable', rate: 520, uses: 2, last: '2025-06-03', active: false, edited: const ['active']),
];

CatalogResult prodLikeCatalog({bool cost = true}) => (entries: kProdLikeServices, canSeeCost: cost, historyDays: 540);

/// The service with rate lines the service page pictures use.
final CatalogEntry kServiceWithRates = _svc(
  'Operator Installation | LiftMaster | 8\' 6690L',
  rate: 395,
  cost: 140,
  uses: 82,
  last: '2026-11-17',
  group: 'Operator Installations',
  description: 'Install a LiftMaster 6690L wall-mount operator on an 8 ft door: mount, wire, program two remotes and the keypad, test the safety reverse.',
  edited: const ['category', 'rates'],
  // Each rate its own commission (USER RULE 2026-11-19 late): a percentage, a fixed amount each, and none.
  rates: const [
    ServiceRate(name: 'Standard install', description: 'Door up to 8 ft, power within 6 ft', rate: 395, cost: 140, paysCommission: true, commissionType: 'percent', commissionValue: 5),
    ServiceRate(name: 'Extra remote', qty: 2, rate: 45, cost: 18, paysCommission: true, commissionType: 'fixed', commissionValue: 5),
    ServiceRate(name: 'Haul away old opener', rate: 35, cost: 0),
  ],
  // Products Used (2026-11-24): two in the catalog and one gone from it.
  products: const [
    ServiceProduct(
      key: 'inv:6690',
      name: "LiftMaster 6690L Wall-Mount Operator",
      entry: CatalogEntry(key: 'inv:6690', name: "LiftMaster 6690L Wall-Mount Operator", kind: 'product', rate: 489, cost: 312, taxable: true),
    ),
    ServiceProduct(
      key: 'inv:877',
      name: 'LiftMaster 877MAX Keypad',
      qty: 1,
      entry: CatalogEntry(key: 'inv:877', name: 'LiftMaster 877MAX Keypad', kind: 'product', rate: 59, cost: 28, taxable: true),
    ),
    ServiceProduct(key: 'inv:41a', name: 'Safety Sensor Kit (old)', qty: 1),
  ],
);

/// A service package as the office builds them (the user, 2026-11-20): separate lines, none of them the "main" one, each
/// with its own rate and commission; only the dispatch line starts at 1, the rest at 0, raised on a job when needed.
/// The rate names are the real Residential Service package's; the prices, costs and commissions are made up.
final CatalogEntry kResidentialServicePackage = _svc(
  'Residential Service',
  rate: 89,
  cost: 25,
  uses: 640,
  last: '2026-11-19',
  group: 'Service Packages',
  description: 'Diagnose and service a residential garage door and opener.',
  edited: const ['category', 'rates'],
  rates: const [
    ServiceRate(name: 'Service Call | Dispatch & Evaluation', rate: 89, cost: 25, paysCommission: true, commissionType: 'percent', commissionValue: 10),
    ServiceRate(name: 'Service | Accessory Install & Program', qty: 0, rate: 65, cost: 15, paysCommission: true, commissionType: 'percent', commissionValue: 10),
    ServiceRate(name: 'Service | Tune-Up', qty: 0, rate: 129, cost: 30, paysCommission: true, commissionType: 'percent', commissionValue: 10),
    ServiceRate(name: 'Service | Standard Repair', qty: 0, rate: 185, cost: 45, paysCommission: true, commissionType: 'percent', commissionValue: 10),
    ServiceRate(name: 'Service | Advanced Repair', qty: 0, rate: 325, cost: 80, paysCommission: true, commissionType: 'percent', commissionValue: 10),
    ServiceRate(name: '+ Additional Door Tune-Up & Service', qty: 0, rate: 79, cost: 20, paysCommission: true, commissionType: 'fixed', commissionValue: 5),
    ServiceRate(name: '+ Priority Call', qty: 0, rate: 75, cost: 0, paysCommission: true, commissionType: 'fixed', commissionValue: 10),
    ServiceRate(name: '+ Travel Charge', qty: 0, rate: 45, cost: 0),
  ],
);
