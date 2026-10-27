// The panel kit the dashboards share, lifted from the Collections dashboard (the reference design), so every page
// that fits the window without scrolling is built from the same pieces:
//
//   DashText, DashGeo   text styles with fixed line heights, and the heights they add up to at the current text size,
//                       so a page can work out which arrangement fits the window (text is never scaled down to fit)
//   DashPanel(+Header)  the white panel with a one-line title and an optional quieter note ("today")
//   DashPressable       anything you can click, or reach with Tab and open with Enter or Space
//   DashLink, DashDrillCard, DashBar, DashRows, DashBarRow, DashSegmented, DashChangeChip, DashSplitPanel
//   DashMonthChart      twelve months as bars (one or two series, stacked or side by side), last year's ticks, a
//                       line, an average; hover or the arrow keys read a month, a toggle switches between views
//
// The Collections dashboard still has its own private copies of the first few; they behave the same.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dashboard_data.dart';
import 'dashboard_kit.dart';

/// Space between panels.
const double dashGap = 14;

// =============================================================================
// TYPE AND GEOMETRY
// =============================================================================

/// Text styles for the panels. Every style sets its line height, so the heights in [DashGeo] are exact.
abstract final class DashText {
  static const tabular = [FontFeature.tabularFigures()];

  static const panelTitle = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w700,
    height: 1.3,
    letterSpacing: -0.1,
    color: DashUi.ink,
  );
  static const panelNote = TextStyle(fontSize: 13, fontWeight: FontWeight.w500, height: 1.3, color: DashUi.subtle);
  static const label = TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.3, color: DashUi.ink);
  static const name = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, height: 1.3, color: DashUi.ink);
  static const meta = TextStyle(fontSize: 12, fontWeight: FontWeight.w500, height: 1.3, color: DashUi.subtle);
  static const money = TextStyle(
    fontSize: 13.5,
    fontWeight: FontWeight.w700,
    height: 1.3,
    color: DashUi.ink,
    fontFeatures: tabular,
  );
  static const bigMoney = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w700,
    height: 1.2,
    color: DashUi.ink,
    fontFeatures: tabular,
  );
  static const link = TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.3, color: DashUi.blue);
  static const legend = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.3, color: DashUi.slate);
  static const empty = TextStyle(fontSize: 14, fontWeight: FontWeight.w500, height: 1.3, color: DashUi.slate);

  /// A column heading over a table of rows.
  static const column = TextStyle(fontSize: 12, fontWeight: FontWeight.w600, height: 1.3, color: DashUi.subtle);
}

/// Heights of the fixed pieces at the current text size, so a page can tell which arrangement fits the window and
/// give every panel at least what its rows need.
class DashGeo {
  final TextScaler s;

  /// A scorecard row (title, value and caption).
  final double tile;

  DashGeo.of(BuildContext context)
      : s = MediaQuery.textScalerOf(context),
        tile = dashTileHeight(context);

  double line(double size, [double height = 1.3]) => s.scale(size) * height;

  /// How much wider text is than at 100%, for columns sized to their text.
  double get k => s.scale(1);

  /// Panel padding (12 top and bottom) plus its 1px border top and bottom, and the gap under the title row.
  static const padV = 26.0;
  static const headerGap = 8.0;
  double get panelHeader => math.max(26.0, math.max(line(15), line(13) + 8));

  /// Everything in a panel above its rows.
  double get panelTop => padV + panelHeader + headerGap;

  /// A row on one line (a wide column), or two lines (label and amount over a bar, a narrow column).
  double get rowWide => math.max(34.0, line(13.5) + 14);
  double get rowTall => math.max(42.0, line(13.5) + line(12) + 9);

  /// A name with a line of detail under it.
  double get listRow => math.max(44.0, line(13.5) + line(12) + 10);

  /// A column-heading row over a table.
  double get columnHead => line(12) + 6;

  /// A panel of [n] rows of [rowH] (an empty panel keeps room for a two-line message).
  double rows(int n, double rowH) => panelTop + math.max(n, 2) * rowH;

  /// The one-row strip panel (title and split bar, then a row of figures), like "How customers paid".
  /// The +4 absorbs the half pixels text lines round up to.
  double get strip => panelTop + line(13) + 3 + line(15, 1.2) + 4;
}

/// The inner width a scorecard needs so its title, value and caption all show whole (AnimatedMetricCard's styles).
double dashTileTextWidth(BuildContext context, {required String title, required String value, String caption = ''}) {
  final s = MediaQuery.textScalerOf(context);
  // Text inherits the page's style (its font and letter spacing), so measure with it.
  final base = DefaultTextStyle.of(context).style;
  double w(String text, double size, FontWeight weight) => (TextPainter(
    text: TextSpan(text: text, style: base.merge(TextStyle(fontSize: size, fontWeight: weight))),
    textDirection: TextDirection.ltr,
    textScaler: s,
    maxLines: 1,
  )..layout())
      .width;
  return [
    w(title, 13, FontWeight.w600),
    w(value, 28, FontWeight.w800),
    if (caption.isNotEmpty) w(caption, 12, FontWeight.w500),
  ].reduce(math.max).ceilToDouble() + 2;
}

/// A scorecard's `sparkMinWidth`: its trend line (84 px and a 12 px gap) only shows when the words still fit beside it.
double dashSparkRoom(BuildContext context, {required String title, required String value, String caption = ''}) =>
    dashTileTextWidth(context, title: title, value: value, caption: caption) + 96;

/// The width of a whole scorecard whose words need [inner] (18 px padding each side and the 1 px border).
double dashTileWidth(double inner) => inner + 38;

// =============================================================================
// PANELS
// =============================================================================

/// White panel with a title row. With [fill], [child] takes the height left under the title.
class DashPanel extends StatelessWidget {
  final Widget header;
  final Widget child;
  final bool fill;
  const DashPanel({super.key, required this.header, required this.child, this.fill = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      decoration: DashUi.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          header,
          const SizedBox(height: DashGeo.headerGap),
          if (fill) Expanded(child: child) else child,
        ],
      ),
    );
  }
}

/// A one-line panel title, an optional quieter [note] after it ("today"), and something small on the right.
class DashPanelHeader extends StatelessWidget {
  final DashGeo g;
  final String title;
  final String? note;
  final Widget? trailing;

  /// Read with the title on hover: what the panel counts, in full.
  final String? tooltip;
  const DashPanelHeader({super.key, required this.g, required this.title, this.note, this.trailing, this.tooltip});

  @override
  Widget build(BuildContext context) {
    Widget text = Text.rich(
      TextSpan(
        children: [
          TextSpan(text: title, style: DashText.panelTitle),
          if (note != null) TextSpan(text: ' · $note', style: DashText.panelNote),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (tooltip != null) text = Tooltip(message: tooltip!, waitDuration: const Duration(milliseconds: 500), child: text);
    return SizedBox(
      height: g.panelHeader,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              label: note == null ? title : '$title, $note',
              child: ExcludeSemantics(child: Align(alignment: Alignment.centerLeft, child: text)),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ],
      ),
    );
  }
}

class DashEmptyNote extends StatelessWidget {
  final String text;
  const DashEmptyNote(this.text, {super.key});

  @override
  Widget build(BuildContext context) =>
      Center(child: Text(text, textAlign: TextAlign.center, style: DashText.empty));
}

/// The blue keyboard-focus ring (never shown after a click). Always a decoration, transparent when unfocused:
/// Container only wraps its child in a DecoratedBox when it has one, and adding that wrapper on focus would rebuild
/// everything inside from scratch (replaying a scorecard's entrance or a bar's growth).
BoxDecoration dashFocusRing(bool focused, BorderRadius radius) => BoxDecoration(
  borderRadius: radius,
  border: Border.all(color: focused ? DashUi.blue : Colors.transparent, width: 2),
);

// =============================================================================
// THINGS YOU CAN CLICK
// =============================================================================

/// Something you can click, or reach with Tab and open with Enter or Space: a pointer cursor, a hover state for
/// [builder] to draw, a blue ring for keyboard focus only, and one screen-reader button named [label]. Without
/// [onTap] it is plain content (a row with nothing behind it to open). [selected] marks one choice of a group.
class DashPressable extends StatefulWidget {
  final VoidCallback? onTap;
  final String label;
  final String? hint;
  final bool? selected;
  final BorderRadius radius;
  final Widget Function(bool hover) builder;
  const DashPressable({
    super.key,
    required this.onTap,
    required this.label,
    this.hint,
    this.selected,
    required this.radius,
    required this.builder,
  });

  @override
  State<DashPressable> createState() => _DashPressableState();
}

class _DashPressableState extends State<DashPressable> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final onTap = widget.onTap;
    if (onTap == null) {
      return Semantics(
        container: true,
        label: widget.label,
        child: ExcludeSemantics(child: widget.builder(false)),
      );
    }
    return Semantics(
      container: true,
      button: true,
      label: widget.label,
      hint: widget.hint,
      selected: widget.selected,
      inMutuallyExclusiveGroup: widget.selected == null ? null : true,
      onTap: onTap,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onTap();
              return null;
            },
          ),
        },
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // The tap is already on the button node above; a second one would split off an unlabelled node.
          excludeFromSemantics: true,
          onTap: onTap,
          child: ExcludeSemantics(
            child: Container(
              foregroundDecoration: dashFocusRing(_focus, widget.radius),
              child: SelectionContainer.disabled(child: widget.builder(_hover)),
            ),
          ),
        ),
      ),
    );
  }
}

/// "All 209 jobs ›": a small text link in a panel's title row.
class DashLink extends StatelessWidget {
  final String text;
  final String label;
  final VoidCallback? onTap;
  const DashLink({super.key, required this.text, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return DashPressable(
      onTap: onTap,
      label: label,
      radius: BorderRadius.circular(6),
      builder: (hover) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 2, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, style: DashText.link.copyWith(decoration: hover ? TextDecoration.underline : null)),
            const Icon(Icons.chevron_right_rounded, size: 18, color: DashUi.blue),
          ],
        ),
      ),
    );
  }
}

/// A scorecard that opens the list behind it. The chevron in the bottom corner says it can be opened.
class DashDrillCard extends StatelessWidget {
  final AnimatedMetricCard card;

  /// How many things the list holds, and what they are ("job"): nothing to open when zero.
  final int count;
  final String noun;
  final VoidCallback onOpen;
  const DashDrillCard({super.key, required this.card, required this.count, this.noun = 'job', required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final c = card;
    final open = count > 0;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return DashPressable(
      onTap: open ? onOpen : null,
      label: '${c.title}: ${c.value == null ? 'no figure yet' : c.format(c.value!)}. ${c.definition ?? c.caption}',
      hint: open ? 'Opens the list of ${dashCount(count, noun)}' : null,
      radius: BorderRadius.circular(12),
      builder: (hover) => Stack(
        fit: StackFit.expand,
        children: [
          c,
          if (open)
            Positioned(
              bottom: 8,
              right: 10,
              // Fades in with the card's own entrance.
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 900),
                curve: const Interval(0.4, 1),
                builder: (context, t, child) => Opacity(opacity: t, child: child),
                child: Icon(Icons.chevron_right_rounded, size: 20, color: hover ? c.valueColor : DashUi.subtle),
              ),
            ),
        ],
      ),
    );
  }
}

/// "1 job", "209 jobs", "1 category".
String dashCount(int n, String noun) {
  final s = n.abs().toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
  final consonantY = RegExp(r'[^aeiou]y$').hasMatch(noun);
  final plural = consonantY
      ? '${noun.substring(0, noun.length - 1)}ies'
      : (RegExp(r'(s|x|ch|sh)$').hasMatch(noun) ? '${noun}es' : '${noun}s');
  return '${n < 0 ? '-' : ''}$s ${n == 1 ? noun : plural}';
}

// =============================================================================
// BARS AND ROWS
// =============================================================================

/// A horizontal bar on a faint track, growing in once (still under reduced motion).
class DashBar extends StatelessWidget {
  final double fraction;
  final Color color;
  final double height;
  const DashBar({super.key, required this.fraction, required this.color, this.height = 8});

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return LayoutBuilder(
      builder: (context, c) => Container(
        height: height,
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(height / 2)),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: fraction.clamp(0.0, 1.0)),
          duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 700),
          curve: Curves.easeOutCubic,
          builder: (context, t, _) => Container(
            width: math.max(fraction > 0 ? height : 0.0, c.maxWidth * t),
            height: height,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(height / 2)),
          ),
        ),
      ),
    );
  }
}

/// One bar split into parts (stock health: active, low, dead), each part sized by its value.
class DashStackBar extends StatelessWidget {
  final List<(double, Color)> parts;
  final double height;
  const DashStackBar({super.key, required this.parts, this.height = 8});

  @override
  Widget build(BuildContext context) {
    final total = parts.fold<double>(0, (s, p) => s + math.max(0, p.$1));
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: Container(
        height: height,
        color: DashUi.faint,
        child: total <= 0
            ? null
            : Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final p in parts)
                    if (p.$1 > 0) Expanded(flex: math.max(1, (p.$1 / total * 1000).round()), child: ColoredBox(color: p.$2)),
                ],
              ),
      ),
    );
  }
}

/// Rows spread over a panel's height when it is given one (a little: never below [base], at most [base] + [give]),
/// or at [base] when the panel sizes to its content.
class DashRows extends StatelessWidget {
  final int count;
  final double base;
  final double give;
  final Widget Function(int i) row;
  const DashRows({super.key, required this.count, required this.base, required this.give, required this.row});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final h = c.maxHeight.isFinite && count > 0 ? (c.maxHeight / count).clamp(base, base + give).toDouble() : base;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [for (var i = 0; i < count; i++) SizedBox(height: h, child: row(i))],
        );
      },
    );
  }
}

/// A labelled bar with its figures: on one line in a wide column (label | bar | amount | detail), or on two in a
/// narrow one (label and amount over the bar and the detail). With [onTap] it opens what is behind it.
class DashBarRow extends StatelessWidget {
  final DashGeo g;
  final String label;
  final double fraction;
  final Color color;
  final String amount;
  final String? detail;
  final bool tall;
  final VoidCallback? onTap;

  /// The whole row in words, for screen readers.
  final String semanticsLabel;
  final String? hint;

  /// Shown on hover over the label (a long name cut short, or what a grouped row holds).
  final String? tooltip;

  /// Replaces the plain bar (for a bar split into parts).
  final Widget? bar;

  /// Column widths at 100% text (they grow with the text).
  final double labelWidth;
  final double amountWidth;
  final double detailWidth;
  final Color? amountColor;
  const DashBarRow({
    super.key,
    required this.g,
    required this.label,
    required this.fraction,
    required this.color,
    required this.amount,
    this.detail,
    required this.tall,
    this.onTap,
    required this.semanticsLabel,
    this.hint,
    this.tooltip,
    this.bar,
    this.labelWidth = 126,
    this.amountWidth = 76,
    this.detailWidth = 62,
    this.amountColor,
  });

  @override
  Widget build(BuildContext context) {
    final open = onTap != null;
    final k = g.k;
    final amountText = Text(
      amount,
      textAlign: TextAlign.right,
      maxLines: 1,
      style: DashText.money.copyWith(color: amountColor ?? DashUi.ink),
    );
    final detailText = detail == null
        ? null
        : Text(detail!, textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.meta);
    Widget labelText = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.label);
    if (tooltip != null) {
      labelText = Tooltip(message: tooltip!, waitDuration: const Duration(milliseconds: 500), child: labelText);
    }
    final barWidget = bar ?? DashBar(fraction: fraction, color: color);

    return DashPressable(
      onTap: onTap,
      label: semanticsLabel,
      hint: open ? (hint ?? 'Opens the list') : null,
      radius: BorderRadius.circular(8),
      builder: (hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: hover ? color.withValues(alpha: 0.08) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(
              child: tall
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(children: [Expanded(child: labelText), const SizedBox(width: 8), amountText]),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(child: barWidget),
                            if (detailText != null) ...[const SizedBox(width: 10), detailText],
                          ],
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        SizedBox(width: labelWidth * k, child: labelText),
                        const SizedBox(width: 8),
                        Expanded(child: barWidget),
                        const SizedBox(width: 12),
                        SizedBox(width: amountWidth * k, child: amountText),
                        if (detailText != null) SizedBox(width: detailWidth * k, child: detailText),
                      ],
                    ),
            ),
            SizedBox(
              width: open ? 22 : 0,
              child: open ? Icon(Icons.chevron_right_rounded, size: 18, color: hover ? DashUi.ink : DashUi.subtle) : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// A coloured rank badge: gold, silver and bronze for the first three, plain after that.
class DashRankBadge extends StatelessWidget {
  final int rank;
  final double size;
  const DashRankBadge({super.key, required this.rank, this.size = 24});

  static const _gold = Color(0xFFB45309);
  static const _silver = Color(0xFF64748B);
  static const _bronze = Color(0xFF9A3412);

  @override
  Widget build(BuildContext context) {
    final (Color fg, Color bg) = switch (rank) {
      1 => (_gold, const Color(0xFFFEF3C7)),
      2 => (_silver, const Color(0xFFF1F5F9)),
      3 => (_bronze, const Color(0xFFFFEDD5)),
      _ => (DashUi.subtle, Colors.white),
    };
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: Border.all(color: rank <= 3 ? fg.withValues(alpha: 0.45) : DashUi.line),
      ),
      child: Text(
        '$rank',
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, height: 1.2, color: fg, fontFeatures: DashText.tabular),
      ),
    );
  }
}

// =============================================================================
// SMALL PIECES
// =============================================================================

/// A row of choices, one selected: a chart's views ("Revenue", "Profit"). Each is a button screen readers hear as
/// one of a group, reachable with Tab; the arrow keys are left to the chart.
class DashSegmented<T> extends StatelessWidget {
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  /// What the choice is about, read before each option ("Chart view").
  final String label;
  final Color activeColor;
  const DashSegmented({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.label,
    this.activeColor = DashUi.blue,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(8)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final o in options)
            DashPressable(
              onTap: o.$1 == value ? () {} : () => onChanged(o.$1),
              label: '$label: ${o.$2}',
              selected: o.$1 == value,
              radius: BorderRadius.circular(6),
              builder: (hover) {
                final on = o.$1 == value;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  decoration: BoxDecoration(
                    color: on ? Colors.white : (hover ? Colors.white.withValues(alpha: 0.6) : Colors.white.withValues(alpha: 0)),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: on ? DashUi.line : DashUi.line.withValues(alpha: 0)),
                  ),
                  child: Text(
                    o.$2,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.3,
                      fontWeight: on ? FontWeight.w700 : FontWeight.w600,
                      color: on ? activeColor : DashUi.slate,
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// "↓ 6% vs 2025 to date": a change in a small pill, its sentence on hover and for screen readers.
/// [upIsGood] false colours a rise red (lost value, callbacks).
class DashChangeChip extends StatelessWidget {
  final double pct;
  final String text;
  final String tooltip;
  final String semanticsLabel;
  final bool upIsGood;
  const DashChangeChip({
    super.key,
    required this.pct,
    required this.text,
    required this.tooltip,
    required this.semanticsLabel,
    this.upIsGood = true,
  });

  /// The month-over-month chip: the last two finished months (dashMonthChange), "↓ 14% Sep vs Aug".
  static Widget? monthOverMonth(List<double> monthly, int year, {required String what, bool upIsGood = true}) {
    final c = dashMonthChange(monthly, year);
    if (c == null) return null;
    final parts = c.label.split(' vs ');
    final pct = c.pct.abs().round();
    return DashChangeChip(
      pct: c.pct,
      text: '$pct% ${c.label}',
      tooltip: '$what in ${parts.first} against ${parts.last}, the last two finished months. '
          'The month in progress is never compared.',
      semanticsLabel: '${c.pct >= 0 ? 'Up' : 'Down'} $pct% in ${parts.first} against ${parts.last}',
      upIsGood: upIsGood,
    );
  }

  @override
  Widget build(BuildContext context) {
    final up = pct >= 0;
    final good = up == upIsGood;
    final color = good ? DashUi.emeraldText : DashUi.redText;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: semanticsLabel,
        child: ExcludeSemantics(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 13, color: color),
                const SizedBox(width: 3),
                Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, height: 1.3, color: color)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A legend entry: a square swatch (bars), a short thick line (ticks), or a dashed line (an average).
class DashLegendSwatch extends StatelessWidget {
  final Color color;
  final String text;
  final bool tick;
  final bool dashed;
  final bool outlined;
  const DashLegendSwatch({
    super.key,
    required this.color,
    required this.text,
    this.tick = false,
    this.dashed = false,
    this.outlined = false,
  });

  @override
  Widget build(BuildContext context) {
    final Widget swatch;
    if (dashed) {
      swatch = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Container(width: 4, height: 2.5, margin: EdgeInsets.only(right: i == 2 ? 0 : 2), color: color),
        ],
      );
    } else {
      swatch = Container(
        width: tick ? 14 : 11,
        height: tick ? 3 : 11,
        decoration: BoxDecoration(
          color: outlined ? color.withValues(alpha: 0.4) : color,
          borderRadius: BorderRadius.circular(tick ? 1.5 : 3),
          border: outlined ? Border.all(color: color, width: 1.2) : null,
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        swatch,
        const SizedBox(width: 6),
        Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.legend)),
      ],
    );
  }
}

// =============================================================================
// STRIP PANEL ("How customers paid": a split bar in the title row, the parts listed under it)
// =============================================================================

class DashSplitItem {
  final String label;
  final double amount;
  final String value;
  final Color color;

  /// The share text beside the label; worked out from the amounts when null.
  final String? share;
  final String? tooltip;
  final String semanticsLabel;
  final VoidCallback? onTap;
  final String? hint;
  const DashSplitItem({
    required this.label,
    required this.amount,
    required this.value,
    required this.color,
    this.share,
    this.tooltip,
    required this.semanticsLabel,
    this.onTap,
    this.hint,
  });
}

/// A share as a whole percentage; a sliver reads "<1%" rather than a misleading 0%.
String dashShare(double part, double whole) {
  if (whole <= 0) return '0%';
  final p = part / whole * 100;
  return p > 0 && p < 1 ? '<1%' : '${p.round()}%';
}

class DashSplitPanel extends StatelessWidget {
  final DashGeo g;
  final String title;
  final String? note;
  final List<DashSplitItem> items;
  final String emptyText;
  final String? tooltip;
  const DashSplitPanel({
    super.key,
    required this.g,
    required this.title,
    this.note,
    required this.items,
    required this.emptyText,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final total = items.fold<double>(0, (s, m) => s + math.max(0, m.amount));
    Widget titleText = Text.rich(
      TextSpan(
        children: [
          TextSpan(text: title, style: DashText.panelTitle),
          if (note != null) TextSpan(text: ' · $note', style: DashText.panelNote),
        ],
      ),
      maxLines: 1,
    );
    if (tooltip != null) titleText = Tooltip(message: tooltip!, child: titleText);
    return DashPanel(
      header: SizedBox(
        height: g.panelHeader,
        child: Row(
          children: [
            Semantics(
              header: true,
              label: note == null ? title : '$title, $note',
              child: ExcludeSemantics(child: titleText),
            ),
            const SizedBox(width: 16),
            Expanded(child: total <= 0 ? const SizedBox.shrink() : _splitBar(total)),
          ],
        ),
      ),
      child: total <= 0
          ? SizedBox(
              height: g.line(13) + 3 + g.line(15, 1.2),
              child: Align(alignment: Alignment.centerLeft, child: Text(emptyText, style: DashText.empty)),
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(child: _item(items[i], total)),
                ],
              ],
            ),
    );
  }

  /// Repeats the figures listed under it, so screen readers skip it.
  Widget _splitBar(double total) => ExcludeSemantics(
    child: ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: SizedBox(
        height: 10,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < items.length; i++)
              if (items[i].amount > 0) ...[
                if (i > 0) const SizedBox(width: 2),
                Expanded(
                  flex: math.max(1, (items[i].amount / total * 1000).round()),
                  child: ColoredBox(color: items[i].color),
                ),
              ],
          ],
        ),
      ),
    ),
  );

  Widget _item(DashSplitItem m, double total) {
    Widget body(bool hover) => Padding(
      padding: EdgeInsets.symmetric(horizontal: m.onTap == null ? 0 : 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: m.color, borderRadius: BorderRadius.circular(3)),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  m.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DashText.label.copyWith(decoration: hover ? TextDecoration.underline : null),
                ),
              ),
              const SizedBox(width: 6),
              Text(m.share ?? dashShare(m.amount, total), style: DashText.meta),
            ],
          ),
          const SizedBox(height: 3),
          Text(m.value, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.bigMoney),
        ],
      ),
    );
    Widget item = DashPressable(
      onTap: m.onTap,
      label: m.semanticsLabel,
      hint: m.onTap == null ? null : (m.hint ?? 'Opens the list'),
      radius: BorderRadius.circular(6),
      builder: body,
    );
    if (m.tooltip != null) {
      item = Tooltip(message: m.tooltip!, waitDuration: const Duration(milliseconds: 400), child: item);
    }
    return item;
  }
}

// =============================================================================
// SKELETON PIECES
// =============================================================================

/// A scorecard-shaped placeholder.
class DashSkeletonTile extends StatelessWidget {
  const DashSkeletonTile({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
    decoration: DashUi.panel(radius: 12),
    child: const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SkeletonBox(h: 12, w: 110),
        SizedBox(height: 10),
        SkeletonBox(h: 24, w: 150),
        SizedBox(height: 8),
        SkeletonBox(h: 10, w: 130),
      ],
    ),
  );
}

/// A panel-shaped placeholder: a title bar, then a block ([fill]) or [rows] lines of [rowH].
class DashSkeletonPanel extends StatelessWidget {
  final bool fill;
  final int rows;
  final double rowH;
  const DashSkeletonPanel({super.key, this.fill = false, this.rows = 0, this.rowH = 34});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
    decoration: DashUi.panel(),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SkeletonBox(h: 14, w: 160),
        const SizedBox(height: 16),
        if (fill)
          const Expanded(child: SkeletonBox(r: 10))
        else
          for (var i = 0; i < rows; i++)
            SizedBox(height: rowH, child: const Align(alignment: Alignment.centerLeft, child: SkeletonBox(h: 12))),
      ],
    ),
  );
}

// =============================================================================
// MONTHLY CHART
// =============================================================================

enum DashSeriesKind { bar, line }

/// One series of twelve monthly values, January first.
class DashSeries {
  final String label;
  final List<double> values;
  final Color color;
  final DashSeriesKind kind;
  const DashSeries(this.label, this.values, this.color, {this.kind = DashSeriesKind.bar});
}

/// One line of a month's tooltip, also read to screen readers.
class DashTipRow {
  final String label;
  final String value;
  final Color? color;
  const DashTipRow(this.label, this.value, {this.color});
}

/// What the chart shows in one of its views.
class DashChartView {
  /// The toggle's text ("Revenue") and the panel title for this view.
  final String tab;
  final String title;

  /// A quieter note after the title ("$2.3M in 2026").
  final String? note;

  /// Bars first (at most two), then at most one line.
  final List<DashSeries> series;

  /// Two bar series stacked (parts of one whole) instead of side by side.
  final bool stacked;

  /// Last year's values for the first bar series, drawn as a tick over each bar, and its legend name ("2025").
  final List<double>? prior;
  final String priorLabel;

  /// A dashed line across the plot (left scale), and its legend text.
  final double? average;
  final String? averageLabel;

  final String Function(double) axis;

  /// The figure over each bar, when there is one bar series and room for it.
  final String Function(double)? barLabel;

  /// The tooltip lines for a month that has happened (index 0 = January).
  final List<DashTipRow> Function(int month) tip;

  /// The months in words for screen readers ("Jan $230.7k, Feb $195.2k ...").
  final String Function(int lastMonth) summary;
  final String emptyText;

  /// A chip beside the title (a change against last month or last year).
  final Widget? badge;
  final String semanticsLabel;

  const DashChartView({
    required this.tab,
    required this.title,
    this.note,
    required this.series,
    this.stacked = false,
    this.prior,
    this.priorLabel = '',
    this.average,
    this.averageLabel,
    required this.axis,
    this.barLabel,
    required this.tip,
    required this.summary,
    required this.emptyText,
    this.badge,
    required this.semanticsLabel,
  });

  List<DashSeries> get bars => [for (final s in series) if (s.kind == DashSeriesKind.bar) s];
  DashSeries? get line => series.where((s) => s.kind == DashSeriesKind.line).firstOrNull;
}

class _MonthIntent extends Intent {
  final int delta;
  const _MonthIntent(this.delta);
}

/// Twelve months in a panel: bars for the year shown (the month in progress lighter, months to come empty), last
/// year's ticks, a line, an average. Hover or the arrow keys pick a month and a tooltip beside it reads it out; a
/// toggle in the title row switches between [views] (never on its own).
class DashMonthChart extends StatefulWidget {
  final List<DashChartView> views;
  final int year;

  /// Called when the view changes (a page can keep the choice).
  final ValueChanged<int>? onView;
  final int initialView;
  const DashMonthChart({super.key, required this.views, required this.year, this.onView, this.initialView = 0});

  @override
  State<DashMonthChart> createState() => _DashMonthChartState();
}

class _DashMonthChartState extends State<DashMonthChart> with SingleTickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  late int _view = widget.initialView.clamp(0, widget.views.length - 1);

  /// The month under the pointer, or picked with the arrow keys.
  int? _index;
  bool _focused = false;

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduceMotion) {
      _intro.value = 1;
    } else if (_intro.isDismissed) {
      _intro.forward();
    }
  }

  @override
  void didUpdateWidget(covariant DashMonthChart old) {
    super.didUpdateWidget(old);
    if (_view >= widget.views.length) _view = 0;
    if (old.year != widget.year) _replay();
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  void _replay() {
    _index = null;
    if (_reduceMotion) {
      _intro.value = 1;
    } else {
      _intro.forward(from: 0);
    }
  }

  void _setView(int i) {
    if (i == _view) return;
    setState(() {
      _view = i;
      _replay();
    });
    widget.onView?.call(i);
  }

  /// This year's month in progress (drawn lighter: it isn't a whole month yet). Null for a past year.
  int? get _inProgress {
    final now = DashClock.now();
    if (widget.year > now.year) return -1;
    return widget.year == now.year ? now.month - 1 : null;
  }

  int get _lastMonth => _inProgress ?? 11;

  int? _indexFor(double dx, double width) {
    final plotW = width - _DashChartPainter.left - _DashChartPainter.right;
    if (plotW <= 0) return null;
    final i = ((dx - _DashChartPainter.left) / (plotW / 12)).floor();
    return (i < 0 || i >= 12) ? null : i;
  }

  void _step(int delta) {
    final start = _index ?? math.max(0, _lastMonth);
    setState(() => _index = (start + (_index == null ? 0 : delta)).clamp(0, 11));
  }

  String _monthTitle(int i) {
    final ip = _inProgress;
    return '${dashMonthNames[i]} ${widget.year}${i == ip ? ' so far' : ''}';
  }

  bool _future(int i) {
    final ip = _inProgress;
    return ip != null && i > ip;
  }

  String _describe(DashChartView v, int i) {
    final rows = _future(i) ? const <DashTipRow>[] : v.tip(i);
    final head = _future(i) ? '${_monthTitle(i)}: not here yet' : _monthTitle(i);
    final prior = v.prior;
    return [
      head,
      for (final r in rows) '${r.label}: ${r.value}',
      if (_future(i) && prior != null && prior[i] > 0) '${v.priorLabel}: ${v.axis(prior[i])}',
    ].join('. ');
  }

  bool _isEmpty(DashChartView v) {
    final last = _lastMonth;
    if (last < 0) return true;
    for (final s in v.series) {
      for (var i = 0; i <= last && i < s.values.length; i++) {
        if (s.values[i] != 0) return false;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.views[_view];
    final empty = _isEmpty(v);
    final inProgress = _inProgress;
    final font = DefaultTextStyle.of(context).style.fontFamily;
    final bars = v.bars;

    final legend = <Widget>[
      for (var i = 0; i < bars.length; i++) DashLegendSwatch(color: bars[i].color, text: bars[i].label),
      if (inProgress != null && inProgress >= 0 && bars.isNotEmpty && bars.first.values[inProgress] != 0)
        DashLegendSwatch(color: bars.first.color, text: '${dashMonthNames[inProgress]} so far', outlined: true),
      if (v.prior != null && v.prior!.any((p) => p != 0)) DashLegendSwatch(color: DashUi.slate, text: v.priorLabel, tick: true),
      if (v.line != null) DashLegendSwatch(color: v.line!.color, text: v.line!.label, tick: true),
      if (v.average != null && v.averageLabel != null) DashLegendSwatch(color: DashUi.subtle, text: v.averageLabel!, dashed: true),
    ];

    final titleSpan = TextSpan(
      children: [
        TextSpan(text: v.title, style: DashText.panelTitle),
        if (v.note != null) TextSpan(text: ' · ${v.note}', style: DashText.panelNote),
      ],
    );
    final title = Row(
      children: [
        Flexible(
          child: Semantics(
            header: true,
            label: v.note == null ? v.title : '${v.title}, ${v.note}',
            child: ExcludeSemantics(
              child: Text.rich(titleSpan, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
        if (v.badge != null && !empty) ...[const SizedBox(width: 10), v.badge!],
      ],
    );
    final toggle = widget.views.length < 2
        ? null
        : DashSegmented<int>(
            value: _view,
            label: 'Chart view',
            options: [for (var i = 0; i < widget.views.length; i++) (i, widget.views[i].tab)],
            onChanged: _setView,
          );
    final legendWrap = ExcludeSemantics(child: Wrap(spacing: 14, runSpacing: 4, children: legend));
    final legendEntries = [for (final l in legend) l as DashLegendSwatch];
    final showLegend = !empty && legend.isNotEmpty;

    // The toggle shares the title's row when both fit; otherwise it moves down beside the legend, so the title is
    // never the one cut short.
    final header = LayoutBuilder(
      builder: (context, c) {
        final inline = toggle == null || _titleWidth(context, titleSpan, v.badge != null && !empty) + 12 +
                _toggleWidth(context) <= c.maxWidth;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(child: title),
                if (inline && toggle != null) ...[const SizedBox(width: 12), toggle],
              ],
            ),
            if (inline && showLegend) ...[const SizedBox(height: 6), legendWrap],
            if (!inline && (!showLegend || _legendWidth(context, legendEntries) + 12 + _toggleWidth(context) <= c.maxWidth)) ...[
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: showLegend ? legendWrap : const SizedBox.shrink()),
                  const SizedBox(width: 12),
                  toggle,
                ],
              ),
            ] else if (!inline) ...[
              // Too narrow for both on one line (larger text): the toggle gets its own line under the legend.
              const SizedBox(height: 6),
              legendWrap,
              const SizedBox(height: 6),
              Align(alignment: Alignment.centerRight, child: toggle),
            ],
          ],
        );
      },
    );

    return DashPanel(
      fill: true,
      header: header,
      child: empty
          ? DashEmptyNote(v.emptyText)
          : Semantics(
              container: true,
              label: v.semanticsLabel,
              value: _index == null ? v.summary(_lastMonth) : _describe(v, _index!),
              hint: 'Left and right arrow keys move between months',
              child: FocusableActionDetector(
                shortcuts: const {
                  SingleActivator(LogicalKeyboardKey.arrowLeft): _MonthIntent(-1),
                  SingleActivator(LogicalKeyboardKey.arrowRight): _MonthIntent(1),
                  SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
                },
                actions: {
                  _MonthIntent: CallbackAction<_MonthIntent>(onInvoke: (i) {
                    _step(i.delta);
                    return null;
                  }),
                  DismissIntent: CallbackAction<DismissIntent>(onInvoke: (_) {
                    setState(() => _index = null);
                    return null;
                  }),
                },
                onShowFocusHighlight: (on) => setState(() {
                  _focused = on;
                  // Keyboard focus starts on the latest month; leaving clears the pick.
                  _index = on ? (_index ?? math.max(0, _lastMonth)) : null;
                }),
                child: ExcludeSemantics(
                  child: LayoutBuilder(
                    builder: (context, c) => MouseRegion(
                      onHover: (e) {
                        final i = _indexFor(e.localPosition.dx, c.maxWidth);
                        if (i != _index) setState(() => _index = i);
                      },
                      onExit: (_) {
                        if (!_focused) setState(() => _index = null);
                      },
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (d) => setState(() => _index = _indexFor(d.localPosition.dx, c.maxWidth)),
                        child: Container(
                          foregroundDecoration: dashFocusRing(_focused, BorderRadius.circular(8)),
                          child: Stack(
                            children: [
                              RepaintBoundary(
                                child: AnimatedBuilder(
                                  animation: _intro,
                                  builder: (context, _) => CustomPaint(
                                    size: Size(c.maxWidth, c.maxHeight),
                                    painter: _DashChartPainter(
                                      view: v,
                                      hover: _index,
                                      inProgress: inProgress,
                                      intro: Curves.easeOutCubic.transform(_intro.value),
                                      fontFamily: font,
                                    ),
                                  ),
                                ),
                              ),
                              if (_index != null) _tooltip(v, c, _index!),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  double _measure(BuildContext context, InlineSpan span) => (TextPainter(
    text: span,
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout())
      .width;

  /// The title and note on one line, plus room for a change chip.
  double _titleWidth(BuildContext context, InlineSpan span, bool badge) {
    final w = _measure(context, TextSpan(style: DefaultTextStyle.of(context).style, children: [span]));
    return w + (badge ? 10 + MediaQuery.textScalerOf(context).scale(132) : 0);
  }

  /// The legend on one line: each entry's swatch, gap and text, and the spacing between entries.
  double _legendWidth(BuildContext context, List<DashLegendSwatch> entries) {
    final base = DefaultTextStyle.of(context).style.merge(DashText.legend);
    var w = 14.0 * math.max(0, entries.length - 1);
    for (final e in entries) {
      final swatch = e.dashed ? 16.0 : (e.tick ? 14.0 : 11.0);
      w += swatch + 6 + _measure(context, TextSpan(text: e.text, style: base));
    }
    return w.ceilToDouble();
  }

  /// The view toggle: each option's text plus its padding and border, and the toggle's own padding.
  double _toggleWidth(BuildContext context) {
    final base = DefaultTextStyle.of(context).style;
    var w = 4.0;
    for (final view in widget.views) {
      w += _measure(
            context,
            TextSpan(text: view.tab, style: base.merge(const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700))),
          ) +
          22;
    }
    return w;
  }

  Widget _tooltip(DashChartView v, BoxConstraints c, int i) {
    final plotW = c.maxWidth - _DashChartPainter.left - _DashChartPainter.right;
    final slot = plotW / 12;
    final cx = _DashChartPainter.left + slot * i + slot / 2;
    const tipW = 204.0;
    // Beside the month rather than over it, so the bar and its label stay visible.
    final rightSide = cx + slot / 2 + 8 + tipW <= c.maxWidth;
    final left = rightSide ? cx + slot / 2 + 4 : math.max(0.0, cx - slot / 2 - 4 - tipW);
    final future = _future(i);
    final rows = future ? const <DashTipRow>[] : v.tip(i);
    final prior = v.prior;

    const dim = TextStyle(fontSize: 12, fontWeight: FontWeight.w600, height: 1.3, color: Color(0xFFCBD5E1));
    const strong = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w700,
      height: 1.3,
      color: Colors.white,
      fontFeatures: DashText.tabular,
    );
    return Positioned(
      left: left,
      top: 4,
      width: tipW,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(color: DashUi.ink, borderRadius: BorderRadius.circular(10)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_monthTitle(i), style: dim),
              const SizedBox(height: 3),
              if (future) const Text('Not here yet', style: strong),
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Row(
                    children: [
                      if (r.color != null) ...[
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(color: r.color, borderRadius: BorderRadius.circular(2)),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Expanded(child: Text(r.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: dim)),
                      const SizedBox(width: 8),
                      Text(r.value, style: strong),
                    ],
                  ),
                ),
              if (future && prior != null && prior[i] > 0) ...[
                const SizedBox(height: 2),
                Text('${v.priorLabel}: ${v.axis(prior[i])}', style: dim),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// An axis from [min] to [max] in steps of [step] (min is below zero only when the data is).
class DashScale {
  final double min;
  final double max;
  final double step;
  const DashScale(this.min, this.max, this.step);

  double get span => max - min;
  int get ticks => (span / step).round();

  /// About four steps covering [lo]..[hi], with a little room above the top value.
  factory DashScale.nice(double lo, double hi, {double emptyMax = 10000}) {
    lo = math.min(0, lo);
    hi = math.max(0, hi);
    if (hi - lo <= 0) return DashScale(0, emptyMax, emptyMax / 4);
    final raw = (hi - lo) / 4;
    final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    final norm = raw / mag;
    final nice = norm <= 1 ? 1.0 : (norm <= 2 ? 2.0 : (norm <= 5 ? 5.0 : 10.0));
    final step = nice * mag;
    var top = (hi / step).ceil() * step;
    var bottom = (lo / step).floor() * step;
    if (hi > 0 && top < hi * 1.08) top += step;
    if (lo < 0 && bottom > lo * 1.08) bottom -= step;
    if (top == bottom) top += step;
    return DashScale(bottom, top, step);
  }
}

class _DashChartPainter extends CustomPainter {
  /// Room for the axis labels on the left, the month labels below, and the value labels above the tallest bar.
  static const left = 54.0;
  static const bottom = 22.0;
  static const top = 18.0;
  static const right = 4.0;

  final DashChartView view;
  final int? hover;
  final int? inProgress;
  final double intro;
  final String? fontFamily;

  const _DashChartPainter({
    required this.view,
    required this.hover,
    required this.inProgress,
    required this.intro,
    required this.fontFamily,
  });

  void _text(Canvas canvas, String s, Offset at, TextStyle style, {TextAlign align = TextAlign.left}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style.copyWith(fontFamily: fontFamily)),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = align == TextAlign.right
        ? at.dx - tp.width
        : (align == TextAlign.center ? at.dx - tp.width / 2 : at.dx);
    tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
  }

  bool _future(int i) => inProgress != null && i > inProgress!;

  @override
  void paint(Canvas canvas, Size size) {
    final v = view;
    final plot = Rect.fromLTRB(left, top, size.width - right, size.height - bottom);
    if (plot.width <= 0 || plot.height <= 0) return;
    const axisStyle = TextStyle(
      fontSize: 11.5,
      color: DashUi.subtle,
      fontWeight: FontWeight.w500,
      fontFeatures: DashText.tabular,
    );

    final bars = v.bars;
    final line = v.line;

    // The left scale covers the bars (their sum when stacked), last year's ticks, a left-axis line and the average.
    var lo = 0.0, hi = 0.0;
    for (var i = 0; i < 12; i++) {
      if (_future(i)) {
        final p = v.prior;
        if (p != null) hi = math.max(hi, p[i]);
        continue;
      }
      if (v.stacked) {
        final sum = bars.fold<double>(0, (s, b) => s + b.values[i]);
        hi = math.max(hi, sum);
        lo = math.min(lo, sum);
      } else {
        for (final b in bars) {
          hi = math.max(hi, b.values[i]);
          lo = math.min(lo, b.values[i]);
        }
      }
      if (line != null) {
        hi = math.max(hi, line.values[i]);
        lo = math.min(lo, line.values[i]);
      }
      final p = v.prior;
      if (p != null) hi = math.max(hi, p[i]);
    }
    if (v.average != null) hi = math.max(hi, v.average!);
    final scale = DashScale.nice(lo, hi);
    double y(double value) => plot.bottom - plot.height * ((value - scale.min) / scale.span);
    final zero = y(0);

    // On a short plot the axis labels would touch: every other gridline is labelled (zero always is).
    final labelEvery = scale.ticks > 0 && plot.height / scale.ticks < 22 ? 2 : 1;
    for (var t = 0; t <= scale.ticks; t++) {
      final value = scale.min + t * scale.step;
      final gy = y(value);
      canvas.drawLine(
        Offset(plot.left, gy),
        Offset(plot.right, gy),
        Paint()
          ..color = value == 0 ? DashUi.line : DashUi.faint
          ..strokeWidth = value == 0 ? 1.2 : 1,
      );
      final zeroTick = (value / scale.step).round();
      if (value == 0 || zeroTick % labelEvery == 0) {
        _text(canvas, v.axis(value), Offset(plot.left - 10, gy), axisStyle, align: TextAlign.right);
      }
    }
    final slot = plot.width / 12;
    final grouped = bars.length > 1 && !v.stacked;
    final barW = grouped ? math.min(slot * 0.36, 22.0) : math.min(slot * 0.54, 42.0);
    // Value labels only with one bar series and when each month has room for "$396k" without touching its neighbours.
    final labels = v.barLabel != null && bars.length == 1 && slot >= 34;
    final labelAlpha = ((intro - 0.6) / 0.4).clamp(0.0, 1.0);

    for (var i = 0; i < 12; i++) {
      final cx = plot.left + slot * i + slot / 2;
      final focus = hover == i;
      final dim = hover != null && !focus;
      _text(
        canvas,
        dashMonthNames[i],
        Offset(cx, plot.bottom + 12),
        TextStyle(
          fontSize: 11.5,
          fontWeight: focus ? FontWeight.w800 : FontWeight.w600,
          color: focus ? DashUi.ink : DashUi.subtle,
        ),
        align: TextAlign.center,
      );

      // Months that haven't happened yet draw nothing, not a zero-height bar.
      final future = _future(i);
      final partial = i == inProgress;
      final alpha = partial ? 0.4 : 1.0;

      void drawBar(double x, double w, double from, double to, Color color, {bool roundTop = true}) {
        if (to == from) return;
        final y0 = y(from);
        final y1 = y0 + (y(to) - y0) * intro;
        final rect = Rect.fromLTRB(x, math.min(y0, y1), x + w, math.max(y0, y1));
        final up = to >= from;
        final rr = RRect.fromRectAndCorners(
          rect,
          topLeft: roundTop && up ? const Radius.circular(5) : Radius.zero,
          topRight: roundTop && up ? const Radius.circular(5) : Radius.zero,
          bottomLeft: roundTop && !up ? const Radius.circular(5) : Radius.zero,
          bottomRight: roundTop && !up ? const Radius.circular(5) : Radius.zero,
        );
        canvas.drawRRect(rr, Paint()..color = color.withValues(alpha: dim ? alpha * 0.35 : alpha));
        // The month in progress is lighter with an outline: a part month, not a collapse.
        if (partial) {
          canvas.drawRRect(
            rr.deflate(0.75),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..color = color.withValues(alpha: dim ? 0.35 : 1),
          );
        }
      }

      var barTop = zero;
      if (!future && bars.isNotEmpty) {
        if (v.stacked) {
          var base = 0.0;
          for (var b = 0; b < bars.length; b++) {
            final value = bars[b].values[i];
            if (value <= 0) continue;
            drawBar(cx - barW / 2, barW, base, base + value, bars[b].color, roundTop: b == bars.length - 1);
            base += value;
          }
          barTop = y(base);
        } else if (grouped) {
          for (var b = 0; b < bars.length; b++) {
            final x = cx - barW - 1 + b * (barW + 2);
            drawBar(x, barW, 0, bars[b].values[i], bars[b].color);
          }
          barTop = y(bars.fold<double>(0, (m, b) => math.max(m, b.values[i])));
        } else {
          drawBar(cx - barW / 2, barW, 0, bars.first.values[i], bars.first.color);
          barTop = y(math.max(0, bars.first.values[i]));
        }
      }

      // Last year's tick over the first bar series; the label moves above it only when the tick would cross it.
      var labelY = barTop - 10;
      final prior = v.prior;
      if (prior != null && prior[i] > 0) {
        final ty = y(prior[i]);
        final tx = grouped ? cx - barW - 1 : cx - barW / 2;
        canvas.drawLine(
          Offset(tx - 4, ty),
          Offset(tx + barW + 4, ty),
          Paint()
            ..color = DashUi.slate.withValues(alpha: dim ? 0.3 : 0.9)
            ..strokeWidth = 2.5
            ..strokeCap = StrokeCap.round,
        );
        if (ty > labelY - 11 && ty < barTop + 2) labelY = ty - 11;
      }

      if (labels && labelAlpha > 0 && !future && bars.first.values[i] != 0) {
        _text(
          canvas,
          v.barLabel!(bars.first.values[i]),
          Offset(cx, labelY),
          TextStyle(
            fontSize: 11.5,
            fontWeight: focus ? FontWeight.w800 : FontWeight.w600,
            color: (focus ? DashUi.ink : DashUi.slate).withValues(alpha: labelAlpha * (dim ? 0.45 : 1)),
            fontFeatures: DashText.tabular,
          ),
          align: TextAlign.center,
        );
      }
    }

    if (v.average != null && v.average! > 0) {
      final ay = y(v.average!);
      final dash = Paint()
        ..color = DashUi.subtle.withValues(alpha: 0.8)
        ..strokeWidth = 1.3;
      for (var x = plot.left; x < plot.right; x += 8) {
        canvas.drawLine(Offset(x, ay), Offset(math.min(x + 4, plot.right), ay), dash);
      }
    }

    if (line != null) {
      final pts = <Offset>[
        for (var i = 0; i < 12; i++)
          if (!_future(i)) Offset(plot.left + slot * i + slot / 2, y(line.values[i])),
      ];
      if (pts.length >= 2) {
        final path = Path()..moveTo(pts.first.dx, pts.first.dy);
        for (final p in pts.skip(1)) {
          path.lineTo(p.dx, p.dy);
        }
        final metric = path.computeMetrics().firstOrNull;
        if (metric != null) {
          canvas.drawPath(
            metric.extractPath(0, metric.length * intro),
            Paint()
              ..color = line.color
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.2
              ..strokeJoin = StrokeJoin.round
              ..strokeCap = StrokeCap.round,
          );
        }
      }
      if (intro >= 1) {
        for (var i = 0; i < pts.length; i++) {
          final focus = hover == i;
          canvas.drawCircle(pts[i], focus ? 4.5 : 3, Paint()..color = Colors.white);
          canvas.drawCircle(
            pts[i],
            focus ? 4.5 : 3,
            Paint()
              ..color = line.color
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashChartPainter old) =>
      !identical(old.view, view) ||
      old.hover != hover ||
      old.intro != intro ||
      old.inProgress != inProgress ||
      old.fontFamily != fontFamily;
}
