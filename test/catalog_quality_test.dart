import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/services/line_items_api.dart';
import 'package:iohd_desktop/utils/catalog_quality.dart';

// The Product Catalog's data-quality checks (lib/utils/catalog_quality.dart). Names are real ones from the 11-16 price
// list: the checks must catch real duplicates and leave the catalog's many genuine variants (left/right hand, left/right
// wound, model codes, sizes) alone.

CatalogEntry p(
  int id,
  String name, {
  String sku = '',
  String category = 'Misc',
  double? cost,
  double? rate,
  bool active = true,
  int uses = 1,
  int? stock,
  String? conflict,
  String? link,
}) => CatalogEntry(
  key: 'cat:$id',
  name: name,
  sku: sku,
  category: category,
  cost: cost,
  rate: rate,
  active: active,
  uses: uses,
  lastUsed: uses > 0 ? '2026-10-01' : null,
  stock: stock,
  inventoryConflict: conflict,
  inventoryLink: link,
  updatedAt: '2026-11-16T15:52:00.045Z',
);

void main() {
  group('similar names', () {
    test('catches spacing, punctuation, word order and one misspelt word', () {
      final groups = similarNameGroups([
        'Weather Seal | Stop Mold | 10\' White',
        'Weather Seal|Stop Mold | 10\'  White',
        'Hinge | Commercial | #3',
        'Commercial | Hinge | #3',
        'Bottom Bracket | Residential | RH | SRBB-75',
        'Bottom Braket | Residential | RH | SRBB-75',
        'Lubricant | Adjustable Nozzle Garage Door Lubricant',
      ]);
      expect(groups, hasLength(3));
      expect(groups.map((g) => g.why), containsAll(['spacing or punctuation', 'word order', 'spelling: bracket / braket']));
    });

    test('leaves real variants alone: LH/RH, LW/RW, model codes, sizes, lengths', () {
      final groups = similarNameGroups([
        'Bottom Bracket | Commercial | LH | CBB-95-2',
        'Bottom Bracket | Commercial | RH | CBB-95-2',
        'Torsion Spring - RC | RW .192 x 2 x 18.5',
        'Torsion Spring RC | LW .192 x 2 x 18.5',
        'Keypad | L979S | LiftMaster',
        'Keypad | L979U | LiftMaster',
        'Remote | 811LM | LiftMaster',
        'Remote | 811LMX | LiftMaster',
        'Weather Seal | Stop Mold | 10\' Almond',
        'Weather Seal | Stop Mold | 16\' Almond',
        'Clopay Classic Steel | T40F | Complete Door',
        'Clopay Classic Steel | T40L | Complete Door',
      ]);
      expect(groups, isEmpty);
    });

    test('exact duplicates are left to the Same name check', () {
      expect(similarNameGroups(['Bottom Bracket | Commercial | LH | Sure-Stop', 'bottom bracket | commercial | lh | sure-stop']), isEmpty);
    });
  });

  group('catalogQuality', () {
    final list = [
      p(16, 'Bottom Bracket | Commercial | LH | Sure-Stop', sku: '120420', category: 'Bottom Bracket - Com', cost: 300, rate: 471.55),
      p(17, 'Bottom Bracket | Commercial | LH | Sure-Stop', sku: '120436', category: 'Bottom Bracket - Com', cost: 410, rate: 618.15),
      p(30, 'Spring Parts | 2 5/8 Cone Left | 1" Shaft', sku: '0140900', category: 'Spring Parts', cost: 2, rate: 9),
      p(31, 'Spring Parts | 2 Cone Left | 1" Shaft', sku: '0140900', category: 'Spring Parts', cost: 2, rate: 9),
      p(32, 'Spring Parts | Bumpers | Leaf Type Pair', sku: '0140950', category: 'Spring Parts', cost: 6.41, rate: 116.6),
      p(33, 'Spring Parts | Winding Bar', category: 'Tools', cost: 4, rate: 4),
      p(34, 'Spring Parts | Cone Set', sku: 'SP-1', category: 'Spring Parts', cost: 5, rate: 4),
      p(40, 'Lubricant | Garage Door', category: '', uses: 0, stock: 0),
      p(41, 'Decorative Handle', sku: 'DH-1', category: 'Decorative Hardware', conflict: 'duplicate_name'),
      p(42, 'Old Opener', sku: 'OO-1', category: 'Operators', active: false, uses: 0),
      p(43, 'Old Opener', sku: 'OO-1', category: 'Operators', uses: 0, stock: 2, link: 'name'),
    ];

    test('groups duplicates, flags missing info, pricing, odd categories, links and obsolete products', () {
      final q = catalogQuality(list, withCost: true);
      expect(q.total, 11);
      expect(q.checked, 10, reason: 'inactive products are not checked');
      expect(q.groups[CatalogCheck.dupeName]!.single.ids, [16, 17]);
      expect(q.groups[CatalogCheck.dupePart]!.single.ids, [30, 31]);
      expect(q.groupCount(CatalogCheck.similarName), 0);
      expect(q.flagged[CatalogCheck.noPart], {'cat:33', 'cat:40'});
      expect(q.flagged[CatalogCheck.noCategory], {'cat:40'});
      expect(q.flagged[CatalogCheck.noCost], {'cat:40', 'cat:41', 'cat:43'});
      expect(q.flagged[CatalogCheck.costAbove], {'cat:33', 'cat:34'}, reason: 'cost equal to or above the price');
      expect(q.flagged[CatalogCheck.highMarkup], {'cat:32'}, reason: r'$116.60 on a $6.41 cost');
      expect(q.flagged[CatalogCheck.categoryOdd], {'cat:33'}, reason: 'the one Spring Parts product filed under Tools');
      expect(q.usualCategory['cat:33'], 'Spring Parts');
      expect(q.flagged[CatalogCheck.linkReview], {'cat:41'});
      expect(q.flagged[CatalogCheck.obsolete], {'cat:40'}, reason: 'never sold and none on hand; 43 has stock, 42 is inactive');
      expect(q.nameLinked, 1);
      expect(q.productsWithIssues, greaterThan(0));
    });

    test('without costs the cost checks do not exist at all', () {
      final q = catalogQuality(list, withCost: false);
      expect(q.checks, isNot(contains(CatalogCheck.noCost)));
      expect(q.checks, isNot(contains(CatalogCheck.costAbove)));
      expect(q.checks, isNot(contains(CatalogCheck.highMarkup)));
      expect(q.flagged[CatalogCheck.costAbove], isNull);
    });

    test('a reviewed group is set aside, and comes back when the group changes', () {
      final group = catalogQuality(list, withCost: true).groups[CatalogCheck.dupePart]!.single;
      final review = CatalogReview(issueKey: 'dupe_part:0140900', signature: '30,31', basis: group.basis);
      final q = catalogQuality(list, withCost: true, reviews: [review]);
      expect(q.groupCount(CatalogCheck.dupePart), 0);
      expect(q.reviewedCount(CatalogCheck.dupePart), 1);
      expect(q.flagged[CatalogCheck.dupePart], isNull, reason: 'a reviewed group is not in the Needs attention filter');
      // A third product takes the same part number: the group is no longer the one that was reviewed.
      final grown = [...list, p(35, 'Spring Parts | 1-3/4 Cone Left', sku: '0140900', category: 'Spring Parts')];
      final q2 = catalogQuality(grown, withCost: true, reviews: [review]);
      expect(q2.groups[CatalogCheck.dupePart]!.single.ids, [30, 31, 35]);
    });

    test('making one of a duplicate pair inactive resolves it', () {
      final fixed = [for (final e in list) e.key == 'cat:17' ? e.withChange(active: false) : e];
      expect(catalogQuality(fixed, withCost: true).groupCount(CatalogCheck.dupeName), 0);
    });
  });

  group('category names', () {
    test('flags the same name typed differently, a misspelling, and a word written two ways', () {
      final issues = categoryNameIssues([
        'Weather Seal',
        'Weather  seal',
        'Sprocket',
        'Sprockets',
        'Bottom Bracket - Com',
        'Hinge - Com',
        'Strut - Com',
        'Commercial Operator Head',
        'Vertical Track - Res',
        'Residential Operator Head',
        'Wall Station - Res',
      ]);
      final kinds = {for (final i in issues) i.kind};
      expect(kinds, {'spacing', 'spelling', 'abbreviation'});
      final abbr = issues.where((i) => i.kind == 'abbreviation').toList();
      expect(abbr.map((i) => i.names), containsAll([['Commercial Operator Head'], ['Residential Operator Head']]));
      expect(abbr.first.message, contains('written "Com" in 3 categories'));
    });

    test('never treats RC as Residential, or Com and RC as the same category', () {
      final issues = categoryNameIssues(['Spring Anchor - RC', 'Spring Anchor - Res', 'Top Bracket - RC', 'Top Bracket - Res', 'Hinge - Com', 'Hinge - RC']);
      expect(issues, isEmpty);
    });
  });

  // ---- refinement 2026-11-18 -------------------------------------------------------------------------------------

  group('marks on one product under one check', () {
    CatalogEntry e(int id, {String sku = 'X', double? rate = 10, double? cost = 4, int uses = 3, int? stock = 1}) =>
        CatalogEntry(key: 'cat:$id', name: 'Product $id', sku: sku, category: 'Misc', rate: rate, cost: cost, uses: uses, lastUsed: uses > 0 ? '2026-10-01' : null, stock: stock);

    test('reviewed and follow-up marks set a product aside; it still counts nowhere else', () {
      final list = [e(1, sku: ''), e(2, sku: ''), e(3, sku: '')];
      final q = catalogQuality(list, withCost: true, reviews: [
        CatalogReview(issueKey: 'no_part:1', signature: '1', basis: catalogFindingBasis(CatalogCheck.noPart, list[0])),
        CatalogReview(issueKey: 'no_part:2', signature: '2', status: 'follow_up', note: 'Ask the vendor', basis: catalogFindingBasis(CatalogCheck.noPart, list[1])),
      ]);
      expect(q.productCount(CatalogCheck.noPart), 1);
      expect(q.openCount(CatalogCheck.noPart), 1);
      expect([for (final x in q.reviewedItems[CatalogCheck.noPart]!) x.key], ['cat:1']);
      expect([for (final x in q.followUpItems[CatalogCheck.noPart]!) x.key], ['cat:2']);
      expect(q.followUpCount(CatalogCheck.noPart), 1);
      expect(q.reviewedCount(CatalogCheck.noPart), 1);
      expect(q.followUpTotal, 1);
      expect(q.productsWithIssues, 1);
      expect(q.markOf(CatalogCheck.noPart, list[1])!.note, 'Ask the vendor');
    });

    test('a pricing mark lapses when the price or cost it was made on changes', () {
      final before = e(5, rate: 10, cost: 12);
      final basis = catalogFindingBasis(CatalogCheck.costAbove, before);
      final mark = CatalogReview(issueKey: 'cost_above:5', signature: '5', basis: basis);
      expect(catalogQuality([before], withCost: true, reviews: [mark]).productCount(CatalogCheck.costAbove), 0);
      final after = e(5, rate: 10, cost: 13);
      expect(catalogQuality([after], withCost: true, reviews: [mark]).productCount(CatalogCheck.costAbove), 1, reason: 'the cost went up again: look again');
    });

    test('a mark on another product, or on a product of another check, does not apply', () {
      final q = catalogQuality([e(1, sku: '')], withCost: true, reviews: const [
        CatalogReview(issueKey: 'no_part:1', signature: '2'),
        CatalogReview(issueKey: 'no_cost:1', signature: '1'),
      ]);
      expect(q.productCount(CatalogCheck.noPart), 1);
    });

    test('a possibly obsolete product marked to follow up stays a follow-up, never anything more', () {
      final old = e(9, uses: 0, stock: 0);
      final q = catalogQuality([old], withCost: true, reviews: [
        CatalogReview(issueKey: 'obsolete:9', signature: '9', basis: catalogFindingBasis(CatalogCheck.obsolete, old), status: 'follow_up', reviewedAt: DateTime.now()),
      ]);
      expect(q.followUpCount(CatalogCheck.obsolete), 1);
      expect(q.productCount(CatalogCheck.obsolete), 0);
      expect(old.active, isTrue);
    });

    test('a duplicate group marked to follow up is kept apart from reviewed groups', () {
      final pair = [e(30, sku: 'SMAL'), e(31, sku: 'SMAL')];
      final basis = catalogQuality(pair, withCost: true).groups[CatalogCheck.dupePart]!.single.basis;
      final q = catalogQuality(pair, withCost: true, reviews: [CatalogReview(issueKey: 'dupe_part:smal', signature: '30,31', status: 'follow_up', basis: basis)]);
      expect(q.followUpCount(CatalogCheck.dupePart), 1);
      expect(q.reviewedCount(CatalogCheck.dupePart), 0);
      expect(q.groupCount(CatalogCheck.dupePart), 0);
    });
  });

  group('categoryLookalikes', () {
    const cats = ['Keypad', 'Weather Seal', 'Spring - Res', 'Commercial Operator Head', 'Hinge - RC'];
    test('a plural, a spacing twin and a name inside another are offered, best first', () {
      expect(categoryLookalikes('Keypads', cats), ['Keypad']);
      expect(categoryLookalikes('weather  seal', cats), ['Weather Seal']);
      expect(categoryLookalikes('Operator Head', cats), ['Commercial Operator Head']);
    });
    test('RC is never offered as Res, and an unlike name gets nothing', () {
      expect(categoryLookalikes('Spring - RC', cats), isEmpty);
      expect(categoryLookalikes('Garage Door Opener', cats), isEmpty);
      expect(categoryLookalikes('', cats), isEmpty);
    });
  });

  // ---- final audit 2026-11-18: a mark never silently outlives a material change ---------------------------------

  group('marks lapse when the finding changes', () {
    CatalogEntry e(int id, {String name = '', String sku = 'X', String category = 'Misc', double? rate = 10, double? cost = 4, int uses = 3, int? stock = 1}) => CatalogEntry(
      key: 'cat:$id',
      name: name.isEmpty ? 'Product $id' : name,
      sku: sku,
      category: category,
      rate: rate,
      cost: cost,
      uses: uses,
      lastUsed: uses > 0 ? '2026-10-01' : null,
      stock: stock,
    );
    CatalogReview mark(CatalogCheck c, CatalogEntry x, {String? usual, DateTime? at}) =>
        CatalogReview(issueKey: catalogFindingKey(c, x)!, signature: '${x.productId}', basis: catalogFindingBasis(c, x, usual: usual), reviewedAt: at ?? DateTime.now());

    test('a one-product mark lapses when the product is renamed or re-numbered, not when something unrelated changes', () {
      final before = e(1, sku: '', name: 'Bracket A');
      final m = mark(CatalogCheck.noPart, before);
      expect(catalogQuality([before], withCost: true, reviews: [m]).productCount(CatalogCheck.noPart), 0);
      expect(catalogQuality([e(1, sku: '', name: 'Bracket B')], withCost: true, reviews: [m]).productCount(CatalogCheck.noPart), 1, reason: 'renamed');
      expect(catalogQuality([e(1, sku: '', name: 'Bracket A', rate: 99)], withCost: true, reviews: [m]).productCount(CatalogCheck.noPart), 0, reason: 'a price is not what "no part #" is about');
    });

    test('a group mark lapses when a member is renamed or re-numbered while it stays in the group', () {
      final pair = [e(30, sku: 'SMAL', name: 'Seal 7ft'), e(31, sku: 'SMAL', name: 'Seal 9ft')];
      final g = catalogQuality(pair, withCost: true).groups[CatalogCheck.dupePart]!.single;
      final m = CatalogReview(issueKey: g.issueKey, signature: g.signature, basis: g.basis);
      expect(catalogQuality(pair, withCost: true, reviews: [m]).groupCount(CatalogCheck.dupePart), 0);
      final renamed = [e(30, sku: 'SMAL', name: 'Seal 7ft'), e(31, sku: 'SMAL', name: 'Seal 7ft white')];
      expect(catalogQuality(renamed, withCost: true, reviews: [m]).groupCount(CatalogCheck.dupePart), 1);
      final noBasis = CatalogReview(issueKey: g.issueKey, signature: g.signature);
      expect(catalogQuality(pair, withCost: true, reviews: [noBasis]).groupCount(CatalogCheck.dupePart), 1, reason: 'a mark that does not say what it was made on never applies');
    });

    test('an unusual-category mark lapses when the usual category of its family changes', () {
      List<CatalogEntry> family(String usual) => [
        for (var i = 0; i < 4; i++) e(10 + i, name: 'Hinge RC | #$i', category: usual),
        e(20, name: 'Hinge RC | #9', category: 'Odd'),
      ];
      final odd = family('Hinge - RC').last;
      final m = mark(CatalogCheck.categoryOdd, odd, usual: 'Hinge - RC');
      expect(catalogQuality(family('Hinge - RC'), withCost: true, reviews: [m]).productCount(CatalogCheck.categoryOdd), 0);
      expect(catalogQuality(family('Hinges'), withCost: true, reviews: [m]).productCount(CatalogCheck.categoryOdd), 1);
    });

    test('a possibly obsolete mark lapses once it is older than the history window (so it never outlives a sale)', () {
      final old = e(9, uses: 0, stock: 0);
      final fresh = mark(CatalogCheck.obsolete, old, at: DateTime(2026, 11, 1));
      final stale = mark(CatalogCheck.obsolete, old, at: DateTime(2025, 1, 1));
      final now = DateTime(2026, 11, 18);
      expect(catalogQuality([old], withCost: true, reviews: [fresh], now: now).productCount(CatalogCheck.obsolete), 0);
      expect(catalogQuality([old], withCost: true, reviews: [stale], now: now).productCount(CatalogCheck.obsolete), 1);
      expect(catalogQuality([old], withCost: true, reviews: [fresh], now: now, historyDays: 10).productCount(CatalogCheck.obsolete), 1);
    });

    test('a pricing mark keeps no price or cost in what it stores', () {
      final x = e(5, rate: 471.55, cost: 94.31);
      final b = catalogFindingBasis(CatalogCheck.costAbove, x);
      expect(b, startsWith('v2:'));
      expect(b.contains('471'), isFalse);
      expect(b.contains('94'), isFalse);
      expect(catalogFindingBasis(CatalogCheck.costAbove, e(5, rate: 471.55, cost: 94.32)), isNot(b));
    });

    test('the fingerprint is the same every time (the web and desktop app agree)', () {
      expect(catalogDigest('no_part||bracket a|'), catalogDigest('no_part||bracket a|'));
      expect(catalogDigest('a'), isNot(catalogDigest('b')));
    });
  });
}
