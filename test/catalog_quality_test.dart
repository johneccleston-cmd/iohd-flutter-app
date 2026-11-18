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
      const review = CatalogReview(issueKey: 'dupe_part:0140900', signature: '30,31');
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
}
