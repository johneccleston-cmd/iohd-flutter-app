import 'package:flutter/material.dart';

import 'app_ribbon.dart';
import 'dashboard_kit.dart';

/// The Product Catalog's own design system (Phase 1 redesign, 2026-11-16): the list, its filters and the product page are
/// built from these pieces so they share one rhythm. The language follows the redesigned Products & Services block
/// (white surfaces, small-caps slate labels, soft stripes instead of rules, muted "|" in names, tabular figures) and only
/// uses existing tokens (DashUi, RibbonColors). Nothing here is used outside the catalog, so other screens are unchanged.
class CatalogUi {
  CatalogUi._();

  // Rhythm. Rows are 42 px for a one-line name (a long name takes a second line rather than being cut off).
  static const double rowHeight = 42;
  static const double headerHeight = 36;
  static const double commandHeight = 52;
  static const double footerHeight = 44;
  static const double sidebarWidth = 248;

  /// The table's inset from the sheet's edge, and the gap between its columns.
  static const double side = 20;
  static const double gap = 14;

  /// A row's pick box sits in a lead area at its left edge (not a column): [leadInset] from the edge, [leadWidth] wide,
  /// so the columns lose only (leadInset + leadWidth - side) = 22 px to it.
  static const double leadInset = 8;
  static const double leadWidth = 34;

  // Surfaces. A stripe is half way between white and `faint`, so rows separate without a rule between them.
  static final Color stripe = Color.lerp(Colors.white, DashUi.faint, 0.55)!;
  static const Color hover = DashUi.faint;
  static final Color picked = DashUi.ink.withValues(alpha: 0.06);
  static final Color pickedHover = DashUi.ink.withValues(alpha: 0.1);

  // Type.
  static const List<FontFeature> figures = [FontFeature.tabularFigures()];

  /// Table headers and section labels: small capitals in slate (the strings are passed in capitals).
  static const TextStyle head = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.slate, letterSpacing: 0.8, height: 1.2);
  static const TextStyle name = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: DashUi.ink, height: 1.3, letterSpacing: -0.1);
  static const TextStyle cell = TextStyle(fontSize: 14.5, color: DashUi.ink, height: 1.3, fontFeatures: figures);
  static const TextStyle cellStrong = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: DashUi.ink, height: 1.3, fontFeatures: figures);
  static const TextStyle cellQuiet = TextStyle(fontSize: 14.5, color: DashUi.slate, height: 1.3, fontFeatures: figures);
  static const TextStyle groupTitle = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink);
  static const TextStyle body = TextStyle(fontSize: 14.5, color: DashUi.ink, height: 1.5);
  static const TextStyle meta = TextStyle(fontSize: 13, color: DashUi.slate, height: 1.35);

  /// Motion that stops when the system asks for reduced motion.
  static Duration motion(BuildContext context, [int ms = 180]) => MediaQuery.disableAnimationsOf(context) ? Duration.zero : Duration(milliseconds: ms);
}

/// A catalog name with its "|" separators drawn quieter than its words, as the Products & Services block draws them.
/// Its plain text is the name exactly, so it reads, copies and is found the same.
TextSpan catalogNameSpan(String text, TextStyle style) {
  if (!text.contains('|')) return TextSpan(text: text, style: style);
  final parts = text.split('|');
  return TextSpan(
    style: style,
    children: [
      for (var i = 0; i < parts.length; i++) ...[
        if (i > 0)
          const TextSpan(
            text: '|',
            style: TextStyle(color: DashUi.muted, fontWeight: FontWeight.w400),
          ),
        TextSpan(text: parts[i]),
      ],
    ],
  );
}

/// The margin on a real price and a real cost (a per-job price or a cost not entered gives none, never 100%).
({double pct, bool above, bool even})? catalogMargin(double? price, double? cost) {
  if (price == null || cost == null || price <= 0 || cost <= 0) return null;
  return (pct: (price - cost) / price * 100, above: cost > price, even: cost == price);
}

/// The colour a margin reads in: red when the cost is at or above the price, amber when thin, ink otherwise.
Color catalogMarginTone(double pct) => pct <= 0 ? DashUi.redText : (pct < 10 ? DashUi.amberText : DashUi.ink);

// ---- small pieces ------------------------------------------------------------------------------------------------------

enum CatalogTone { neutral, good, warn, danger, info }

/// A small status pill ("Inactive", "Review", "Inventory item"). Text in a text-safe tone on a light tint of it.
class CatalogTag extends StatelessWidget {
  final String label;
  final CatalogTone tone;
  final IconData? icon;
  const CatalogTag(this.label, {super.key, this.tone = CatalogTone.neutral, this.icon});

  static (Color, Color) colors(CatalogTone tone) => switch (tone) {
    CatalogTone.good => (DashUi.emeraldText, DashUi.emerald.withValues(alpha: 0.12)),
    CatalogTone.warn => (DashUi.amberText, DashUi.amber.withValues(alpha: 0.12)),
    CatalogTone.danger => (DashUi.redText, DashUi.red.withValues(alpha: 0.09)),
    CatalogTone.info => (DashUi.ink, DashUi.blue.withValues(alpha: 0.08)),
    CatalogTone.neutral => (DashUi.slate, DashUi.faint),
  };

  @override
  Widget build(BuildContext context) {
    final (fg, bg) = colors(tone);
    return Container(
      padding: EdgeInsets.fromLTRB(icon == null ? 8 : 6, 2, 8, 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 13, color: fg), const SizedBox(width: 4)],
          // In a narrow cell (the list's In stock column) the label gives way rather than spilling over.
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}

/// A section label: small capitals with an optional quiet note after it, and room for a trailing control.
class CatalogLabel extends StatelessWidget {
  final String text;
  final String? note;
  final Widget? trailing;
  const CatalogLabel(this.text, {super.key, this.note, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: CatalogUi.head)),
        if (note != null) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(note!, maxLines: 1, overflow: TextOverflow.ellipsis, style: CatalogUi.meta),
          ),
        ],
        if (trailing != null) ...[const Spacer(), trailing!],
      ],
    );
  }
}

/// The catalog's search box: white with a hairline, an ink ring when focused, and a "/" key hint while it's empty.
class CatalogSearchField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onClear;
  final bool shortcutHint;
  final double height;

  /// Takes the keyboard when it appears (the pickers in the catalog's dialogs).
  final bool autofocus;
  const CatalogSearchField({
    super.key,
    required this.controller,
    required this.hint,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.onClear,
    this.shortcutHint = false,
    this.height = 38,
    this.autofocus = false,
  });

  @override
  State<CatalogSearchField> createState() => _CatalogSearchFieldState();
}

class _CatalogSearchFieldState extends State<CatalogSearchField> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: c, width: w),
    );
    final hasText = widget.controller.text.isNotEmpty;
    Widget? suffix;
    if (hasText && widget.onClear != null) {
      suffix = IconButton(
        tooltip: 'Clear search',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.close_rounded, size: 18, color: DashUi.slate),
        onPressed: widget.onClear,
      );
    } else if (widget.shortcutHint) {
      // Tells keyboard users that "/" jumps here.
      suffix = ExcludeSemantics(
        child: Center(
          widthFactor: 1,
          child: Container(
            margin: const EdgeInsets.only(right: 10),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: DashUi.line),
            ),
            child: const Text(
              '/',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.subtle),
            ),
          ),
        ),
      );
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: SizedBox(
        height: widget.height,
        child: TextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          style: const TextStyle(fontSize: 14.5, color: DashUi.ink),
          textInputAction: TextInputAction.search,
          textAlignVertical: TextAlignVertical.center,
          decoration: InputDecoration(
            hintText: widget.hint,
            hintStyle: const TextStyle(color: DashUi.subtle, fontSize: 14.5),
            prefixIcon: const Icon(Icons.search_rounded, size: 20, color: DashUi.slate),
            prefixIconConstraints: const BoxConstraints(minWidth: 40),
            suffixIcon: suffix,
            suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
            isDense: true,
            filled: true,
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            border: border(DashUi.line),
            enabledBorder: border(_hover ? DashUi.fieldEdge : DashUi.line),
            focusedBorder: border(DashUi.ink, 1.5),
          ),
          onChanged: widget.onChanged,
          onSubmitted: widget.onSubmitted,
        ),
      ),
    );
  }
}

/// An active filter, removable: "Category  Bearing - RC  x". [group] is the quiet part, [value] the strong one.
class CatalogFilterChip extends StatefulWidget {
  final String group;
  final String value;
  final VoidCallback onRemove;
  const CatalogFilterChip({super.key, required this.group, required this.value, required this.onRemove});

  @override
  State<CatalogFilterChip> createState() => _CatalogFilterChipState();
}

class _CatalogFilterChipState extends State<CatalogFilterChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Remove filter ${widget.group} ${widget.value}',
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onRemove,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: CatalogUi.motion(context, 220),
            curve: Curves.easeOutCubic,
            builder: (context, t, child) => Opacity(
              opacity: t,
              child: Transform.scale(scale: 0.92 + 0.08 * t, child: child),
            ),
            child: AnimatedContainer(
              duration: CatalogUi.motion(context, 120),
              height: 30,
              padding: const EdgeInsets.fromLTRB(11, 0, 5, 0),
              decoration: BoxDecoration(color: _hover ? CatalogUi.pickedHover : CatalogUi.picked, borderRadius: BorderRadius.circular(999)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '${widget.group}  ',
                            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: DashUi.slate),
                          ),
                          TextSpan(
                            text: widget.value,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.ink),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  AnimatedContainer(
                    duration: CatalogUi.motion(context, 120),
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: _hover ? DashUi.ink : Colors.transparent),
                    child: Icon(Icons.close_rounded, size: 14, color: _hover ? Colors.white : DashUi.slate),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A pick-any-number row in the filter sidebar: a check box, the name and how many products it holds.
class CatalogCheckRow extends StatelessWidget {
  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  /// A coloured dot before the name (the "Needs attention" rows), or null.
  final Color? dot;
  const CatalogCheckRow({super.key, required this.label, required this.count, required this.selected, required this.onTap, this.dot});

  static final _fmt = RegExp(r'\B(?=(\d{3})+(?!\d))');

  @override
  Widget build(BuildContext context) {
    final n = count?.toString().replaceAll(_fmt, ',');
    return Semantics(
      button: true,
      checked: selected,
      label: n == null ? label : '$label, $n',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        hoverColor: selected ? CatalogUi.pickedHover : DashUi.faint,
        child: AnimatedContainer(
          duration: CatalogUi.motion(context),
          curve: Curves.easeOutCubic,
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(color: selected ? CatalogUi.picked : Colors.transparent, borderRadius: BorderRadius.circular(8)),
          child: Row(
            children: [
              CatalogCheckBox(selected),
              const SizedBox(width: 10),
              if (dot != null) ...[
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
                const SizedBox(width: 7),
              ],
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, color: DashUi.ink),
                ),
              ),
              if (n != null) ...[
                const SizedBox(width: 8),
                Text(
                  n,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: selected ? DashUi.ink : DashUi.subtle, fontFeatures: CatalogUi.figures),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A 16 px check box: a slate outline, filled with ink (and a white tick) when picked.
class CatalogCheckBox extends StatelessWidget {
  final bool selected;
  const CatalogCheckBox(this.selected, {super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: CatalogUi.motion(context, 140),
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: selected ? DashUi.ink : Colors.white,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: selected ? DashUi.ink : DashUi.fieldEdge, width: 1.5),
      ),
      child: selected ? const Icon(Icons.check_rounded, size: 12, color: Colors.white) : null,
    );
  }
}

/// A collapsible group in the filter sidebar: its title, how many of its picks are on (shown while it is closed), a chevron.
class CatalogFilterGroup extends StatefulWidget {
  final String title;
  final int picked;
  final bool initiallyOpen;
  final Widget child;
  const CatalogFilterGroup({super.key, required this.title, required this.child, this.picked = 0, this.initiallyOpen = true});

  @override
  State<CatalogFilterGroup> createState() => _CatalogFilterGroupState();
}

class _CatalogFilterGroupState extends State<CatalogFilterGroup> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: _open,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _open = !_open),
              child: SizedBox(
                height: 34,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      Expanded(child: Text(widget.title, style: CatalogUi.groupTitle)),
                      if (!_open && widget.picked > 0)
                        Container(
                          margin: const EdgeInsets.only(right: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 7),
                          decoration: BoxDecoration(color: DashUi.ink, borderRadius: BorderRadius.circular(999)),
                          child: Text(
                            '${widget.picked}',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white, height: 1.5),
                          ),
                        ),
                      AnimatedRotation(
                        turns: _open ? 0 : -0.25,
                        duration: CatalogUi.motion(context),
                        child: const Icon(Icons.expand_more_rounded, size: 18, color: DashUi.subtle),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: CatalogUi.motion(context, 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _open ? Padding(padding: const EdgeInsets.only(bottom: 6), child: widget.child) : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

// ---- the table ---------------------------------------------------------------------------------------------------------

class CatalogCol {
  /// In capitals, as it is drawn.
  final String label;

  /// A fixed width, or null to take the room that is left (one flexible column per table).
  final double? width;
  final bool right;
  final String? sortKey;

  /// Drawn in the header instead of [label] (the select-all box).
  final Widget? header;
  const CatalogCol(this.label, {this.width, this.right = false, this.sortKey, this.header});
}

/// Lays out one row of cells under [cols]: fixed columns at their widths, the flexible one taking the rest, a
/// [CatalogUi.gap] between them.
class CatalogCells extends StatelessWidget {
  final List<CatalogCol> cols;
  final List<Widget> cells;
  const CatalogCells({super.key, required this.cols, required this.cells});

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < cols.length; i++) {
      final c = cols[i];
      if (i > 0) children.add(const SizedBox(width: CatalogUi.gap));
      final cell = Align(alignment: c.right ? Alignment.centerRight : Alignment.centerLeft, child: cells[i]);
      children.add(c.width == null ? Expanded(child: cell) : SizedBox(width: c.width, child: cell));
    }
    return Row(children: children);
  }
}

/// The table's header: white, small-caps slate labels on a hairline. A sortable label is a button; the sorted one is
/// ink with its arrow, and the others show a faint arrow on hover.
class CatalogTableHeader extends StatelessWidget {
  final List<CatalogCol> cols;
  final String sortKey;
  final bool ascending;
  final ValueChanged<String> onSort;

  /// The pick-every-row box, in the lead area over the rows' boxes (see [CatalogRow.leading]).
  final Widget? leading;
  const CatalogTableHeader({super.key, required this.cols, required this.sortKey, required this.ascending, required this.onSort, this.leading});

  @override
  Widget build(BuildContext context) {
    final cells = CatalogCells(
      cols: cols,
      cells: [for (final c in cols) c.header ?? _HeaderLabel(col: c, active: c.sortKey != null && c.sortKey == sortKey, ascending: ascending, onSort: onSort)],
    );
    return Container(
      height: CatalogUi.headerHeight,
      padding: EdgeInsets.fromLTRB(leading == null ? CatalogUi.side : CatalogUi.leadInset, 0, CatalogUi.side, 0),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: DashUi.line)),
      ),
      child: SelectionContainer.disabled(
        child: leading == null
            ? cells
            : Row(
                children: [
                  SizedBox(width: CatalogUi.leadWidth, child: Center(child: leading)),
                  Expanded(child: cells),
                ],
              ),
      ),
    );
  }
}

class _HeaderLabel extends StatefulWidget {
  final CatalogCol col;
  final bool active;
  final bool ascending;
  final ValueChanged<String> onSort;
  const _HeaderLabel({required this.col, required this.active, required this.ascending, required this.onSort});

  @override
  State<_HeaderLabel> createState() => _HeaderLabelState();
}

class _HeaderLabelState extends State<_HeaderLabel> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.col;
    final text = Text(
      c.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: CatalogUi.head.copyWith(color: widget.active || _hover ? DashUi.ink : DashUi.slate),
    );
    if (c.sortKey == null) return text;
    // The sorted column shows its arrow; the others show a faint one only while hovered (and take no room otherwise, so
    // a narrow column keeps its whole label).
    final Widget? arrow = widget.active
        ? Icon(widget.ascending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 14, color: DashUi.ink)
        : (_hover ? const Icon(Icons.unfold_more_rounded, size: 14, color: DashUi.muted) : null);
    return Semantics(
      button: true,
      value: widget.active ? (widget.ascending ? 'Sorted ascending' : 'Sorted descending') : null,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onSort(c.sortKey!),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // On a right-aligned column the arrow goes first, so the label stays over its figures.
              if (c.right && arrow != null) ...[arrow, const SizedBox(width: 3)],
              Flexible(child: text),
              if (!c.right && arrow != null) ...[const SizedBox(width: 3), arrow],
            ],
          ),
        ),
      ),
    );
  }
}

/// One product row: at least [CatalogUi.rowHeight] tall, a soft stripe on odd rows, no rule between rows. Hovering lifts
/// it to `faint` and slides in an arrow at its end; keyboard focus draws an ink bar down its left edge.
class CatalogRow extends StatefulWidget {
  final List<CatalogCol> cols;
  final List<Widget> cells;
  final int index;
  final VoidCallback onTap;
  final String semanticLabel;

  /// Picked for a change to several products: a light ink wash, kept while hovered.
  final bool selected;

  /// The pick box, in a lead area at the row's left edge rather than a column (so the columns keep their room).
  final Widget? leading;
  const CatalogRow({
    super.key,
    required this.cols,
    required this.cells,
    required this.index,
    required this.onTap,
    required this.semanticLabel,
    this.selected = false,
    this.leading,
  });

  @override
  State<CatalogRow> createState() => _CatalogRowState();
}

class _CatalogRowState extends State<CatalogRow> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final base = widget.selected ? CatalogUi.picked : (widget.index.isOdd ? CatalogUi.stripe : Colors.white);
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.semanticLabel,
      // Not selectable text: the app-wide selection's I-beam would replace the click cursor.
      child: SelectionContainer.disabled(
        child: InkWell(
          onTap: widget.onTap,
          onHover: (v) => setState(() => _hover = v),
          onFocusChange: (v) => setState(() => _focus = v),
          hoverColor: Colors.transparent,
          focusColor: Colors.transparent,
          splashColor: DashUi.ink.withValues(alpha: 0.04),
          highlightColor: DashUi.ink.withValues(alpha: 0.03),
          child: AnimatedContainer(
            duration: CatalogUi.motion(context, 110),
            constraints: const BoxConstraints(minHeight: CatalogUi.rowHeight),
            padding: EdgeInsets.fromLTRB(widget.leading == null ? CatalogUi.side : CatalogUi.leadInset, 8, CatalogUi.side, 8),
            decoration: BoxDecoration(
              color: _hover ? (widget.selected ? CatalogUi.pickedHover : CatalogUi.hover) : base,
              border: Border(left: BorderSide(color: _focus ? DashUi.ink : Colors.transparent, width: 3)),
            ),
            // The arrow sits in the row's right padding, so it costs the columns no room.
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.centerRight,
              children: [
                if (widget.leading == null)
                  CatalogCells(cols: widget.cols, cells: widget.cells)
                else
                  Row(
                    children: [
                      SizedBox(width: CatalogUi.leadWidth, child: Center(child: widget.leading)),
                      Expanded(child: CatalogCells(cols: widget.cols, cells: widget.cells)),
                    ],
                  ),
                Positioned(
                  right: -CatalogUi.side + 1,
                  child: AnimatedSlide(
                    offset: _hover || _focus ? Offset.zero : const Offset(-0.3, 0),
                    duration: CatalogUi.motion(context, 140),
                    child: AnimatedOpacity(
                      opacity: _hover || _focus ? 1 : 0,
                      duration: CatalogUi.motion(context, 140),
                      child: const Icon(Icons.chevron_right_rounded, size: 18, color: DashUi.slate),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Placeholder rows while the list loads: the table's own header and rows, pulsing (still with reduced motion).
class CatalogSkeleton extends StatelessWidget {
  final List<CatalogCol> cols;
  final int rows;

  /// Leave the pick boxes' lead area, as the loaded rows will (see [CatalogRow.leading]).
  final bool lead;
  const CatalogSkeleton({super.key, required this.cols, this.rows = 14, this.lead = false});

  @override
  Widget build(BuildContext context) {
    Widget bar(double w) => Container(
      width: w,
      height: 11,
      decoration: BoxDecoration(color: DashUi.line, borderRadius: BorderRadius.circular(6)),
    );
    const widths = [0.62, 0.48, 0.71, 0.55, 0.66, 0.42, 0.58];
    return SkeletonPulse(
      child: Column(
        children: [
          for (var r = 0; r < rows; r++)
            Container(
              height: CatalogUi.rowHeight,
              padding: EdgeInsets.fromLTRB(lead ? CatalogUi.leadInset + CatalogUi.leadWidth : CatalogUi.side, 0, CatalogUi.side, 0),
              color: r.isOdd ? CatalogUi.stripe : Colors.white,
              child: CatalogCells(
                cols: cols,
                cells: [
                  for (var i = 0; i < cols.length; i++)
                    LayoutBuilder(
                      builder: (_, c) =>
                          bar(cols[i].width == null ? 320 * widths[r % widths.length] : (cols[i].width! * (0.5 + 0.4 * widths[(r + i) % widths.length]))),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The list's footer: rows per page on the left, where you are and the page buttons on the right.
class CatalogPager extends StatelessWidget {
  final int page;
  final int totalPages;
  final int firstRow;
  final int rowsShown;
  final int pageSize;
  final List<int> pageSizes;
  final ValueChanged<int> onPage;
  final ValueChanged<int> onPageSize;
  final bool compact;
  const CatalogPager({
    super.key,
    required this.page,
    required this.totalPages,
    required this.firstRow,
    required this.rowsShown,
    required this.pageSize,
    required this.onPage,
    required this.onPageSize,
    this.pageSizes = const [50, 100],
    this.compact = false,
  });

  /// The page numbers to show: the first, the last, and the ones around [page], with null for a gap.
  static List<int?> numbers(int page, int total, {int around = 1}) {
    if (total <= 7) return [for (var i = 1; i <= total; i++) i];
    final keep = <int>{
      1,
      total,
      for (var i = page - around; i <= page + around; i++)
        if (i > 1 && i < total) i,
    };
    if (page <= 3) keep.addAll([2, 3, 4]);
    if (page >= total - 2) keep.addAll([total - 3, total - 2, total - 1]);
    final sorted = keep.toList()..sort();
    final out = <int?>[];
    for (final n in sorted) {
      if (out.isNotEmpty && out.last != null && n - out.last! > 1) out.add(null);
      out.add(n);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final last = firstRow + rowsShown - 1;
    return SelectionContainer.disabled(
      child: Container(
        height: CatalogUi.footerHeight,
        padding: EdgeInsets.symmetric(horizontal: compact ? 12 : CatalogUi.side),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: DashUi.line)),
        ),
        child: Row(
          children: [
            if (!compact) ...[
              const Text(
                'Rows',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.slate),
              ),
              const SizedBox(width: 8),
              for (final s in pageSizes) _SizePill(size: s, selected: s == pageSize, onTap: () => onPageSize(s)),
              const SizedBox(width: 16),
            ],
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'Showing ',
                    style: const TextStyle(color: DashUi.slate),
                  ),
                  TextSpan(
                    text: '$firstRow–$last',
                    style: const TextStyle(color: DashUi.ink, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              style: const TextStyle(fontSize: 13, fontFeatures: CatalogUi.figures),
            ),
            const Spacer(),
            if (totalPages > 1) ...[
              _PageButton(icon: Icons.chevron_left_rounded, tooltip: 'Previous page', onTap: page > 1 ? () => onPage(page - 1) : null),
              if (compact)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    '$page of $totalPages',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.ink, fontFeatures: CatalogUi.figures),
                  ),
                )
              else
                for (final n in numbers(page, totalPages))
                  n == null
                      ? const SizedBox(
                          width: 24,
                          child: Center(
                            child: Text('…', style: TextStyle(fontSize: 13, color: DashUi.subtle)),
                          ),
                        )
                      : _PageButton(label: '$n', selected: n == page, onTap: n == page ? null : () => onPage(n)),
              _PageButton(icon: Icons.chevron_right_rounded, tooltip: 'Next page', onTap: page < totalPages ? () => onPage(page + 1) : null),
            ],
          ],
        ),
      ),
    );
  }
}

class _SizePill extends StatelessWidget {
  final int size;
  final bool selected;
  final VoidCallback onTap;
  const _SizePill({required this.size, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '$size rows per page',
      excludeSemantics: true,
      child: InkWell(
        onTap: selected ? null : onTap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: CatalogUi.motion(context, 140),
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: selected ? CatalogUi.picked : Colors.transparent, borderRadius: BorderRadius.circular(8)),
          child: Text(
            '$size',
            style: TextStyle(fontSize: 13, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, color: selected ? DashUi.ink : DashUi.slate),
          ),
        ),
      ),
    );
  }
}

class _PageButton extends StatelessWidget {
  final String? label;
  final IconData? icon;
  final String? tooltip;
  final bool selected;
  final VoidCallback? onTap;
  const _PageButton({this.label, this.icon, this.tooltip, this.selected = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    final off = onTap == null && !selected;
    final child = Semantics(
      button: true,
      selected: selected,
      label: tooltip ?? 'Page $label',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: CatalogUi.motion(context, 140),
          constraints: const BoxConstraints(minWidth: 30),
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: selected ? DashUi.ink : Colors.transparent, borderRadius: BorderRadius.circular(8)),
          child: icon != null
              ? Icon(icon, size: 20, color: off ? DashUi.line : DashUi.ink)
              : Text(
                  label!,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: selected ? Colors.white : DashUi.ink, fontFeatures: CatalogUi.figures),
                ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: tooltip == null ? child : Tooltip(message: tooltip!, child: child),
    );
  }
}

// ---- controls ----------------------------------------------------------------------------------------------------------

/// A secondary button on the navy ribbon: white text on glass with a light edge, so it reads as quieter than the white
/// primary button beside it (PageBanner.button). Uses RibbonColors only; the ribbon itself is unchanged.
class RibbonGhostButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  const RibbonGhostButton({super.key, required this.icon, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14)),
        foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? RibbonColors.quiet : Colors.white),
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.hovered) || s.contains(WidgetState.focused) ? Colors.white.withValues(alpha: 0.12) : RibbonColors.glass,
        ),
        overlayColor: WidgetStatePropertyAll(Colors.white.withValues(alpha: 0.06)),
        side: WidgetStateProperty.resolveWith((s) => BorderSide(color: s.contains(WidgetState.focused) ? Colors.white : RibbonColors.glassEdge)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
        textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
      ),
    );
  }
}

/// The catalog's switch: ink when on; when off a light slate track with a white thumb and a visible edge (the Material 3
/// default here was pink, from the red brand seed).
class CatalogSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  const CatalogSwitch({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Switch(
      value: value,
      onChanged: onChanged,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith((s) {
        final on = s.contains(WidgetState.selected);
        if (s.contains(WidgetState.disabled)) return on ? DashUi.slate : DashUi.faint;
        return on ? DashUi.ink : DashUi.line;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.transparent : DashUi.fieldEdge),
      thumbIcon: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? const Icon(Icons.check_rounded, size: 14, color: DashUi.ink) : null),
      overlayColor: WidgetStatePropertyAll(DashUi.ink.withValues(alpha: 0.06)),
    );
  }
}

// ---- Phase 3: selecting, managing -------------------------------------------------------------------------------------

/// A row's pick box for a change to several products: 16 px drawn on a 32 x 26 target (over the 24 px minimum, and
/// no taller than a one-line row's text, so rows keep their 42 px), easy to hit without opening the row. [value] null
/// draws the "some picked" dash (the header's box).
class CatalogSelectBox extends StatelessWidget {
  final bool? value;
  final ValueChanged<bool> onChanged;
  final String semanticLabel;
  const CatalogSelectBox({super.key, required this.value, required this.onChanged, required this.semanticLabel});

  @override
  Widget build(BuildContext context) {
    final on = value != false;
    return Semantics(
      checked: value == true,
      mixed: value == null,
      label: semanticLabel,
      excludeSemantics: true,
      child: SizedBox(
        width: 32,
        height: 26,
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: () => onChanged(value != true),
          hoverColor: DashUi.ink.withValues(alpha: 0.06),
          child: Center(
            child: AnimatedContainer(
              duration: CatalogUi.motion(context, 140),
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: on ? DashUi.ink : Colors.white,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: on ? DashUi.ink : DashUi.fieldEdge, width: 1.5),
              ),
              child: value == null
                  ? const Icon(Icons.remove_rounded, size: 12, color: Colors.white)
                  : (value! ? const Icon(Icons.check_rounded, size: 12, color: Colors.white) : null),
            ),
          ),
        ),
      ),
    );
  }
}

/// A quiet outlined button for the catalog's panes (Rename, Merge, Mark reviewed): white with a hairline, ink text.
/// [danger] draws it in the red text tone (Delete); a disabled one stays readable.
class CatalogOutlineButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool danger;
  final bool dense;
  const CatalogOutlineButton({super.key, required this.label, this.icon, required this.onPressed, this.danger = false, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final fg = danger ? DashUi.redText : DashUi.ink;
    final style = OutlinedButton.styleFrom(
      minimumSize: Size(0, dense ? 32 : 36),
      padding: EdgeInsets.symmetric(horizontal: dense ? 10 : 12),
      foregroundColor: fg,
      disabledForegroundColor: DashUi.muted,
      backgroundColor: Colors.white,
      side: const BorderSide(color: DashUi.line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      textStyle: TextStyle(fontSize: dense ? 12.5 : 13, fontWeight: FontWeight.w700),
    );
    return icon == null
        ? OutlinedButton(onPressed: onPressed, style: style, child: Text(label))
        : OutlinedButton.icon(
            onPressed: onPressed,
            style: style,
            icon: Icon(icon, size: dense ? 16 : 17),
            label: Text(label),
          );
  }
}

/// One line of the Cleanup overview: what the check is, one line of why it matters, how many, and where it goes.
/// Zero reads "None" with a quiet tick, so a clean check is good news rather than a blank. [selected] marks the check
/// whose groups are open beside it.
class CatalogIssueRow extends StatefulWidget {
  final String label;
  final String caption;
  final int count;

  /// Shown instead of [caption] when set ("2 groups · 4 products").
  final String? detail;
  final Color dot;
  final bool selected;

  /// Where a click goes: the product list (an arrow) or the groups beside it (a chevron).
  final bool opensList;
  final VoidCallback? onTap;
  const CatalogIssueRow({
    super.key,
    required this.label,
    required this.caption,
    required this.count,
    required this.dot,
    this.detail,
    this.selected = false,
    this.opensList = false,
    this.onTap,
  });

  @override
  State<CatalogIssueRow> createState() => _CatalogIssueRowState();
}

class _CatalogIssueRowState extends State<CatalogIssueRow> {
  bool _hover = false;
  static final _fmt = RegExp(r'\B(?=(\d{3})+(?!\d))');

  @override
  Widget build(BuildContext context) {
    final none = widget.count == 0;
    final n = widget.count.toString().replaceAll(_fmt, ',');
    return Semantics(
      button: widget.onTap != null,
      selected: widget.selected,
      label: '${widget.label}, ${none ? 'none' : n}. ${widget.detail ?? widget.caption}',
      excludeSemantics: true,
      child: InkWell(
        onTap: widget.onTap,
        onHover: (v) => setState(() => _hover = v),
        borderRadius: BorderRadius.circular(10),
        hoverColor: Colors.transparent,
        child: AnimatedContainer(
          duration: CatalogUi.motion(context, 140),
          padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
          decoration: BoxDecoration(
            color: widget.selected ? CatalogUi.picked : (_hover && widget.onTap != null ? DashUi.faint : Colors.transparent),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: none ? DashUi.line : widget.dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, fontWeight: widget.selected ? FontWeight.w800 : FontWeight.w700, color: DashUi.ink),
                    ),
                    Text(
                      widget.detail ?? widget.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: DashUi.slate, height: 1.25),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (none)
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_rounded, size: 15, color: DashUi.emeraldText),
                    SizedBox(width: 3),
                    Text(
                      'None',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.subtle),
                    ),
                  ],
                )
              else
                Text(
                  n,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: DashUi.ink, fontFeatures: CatalogUi.figures),
                ),
              SizedBox(
                width: 24,
                child: none || widget.onTap == null
                    ? null
                    : Icon(
                        widget.opensList ? Icons.arrow_forward_rounded : Icons.chevron_right_rounded,
                        size: widget.opensList ? 15 : 18,
                        color: _hover || widget.selected ? DashUi.ink : DashUi.muted,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A section label inside a pane ("DUPLICATES"), with room above it.
class CatalogSectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const CatalogSectionLabel(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 9, 10, 3),
      child: CatalogLabel(text, trailing: trailing),
    );
  }
}

/// A pane's title bar inside the page (Categories list, a check's groups): [CatalogUi.commandHeight] tall with a
/// hairline under it, so it lines up with the list's command row and the filter sidebar's header.
class CatalogPaneHeader extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const CatalogPaneHeader({super.key, required this.child, this.padding = const EdgeInsets.symmetric(horizontal: CatalogUi.side)});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: CatalogUi.commandHeight),
      padding: padding,
      alignment: Alignment.centerLeft,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: DashUi.line)),
      ),
      child: child,
    );
  }
}
