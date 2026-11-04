import 'dart:async';

import 'package:flutter/material.dart';

import '../services/line_items_api.dart';
import '../utils/line_item_math.dart';
import 'dashboard_kit.dart';

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
        controller: controller,
        focusNode: focus,
        onSubmitted: (_) => onSubmit(),
        style: const TextStyle(fontSize: 13.5, color: DashUi.ink),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: const Color(0xFFF8FAFC),
          hintText: 'Add a line: search products and services by name or SKU',
          hintStyle: const TextStyle(fontSize: 13, color: DashUi.subtle, fontWeight: FontWeight.w500),
          prefixIcon: const Icon(Icons.add_circle_outline_rounded, size: 19, color: DashUi.slate),
          prefixIconConstraints: const BoxConstraints(minWidth: 38, minHeight: 36),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: DashUi.line)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: DashUi.line)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: DashUi.ink, width: 1.2)),
        ),
      ),
      optionsViewBuilder: (context, onSelected, options) {
        final list = options.toList();
        // No Align of its own: the autocomplete lines the list up under (or over) the field.
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Material(
              color: Colors.white,
              elevation: 10,
              shadowColor: Colors.black.withValues(alpha: 0.16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: DashUi.line)),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640, maxHeight: 360),
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  shrinkWrap: true,
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1, color: DashUi.faint),
                  itemBuilder: (context, i) {
                    final highlighted = AutocompleteHighlightedOption.of(context) == i;
                    return _ChoiceRow(choice: list[i], highlighted: highlighted, showCost: widget.showCost, onTap: () => onSelected(list[i]));
                  },
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
    final bg = highlighted ? DashUi.faint : Colors.white;
    if (choice.message != null) {
      return Container(
        color: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Text(choice.message!, style: const TextStyle(fontSize: 13, color: DashUi.slate)),
      );
    }
    if (choice.custom != null) {
      return InkWell(
        onTap: onTap,
        child: Container(
          color: bg,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.edit_note_rounded, size: 18, color: DashUi.slate),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(text: 'Add a custom line: '),
                      TextSpan(text: '"${choice.custom}"', style: const TextStyle(fontWeight: FontWeight.w800, color: DashUi.ink)),
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
        ),
      );
    }
    final e = choice.entry!;
    final meta = [
      if (e.sku.isNotEmpty) 'SKU ${e.sku}',
      if (e.category.isNotEmpty) e.category,
      if (e.stock != null) '${e.stock} in stock',
      if (e.uses > 0) 'on ${e.uses} Service Fusion line${e.uses == 1 ? '' : 's'}',
    ].join('  ·  ');
    final Widget price;
    if (e.rate != null) {
      price = Text(centsMoney((e.rate! * 100).round()), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: DashUi.ink, fontFeatures: [FontFeature.tabularFigures()]));
    } else if (e.rateMin != null && e.rateMax != null && e.rateMin != e.rateMax) {
      price = Text(
        'Price varies\n${centsMoney((e.rateMin! * 100).round())} – ${centsMoney((e.rateMax! * 100).round())}',
        textAlign: TextAlign.right,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.amberText, height: 1.3),
      );
    } else {
      price = const Text('No price on file', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: DashUi.subtle));
    }
    return InkWell(
      onTap: onTap,
      child: Container(
        color: bg,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          children: [
            Icon(e.kind == 'service' ? Icons.handyman_outlined : Icons.inventory_2_outlined, size: 18, color: DashUi.slate),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink)),
                  if (meta.isNotEmpty)
                    Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: DashUi.subtle)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                price,
                if (showCost && e.cost != null)
                  Text('Cost ${centsMoney((e.cost! * 100).round())}', style: const TextStyle(fontSize: 12, color: DashUi.subtle, fontFeatures: [FontFeature.tabularFigures()])),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
