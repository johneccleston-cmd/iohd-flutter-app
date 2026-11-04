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

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dash_hover_card.dart';
import 'dashboard_data.dart';
import 'dash_story.dart';
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

  DashGeo.of(BuildContext context) : s = MediaQuery.textScalerOf(context), tile = dashTileHeight(context);

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

  /// The line under a panel's title naming its finding ([DashCallout]).
  double get callout => line(12) + 6;

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
    text: TextSpan(
      text: text,
      style: base.merge(TextStyle(fontSize: size, fontWeight: weight)),
    ),
    textDirection: TextDirection.ltr,
    textScaler: s,
    maxLines: 1,
  )..layout()).width;
  return [
        w(title, 13, FontWeight.w600),
        w(value, 28, FontWeight.w800),
        if (caption.isNotEmpty) w(caption, 12, FontWeight.w500),
      ].reduce(math.max).ceilToDouble() +
      2;
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
    if (tooltip != null)
      text = Tooltip(message: tooltip!, waitDuration: const Duration(milliseconds: 500), child: text);
    return SizedBox(
      height: g.panelHeader,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              label: note == null ? title : '$title, $note',
              child: ExcludeSemantics(
                child: Align(alignment: Alignment.centerLeft, child: text),
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ],
      ),
    );
  }
}

/// The line under a panel's title that names what its figures show, in words ("Payroll is 38% of spending").
class DashCallout extends StatelessWidget {
  final DashGeo g;
  final String text;
  final Color color;
  const DashCallout({super.key, required this.g, required this.text, this.color = DashUi.emeraldText});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: g.callout,
    child: Align(
      alignment: Alignment.topLeft,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: DashText.meta.copyWith(fontWeight: FontWeight.w700, color: color),
      ),
    ),
  );
}

class DashEmptyNote extends StatelessWidget {
  final String text;
  const DashEmptyNote(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Text(text, textAlign: TextAlign.center, style: DashText.empty),
  );
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

  /// For a button that opens a menu: the same node goes to the MenuAnchor's `childFocusNode`, so the keyboard can move
  /// into the menu and back.
  final FocusNode? focusNode;
  const DashPressable({
    super.key,
    required this.onTap,
    required this.label,
    this.hint,
    this.selected,
    required this.radius,
    required this.builder,
    this.focusNode,
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
        focusNode: widget.focusNode,
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
          builder: (context, t, _) => _BarFx(
            width: math.max(fraction > 0 ? height : 0.0, c.maxWidth * t),
            height: height,
            glow: color,
            child: ColoredBox(color: color),
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
    final biggest = parts.isEmpty ? DashUi.slate : parts.reduce((a, b) => b.$1 > a.$1 ? b : a).$2;
    return _BarFx(
      height: height,
      glow: biggest,
      child: ColoredBox(
        color: DashUi.faint,
        child: total <= 0
            ? null
            : Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final p in parts)
                    if (p.$1 > 0)
                      Expanded(
                        flex: math.max(1, (p.$1 / total * 1000).round()),
                        child: ColoredBox(color: p.$2),
                      ),
                ],
              ),
      ),
    );
  }
}

/// Tells the bar inside a [DashBarRow] that the pointer is over its row.
class _BarHover extends InheritedWidget {
  final bool hover;
  const _BarHover({required this.hover, required super.child});

  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_BarHover>()?.hover ?? false;

  @override
  bool updateShouldNotify(_BarHover old) => hover != old.hover;
}

/// A bar's fill, with the hover effect: while the pointer is over the row the fill swells past its track, glows in its
/// own colour, and a band of light sweeps across it once. Under reduced motion it only swells and glows (no sweep).
class _BarFx extends StatefulWidget {
  final double? width;
  final double height;
  final Color glow;
  final Widget child;
  const _BarFx({this.width, required this.height, required this.glow, required this.child});

  @override
  State<_BarFx> createState() => _BarFxState();
}

class _BarFxState extends State<_BarFx> with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  bool _wasHover = false;

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hover = _BarHover.of(context);
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (hover && !_wasHover && !reduce) _sweep.forward(from: 0);
    if (!hover) _sweep.value = 0;
    _wasHover = hover;
    final radius = BorderRadius.circular(widget.height / 2);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: hover ? 1.0 : 0.0),
      duration: reduce ? Duration.zero : const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      builder: (context, h, child) => SizedBox(
        width: widget.width,
        height: widget.height,
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.diagonal3Values(1, 1 + 0.7 * h, 1),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: h > 0
                  ? [
                      BoxShadow(
                        color: widget.glow.withValues(alpha: 0.5 * h),
                        blurRadius: 12 * h,
                      ),
                    ]
                  : null,
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  child!,
                  if (h > 0 && !reduce)
                    IgnorePointer(
                      child: AnimatedBuilder(
                        animation: _sweep,
                        builder: (context, _) {
                          final x = -2 + 4 * Curves.easeInOut.transform(_sweep.value);
                          return DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment(x - 0.5, 0),
                                end: Alignment(x + 0.5, 0),
                                colors: [
                                  Colors.white.withValues(alpha: 0),
                                  Colors.white.withValues(alpha: 0.6),
                                  Colors.white.withValues(alpha: 0),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
      child: widget.child,
    );
  }
}

/// Tracks the pointer over its content, for rows that have nothing to open (so [DashPressable] has no hover state).
class _RowHover extends StatefulWidget {
  final Widget Function(bool hover) builder;
  const _RowHover({required this.builder});

  @override
  State<_RowHover> createState() => _RowHoverState();
}

class _RowHoverState extends State<_RowHover> {
  bool _in = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _in = true),
    onExit: (_) => setState(() => _in = false),
    child: widget.builder(_in),
  );
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
      builder: (pressHover) => _RowHover(
        builder: (rowHover) {
          final hover = pressHover || rowHover;
          return _BarHover(
            hover: hover,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: hover ? color.withValues(alpha: 0.08) : color.withValues(alpha: 0),
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
                              Row(
                                children: [
                                  Expanded(child: labelText),
                                  const SizedBox(width: 8),
                                  amountText,
                                ],
                              ),
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
                    child: open
                        ? Icon(Icons.chevron_right_rounded, size: 18, color: hover ? DashUi.ink : DashUi.subtle)
                        : null,
                  ),
                ],
              ),
            ),
          );
        },
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
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          height: 1.2,
          color: fg,
          fontFeatures: DashText.tabular,
        ),
      ),
    );
  }
}

// =============================================================================
// SMALL PIECES
// =============================================================================

/// A row of choices, one selected: a chart's views ("Revenue", "Profit"). Each is a button screen readers hear as
/// one of a group, reachable with Tab; the arrow keys are left to the chart. The selected one is white with its label
/// in ink, like every tab in the app (the calendar's included): never a coloured label.
class DashSegmented<T> extends StatefulWidget {
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  /// What the choice is about, read before each option ("Chart view").
  final String label;

  const DashSegmented({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.label,
  });

  @override
  State<DashSegmented<T>> createState() => _DashSegmentedState<T>();
}

/// The white pill is one piece that slides to the option picked (measured after layout, so it fits any label and any
/// text size); until the first measurement, and with reduced motion, the selected option simply draws it in place.
class _DashSegmentedState<T> extends State<DashSegmented<T>> {
  final _stack = GlobalKey();
  final _keys = <GlobalKey>[];
  Rect? _thumb;

  static const _pill = BorderRadius.all(Radius.circular(6));

  void _measure() {
    if (!mounted) return;
    final i = widget.options.indexWhere((o) => o.$1 == widget.value);
    final stack = _stack.currentContext?.findRenderObject() as RenderBox?;
    final box = i < 0 || i >= _keys.length ? null : _keys[i].currentContext?.findRenderObject() as RenderBox?;
    if (stack == null || box == null || !stack.hasSize || !box.hasSize) return;
    final r = box.localToGlobal(Offset.zero, ancestor: stack) & box.size;
    if (r != _thumb) setState(() => _thumb = r);
  }

  @override
  Widget build(BuildContext context) {
    while (_keys.length < widget.options.length) {
      _keys.add(GlobalKey());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    final still = MediaQuery.disableAnimationsOf(context);
    final thumb = _thumb;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(8)),
      child: Stack(
        key: _stack,
        children: [
          if (thumb != null)
            AnimatedPositioned(
              duration: still ? Duration.zero : const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              left: thumb.left,
              top: thumb.top,
              width: thumb.width,
              height: thumb.height,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: _pill,
                    border: Border.all(color: DashUi.line),
                    boxShadow: [
                      BoxShadow(color: DashUi.ink.withValues(alpha: 0.06), blurRadius: 4, offset: const Offset(0, 1)),
                    ],
                  ),
                ),
              ),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < widget.options.length; i++)
                KeyedSubtree(
                  key: _keys[i],
                  child: DashPressable(
                    onTap: widget.options[i].$1 == widget.value ? () {} : () => widget.onChanged(widget.options[i].$1),
                    label: '${widget.label}: ${widget.options[i].$2}',
                    selected: widget.options[i].$1 == widget.value,
                    radius: _pill,
                    builder: (hover) {
                      final on = widget.options[i].$1 == widget.value;
                      // The sliding pill draws the selection once it is measured; before that the option does.
                      final own = on && thumb == null;
                      return AnimatedContainer(
                        duration: still ? Duration.zero : const Duration(milliseconds: 150),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                        decoration: BoxDecoration(
                          color: own
                              ? Colors.white
                              : (hover && !on
                                    ? Colors.white.withValues(alpha: 0.6)
                                    : Colors.white.withValues(alpha: 0)),
                          borderRadius: _pill,
                          border: Border.all(color: own ? DashUi.line : DashUi.line.withValues(alpha: 0)),
                        ),
                        child: AnimatedDefaultTextStyle(
                          duration: still ? Duration.zero : const Duration(milliseconds: 200),
                          // Merged, so the labels keep the app's font (this replaces the ambient style).
                          style: DefaultTextStyle.of(context).style.merge(
                            TextStyle(
                              fontSize: 12.5,
                              height: 1.3,
                              fontWeight: on ? FontWeight.w700 : FontWeight.w600,
                              color: on ? DashUi.ink : DashUi.slate,
                            ),
                          ),
                          child: Text(widget.options[i].$2, maxLines: 1),
                        ),
                      );
                    },
                  ),
                ),
            ],
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
      tooltip:
          '$what in ${parts.first} against ${parts.last}, the last two finished months. '
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
                Text(
                  text,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, height: 1.3, color: color),
                ),
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
            Container(
              width: 4,
              height: 2.5,
              margin: EdgeInsets.only(right: i == 2 ? 0 : 2),
              color: color,
            ),
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
        Flexible(
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashText.legend),
        ),
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

  /// The finding, after the title ("led by residential (41%)"); the biggest part and its share when not given.
  final String? finding;
  const DashSplitPanel({
    super.key,
    required this.g,
    required this.title,
    this.note,
    required this.items,
    required this.emptyText,
    this.tooltip,
    this.finding,
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
            if (total > 0) ...[
              const SizedBox(width: 4),
              Flexible(
                flex: 3,
                child: Text(
                  '· ${finding ?? _biggest(total)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DashText.meta.copyWith(fontWeight: FontWeight.w700, color: DashUi.slate),
                ),
              ),
            ],
            const SizedBox(width: 16),
            Expanded(flex: 2, child: total <= 0 ? const SizedBox.shrink() : _splitBar(total)),
          ],
        ),
      ),
      child: total <= 0
          ? SizedBox(
              height: g.line(13) + 3 + g.line(15, 1.2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(emptyText, style: DashText.empty),
              ),
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

  /// "mostly residential (62%)" when the biggest part is the majority, "led by residential (41%)" when it isn't.
  String _biggest(double total) {
    final top = items.reduce((a, b) => b.amount > a.amount ? b : a);
    final lead = top.amount * 2 > total ? 'mostly' : 'led by';
    return '$lead ${top.label.toLowerCase()} (${dashShare(top.amount, total)})';
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
            SizedBox(
              height: rowH,
              child: const Align(alignment: Alignment.centerLeft, child: SkeletonBox(h: 12)),
            ),
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

  /// Months (0-11) with no figure at all, as opposed to a real 0: a line breaks over them and draws no point there
  /// (e.g. the rest of the team's labor a day in a month none of them has worked yet). Bars ignore it.
  final Set<int> gaps;

  /// Bars under zero drawn in this colour instead (a month that lost money), keyed as [belowLabel].
  final Color? below;
  final String belowLabel;
  const DashSeries(
    this.label,
    this.values,
    this.color, {
    this.kind = DashSeriesKind.bar,
    this.gaps = const {},
    this.below,
    this.belowLabel = 'Below zero',
  });

  /// The colour of the bar for [value].
  Color colorFor(double value) => value < 0 && below != null ? below! : color;
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

  /// The story (dash_story.dart): figures that answer the chart's question, shown over it ([DashStoryStat]s), and one
  /// line naming the finding. With a story the key moves under the chart, like the KPI pages' charts.
  final List<Widget>? headline;
  final String? callout;
  final Color calloutColor;

  /// A line-only view drawn as a headline line ([_DashChartPainter._liveLine]): smooth, shaded against the target
  /// ([average]), with the latest month's point pulsing (the only part of the chart that keeps moving).
  final bool liveLine;
  DashChartView({
    DashStory? story,
    List<Widget>? headline,
    String? callout,
    Color? calloutColor,
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
    this.liveLine = false,
  }) : headline = headline ?? story?.headline,
       callout = callout ?? story?.callout,
       calloutColor = calloutColor ?? story?.calloutColor ?? DashUi.slate;

  List<DashSeries> get bars => [
    for (final s in series)
      if (s.kind == DashSeriesKind.bar) s,
  ];
  DashSeries? get line => series.where((s) => s.kind == DashSeriesKind.line).firstOrNull;
}

class _MonthIntent extends Intent {
  final int delta;
  const _MonthIntent(this.delta);
}

/// Twelve months in a panel: bars for the year shown (the month in progress lighter, months to come empty), last
/// year's ticks, a line, an average. Hover or the arrow keys pick a month and a tooltip beside it reads it out; a
/// toggle in the title row switches between [views] (on its own only when [autoCycle] is set).
class DashMonthChart extends StatefulWidget {
  final List<DashChartView> views;
  final int year;

  /// Called when the view changes (a page can keep the choice).
  final ValueChanged<int>? onView;
  final int initialView;

  /// Step to the next view this often (the KPI pages; the dashboards leave it off). It holds while the pointer is on
  /// the chart or it has keyboard focus, never runs with reduced motion, and a view picked by hand restarts the wait.
  final Duration? autoCycle;
  const DashMonthChart({
    super.key,
    required this.views,
    required this.year,
    this.onView,
    this.initialView = 0,
    this.autoCycle,
  });

  @override
  State<DashMonthChart> createState() => _DashMonthChartState();
}

class _DashMonthChartState extends State<DashMonthChart> with TickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  /// The latest point's pulse on a [DashChartView.liveLine] view; still on every other view.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );
  late int _view = widget.initialView.clamp(0, widget.views.length - 1);

  /// The month under the pointer, or picked with the arrow keys.
  int? _index;
  bool _focused = false;

  /// [DashMonthChart.autoCycle]: the timer, and whether the pointer is over the panel.
  Timer? _cycle;
  bool _pointerIn = false;

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
    _restartCycle();
  }

  void _restartCycle() {
    _cycle?.cancel();
    final every = widget.autoCycle;
    if (every == null) return;
    _cycle = Timer.periodic(every, (_) {
      // Also still while the page is off screen (another branch of the app's tabs is showing): tickers are off there.
      if (!mounted ||
          _pointerIn ||
          _focused ||
          _reduceMotion ||
          widget.views.length < 2 ||
          !TickerMode.getValuesNotifier(context).value.enabled)
        return;
      _show((_view + 1) % widget.views.length);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduceMotion) {
      _intro.value = 1;
    } else if (_intro.isDismissed) {
      _intro.forward();
    }
    _syncPulse();
  }

  /// The pulse runs only while a [DashChartView.liveLine] view shows and motion is on.
  void _syncPulse() {
    final live = widget.views.isNotEmpty && widget.views[_view.clamp(0, widget.views.length - 1)].liveLine;
    if (live && !_reduceMotion) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse.stop();
      if (_pulse.value != 0.35) _pulse.value = 0.35;
    }
  }

  @override
  void didUpdateWidget(covariant DashMonthChart old) {
    super.didUpdateWidget(old);
    if (_view >= widget.views.length) _view = 0;
    if (old.year != widget.year) _replay();
    _syncPulse();
  }

  @override
  void dispose() {
    _cycle?.cancel();
    _intro.dispose();
    _pulse.dispose();
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

  /// A view picked by hand: shows it and restarts the auto-cycle's wait.

  void _setView(int i) {
    _show(i);
    _restartCycle();
  }

  void _show(int i) {
    if (i == _view) return;
    setState(() {
      _view = i;
      _replay();
    });
    _syncPulse();
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
      for (final b in bars)
        if (b.below != null && b.values.any((x) => x < 0)) DashLegendSwatch(color: b.below!, text: b.belowLabel),
      if (inProgress != null && inProgress >= 0 && bars.isNotEmpty && bars.first.values[inProgress] != 0)
        DashLegendSwatch(color: bars.first.color, text: '${dashMonthNames[inProgress]} so far', outlined: true),
      if (v.prior != null && v.prior!.any((p) => p != 0))
        DashLegendSwatch(color: DashUi.slate, text: v.priorLabel, tick: true),
      if (v.line != null) DashLegendSwatch(color: v.line!.color, text: v.line!.label, tick: true),
      if (v.average != null && v.averageLabel != null)
        DashLegendSwatch(color: DashUi.subtle, text: v.averageLabel!, dashed: true),
    ];

    final titleSpan = TextSpan(
      children: [
        TextSpan(text: v.title, style: DashText.panelTitle),
        if (v.note != null) TextSpan(text: ' · ${v.note}', style: DashText.panelNote),
      ],
    );
    Widget titleRow(bool badge) => Row(
      children: [
        Flexible(
          child: Semantics(
            header: true,
            label: v.note == null ? v.title : '${v.title}, ${v.note}',
            child: ExcludeSemantics(child: Text.rich(titleSpan, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ),
        ),
        if (badge) ...[const SizedBox(width: 10), v.badge!],
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
    final story = !empty && v.callout != null;
    // A story puts the key under the chart, so the title row carries only the title and the toggle.
    final showLegend = !empty && legend.isNotEmpty && !story;

    // The toggle shares the title's row when both fit; otherwise it moves down beside the legend, so the title is
    // never the one cut short.
    final header = LayoutBuilder(
      builder: (context, c) {
        bool fits(bool badge) =>
            toggle == null || _titleWidth(context, titleSpan, badge) + 12 + _toggleWidth(context) <= c.maxWidth;
        // With a story the headline already says how the year is going, so a change chip that would push the toggle
        // onto a row of its own (and take that height from the chart) is left out.
        final badge = v.badge != null && !empty && (!story || fits(true));
        final inline = fits(badge);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(child: titleRow(badge)),
                if (inline && toggle != null) ...[const SizedBox(width: 12), toggle],
              ],
            ),
            if (inline && showLegend) ...[const SizedBox(height: 6), legendWrap],
            if (!inline &&
                (!showLegend || _legendWidth(context, legendEntries) + 12 + _toggleWidth(context) <= c.maxWidth)) ...[
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: showLegend ? legendWrap : const SizedBox.shrink()),
                  const SizedBox(width: 12),
                  ?toggle,
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

    final Widget chart = empty
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
                _MonthIntent: CallbackAction<_MonthIntent>(
                  onInvoke: (i) {
                    _step(i.delta);
                    return null;
                  },
                ),
                DismissIntent: CallbackAction<DismissIntent>(
                  onInvoke: (_) {
                    setState(() => _index = null);
                    return null;
                  },
                ),
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
                                animation: Listenable.merge([_intro, _pulse]),
                                builder: (context, _) => CustomPaint(
                                  size: Size(c.maxWidth, c.maxHeight),
                                  painter: _DashChartPainter(
                                    view: v,
                                    hover: _index,
                                    inProgress: inProgress,
                                    intro: Curves.easeOutCubic.transform(_intro.value),
                                    pulse: v.liveLine ? _pulse.value : 0,
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
          );
    final panel = DashPanel(
      fill: true,
      header: header,
      child: !story
          ? chart
          : DashStoryFrame(
              headline: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  for (final (k, stat) in (v.headline ?? const <Widget>[]).indexed) ...[
                    if (k > 0) const SizedBox(width: 22),
                    stat,
                  ],
                ],
              ),
              callout: v.callout!,
              calloutColor: v.calloutColor,
              chart: chart,
              legend: legend.isEmpty ? null : Wrap(spacing: 14, runSpacing: 4, children: legend),
            ),
    );
    if (widget.autoCycle == null) return panel;
    // The auto-cycle holds while the pointer is anywhere on the panel (reading a month, reaching for the toggle).
    return MouseRegion(onEnter: (_) => _pointerIn = true, onExit: (_) => _pointerIn = false, child: panel);
  }

  double _measure(BuildContext context, InlineSpan span) => (TextPainter(
    text: span,
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout()).width;

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
      w +=
          _measure(
            context,
            TextSpan(
              text: view.tab,
              style: base.merge(const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
            ),
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
          decoration: dashTipDecoration,
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
                      Expanded(
                        child: Text(r.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: dim),
                      ),
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

  /// The latest point's pulse, 0 to 1 and round again ([DashChartView.liveLine] only).
  final double pulse;
  final String? fontFamily;

  const _DashChartPainter({
    required this.view,
    required this.hover,
    required this.inProgress,
    required this.intro,
    this.pulse = 0,
    required this.fontFamily,
  });

  void _text(Canvas canvas, String s, Offset at, TextStyle style, {TextAlign align = TextAlign.left, Color? backing}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: style.copyWith(fontFamily: fontFamily),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = align == TextAlign.right ? at.dx - tp.width : (align == TextAlign.center ? at.dx - tp.width / 2 : at.dx);
    final top = Offset(dx, at.dy - tp.height / 2);
    if (backing != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius((top & tp.size).inflate(2), const Radius.circular(3)),
        Paint()..color = backing,
      );
    }
    tp.paint(canvas, top);
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
      if (line != null && !line.gaps.contains(i)) {
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
    // Bar labels the average line crosses, drawn after it.
    final onLine = <(String, Offset, TextStyle)>[];

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
            drawBar(x, barW, 0, bars[b].values[i], bars[b].colorFor(bars[b].values[i]));
          }
          barTop = y(bars.fold<double>(0, (m, b) => math.max(m, b.values[i])));
        } else {
          drawBar(cx - barW / 2, barW, 0, bars.first.values[i], bars.first.colorFor(bars.first.values[i]));
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
        final label = (
          v.barLabel!(bars.first.values[i]),
          Offset(cx, labelY),
          TextStyle(
            fontSize: 11.5,
            fontWeight: focus ? FontWeight.w800 : FontWeight.w600,
            color: (focus ? DashUi.ink : DashUi.slate).withValues(alpha: labelAlpha * (dim ? 0.45 : 1)),
            fontFeatures: DashText.tabular,
          ),
        );
        // A label the dashed average line would cross (a bar a little under the average) stays on its bar and is
        // drawn after the line, on a patch of the panel's white, so neither the figure nor the bar's height misleads.
        final avg = v.average;
        if (avg != null && avg > 0 && (labelY - y(avg)).abs() < 9) {
          onLine.add(label);
        } else {
          _text(canvas, label.$1, label.$2, label.$3, align: TextAlign.center);
        }
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
    for (final (text, at, style) in onLine) {
      _text(canvas, text, at, style, align: TextAlign.center, backing: Colors.white);
    }

    if (line != null && v.liveLine) {
      _liveLine(canvas, plot, slot, y, line);
    } else if (line != null) {
      // Each point keeps its month, so a gap (a month with no figure) breaks the line and the hover still matches.
      final pts = <(int, Offset)>[
        for (var i = 0; i < 12; i++)
          if (!_future(i) && !line.gaps.contains(i)) (i, Offset(plot.left + slot * i + slot / 2, y(line.values[i]))),
      ];
      final path = Path();
      for (var k = 0; k < pts.length; k++) {
        final (month, at) = pts[k];
        if (k == 0 || pts[k - 1].$1 != month - 1) {
          path.moveTo(at.dx, at.dy);
        } else {
          path.lineTo(at.dx, at.dy);
        }
      }
      // Every piece draws itself in together as the chart opens.
      for (final metric in path.computeMetrics()) {
        if (metric.length <= 0) continue;
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
      if (intro >= 1) {
        for (final (month, at) in pts) {
          final focus = hover == month;
          canvas.drawCircle(at, focus ? 4.5 : 3, Paint()..color = Colors.white);
          canvas.drawCircle(
            at,
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

  /// [DashChartView.liveLine]: a smooth curve that draws itself in left to right, the gap to the target ([average])
  /// shaded green above it and red below it, each finished month's point ringed green or red against the target, the
  /// month in progress joined by a dashed stretch, and the latest point pulsing with its figure in a pill over it.
  void _liveLine(Canvas canvas, Rect plot, double slot, double Function(double) y, DashSeries line) {
    final idx = [
      for (var i = 0; i < 12; i++)
        if (!_future(i)) i,
    ];
    if (idx.isEmpty) return;
    final pts = [for (final i in idx) Offset(plot.left + slot * i + slot / 2, y(line.values[i]))];
    final target = view.average != null && view.average! > 0 ? view.average : null;
    final partial = pts.length >= 2 && idx.last == inProgress;

    // Level tangents at every point: smooth, and it never swings past a month's own figure.
    Path curve(List<Offset> p) {
      final path = Path()..moveTo(p.first.dx, p.first.dy);
      for (var k = 1; k < p.length; k++) {
        final mid = (p[k - 1].dx + p[k].dx) / 2;
        path.cubicTo(mid, p[k - 1].dy, mid, p[k].dy, p[k].dx, p[k].dy);
      }
      return path;
    }

    final full = curve(pts);
    final reveal = pts.first.dx + (pts.last.dx - pts.first.dx) * intro;
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(plot.left, plot.top - top, reveal + 8, plot.bottom + 1));

    if (pts.length >= 2) {
      if (target != null) {
        // The gap between the line and the target: green where it's over, red where it's under.
        final ty = y(target);
        final band = Path.from(full)
          ..lineTo(pts.last.dx, ty)
          ..lineTo(pts.first.dx, ty)
          ..close();
        for (final (over, color) in [(true, DashUi.emerald), (false, DashUi.red)]) {
          final zone = over
              ? Rect.fromLTRB(plot.left, plot.top - top, plot.right, ty)
              : Rect.fromLTRB(plot.left, ty, plot.right, plot.bottom);
          canvas.save();
          canvas.clipRect(zone);
          canvas.drawPath(
            band,
            Paint()
              ..shader = LinearGradient(
                begin: over ? Alignment.bottomCenter : Alignment.topCenter,
                end: over ? Alignment.topCenter : Alignment.bottomCenter,
                colors: [color.withValues(alpha: 0.04), color.withValues(alpha: 0.16)],
              ).createShader(zone),
          );
          canvas.restore();
        }
      } else {
        final area = Path.from(full)
          ..lineTo(pts.last.dx, plot.bottom)
          ..lineTo(pts.first.dx, plot.bottom)
          ..close();
        canvas.drawPath(
          area,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [line.color.withValues(alpha: 0.2), line.color.withValues(alpha: 0)],
            ).createShader(plot),
        );
      }

      // A soft glow under the line, then the line: solid through the finished months, dashed into this one.
      Paint stroke(Color c, double w) => Paint()
        ..color = c
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(full, stroke(line.color.withValues(alpha: 0.14), 8));
      if (!partial || pts.length > 2) {
        canvas.drawPath(partial ? curve(pts.sublist(0, pts.length - 1)) : full, stroke(line.color, 2.6));
      }
      if (partial) {
        final a = pts[pts.length - 2], b = pts.last, mid = (a.dx + b.dx) / 2;
        final tail = Path()
          ..moveTo(a.dx, a.dy)
          ..cubicTo(mid, a.dy, mid, b.dy, b.dx, b.dy);
        for (final m in tail.computeMetrics()) {
          for (var d = 0.0; d < m.length; d += 9) {
            canvas.drawPath(m.extractPath(d, math.min(d + 5, m.length)), stroke(line.color, 2.6));
          }
        }
      }
    }

    // Finished months' points, ringed by how they did against the target.
    for (var k = 0; k < pts.length - 1; k++) {
      final i = idx[k];
      final focus = hover == i;
      final value = line.values[i];
      final ring = target == null ? line.color : (value >= target ? DashUi.emerald : DashUi.red);
      final r = focus ? 5.0 : 3.6;
      canvas.drawCircle(pts[k], r, Paint()..color = Colors.white);
      canvas.drawCircle(
        pts[k],
        r,
        Paint()
          ..color = ring.withValues(alpha: hover != null && !focus ? 0.45 : 1)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2,
      );
    }
    canvas.restore();

    // The latest point once the line reaches it: two rings spreading out from it, the dot, and its figure in a pill.
    final arrive = ((intro - 0.85) / 0.15).clamp(0.0, 1.0);
    if (arrive <= 0) return;
    final p = pts.last;
    final value = line.values[idx.last];
    for (final phase in [pulse, (pulse + 0.5) % 1]) {
      canvas.drawCircle(
        p,
        5 + 13 * Curves.easeOut.transform(phase),
        Paint()..color = line.color.withValues(alpha: 0.3 * (1 - phase) * arrive),
      );
    }
    canvas.drawCircle(p, 6.5 * arrive, Paint()..color = Colors.white);
    canvas.drawCircle(p, 4.5 * arrive, Paint()..color = line.color);

    final tp = TextPainter(
      text: TextSpan(
        text: '${(view.barLabel ?? view.axis)(value)}${partial ? ' so far' : ''}',
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
          height: 1.2,
          color: Colors.white.withValues(alpha: arrive),
          fontFamily: fontFamily,
          fontFeatures: DashText.tabular,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final w = tp.width + 14, h = tp.height + 6;
    final above = p.dy - 14 - h >= plot.top - top + 2;
    final box = Rect.fromLTWH(
      (p.dx - w / 2).clamp(plot.left, math.max(plot.left, plot.right - w)),
      above ? p.dy - 14 - h : p.dy + 14,
      w,
      h,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(box, Radius.circular(h / 2)),
      Paint()..color = DashUi.ink.withValues(alpha: 0.92 * arrive),
    );
    tp.paint(canvas, Offset(box.left + 7, box.top + 3));
  }

  @override
  bool shouldRepaint(covariant _DashChartPainter old) =>
      !identical(old.view, view) ||
      old.hover != hover ||
      old.intro != intro ||
      old.pulse != pulse ||
      old.inProgress != inProgress ||
      old.fontFamily != fontFamily;
}
