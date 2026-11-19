import 'dart:async';

import 'package:flutter/material.dart';

import '../services/line_items_api.dart';
import '../utils/line_item_math.dart';
import 'dashboard_kit.dart';
import 'ps_menu.dart';

/// What a pick from the catalog search is: a catalog entry, a custom line named after what was typed, or a message
/// (searching failed, nothing matched) that can't be picked.
class CatalogChoice {
  final CatalogEntry? entry;
  final String? custom;
  final String? message;
  const CatalogChoice.entry(CatalogEntry this.entry) : custom = null, message = null;
  const CatalogChoice.custom(String this.custom) : entry = null, message = null;
  const CatalogChoice.message(String this.message) : entry = null, custom = null;
  bool get pickable => message == null;
}

/// "Search the catalog to add a line": type part of a name or a SKU, matches drop down as you type (best first),
/// arrow keys and Enter pick one. The field keeps focus after a pick, so several lines go in one after another.
class CatalogSearchField extends StatefulWidget {
  /// The search box's height, fixed, so the buttons beside it can be exactly as tall (round 3, 2026-11-13: a field's
  /// own height comes from its font, and its intrinsic height, which a Row stretched to, is taller than it draws).
  static const height = 40.0;

  final ValueChanged<CatalogChoice> onPick;
  final bool showCost;

  /// Swappable for tests; the real search is [LineItemsApi.searchCatalog].
  final Future<List<CatalogEntry>> Function(String q)? search;
  final FocusNode? focusNode;
  const CatalogSearchField({super.key, required this.onPick, required this.showCost, this.search, this.focusNode});

  @override
  State<CatalogSearchField> createState() => _CatalogSearchFieldState();
}

class _CatalogSearchFieldState extends State<CatalogSearchField> {
  final _controller = TextEditingController();
  final _fieldKey = GlobalKey(debugLabel: 'catalog search');
  late final FocusNode _focus = widget.focusNode ?? FocusNode();
  int _asked = 0;
  String _lastQ = '';
  List<CatalogChoice> _last = const [];

  @override
  void dispose() {
    _controller.dispose();
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  Future<Iterable<CatalogChoice>> _options(TextEditingValue v) async {
    final q = v.text.trim();
    if (q.isEmpty) return const [];
    if (q == _lastQ) return _last;
    final ticket = ++_asked;
    // A short pause so typing "torsion" asks once, not seven times.
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (ticket != _asked) return _last;
    List<CatalogChoice> out;
    try {
      final found = await (widget.search ?? LineItemsApi.searchCatalog)(q);
      out = [
        for (final e in found) CatalogChoice.entry(e),
        if (found.isEmpty) const CatalogChoice.message('Nothing in the catalog matches. Add it as a custom line below.'),
        CatalogChoice.custom(q),
      ];
    } catch (e) {
      out = [CatalogChoice.message('Couldn\'t search the catalog: $e'), CatalogChoice.custom(q)];
    }
    if (ticket != _asked) return _last;
    _lastQ = q;
    _last = out;
    return out;
  }

  void _picked(CatalogChoice c) {
    if (!c.pickable) return;
    widget.onPick(c);
    _controller.clear();
    _lastQ = '';
    _last = const [];
    _focus.requestFocus();
  }

  /// Whether the results open over the field: the side with more room, as [OptionsViewOpenDirection.mostSpace] picks.
  bool _opensUp() {
    final box = _fieldKey.currentContext?.findRenderObject();
    final overlay = Overlay.maybeOf(context)?.context.findRenderObject();
    if (box is! RenderBox || overlay is! RenderBox || !box.hasSize) return false;
    final top = box.localToGlobal(Offset.zero, ancestor: overlay).dy;
    return top > overlay.size.height - (top + box.size.height);
  }

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<CatalogChoice>(
      textEditingController: _controller,
      focusNode: _focus,
      optionsBuilder: _options,
      displayStringForOption: (_) => '',
      onSelected: _picked,
      // The search sits under the last line, often low on the page: the list opens where there is room.
      optionsViewOpenDirection: OptionsViewOpenDirection.mostSpace,
      fieldViewBuilder: (context, controller, focus, onSubmit) => TextField(
        key: _fieldKey,
        mouseCursor: SystemMouseCursors.click,
        controller: controller,
        focusNode: focus,
        onSubmitted: (_) => onSubmit(),
        style: const TextStyle(fontSize: 13.5, color: DashUi.ink),
        textAlignVertical: TextAlignVertical.center,
        // A plus and the hint in an outlined box, so it reads as something to click (user 2026-11-13), in the same quiet
        // hairline as the line boxes above it (user 2026-11-13 pass 5), a light fill under the pointer, ink while typing.
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0),
          hoverColor: DashUi.faint.withValues(alpha: 0.6),
          hintText: 'Add a line: search products and services by name or SKU',
          hintStyle: const TextStyle(fontSize: 13, color: DashUi.ink, fontWeight: FontWeight.w500),
          prefixIcon: const Icon(Icons.add_rounded, size: 18, color: DashUi.ink),
          prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 36),
          constraints: const BoxConstraints.tightFor(height: CatalogSearchField.height),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: DashUi.fieldEdge),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: DashUi.fieldEdge),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: DashUi.ink, width: 1.5),
          ),
        ),
      ),
      optionsViewBuilder: (context, onSelected, options) {
        final list = options.toList();
        // No Align of its own: the autocomplete lines the list up under (or over) the field. It opens the way there is
        // more room (mostSpace), so it grows out of the field from that side.
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: PsMenuEntrance(
            up: _opensUp(),
            child: Container(
              decoration: psMenuPanelDecoration(),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: Material(
                  type: MaterialType.transparency,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640, maxHeight: 360),
                    child: ListView.builder(
                      padding: const EdgeInsets.all(6),
                      shrinkWrap: true,
                      itemCount: list.length,
                      itemBuilder: (context, i) {
                        final highlighted = AutocompleteHighlightedOption.of(context) == i;
                        return _ChoiceRow(choice: list[i], highlighted: highlighted, showCost: widget.showCost, onTap: () => onSelected(list[i]));
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ChoiceRow extends StatelessWidget {
  final CatalogChoice choice;
  final bool highlighted;
  final bool showCost;
  final VoidCallback onTap;
  const _ChoiceRow({required this.choice, required this.highlighted, required this.showCost, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (choice.message != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Text(choice.message!, style: const TextStyle(fontSize: 13, color: DashUi.slate)),
      );
    }
    if (choice.custom != null) {
      return _tap(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.edit_note_rounded, size: 18, color: DashUi.slate),
            const SizedBox(width: 10),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(text: 'Add a custom line: '),
                    TextSpan(
                      text: '"${choice.custom}"',
                      style: const TextStyle(fontWeight: FontWeight.w800, color: DashUi.ink),
                    ),
                    const TextSpan(text: '  (you enter the price)'),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: DashUi.slate),
              ),
            ),
          ],
        ),
      );
    }
    final e = choice.entry!;
    // A service from the Services Catalog (Phase 2) says how sure its price is; a product, or a service from a server
    // older than that (no price status), is shown as it always was.
    if (e.isService && e.priceStatus != null) return _serviceRow(e);
    final meta = [
      if (e.sku.isNotEmpty) 'SKU ${e.sku}',
      if (e.category.isNotEmpty) e.category,
      if (e.stock != null) '${e.stock} in stock',
      if (e.uses > 0) 'on ${e.uses} Service Fusion line${e.uses == 1 ? '' : 's'}',
    ].join('  ·  ');
    final Widget price;
    if (e.rate != null) {
      price = Text(
        centsMoney((e.rate! * 100).round()),
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: DashUi.ink, fontFeatures: [FontFeature.tabularFigures()]),
      );
    } else if (e.rateMin != null && e.rateMax != null && e.rateMin != e.rateMax) {
      price = Text(
        'Price varies\n${centsMoney((e.rateMin! * 100).round())} – ${centsMoney((e.rateMax! * 100).round())}',
        textAlign: TextAlign.right,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.amberText, height: 1.3),
      );
    } else {
      price = const Text(
        'No price on file',
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: DashUi.subtle),
      );
    }
    return _tap(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      child: Row(
        children: [
          Icon(e.kind == 'service' ? Icons.handyman_outlined : Icons.inventory_2_outlined, size: 18, color: DashUi.slate),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink),
                ),
                if (meta.isNotEmpty)
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: DashUi.subtle),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              price,
              if (showCost && e.cost != null)
                Text(
                  'Cost ${centsMoney((e.cost! * 100).round())}',
                  style: const TextStyle(fontSize: 12, color: DashUi.subtle, fontFeatures: [FontFeature.tabularFigures()]),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _money(double v) => centsMoney((v * 100).round());

  static const _metaText = TextStyle(fontSize: 12, color: DashUi.subtle);
  static const _figures = [FontFeature.tabularFigures()];

  /// A service's row: its name; its group and how often it was billed (and a tax hint when its billed lines differ);
  /// a renamed line says what it replaced (once it has taken over: the old entry is no longer offered) or what it was
  /// split from; at the right, how sure its price is: the price once settled, else why there is none (a recent change
  /// shows the 18-month median and the newest prices apart).
  Widget _serviceRow(CatalogEntry e) {
    final group = e.group.isNotEmpty ? e.group : e.category;
    final billed = e.uses > 0 ? e.uses : e.rateUses;
    final meta = [if (group.isNotEmpty) group, billed > 0 ? 'billed $billed×' : 'never billed'].join(' · ');
    final variantOf = e.variantOf;
    final lineage = e.replaces.isNotEmpty
        ? 'Replaces ${e.replaces.map((r) => r.name).join(', ')}'
        : variantOf != null
        ? 'Renamed line of ${variantOf.name}, with its own price'
        : null;
    // A recent price change: the 18-month median and the newest billed prices, apart (neither is filled in).
    final change = e.recentChange;
    final median = change?.median ?? e.medianPrice;
    final recent = change != null && change.prices.isNotEmpty ? change.prices : e.recentPrices;
    final changeLine = e.priceStatus == 'recent_change'
        ? [
            if (median != null) '18-mo median ${_money(median)}',
            if (recent.isNotEmpty) 'recent ${recent.map((p) => _money(p.price)).join(', ')}',
          ].join(' · ')
        : '';
    const amberStrong = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.amberText, height: 1.3);
    const quiet = TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: DashUi.subtle);
    final last = e.lastBilled?.price ?? e.medianPrice;
    final Widget price = switch (e.priceStatus) {
      'settled' when e.rate != null => Text(
        _money(e.rate!),
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: DashUi.ink, fontFeatures: _figures),
      ),
      'recent_change' => const Text('Recent price change', textAlign: TextAlign.right, style: amberStrong),
      'varies' when e.rateMin != null && e.rateMax != null => Text(
        'Price varies ${_money(e.rateMin!)} – ${_money(e.rateMax!)}',
        textAlign: TextAlign.right,
        style: amberStrong,
      ),
      'single' when last != null => Text('Billed once · ${_money(last)}', textAlign: TextAlign.right, style: quiet),
      'quote_only' when e.quoteMedian != null => Text('No billed price · quoted ${_money(e.quoteMedian!)}', textAlign: TextAlign.right, style: quiet),
      _ => const Text('No price on file', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: DashUi.subtle)),
    };
    return _tap(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      child: Row(
        children: [
          const Icon(Icons.handyman_outlined, size: 18, color: DashUi.slate),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink),
                ),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: meta),
                      // Taxed on some of its billed jobs and not others: the line starts untaxed, so check it.
                      if (e.taxDefault == 'mixed')
                        const TextSpan(text: '  ·  tax varies', style: TextStyle(fontWeight: FontWeight.w600, color: DashUi.amberText)),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _metaText,
                ),
                if (lineage != null) Text(lineage, maxLines: 1, overflow: TextOverflow.ellipsis, style: _metaText),
                if (changeLine.isNotEmpty)
                  Text(
                    changeLine,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _metaText.copyWith(color: DashUi.amberText, fontFeatures: _figures),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              price,
              if (showCost && e.cost != null)
                Text('Cost ${_money(e.cost!)}', style: const TextStyle(fontSize: 12, color: DashUi.subtle, fontFeatures: _figures)),
            ],
          ),
        ],
      ),
    );
  }

  /// A pickable row: a rounded highlight inset in the list (the arrow keys' choice, or the pointer's), a touch darker
  /// while pressed, as the block's menus have it.
  Widget _tap({required EdgeInsets padding, required Widget child}) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(6),
    hoverColor: DashUi.faint,
    highlightColor: DashUi.line.withValues(alpha: 0.6),
    splashFactory: NoSplash.splashFactory,
    child: Ink(
      decoration: BoxDecoration(color: highlighted ? DashUi.faint : Colors.white.withValues(alpha: 0), borderRadius: BorderRadius.circular(6)),
      padding: padding,
      child: child,
    ),
  );
}
