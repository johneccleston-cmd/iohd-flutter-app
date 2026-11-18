import '../services/line_items_api.dart';

/// The Product Catalog's data-quality checks (Phase 3, 2026-11-16): what the Cleanup view counts and lists, and what the
/// list's "Needs attention" filters pick. Pure functions over the list the page already has, so they cost no server
/// round trip and follow the person's switches by themselves: the cost checks need costs, which the server only sends
/// with the Line Items & Costs > View switch.
///
/// Only ACTIVE products are checked: making a duplicate inactive is how it is resolved, so it then drops off.
///
/// Nothing here decides anything. Each check is a question for a person ("these two have the same part number: is that
/// right?"); the page never merges, deletes or re-links a product on its own. The rules were tuned on the real price
/// list (11-16 export): "similar names" is strict on purpose, because the catalog is full of real variants that differ
/// by one token (LH/RH, LW/RW, model codes, sizes) and are NOT duplicates.

/// One check. [needsCost] checks only exist for people who can see costs; [grouped] checks come in groups of products
/// that belong together (a shared name or part number) rather than single products.
enum CatalogCheck {
  dupeName('dupe_name', 'Same name', 'Exactly the same name', grouped: true),
  dupePart('dupe_part', 'Same part #', 'One part # on several products', grouped: true),
  similarName('similar', 'Similar names', 'Differ only in spacing or spelling', grouped: true),
  noPart('no_part', 'No part #', 'No part number entered'),
  noCost('no_cost', 'No cost entered', 'Margin can\'t be worked out', needsCost: true),
  noCategory('no_category', 'No category', 'Not in any category'),
  costAbove('cost_above', 'Cost at or above price', 'Sells for its cost or less', needsCost: true),
  highMarkup('high_markup', 'Price over 10× cost', 'Check the price or the cost', needsCost: true),
  categoryOdd('category_odd', 'Unusual category', 'Others like it are filed elsewhere'),
  linkReview('link_review', 'Stock link to review', 'Its inventory row needs a person'),
  obsolete('obsolete', 'Possibly obsolete', 'No job in the history window, none on hand');

  final String key;
  final String label;
  final String caption;
  final bool needsCost;
  final bool grouped;
  const CatalogCheck(this.key, this.label, this.caption, {this.needsCost = false, this.grouped = false});

  static CatalogCheck? byKey(String key) {
    for (final c in values) {
      if (c.key == key) return c;
    }
    return null;
  }
}

/// Products that belong together under one check ("Same part # 0140900"). [issueKey] names the group for a reviewed
/// mark; [signature] is its products' ids, so a mark lapses when the group changes.
class CatalogIssueGroup {
  final CatalogCheck check;
  final String issueKey;

  /// What they share, as shown: the name, the part number, or for similar names the first name.
  final String title;
  final List<CatalogEntry> products;

  /// For similar names: why they look alike ("spacing", "word order", "spelling: bracket / braket").
  final String? why;
  const CatalogIssueGroup({required this.check, required this.issueKey, required this.title, required this.products, this.why});

  List<int> get ids => [
    for (final e in products)
      if (e.productId != null) e.productId!,
  ]..sort();
  String get signature => ids.join(',');
}

/// The checks' results for one list.
class CatalogQuality {
  /// Every product loaded (active and inactive), and the active ones the checks looked at.
  final int total;
  final int checked;

  /// Whether the cost checks ran (the person can see costs).
  final bool withCost;

  /// Open groups per grouped check (reviewed ones are in [reviewedGroups]).
  final Map<CatalogCheck, List<CatalogIssueGroup>> groups;
  final Map<CatalogCheck, List<CatalogIssueGroup>> reviewedGroups;

  /// Product keys flagged by each check (for a grouped check: the products of its OPEN groups).
  final Map<CatalogCheck, Set<String>> flagged;

  /// For [CatalogCheck.categoryOdd]: the category most products named like it are in.
  final Map<String, String> usualCategory;

  /// Products whose stock is found by name, not by their own inventory row: true for every product until the
  /// inventory-link backfill runs on the server.
  final int nameLinked;

  const CatalogQuality({
    required this.total,
    required this.checked,
    required this.withCost,
    required this.groups,
    required this.reviewedGroups,
    required this.flagged,
    required this.usualCategory,
    required this.nameLinked,
  });

  static const empty = CatalogQuality(
    total: 0,
    checked: 0,
    withCost: false,
    groups: {},
    reviewedGroups: {},
    flagged: {},
    usualCategory: {},
    nameLinked: 0,
  );

  /// The checks this person gets (the cost ones only with costs).
  List<CatalogCheck> get checks => [
    for (final c in CatalogCheck.values)
      if (!c.needsCost || withCost) c,
  ];

  bool flags(CatalogCheck c, CatalogEntry e) => flagged[c]?.contains(e.key) ?? false;

  /// Products flagged by [c] (for a grouped check, in its open groups).
  int productCount(CatalogCheck c) => flagged[c]?.length ?? 0;

  /// Open groups of a grouped check.
  int groupCount(CatalogCheck c) => groups[c]?.length ?? 0;
  int reviewedCount(CatalogCheck c) => reviewedGroups[c]?.length ?? 0;

  /// How many products have at least one open issue (the Cleanup headline).
  int get productsWithIssues => {for (final s in flagged.values) ...s}.length;
}

/// Lower case, single spaces, trimmed: how names and part numbers are compared.
String catalogNorm(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

List<String> _words(String s) => catalogNorm(s).split(RegExp(r'[^a-z0-9]+')).where((w) => w.isNotEmpty).toList();

/// Edit distance (insert, delete, change one letter), small words only.
int catalogEditDistance(String a, String b) {
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      final del = prev[j] + 1;
      final ins = cur[j - 1] + 1;
      final sub = prev[j - 1] + cost;
      cur[j] = del < ins ? (del < sub ? del : sub) : (ins < sub ? ins : sub);
    }
    prev = cur;
  }
  return prev[b.length];
}

final _letters = RegExp(r'^[a-z]+$');

/// Whether two differing words read as one word misspelt (or made plural): letters only (a model code like "L979S" vs
/// "L979U", or LH vs RH, is a real difference), at least 5 letters, 1 edit apart (2 when both are 8 or longer).
bool _spellingVariant(String x, String y) {
  if (!_letters.hasMatch(x) || !_letters.hasMatch(y)) return false;
  final shorter = x.length < y.length ? x.length : y.length;
  if (shorter < 5) return false;
  return catalogEditDistance(x, y) <= (shorter >= 8 ? 2 : 1);
}

/// Groups of names that look like the same thing written differently. Returns, per group, its members' indexes and why.
/// Exact duplicates (same name once spaces and case are ignored) are left to the Same name check unless [includeExact]
/// (category names: "Weather Seal" and "Weather  seal" are two categories). A misspelt word is looked for in names of
/// [minWords] words or more (product names need two, so a lone word is never compared; category names can be one word).
List<({List<int> members, String why})> similarNameGroups(List<String> names, {bool includeExact = false, int minWords = 2}) {
  final n = names.length;
  final parent = List<int>.generate(n, (i) => i);
  int find(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  final why = <int, String>{};
  void join(int a, int b, String reason) {
    final ra = find(a);
    final rb = find(b);
    if (ra == rb) return;
    parent[rb] = ra;
    why[ra] ??= reason;
    if (why.containsKey(rb)) why[ra] ??= why[rb]!;
  }

  final normed = [for (final s in names) catalogNorm(s)];
  final words = [for (final s in names) _words(s)];
  // Spacing and punctuation only, and the same words in another order: one pass each, by key.
  void byKey(String Function(int i) key, String reason) {
    final first = <String, int>{};
    for (var i = 0; i < n; i++) {
      final k = key(i);
      if (k.isEmpty) continue;
      final j = first[k];
      if (j == null) {
        first[k] = i;
      } else if (includeExact || normed[i] != normed[j]) {
        join(j, i, reason);
      }
    }
  }

  byKey((i) => words[i].join(), 'spacing or punctuation');
  byKey((i) => ([...words[i]]..sort()).join(' '), 'word order');
  // One word spelt differently, everything else the same: names that match with that word blanked out.
  final slot = <String, List<int>>{};
  for (var i = 0; i < n; i++) {
    final w = words[i];
    if (w.length < minWords) continue;
    for (var p = 0; p < w.length; p++) {
      if (!_letters.hasMatch(w[p]) || w[p].length < 5) continue;
      final k = '${w.length}|$p|${[...w.sublist(0, p), '*', ...w.sublist(p + 1)].join(' ')}';
      (slot[k] ??= []).add(i);
    }
  }
  for (final e in slot.entries) {
    final members = e.value;
    if (members.length < 2) continue;
    final p = int.parse(e.key.split('|')[1]);
    for (var a = 0; a < members.length; a++) {
      for (var b = a + 1; b < members.length; b++) {
        final i = members[a];
        final j = members[b];
        if (normed[i] == normed[j]) continue;
        final x = words[i][p];
        final y = words[j][p];
        if (x != y && _spellingVariant(x, y)) join(i, j, 'spelling: $x / $y');
      }
    }
  }
  final byRoot = <int, List<int>>{};
  for (var i = 0; i < n; i++) {
    (byRoot[find(i)] ??= []).add(i);
  }
  return [
    for (final e in byRoot.entries)
      if (e.value.length > 1 && (includeExact || e.value.map((i) => normed[i]).toSet().length > 1)) (members: e.value, why: why[e.key] ?? 'similar'),
  ];
}

/// The first part of a catalog name ("Hinge RC | 14GA | #2" -> "hinge rc"): products named alike start alike.
String _family(String name) => name.contains('|') ? catalogNorm(name.split('|').first) : '';

/// Runs every check over [entries] (products only). [reviews] are the saved "reviewed" marks: a group whose products
/// still match its mark is set aside rather than counted.
CatalogQuality catalogQuality(List<CatalogEntry> entries, {required bool withCost, List<CatalogReview> reviews = const []}) {
  final products = [
    for (final e in entries)
      if (e.kind == 'product') e,
  ];
  final active = [
    for (final e in products)
      if (e.active) e,
  ];
  final reviewed = {for (final r in reviews) r.issueKey: r.signature};
  final groups = <CatalogCheck, List<CatalogIssueGroup>>{};
  final reviewedGroups = <CatalogCheck, List<CatalogIssueGroup>>{};
  final flagged = <CatalogCheck, Set<String>>{};
  void flag(CatalogCheck c, CatalogEntry e) => (flagged[c] ??= <String>{}).add(e.key);
  void addGroup(CatalogIssueGroup g) {
    final sorted = [...g.products]..sort((a, b) => (a.productId ?? 0).compareTo(b.productId ?? 0));
    final group = CatalogIssueGroup(check: g.check, issueKey: g.issueKey, title: g.title, products: sorted, why: g.why);
    if (reviewed[group.issueKey] == group.signature) {
      (reviewedGroups[g.check] ??= []).add(group);
      return;
    }
    (groups[g.check] ??= []).add(group);
    for (final e in group.products) {
      flag(g.check, e);
    }
  }

  // Same name, same part number.
  final byName = <String, List<CatalogEntry>>{};
  final byPart = <String, List<CatalogEntry>>{};
  for (final e in active) {
    (byName[catalogNorm(e.name)] ??= []).add(e);
    final p = catalogNorm(e.sku);
    if (p.isNotEmpty) (byPart[p] ??= []).add(e);
  }
  for (final e in byName.entries) {
    if (e.value.length > 1) addGroup(CatalogIssueGroup(check: CatalogCheck.dupeName, issueKey: 'dupe_name:${e.key}', title: e.value.first.name, products: e.value));
  }
  for (final e in byPart.entries) {
    if (e.value.length > 1) addGroup(CatalogIssueGroup(check: CatalogCheck.dupePart, issueKey: 'dupe_part:${e.key}', title: e.value.first.sku, products: e.value));
  }
  // Similar names.
  for (final g in similarNameGroups([for (final e in active) e.name])) {
    final members = [for (final i in g.members) active[i]];
    final ids = [
      for (final e in members)
        if (e.productId != null) e.productId!,
    ]..sort();
    final key = ids.isEmpty ? catalogNorm(members.first.name) : '${ids.first}';
    addGroup(CatalogIssueGroup(check: CatalogCheck.similarName, issueKey: 'similar:$key', title: members.first.name, products: members, why: g.why));
  }

  // Products named alike (same first part) that mostly sit in one category: one in a category none of the others use.
  final usualCategory = <String, String>{};
  final byFamily = <String, List<CatalogEntry>>{};
  for (final e in active) {
    final f = _family(e.name);
    if (f.isNotEmpty) (byFamily[f] ??= []).add(e);
  }
  for (final members in byFamily.values) {
    if (members.length < 4) continue;
    final counts = <String, int>{};
    for (final e in members) {
      counts[e.category] = (counts[e.category] ?? 0) + 1;
    }
    final top = counts.entries.reduce((a, b) => b.value > a.value ? b : a);
    if (top.key.isEmpty || top.value / members.length < 0.6) continue;
    for (final e in members) {
      if (e.category != top.key && e.category.isNotEmpty && counts[e.category] == 1) {
        flag(CatalogCheck.categoryOdd, e);
        usualCategory[e.key] = top.key;
      }
    }
  }

  // One product at a time.
  for (final e in active) {
    if (e.sku.trim().isEmpty) flag(CatalogCheck.noPart, e);
    if (e.category.trim().isEmpty) flag(CatalogCheck.noCategory, e);
    if (e.inventoryConflict != null) flag(CatalogCheck.linkReview, e);
    // Not sold in the history window (no Service Fusion line has it) and nothing on hand: a question, not a verdict.
    if (e.uses == 0 && e.lastUsed == null && (e.stock ?? 0) <= 0 && e.inventoryConflict == null) flag(CatalogCheck.obsolete, e);
    if (withCost) {
      final cost = e.cost;
      final price = e.rate;
      if (cost == null) flag(CatalogCheck.noCost, e);
      if (cost != null && price != null && price > 0 && cost >= price) flag(CatalogCheck.costAbove, e);
      if (cost != null && cost > 0 && price != null && price >= cost * 10) flag(CatalogCheck.highMarkup, e);
    }
  }

  return CatalogQuality(
    total: products.length,
    checked: active.length,
    withCost: withCost,
    groups: groups,
    reviewedGroups: reviewedGroups,
    flagged: flagged,
    usualCategory: usualCategory,
    nameLinked: products.where((e) => e.inventoryLink == 'name').length,
  );
}

// ---- categories ------------------------------------------------------------------------------------------------------

/// A naming question about some categories: [kind] `spacing` (the same name typed differently), `spelling` (one word
/// spelt differently, or singular and plural), or `abbreviation` (one word written two ways across the list).
/// [names] are the categories it is about; for `abbreviation`, the ones that use the less common spelling.
class CategoryNameIssue {
  final String kind;
  final List<String> names;
  final String message;
  const CategoryNameIssue({required this.kind, required this.names, required this.message});
}

/// Words written more than one way in category names. Only spellings that certainly mean the same word: "RC" is NOT in
/// here (in this catalog "Spring Anchor - RC" holds commercial parts, so it is not "Residential").
const _sameWord = {
  'commercial': ['com', 'comm', 'commercial'],
  'residential': ['res', 'resi', 'residential'],
};

/// Naming questions across the category list [names] (each name once).
List<CategoryNameIssue> categoryNameIssues(List<String> names) {
  final out = <CategoryNameIssue>[];
  final seen = <String>{};
  // Same name typed differently (case, spaces, punctuation), and one word spelt differently.
  for (final g in similarNameGroups(names, includeExact: true, minWords: 1)) {
    final members = [for (final i in g.members) names[i]]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (!seen.add(members.join('\n'))) continue;
    final spacing = !g.why.startsWith('spelling');
    out.add(
      CategoryNameIssue(
        kind: spacing ? 'spacing' : 'spelling',
        names: members,
        message: spacing ? 'The same name typed ${members.length} ways' : 'Spelt differently (${g.why.substring(10)})',
      ),
    );
  }
  // The same word written two ways across the list ("Com" in 13, "Commercial" in 1).
  for (final family in _sameWord.entries) {
    final users = <String, List<String>>{};
    for (final name in names) {
      final w = _words(name);
      for (final spelling in family.value) {
        if (w.contains(spelling)) (users[spelling] ??= []).add(name);
      }
    }
    if (users.length < 2) continue;
    final ranked = users.entries.toList()..sort((a, b) => b.value.length.compareTo(a.value.length));
    final common = ranked.first;
    final rest = ranked.skip(1).toList();
    String quote(String s) => '"${s[0].toUpperCase()}${s.substring(1)}"';
    out.add(
      CategoryNameIssue(
        kind: 'abbreviation',
        names: [for (final r in rest) ...r.value]..sort(),
        message:
            '${family.key[0].toUpperCase()}${family.key.substring(1)} is written ${quote(common.key)} in ${common.value.length} '
            '${common.value.length == 1 ? 'category' : 'categories'} and ${[for (final r in rest) '${quote(r.key)} in ${r.value.length}'].join(', ')}',
      ),
    );
  }
  return out;
}
