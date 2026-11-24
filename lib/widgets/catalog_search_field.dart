import 'dart:async';

import 'package:flutter/material.dart';

import '../services/line_items_api.dart';
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

/// Which section of the search list an entry sits in.
String catalogSectionOf(CatalogEntry e) => e.isService ? 'Services' : 'Products';

/// The matches in sections, Services and Products (user 2026-11-20: sorted, under heading labels). Each section keeps
/// the server's best-first order (its ranking, billed services first); the section holding the best match comes first.
List<CatalogEntry> groupCatalogMatches(List<CatalogEntry> ranked) {
  final sections = <String, List<CatalogEntry>>{};
  for (final e in ranked) {
    (sections[catalogSectionOf(e)] ??= []).add(e);
  }
  return [for (final s in sections.values) ...s];
}

/// "Search the catalog to add a line": type part of a name or a SKU, matches drop down as you type (best first),
/// arrow keys and Enter pick one. The field keeps focus after a pick, so several lines go in one after another.
class CatalogSearchField extends StatefulWidget {
  /// The search box's height, fixed, so the buttons beside it can be exactly as tall (round 3, 2026-11-13: a field's
  /// own height comes from its font, and its intrinsic height, which a Row stretched to, is taller than it draws).
  static const height = 40.0;

  /// The room the results need under the box (the list is at most 440 px, with its margins). When the box sits closer
  /// than this to the window's bottom, the page is scrolled up to make it; a page whose search is its last part adds
  /// [CatalogSearchRoom] under it so there is page to scroll.
  static const roomBelow = 460.0;

  /// How many catalog search fields have the keyboard (0 or 1): a page's [CatalogSearchRoom] follows it.
  static final typing = ValueNotifier<int>(0);

  final ValueChanged<CatalogChoice> onPick;

  /// Kept for the callers; the results no longer show price or cost (user 2026-11-20).
  final bool showCost;

  /// Swappable for tests; the real search is [LineItemsApi.searchCatalog].
  final Future<List<CatalogEntry>> Function(String q)? search;
  final FocusNode? focusNode;

  /// The words in the empty box (a job's table: "Add a line: ...").
  final String hint;

  /// Whether "Add a custom line" is offered (a service package's products are catalog products only, 2026-11-24).
  final bool allowCustom;
  const CatalogSearchField({
    super.key,
    required this.onPick,
    required this.showCost,
    this.search,
    this.focusNode,
    this.hint = 'Add a line: search products and services by name or SKU',
    this.allowCustom = true,
  });

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

  /// Whether this field is counted in [CatalogSearchField.typing].
  bool _counted = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  void _focusChanged() {
    final has = _focus.hasFocus;
    if (has == _counted) return;
    _counted = has;
    CatalogSearchField.typing.value += has ? 1 : -1;
  }

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    if (_counted) {
      _counted = false;
      // After this frame: the tree is locked while it is taken down, and the room under the page listens.
      scheduleMicrotask(() => CatalogSearchField.typing.value -= 1);
    }
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
      // An inactive product or service is never offered for a new line (the server leaves them out too; this holds even
      // if one slips through). Lines already on a record are their own copy and don't depend on this.
      final found = groupCatalogMatches([
        for (final e in await (widget.search ?? LineItemsApi.searchCatalog)(q))
          if (e.active) e,
      ]);
      out = [
        for (final e in found) CatalogChoice.entry(e),
        if (found.isEmpty)
          CatalogChoice.message(widget.allowCustom ? 'Nothing in the catalog matches. Add it as a custom line below.' : 'Nothing in the catalog matches.'),
        if (widget.allowCustom) CatalogChoice.custom(q),
      ];
    } catch (e) {
      out = [CatalogChoice.message('Couldn\'t search the catalog: $e'), if (widget.allowCustom) CatalogChoice.custom(q)];
    }
    if (ticket != _asked) return _last;
    _lastQ = q;
    _last = out;
    // After the frame that opens the list: the field's own keep-the-caret-in-view scroll runs in that frame and would
    // cancel a scroll started now.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _makeRoomBelow();
    });
    return out;
  }

  void _picked(CatalogChoice c) {
    if (!c.pickable) return;
    widget.onPick(c);
    _controller.clear();
    _lastQ = '';
    _last = const [];
    _hovered = null;
    _focus.requestFocus();
    // In the browser, an Enter pick still lost the keyboard a moment later: focus fell back to the page's selection
    // area after the line went in (traced in real Chrome 2026-11-20; a mouse pick kept it, and the widget tests never
    // saw it). So once the frame has settled, the box takes it back, unless the person has moved on to another box.
    void again() {
      if (!mounted || _focus.hasFocus) return;
      final now = FocusManager.instance.primaryFocus?.context;
      final typing = now != null && now.mounted && (now.widget is EditableText || now.findAncestorWidgetOfExactType<EditableText>() != null);
      if (!typing) _focus.requestFocus();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // The autocomplete keeps the picked search's matches until its text changes, and the text was already empty, so
      // when the box took the keyboard back the old list opened again under an empty box. A change and back, in one
      // frame, has it work its matches out again (none), so nothing shows until the next search is typed.
      _controller.text = ' ';
      _controller.clear();
      again();
    });
    Future<void>.delayed(const Duration(milliseconds: 150), again);
  }

  /// The option the pointer last moved the highlight to: the list doesn't scroll to it (it is under the pointer already).
  int? _hovered;

  /// The pointer over option [i] makes it THE highlighted option, the one Enter picks, so only one row is ever lit (the
  /// arrow keys' choice and the pointer's used to be lit at once, and Enter took the keyboard's: found in real Chrome
  /// 2026-11-20). The autocomplete keeps its highlight to itself; its arrow-key intents move it, on the field's context.
  void _hover(int i, int current) {
    final ctx = _fieldKey.currentContext;
    if (ctx == null || i == current) return;
    _hovered = i;
    final intent = i > current ? const AutocompleteNextOptionIntent() : const AutocompletePreviousOptionIntent();
    for (var n = (i - current).abs(); n > 0; n--) {
      Actions.maybeInvoke(ctx, intent);
    }
  }

  /// The list drops down under the field. When the field sits too low for it (under [CatalogSearchField.roomBelow] to
  /// the window's bottom), the page scrolls the field up, as far as the page can go (see [CatalogSearchRoom] for a
  /// field at the very end of its page).
  void _makeRoomBelow() {
    final fieldContext = _fieldKey.currentContext;
    final box = fieldContext?.findRenderObject();
    final overlay = Overlay.maybeOf(context)?.context.findRenderObject();
    if (fieldContext == null || box is! RenderBox || overlay is! RenderBox || !box.hasSize) return;
    final bottom = box.localToGlobal(Offset(0, box.size.height), ancestor: overlay).dy;
    final short = CatalogSearchField.roomBelow - (overlay.size.height - bottom);
    if (short <= 0) return;
    final position = Scrollable.maybeOf(fieldContext)?.position;
    if (position == null) return;
    final to = (position.pixels + short).clamp(position.minScrollExtent, position.maxScrollExtent);
    if (to == position.pixels) return;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce) {
      position.jumpTo(to);
    } else {
      position.animateTo(to, duration: const Duration(milliseconds: 180), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<CatalogChoice>(
      textEditingController: _controller,
      focusNode: _focus,
      optionsBuilder: _options,
      displayStringForOption: (_) => '',
      onSelected: _picked,
      // The list always drops down under the field (user 2026-11-20); _makeRoomBelow scrolls the page up when the field
      // sits too low for it.
      optionsViewOpenDirection: OptionsViewOpenDirection.down,
      fieldViewBuilder: (context, controller, focus, onSubmit) => TextField(
        key: _fieldKey,
        controller: controller,
        focusNode: focus,
        onSubmitted: (_) => onSubmit(),
        // Enter picks the highlighted match and the box keeps the keyboard for the next one. Without this, the field's
        // "done" action unfocused it right after the pick asked for focus back, so the next line typed went nowhere
        // (found in real Chrome 2026-11-20; a pick with the mouse kept focus).
        onEditingComplete: () {},
        style: const TextStyle(fontSize: 13.5, color: DashUi.ink),
        textAlignVertical: TextAlignVertical.center,
        // A plus and the hint in an outlined box, so it reads as something to click (user 2026-11-13), in the same quiet
        // hairline as the line boxes above it (user 2026-11-13 pass 5), a light fill under the pointer, ink while typing.
        decoration: InputDecoration(
          isDense: true,
          // Desktop and web are compact by default, which drew this outline 4 px inside its 40 px box, shorter than the
          // "Tax, discounts & fees" button beside it (seen in real Chrome 2026-11-20; the tests run as Android).
          visualDensity: VisualDensity.standard,
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0),
          hoverColor: DashUi.faint.withValues(alpha: 0.6),
          hintText: widget.hint,
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
        // Rows to draw: a heading over each section of matches (its name, how many, and "Price" over the price
        // column), a rule before the custom line. Headings aren't options, so the arrow keys step over them.
        final counts = <String, int>{};
        for (final c in list) {
          if (c.entry != null) counts.update(catalogSectionOf(c.entry!), (n) => n + 1, ifAbsent: () => 1);
        }
        final rows = <Object>[]; // a String heading, the int index of an option, or a _Rule
        String? section;
        for (var i = 0; i < list.length; i++) {
          final e = list[i].entry;
          if (e != null && catalogSectionOf(e) != section) {
            section = catalogSectionOf(e);
            rows.add(section);
          } else if (list[i].custom != null && counts.isNotEmpty) {
            rows.add(const _Rule());
          }
          rows.add(i);
        }
        // No Align of its own: the autocomplete lines the list up under the field, and it grows down out of it.
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: PsMenuEntrance(
            up: false,
            child: Container(
              decoration: psMenuPanelDecoration(),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: Material(
                  type: MaterialType.transparency,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640, maxHeight: 440),
                    child: ListView.builder(
                      padding: const EdgeInsets.all(6),
                      shrinkWrap: true,
                      itemCount: rows.length,
                      itemBuilder: (context, r) {
                        final row = rows[r];
                        if (row is String) return _SectionHeading(label: row, count: counts[row] ?? 0);
                        if (row is _Rule) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 5, horizontal: 4),
                            child: Divider(height: 1, thickness: 1, color: DashUi.line),
                          );
                        }
                        final i = row as int;
                        final current = AutocompleteHighlightedOption.of(context);
                        final highlighted = current == i;
                        if (highlighted && _hovered != i) {
                          // Keep the arrow keys' choice in view (the list is taller than its box once headings are in).
                          // Only when it is out of view, and the first option shows its heading too (back to the top).
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (!context.mounted) return;
                            final position = Scrollable.maybeOf(context)?.position;
                            if (i == 0 && position != null) {
                              position.jumpTo(position.minScrollExtent);
                              return;
                            }
                            Scrollable.ensureVisible(context, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
                            Scrollable.ensureVisible(context, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
                          });
                        }
                        return _ChoiceRow(
                          choice: list[i],
                          highlighted: highlighted,
                          onTap: () => onSelected(list[i]),
                          onHover: list[i].pickable ? () => _hover(i, AutocompleteHighlightedOption.of(context)) : null,
                        );
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

class _Rule {
  const _Rule();
}

/// A section's heading in the search list: its name and how many matches, in the weight of the block's menu headings
/// ([PsMenuHeading]).
class _SectionHeading extends StatelessWidget {
  final String label;
  final int count;
  const _SectionHeading({required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    // Bigger and heavier than the names under it, with a rule beneath, so each section reads as its own block (user
    // 2026-11-20: at 12 px the headings blended into the list).
    const style = TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: DashUi.ink, height: 1.3);
    return Semantics(
      header: true,
      child: Container(
        margin: const EdgeInsets.fromLTRB(4, 8, 4, 4),
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: DashUi.line)),
        ),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: label),
              TextSpan(
                text: '  $count',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.subtle),
              ),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      ),
    );
  }
}

/// One result: its name, and under it a product's SKU and stock, or a service's tax hint and what it replaced. No
/// icon, usage, category, price or cost (user 2026-11-20): the line's price and cost show once it is added.
class _ChoiceRow extends StatelessWidget {
  final CatalogChoice choice;
  final bool highlighted;
  final VoidCallback onTap;

  /// The pointer came over the row: it becomes the highlighted one (see _CatalogSearchFieldState._hover).
  final VoidCallback? onHover;
  const _ChoiceRow({required this.choice, required this.highlighted, required this.onTap, this.onHover});

  static const _metaText = TextStyle(fontSize: 12, color: DashUi.subtle);

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
      );
    }
    final e = choice.entry!;
    final List<InlineSpan> meta;
    String? lineage;
    if (e.isService) {
      // Taxed on some of its billed jobs and not others: the line starts untaxed, so check it.
      meta = [
        if (e.taxDefault == 'mixed')
          const TextSpan(
            text: 'tax varies',
            style: TextStyle(fontWeight: FontWeight.w600, color: DashUi.amberText),
          ),
      ];
      // A renamed line says what it replaced (once it has taken over: the old entry is no longer offered) or what it
      // was split from.
      final variantOf = e.variantOf;
      lineage = e.replaces.isNotEmpty
          ? 'Replaces ${e.replaces.map((r) => r.name).join(', ')}'
          : variantOf != null
          ? 'Renamed line of ${variantOf.name}'
          : null;
    } else {
      final text = [if (e.sku.isNotEmpty) 'SKU ${e.sku}', if (e.stock != null) '${e.stock} in stock'].join('  ·  ');
      meta = [if (text.isNotEmpty) TextSpan(text: text)];
    }
    return _tap(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
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
            Text.rich(
              TextSpan(children: meta),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _metaText,
            ),
          if (lineage != null) Text(lineage, maxLines: 1, overflow: TextOverflow.ellipsis, style: _metaText),
        ],
      ),
    );
  }

  /// A pickable row: a rounded highlight inset in the list (the one highlighted option: the arrow keys' choice, or the
  /// pointer's, which moves it), a touch darker while pressed, as the block's menus have it. No hover colour of its own:
  /// the pointer moves the highlight, so two rows are never lit at once.
  Widget _tap({required EdgeInsets padding, required Widget child}) => InkWell(
    mouseCursor: WidgetStateMouseCursor.clickable,
    onTap: onTap,
    onHover: (inside) {
      if (inside) onHover?.call();
    },
    borderRadius: BorderRadius.circular(6),
    hoverColor: Colors.transparent,
    highlightColor: DashUi.line.withValues(alpha: 0.6),
    splashFactory: NoSplash.splashFactory,
    child: Ink(
      decoration: BoxDecoration(color: highlighted ? DashUi.faint : Colors.white.withValues(alpha: 0), borderRadius: BorderRadius.circular(6)),
      padding: padding,
      child: child,
    ),
  );
}

/// Blank page at the end of a page that holds a [CatalogSearchField], while a search has the keyboard: the page can
/// then scroll the field up and the results drop down in full. Without it a page with little under its search had
/// nothing to scroll to, and the results were squeezed into the strip between the field and the window's bottom (the
/// service page's PRODUCTS USED search, 2026-11-24: one 38 px row, nothing readable; a job's "Add a line" got about three
/// rows). Put it last in the page's scrolling content.
///
/// It never moves what is on screen. It appears in full when a search takes the keyboard (below the window, so nothing
/// moves). When the search lets go, only the part below the window goes at once; what is in view stays and goes as the
/// page is scrolled up past it (checked in Chrome 2026-11-24: taking it all away at once slid the page 383 px down right
/// after a click into a box above).
///
/// [focusNode] ties it to one field; without one it follows every catalog search ([CatalogSearchField.typing]).
class CatalogSearchRoom extends StatefulWidget {
  final FocusNode? focusNode;
  const CatalogSearchRoom({super.key, this.focusNode});

  @override
  State<CatalogSearchRoom> createState() => _CatalogSearchRoomState();
}

class _CatalogSearchRoomState extends State<CatalogSearchRoom> {
  Listenable get _source => widget.focusNode ?? CatalogSearchField.typing;
  bool get _open => widget.focusNode?.hasFocus ?? CatalogSearchField.typing.value > 0;

  /// The room's height now: [CatalogSearchField.roomBelow] while a search has the keyboard, then what is still in view.
  double _height = 0;

  /// The page's scroll position, followed while some room is left over after the search let go.
  ScrollPosition? _position;

  @override
  void initState() {
    super.initState();
    _source.addListener(_changed);
    _height = _open ? CatalogSearchField.roomBelow : 0;
  }

  @override
  void didUpdateWidget(CatalogSearchRoom old) {
    super.didUpdateWidget(old);
    final was = old.focusNode ?? CatalogSearchField.typing;
    if (was != _source) {
      was.removeListener(_changed);
      _source.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _source.removeListener(_changed);
    _follow(null);
    super.dispose();
  }

  void _follow(ScrollPosition? p) {
    if (p == _position) return;
    _position?.removeListener(_scrolled);
    _position = p;
    _position?.addListener(_scrolled);
  }

  /// How much of the room is in view: from its top to the bottom of the page's viewport (0 when it is below it).
  double _inView() {
    final box = context.findRenderObject();
    final scrollable = Scrollable.maybeOf(context);
    final viewport = scrollable?.context.findRenderObject();
    if (box is! RenderBox || !box.attached || viewport is! RenderBox || !viewport.attached) return 0;
    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = viewport.localToGlobal(Offset(0, viewport.size.height)).dy;
    return (bottom - top).clamp(0.0, _height);
  }

  void _changed() {
    if (!mounted) return;
    if (_open) {
      _follow(null);
      if (_height != CatalogSearchField.roomBelow) setState(() => _height = CatalogSearchField.roomBelow);
      return;
    }
    // Let go: keep only what is in view, then follow the page as it scrolls.
    final keep = _inView();
    setState(() => _height = keep);
    _follow(keep > 0 ? Scrollable.maybeOf(context)?.position : null);
  }

  bool _measuring = false;

  /// The page scrolled: once it is laid out at its new offset (positions read before that are the old ones), the room
  /// keeps only what is still in view.
  void _scrolled() {
    if (!mounted || _open || _measuring) return;
    _measuring = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measuring = false;
      if (!mounted || _open) return;
      final keep = _inView();
      if (keep < _height) setState(() => _height = keep);
      if (keep <= 0) _follow(null);
    });
  }

  @override
  Widget build(BuildContext context) => SizedBox(key: const ValueKey('catalog-search-room'), height: _height);
}
