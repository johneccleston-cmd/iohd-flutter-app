// Building blocks for flat, full-width list screens (payroll, team, inventory): the ribbon on top, then plain
// sections separated by hairlines. No cards. Dashboards keep their own cards in dashboard_kit.dart.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph, RenderProxyBox;
import 'package:intl/intl.dart';

import '../theme/app_theme.dart';
import 'app_dialog.dart';
import 'app_ribbon.dart';
import 'dashboard_kit.dart';

/// The ribbon every full screen starts with (the app's standard [AppRibbon]): the page's menu [icon] on a tile, the
/// title in capitals on the left, actions on the right.
class PageBanner extends StatelessWidget {
  final String title;
  final IconData? icon;
  final List<Widget> actions;

  /// Set it while a reload is out and the ribbon runs its refresh motion, like a dashboard's.
  final RibbonActivity? activity;

  /// Right after the title: the page's views as [RibbonTabs] (the Product Catalog's), or badges.
  final Widget? titleTrailing;

  const PageBanner({super.key, required this.title, this.icon, this.actions = const [], this.activity, this.titleTrailing});

  @override
  Widget build(BuildContext context) {
    return AppRibbon(
      title: title.toUpperCase(),
      icon: icon,
      compactSide: 16,
      activity: activity,
      titleTrailing: titleTrailing,
      controls: [
        for (var i = 0; i < actions.length; i++) ...[if (i > 0) const SizedBox(width: 8), actions[i]],
      ],
    );
  }

  static final ButtonStyle _buttonStyle = FilledButton.styleFrom(
    minimumSize: const Size(0, 40),
    padding: const EdgeInsets.symmetric(horizontal: 14),
    backgroundColor: Colors.white,
    foregroundColor: DashUi.ink,
    // Off (a request is out, or the page is already in that state): still readable on the navy.
    disabledBackgroundColor: Colors.white.withValues(alpha: 0.14),
    disabledForegroundColor: RibbonColors.quiet,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    textStyle: const TextStyle(fontFamily: AppTheme.fontFamily, fontFamilyFallback: AppTheme.fontFamilyFallback, fontSize: 12.5, fontWeight: FontWeight.w700),
  );

  /// A white button that stays visible on the dark banner.
  static Widget button({required IconData icon, required String label, required VoidCallback? onPressed}) {
    return FilledButton.icon(icon: Icon(icon, size: 18), label: Text(label), style: _buttonStyle, onPressed: onPressed);
  }

  /// A white "More" button, like [button], that drops down the page's less-used actions (Job detail's Delete). Off
  /// when no item can be picked.
  static Widget more({required List<BannerMenuItem> items, String label = 'More'}) => _BannerMore(items: items, label: label, style: _buttonStyle);

  /// A refresh icon for the banner.
  static Widget refresh({required VoidCallback? onPressed}) => RibbonRefreshButton(onPressed: onPressed);
}

/// One action in a [PageBanner.more] menu. [danger]: a destructive one (Delete), in red. [onPressed] null: shown, off.
class BannerMenuItem {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool danger;
  const BannerMenuItem({required this.icon, required this.label, required this.onPressed, this.danger = false});
}

class _BannerMore extends StatelessWidget {
  final List<BannerMenuItem> items;
  final String label;
  final ButtonStyle style;
  const _BannerMore({required this.items, required this.label, required this.style});

  @override
  Widget build(BuildContext context) {
    final any = items.any((i) => i.onPressed != null);
    return MenuAnchor(
      alignmentOffset: const Offset(0, 6),
      menuChildren: [
        for (final i in items)
          MenuItemButton(
            onPressed: i.onPressed,
            leadingIcon: Icon(i.icon, size: 18, color: i.onPressed == null ? DashUi.muted : (i.danger ? DashUi.redText : DashUi.ink)),
            style: MenuItemButton.styleFrom(minimumSize: const Size(180, 40), padding: const EdgeInsets.symmetric(horizontal: 14)),
            child: Text(
              i.label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: i.onPressed == null ? DashUi.muted : (i.danger ? DashUi.redText : DashUi.ink),
              ),
            ),
          ),
      ],
      builder: (context, controller, _) => FilledButton.icon(
        style: style,
        iconAlignment: IconAlignment.end,
        icon: Icon(controller.isOpen ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18),
        label: Text(label),
        onPressed: any ? () => controller.isOpen ? controller.close() : controller.open() : null,
      ),
    );
  }
}

/// The standard body for every full screen: everything below the ribbon sits on a white sheet that runs edge to edge,
/// lined up with the navy ribbon's left and right edges (user 2026-11-24: the outer side margin is gone app-wide; before
/// that an 8 px [edge] of backdrop showed on each side). Wrap the whole body under the ribbon in it (the 3 px loading
/// strip can stay above it, full width under the ribbon). Content spacing belongs inside the page, not around the sheet.
class PageSheet extends StatelessWidget {
  /// The gutter between a block page's blocks (Job detail). No longer used as an outer margin.
  static const double edge = 8;

  /// The sheet's outer margin: none (user 2026-11-24).
  static const EdgeInsets padding = EdgeInsets.zero;

  final Widget child;

  /// The sheet itself. White on every flat page; a page built of blocks can pass the backdrop to let its gutters show.
  final Color color;

  const PageSheet({super.key, required this.child, this.color = Colors.white});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppTheme.bgColor,
      child: Padding(
        padding: padding,
        // A Material, not a ColoredBox, so ListTile hovers and ink splashes inside still show.
        child: Material(color: color, child: child),
      ),
    );
  }
}

class FlatStat {
  final String label;
  final String value;
  final Color? tone; // null = ink

  /// A figure that counts up to [count] when it lands and again when it changes, shown through [format].
  final double? count;
  final String Function(double)? format;

  const FlatStat(this.label, this.value, {this.tone}) : count = null, format = null;
  const FlatStat.counted(this.label, double this.count, String Function(double) this.format, {this.tone}) : value = '';
}

/// [FlatStat.counted]'s figure. Lands at once with reduced motion; a screen reader gets the final figure.
class _CountUp extends StatelessWidget {
  final double value;
  final String Function(double) format;
  final TextStyle style;
  const _CountUp({required this.value, required this.format, required this.style});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: format(value),
      excludeSemantics: true,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: value),
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 600),
        curve: Curves.easeOutCubic,
        builder: (_, v, _) => Text(format(v), maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
      ),
    );
  }
}

/// A summary strip: label over value, segments split by hairlines, one hairline underneath.
class FlatStats extends StatelessWidget {
  final List<FlatStat> stats;
  const FlatStats({super.key, required this.stats});

  Widget _value(FlatStat stat) {
    final style = TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.5,
      color: stat.tone ?? DashUi.ink,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final count = stat.count;
    if (count != null) return _CountUp(value: count, format: stat.format!, style: style);
    return Text(stat.value, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final perRow = c.maxWidth < 600 ? 2 : stats.length;
        final w = c.maxWidth / perRow;
        return Container(
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: DashUi.line))),
          child: Wrap(
            children: [
              for (var i = 0; i < stats.length; i++)
                Container(
                  width: w,
                  padding: EdgeInsets.fromLTRB(i % perRow == 0 ? 24 : 20, 14, 12, 14),
                  decoration: BoxDecoration(
                    border: i % perRow == 0 ? null : const Border(left: BorderSide(color: DashUi.line)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stats[i].label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.slate),
                      ),
                      const SizedBox(height: 2),
                      _value(stats[i]),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The search box used above flat tables. [onClear] adds the clear button: pass it only while there is text to clear.
InputDecoration flatSearchDecoration(String hint, {VoidCallback? onClear}) => InputDecoration(
  hintText: hint,
  hintStyle: const TextStyle(color: DashUi.muted, fontSize: 14, fontWeight: FontWeight.w500),
  prefixIcon: const Icon(Icons.search_rounded, size: 20, color: DashUi.slate),
  suffixIcon: onClear == null
      ? null
      : IconButton(
          tooltip: 'Clear search',
          icon: const Icon(Icons.close_rounded, size: 18, color: DashUi.slate),
          onPressed: onClear,
        ),
  isDense: true,
  filled: true,
  fillColor: DashUi.faint,
  contentPadding: const EdgeInsets.symmetric(vertical: 11),
  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: DashUi.ink)),
);

/// A filter above a flat table: white, and filled with ink when picked. A filter, not a tab, so the tab rule's ink label
/// does not apply.
class FlatFilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onSelected;
  final String? tooltip;
  const FlatFilterChip({super.key, required this.label, required this.selected, required this.onSelected, this.tooltip});

  @override
  Widget build(BuildContext context) {
    // Not selectable text: the app-wide selection's I-beam would replace the click cursor.
    return SelectionContainer.disabled(
      child: ChoiceChip(
        label: Text(label),
        tooltip: tooltip,
        selected: selected,
        showCheckmark: false,
        labelStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: selected ? Colors.white : DashUi.ink),
        backgroundColor: Colors.white,
        selectedColor: DashUi.ink,
        side: BorderSide(color: selected ? DashUi.ink : DashUi.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        onSelected: (_) => onSelected(),
      ),
    );
  }
}

class FlatCol {
  final String label;
  final int flex;
  final bool right;

  /// What a [FlatTableHeader] sorts this column by. Null: not sortable.
  final String? sortKey;
  const FlatCol(this.label, {this.flex = 1, this.right = false, this.sortKey});
}

Widget _flatCell(FlatCol col, Widget child) => Expanded(
  flex: col.flex,
  child: Padding(
    // Keeps a right-aligned figure from running into the column after it.
    padding: EdgeInsets.only(right: col.right ? 32 : 8),
    child: Align(alignment: col.right ? Alignment.centerRight : Alignment.centerLeft, child: child),
  ),
);

/// A flat table's shaded header row, on its own so a long table can pin it. With [onSort], a column that has a sort key
/// is a button and the column in [sortKey] shows an arrow.
class FlatTableHeader extends StatelessWidget {
  final List<FlatCol> columns;
  final bool striped;
  final String? sortKey;
  final bool ascending;
  final ValueChanged<String>? onSort;
  const FlatTableHeader({super.key, required this.columns, this.striped = false, this.sortKey, this.ascending = false, this.onSort});

  Widget _label(FlatCol col) {
    final text = Text(
      col.label,
      textAlign: col.right ? TextAlign.right : TextAlign.left,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: DashUi.ink),
    );
    final key = col.sortKey;
    if (key == null || onSort == null) return text;
    final active = key == sortKey;
    final arrow = Icon(ascending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 14, color: DashUi.ink);
    return SelectionContainer.disabled(
      child: Semantics(
        button: true,
        value: active ? (ascending ? 'Sorted ascending' : 'Sorted descending') : null,
        child: InkWell(
          mouseCursor: WidgetStateMouseCursor.clickable,
          onTap: () => onSort!(key),
          borderRadius: BorderRadius.circular(6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // On a right-aligned column the arrow goes first, so the label stays over its figures.
              if (active && col.right) ...[arrow, const SizedBox(width: 4)],
              Flexible(child: text),
              if (active && !col.right) ...[const SizedBox(width: 4), arrow],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: striped ? DashUi.rowHead : DashUi.rowStripe, // a striped table needs a header darker than its stripes
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      child: Row(children: [for (final col in columns) _flatCell(col, _label(col))]),
    );
  }
}

/// One flat table row, on its own so a long table can build its rows lazily. [index] picks the stripe.
class FlatTableRow extends StatelessWidget {
  final List<FlatCol> columns;
  final List<Widget> cells;
  final int index;
  final bool striped;
  final VoidCallback? onTap;
  const FlatTableRow({super.key, required this.columns, required this.cells, this.index = 0, this.striped = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      mouseCursor: WidgetStateMouseCursor.clickable,
      onTap: onTap,
      hoverColor: striped ? DashUi.rowHover : DashUi.rowStripe,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        decoration: BoxDecoration(
          color: striped && index.isOdd ? DashUi.rowStripe : null,
          border: const Border(top: BorderSide(color: DashUi.rowRule)),
        ),
        child: Row(children: [for (var i = 0; i < columns.length; i++) _flatCell(columns[i], cells[i])]),
      ),
    );
  }
}

/// Full-width table: shaded header row, hairline between rows, same type as the payroll register.
class FlatTable extends StatelessWidget {
  final List<FlatCol> columns;
  final List<List<Widget>> rows;

  /// Makes each row clickable. Return nothing for a row that has nowhere to go.
  final void Function(int row)? onRowTap;

  /// Shades every other row so a long table is easier to follow across.
  final bool striped;
  const FlatTable({super.key, required this.columns, required this.rows, this.onRowTap, this.striped = false});

  @override
  Widget build(BuildContext context) {
    // Below this width the columns would be crushed, so the table scrolls sideways instead.
    return LayoutBuilder(
      builder: (context, c) {
        final table = _table();
        if (c.maxWidth >= minWidth) return table;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: minWidth, child: table),
        );
      },
    );
  }

  static const double minWidth = 760;

  Widget _table() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FlatTableHeader(columns: columns, striped: striped),
        for (var r = 0; r < rows.length; r++)
          FlatTableRow(columns: columns, cells: rows[r], index: r, striped: striped, onTap: onRowTap == null ? null : () => onRowTap!(r)),
        Container(height: 1, color: DashUi.line),
      ],
    );
  }
}

/// New rows settling in one after another, top first, as [run] goes 0 to 1. Only the first screenful waits its turn.
Widget flatRowEntrance(Animation<double> run, int index, Widget child) {
  final start = math.min(index, 10) * 0.05;
  final t = run.drive(CurveTween(curve: Interval(start, start + 0.5, curve: Curves.easeOutCubic)));
  return FadeTransition(
    opacity: t,
    child: SlideTransition(position: t.drive(Tween(begin: const Offset(0, 0.12), end: Offset.zero)), child: child),
  );
}

/// Hover text that only appears when the text inside [child] is cut short with an ellipsis. A tooltip that just repeats
/// what is already on screen is noise (user rule 2026-11-23), so a name that fits shows no tooltip at all, and one cut
/// off by a narrow column shows its full wording. The first [Text] found under [child] is the one checked.
class OverflowTooltip extends StatefulWidget {
  final String message;
  final Widget child;
  const OverflowTooltip({super.key, required this.message, required this.child});

  @override
  State<OverflowTooltip> createState() => _OverflowTooltipState();
}

class _OverflowTooltipState extends State<OverflowTooltip> {
  bool _cut = false;

  bool _measure() {
    RenderParagraph? text;
    void visit(RenderObject o) {
      if (text != null) return;
      if (o is RenderParagraph) {
        text = o;
        return;
      }
      o.visitChildren(visit);
    }

    final root = context.findRenderObject();
    if (root != null) visit(root);
    final t = text;
    return t != null && t.hasSize && t.didExceedMaxLines;
  }

  // Checked after every build, whenever the cell's width changes (a window resize does not rebuild it), and on hover.
  void _sync() {
    if (!mounted) return;
    final cut = _measure();
    if (cut != _cut) setState(() => _cut = cut);
  }

  void _syncAfterFrame() => WidgetsBinding.instance.addPostFrameCallback((_) => _sync());

  @override
  Widget build(BuildContext context) {
    _syncAfterFrame();
    return MouseRegion(
      onEnter: (_) => _sync(),
      child: _SizeProbe(
        onResize: _syncAfterFrame,
        child: Tooltip(
          message: _cut ? widget.message : '',
          waitDuration: const Duration(milliseconds: 400),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Calls [onResize] when its laid-out size changes. Unlike a LayoutBuilder it is safe inside intrinsic sizing.
class _SizeProbe extends SingleChildRenderObjectWidget {
  final VoidCallback onResize;
  const _SizeProbe({required this.onResize, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSizeProbe(onResize);

  @override
  void updateRenderObject(BuildContext context, _RenderSizeProbe renderObject) => renderObject.onResize = onResize;
}

class _RenderSizeProbe extends RenderProxyBox {
  VoidCallback onResize;
  Size? _last;
  _RenderSizeProbe(this.onResize);

  @override
  void performLayout() {
    super.performLayout();
    if (size != _last) {
      _last = size;
      onResize();
    }
  }
}

/// A link inside a table cell. Not selectable text: the app-wide selection's I-beam would replace the click cursor.
/// [tip] is only for hover text that adds something the link does not say; without it the full link text shows on
/// hover only when the column cuts it short.
class FlatLink extends StatelessWidget {
  final String text;
  final String? tip;
  final VoidCallback onTap;
  const FlatLink(this.text, {super.key, this.tip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tip = this.tip;
    final link = SelectionContainer.disabled(
      child: Semantics(
        link: true,
        child: InkWell(
          mouseCursor: WidgetStateMouseCursor.clickable,
          onTap: onTap,
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: flatCellStyle.copyWith(
              color: DashUi.blue,
              decoration: TextDecoration.underline,
              decorationColor: DashUi.blue.withValues(alpha: 0.4),
            ),
          ),
        ),
      ),
    );
    return tip == null ? OverflowTooltip(message: text, child: link) : Tooltip(message: tip, child: link);
  }
}

/// Pinned under a long table: where you are in the list and how to move, without scrolling to the end of it. One line in
/// a [compact] window, where every line it takes is a line of the list lost.
class FlatPager extends StatelessWidget {
  // Slim arrows keep the bar thin: 30 px square instead of the 40 px compact density gives.
  static final ButtonStyle _pagerButton = IconButton.styleFrom(
    minimumSize: const Size(30, 30),
    maximumSize: const Size(30, 30),
    padding: EdgeInsets.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  final int page;
  final int totalPages;
  final int total;
  final int firstRow; // the number of the first row shown
  final int rowsShown;
  final int pageSize;
  final bool busy;
  final bool compact;
  final ValueChanged<int> onPage;
  final ValueChanged<int> onPageSize;
  const FlatPager({
    super.key,
    required this.page,
    required this.totalPages,
    required this.total,
    required this.firstRow,
    required this.rowsShown,
    required this.pageSize,
    required this.busy,
    required this.compact,
    required this.onPage,
    required this.onPageSize,
  });

  @override
  Widget build(BuildContext context) {
    final count = NumberFormat.decimalPattern();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: DashUi.line))),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: compact ? 8 : 24,
        runSpacing: 4,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (!compact) ...[
                const Text('Rows', style: flatCellMuted),
                SizedBox(
                  width: 112,
                  child: AppSegmented<int>(dense: true, value: pageSize, options: const [(50, '50'), (100, '100')], onChanged: onPageSize),
                ),
              ],
              Text('${count.format(firstRow)}–${count.format(firstRow + rowsShown - 1)} of ${count.format(total)}', style: flatCellMuted),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton.outlined(
                tooltip: 'Previous page',
                visualDensity: VisualDensity.compact,
                style: _pagerButton,
                onPressed: busy || page <= 1 ? null : () => onPage(page - 1),
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12),
                child: Text('Page ${count.format(page)} of ${count.format(totalPages)}', style: flatCellMuted),
              ),
              IconButton.outlined(
                tooltip: 'Next page',
                visualDensity: VisualDensity.compact,
                style: _pagerButton,
                onPressed: busy || page >= totalPages ? null : () => onPage(page + 1),
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A reload failed over rows that are still the right list: they stay, and this says they may be out of date.
class FlatStaleNotice extends StatelessWidget {
  final String message;
  final bool busy;
  final VoidCallback onRetry;
  const FlatStaleNotice({super.key, required this.message, required this.busy, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
        child: Row(
          children: [
            const Icon(Icons.error_outline_rounded, size: 20, color: DashUi.redText),
            const SizedBox(width: 12),
            Expanded(
              child: Text(message, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.redText)),
            ),
            const SizedBox(width: 12),
            TextButton(
              onPressed: busy ? null : onRetry,
              style: TextButton.styleFrom(foregroundColor: DashUi.redText),
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

/// First load: grey rows shaped like the list (same columns, padding and stripes), so the page is not blank while the
/// server answers, and after [slow] a line saying why it is taking a while. Still under reduced motion (SkeletonPulse).
class FlatLoading extends StatelessWidget {
  final String label; // what a screen reader hears
  final List<int> flex; // the table's columns
  final bool compact;
  final bool slow;
  const FlatLoading({super.key, required this.label, required this.flex, required this.compact, required this.slow});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (slow)
          Semantics(
            liveRegion: true,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              color: DashUi.faint,
              child: const Text(
                'Waking up the server, this can take up to a minute.',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.slate),
              ),
            ),
          ),
        Semantics(
          label: label,
          child: SkeletonPulse(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!compact) Container(height: 40, color: DashUi.rowHead),
                for (var r = 0; r < 8; r++)
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 24, vertical: compact ? 12 : 17),
                    decoration: BoxDecoration(
                      color: r.isOdd ? DashUi.rowStripe : null,
                      border: const Border(top: BorderSide(color: DashUi.rowRule)),
                    ),
                    child: compact
                        ? const Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SkeletonBox(h: 14, r: 4),
                              SizedBox(height: 8),
                              FractionallySizedBox(alignment: Alignment.centerLeft, widthFactor: 0.6, child: SkeletonBox(h: 14, r: 4)),
                            ],
                          )
                        : Row(
                            children: [
                              for (final f in flex)
                                Expanded(
                                  flex: f,
                                  child: const Padding(padding: EdgeInsets.only(right: 24), child: SkeletonBox(h: 14, r: 4)),
                                ),
                            ],
                          ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Status text with a dot, instead of a filled pill.
class FlatStatus extends StatelessWidget {
  final String label;
  final Color color;
  const FlatStatus(this.label, this.color, {super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color)),
      ],
    );
  }
}

const TextStyle flatCellStyle = TextStyle(fontSize: 14.5, color: DashUi.ink);
const TextStyle flatCellBold = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: DashUi.ink);
const TextStyle flatCellMuted = TextStyle(fontSize: 14.5, color: DashUi.slate);
const List<FontFeature> flatFigures = [FontFeature.tabularFigures()];

/// Centered empty or failed state for a flat screen: icon, title, one line of explanation, and what to do next.
class FlatEmpty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  const FlatEmpty({super.key, required this.icon, required this.title, required this.message, this.action});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 56, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: DashUi.slate),
          const SizedBox(height: 16),
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: DashUi.ink)),
          const SizedBox(height: 6),
          Text(message, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14.5, color: DashUi.slate)),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}
