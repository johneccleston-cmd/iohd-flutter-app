// Charts that tell a story: the answer in words and figures first (a headline that counts up, and one line naming the
// finding), then the evidence (the chart), then a key saying what each mark means. Shared by the dashboards and the KPI
// pages so the same chart reads the same everywhere.
//
// DashCashByMonth is the "Cash collected by month" chart: it started on the office KPI page and now lives on the
// Collections dashboard.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dashboard_data.dart';
import 'dashboard_kit.dart';
import 'dashboard_panels.dart';

/// The dashed average line's colour (and its key): the same slate as [DashMonthChart]'s average, so a reference line
/// never reads as a warning.
const dashAverageLine = DashUi.subtle;

/// The best month's diamond (and its key), and the warm highlight other marks borrow.
const dashBestMark = Color(0xFFF59E0B);

String _commas(int v) => v.abs().toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');

/// "$2,512,579".
String dashWholeMoney(double v) => '${v < 0 ? '−' : ''}\$${_commas(v.round())}';

/// An axis label: "$375k", "$1.2M".
String _axisMoney(double v) {
  String trim(double x) => x == x.roundToDouble() ? '${x.round()}' : x.toStringAsFixed(1);
  if (v.abs() >= 1000000) return '\$${trim(v / 1000000)}M';
  if (v.abs() >= 1000) return '\$${trim(v / 1000)}k';
  return '\$${v.round()}';
}

// =============================================================================
// THE STORY'S PIECES
// =============================================================================

/// A headline figure that counts up, with a word or two after it ("$2,512,579 collected so far in 2026").
class DashStoryStat extends StatelessWidget {
  final double value;
  final String Function(double) format;
  final String label;
  final Color color;
  const DashStoryStat(this.value, this.format, this.label, this.color, {super.key});

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(begin: still ? value : 0, end: value),
          duration: still ? Duration.zero : const Duration(milliseconds: 900),
          curve: Curves.easeOutCubic,
          builder: (context, x, _) => Text(
            format(x),
            maxLines: 1,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              height: 1.1,
              color: color,
              fontFeatures: DashText.tabular,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, maxLines: 1, style: DashText.meta.copyWith(fontSize: 12.5, color: DashUi.slate)),
      ],
    );
  }
}

/// A key entry under a chart: a swatch and what it means.
Widget dashKeyItem(Widget swatch, String text) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    swatch,
    const SizedBox(width: 6),
    Text(text, maxLines: 1, style: DashText.meta),
  ],
);

/// A bar's swatch for the key.
Widget dashKeyBox(Color fill, {Color? border}) => Container(
  width: 14,
  height: 9,
  decoration: BoxDecoration(
    color: fill,
    borderRadius: BorderRadius.circular(3),
    border: border == null ? null : Border.all(color: border, width: 1.2),
  ),
);

/// The key's swatch for a dashed line.
Widget dashDashedKey([Color color = dashAverageLine]) => Row(
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

/// The key's swatch for the best month's diamond.
Widget dashDiamondKey([Color color = dashBestMark]) => Transform.rotate(
  angle: math.pi / 4,
  child: Container(width: 7, height: 7, color: color),
);

/// The frame of a story: a headline of figures and one line naming the finding (with an action at the right), the
/// chart under it, and the key. The key is left out when the chart labels its own marks.
class DashStoryFrame extends StatelessWidget {
  final Widget headline;
  final String callout;
  final Color calloutColor;
  final Widget? action;
  final Widget chart;
  final Widget? legend;
  const DashStoryFrame({
    super.key,
    required this.headline,
    required this.callout,
    required this.calloutColor,
    this.action,
    required this.chart,
    this.legend,
  });

  /// The headline and callout's height.
  static double headHeight(DashGeo g) => g.line(22, 1.1) + g.line(12) + 2;

  /// The key's height and the gap over it.
  static double keyHeight(DashGeo g) => 8 + g.line(12) + 2;

  /// Below this the chart would be too short to read, so the key gives up its row (the headline and the chart's own
  /// labels still say what the marks are); if that is still not enough, the headline shrinks onto one line with the
  /// callout beside it.
  static const _minChart = 110.0;

  /// The one-line headline of a short chart.
  static double compactHeight(DashGeo g) => g.line(17, 1.15);

  @override
  Widget build(BuildContext context) {
    final g = DashGeo.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final room = c.maxHeight.isFinite ? c.maxHeight - headHeight(g) - 12 : double.infinity;
        final keyed = legend != null && room - keyHeight(g) >= _minChart;
        return _frame(g, keyed, compact: !keyed && room < _minChart);
      },
    );
  }

  Widget _frame(DashGeo g, bool keyed, {bool compact = false}) {
    final calloutText = _Callout(callout, calloutColor);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (compact)
          SizedBox(
            height: compactHeight(g),
            child: Row(
              children: [
                Flexible(
                  flex: 3,
                  child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: headline),
                ),
                const SizedBox(width: 14),
                Flexible(flex: 2, child: calloutText),
                if (action != null) ...[const SizedBox(width: 12), action!],
              ],
            ),
          )
        else
          SizedBox(
            height: headHeight(g),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: headline),
                      ),
                      calloutText,
                    ],
                  ),
                ),
                if (action != null) ...[const SizedBox(width: 12), action!],
              ],
            ),
          ),
        SizedBox(height: compact ? 8 : 12),
        Expanded(child: chart),
        if (keyed) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: g.line(12) + 2,
            child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: legend),
          ),
        ],
      ],
    );
  }
}

/// A story's finding on one line. When the whole of it doesn't fit, its last " · " parts give way one at a time (the
/// first part is the main finding), so a narrow chart reads a shorter sentence instead of one cut off mid-word.
class _Callout extends StatelessWidget {
  final String text;
  final Color color;
  const _Callout(this.text, this.color);

  @override
  Widget build(BuildContext context) {
    final style = DashText.meta.copyWith(fontWeight: FontWeight.w700, color: color);
    final measure = DefaultTextStyle.of(context).style.merge(style);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, c) {
        final parts = text.split(' · ');
        var shown = text;
        for (var n = parts.length; n > 1 && c.maxWidth.isFinite; n--) {
          shown = parts.take(n).join(' · ');
          final tp = TextPainter(
            text: TextSpan(text: shown, style: measure),
            textDirection: TextDirection.ltr,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          final fits = tp.width <= c.maxWidth;
          tp.dispose();
          if (fits) break;
          shown = parts.take(n - 1).join(' · ');
        }
        return Text(shown, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
      },
    );
  }
}

// =============================================================================
// CASH COLLECTED BY MONTH
// =============================================================================

/// Cash as a question: how much came in, and when? The headline answers it (the year's cash and the monthly average)
/// and names the best month; under it each month is a bar against the dashed average, the best month marked with a
/// diamond and the month in progress drawn lighter. Hover a month (or use the arrow keys) for its exact cash, the
/// change on the month before and, given [prior], the same month a year earlier.
class DashCashByMonth extends StatelessWidget {
  /// Twelve months from January.
  final List<double> monthly;
  final int year;

  /// The year's total when it isn't the months added up (net of refunds, say); the months' sum otherwise.
  final double? total;

  /// The twelve months of the year before, for the tooltip.
  final List<double>? prior;
  const DashCashByMonth({super.key, required this.monthly, required this.year, this.total, this.prior});

  @override
  Widget build(BuildContext context) {
    final now = DashClock.now();
    final shown = year == now.year ? now.month : (year < now.year ? 12 : 0);
    final values = <double?>[for (var m = 0; m < 12; m++) m < shown && m < monthly.length ? monthly[m] : null];
    final sum = values.whereType<double>().fold<double>(0, (t, v) => t + v);
    final total = this.total ?? sum;
    if (sum <= 0 && total <= 0) return DashEmptyNote('No payments recorded in $year.');

    // The month in progress isn't a whole month, so the average and the best month use the ones that are over.
    final partial = year == now.year ? now.month - 1 : null;
    final over = [
      for (var m = 0; m < shown; m++)
        if (m != partial && m < monthly.length) m,
    ];
    final average = over.isEmpty ? null : over.fold<double>(0, (t, m) => t + monthly[m]) / over.length;
    int? best;
    for (final m in over) {
      if (best == null || monthly[m] > monthly[best]) best = m;
    }
    if (best != null && monthly[best] <= 0) best = null;

    final String callout;
    var calloutColor = DashUi.emeraldText;
    if (best == null) {
      callout = 'The first month is still in progress';
      calloutColor = DashUi.slate;
    } else {
      callout = 'Best month: ${dashMonthNames[best]}, ${dashWholeMoney(monthly[best])}';
    }
    final headline = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        DashStoryStat(
          total,
          dashWholeMoney,
          year == now.year ? 'collected so far in $year' : 'collected in $year',
          DashUi.emeraldText,
        ),
        if (average != null) ...[
          const SizedBox(width: 22),
          DashStoryStat(average, dashWholeMoney, 'a month on average', DashUi.ink),
        ],
      ],
    );
    final showPartial = partial != null && (values[partial] ?? 0) > 0;
    return Semantics(
      label: '${dashWholeMoney(total)} collected in $year. $callout.',
      child: DashStoryFrame(
        headline: headline,
        callout: callout,
        calloutColor: calloutColor,
        chart: DashMonthBars(
          values: values,
          year: year,
          prior: prior,
          partial: partial,
          average: average,
          best: best,
          color: DashUi.emerald,
          label: 'Cash collected by month, $year',
        ),
        legend: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            dashKeyItem(dashKeyBox(DashUi.emerald), 'Cash collected'),
            if (showPartial) ...[
              const SizedBox(width: 16),
              dashKeyItem(
                dashKeyBox(DashUi.emerald.withValues(alpha: 0.35), border: DashUi.emerald),
                '${dashMonthNames[partial]} so far',
              ),
            ],
            if (average != null) ...[
              const SizedBox(width: 16),
              dashKeyItem(dashDashedKey(), 'Average month'),
            ],
            if (best != null) ...[const SizedBox(width: 16), dashKeyItem(dashDiamondKey(), 'Best month')],
          ],
        ),
      ),
    );
  }
}

class _MonthStep extends Intent {
  final int delta;
  const _MonthStep(this.delta);
}

/// Twelve monthly bars from zero: gradient bars that grow in one after another, the dashed [average], a diamond over
/// the [best] month, the [partial] month lighter with an outline and "so far" under it. Hovering (or the arrow keys)
/// lifts one month and shows its figures in a dark tooltip beside it. [values] has null for months that haven't
/// happened.
///
/// Optional extras: [inner], a part of each bar drawn solid inside it from the bottom (the profit inside the sales, say);
/// [labelFormat], a figure over each bar; [axisFormat] for the side (money by default); [maxValue], a fixed top of
/// the axis (100 for a rate); and [detail], more lines for a month's tooltip.
class DashMonthBars extends StatefulWidget {
  final List<double?> values;
  final int year;
  final List<double>? prior;
  final int? partial;
  final double? average;
  final int? best;
  final Color color;

  /// What the chart is, for screen readers.
  final String label;
  final String Function(double) format;
  final List<double?>? inner;
  final Color? innerColor;
  final String Function(double)? axisFormat;
  final String Function(double)? labelFormat;
  final double? maxValue;
  final List<String> Function(int month)? detail;

  /// Whether a month's tooltip gives the change on the month before (off for a rate, where a % change of a % misleads).
  final bool compare;
  const DashMonthBars({
    super.key,
    required this.values,
    required this.year,
    required this.color,
    required this.label,
    this.prior,
    this.partial,
    this.average,
    this.best,
    this.format = dashWholeMoney,
    this.inner,
    this.innerColor,
    this.axisFormat,
    this.labelFormat,
    this.maxValue,
    this.detail,
    this.compare = true,
  });

  @override
  State<DashMonthBars> createState() => _DashMonthBarsState();
}

class _DashMonthBarsState extends State<DashMonthBars> with TickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  late final AnimationController _hover = AnimationController(vsync: this, duration: const Duration(milliseconds: 160));

  /// The month under the pointer or picked with the arrow keys; [_painted] keeps it while the highlight fades out.
  int? _index;
  int? _painted;
  bool _focused = false;

  bool get _still => MediaQuery.disableAnimationsOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_still) {
      _intro.value = 1;
    } else if (_intro.isDismissed) {
      _intro.forward();
    }
  }

  @override
  void didUpdateWidget(covariant DashMonthBars old) {
    super.didUpdateWidget(old);
    if (old.year != widget.year || !_same(old.values, widget.values)) {
      _index = null;
      _painted = null;
      _hover.value = 0;
      _still ? _intro.value = 1 : _intro.forward(from: 0);
    }
  }

  static bool _same(List<double?> a, List<double?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _intro.dispose();
    _hover.dispose();
    super.dispose();
  }

  List<int> get _months => [
    for (var i = 0; i < widget.values.length; i++)
      if (widget.values[i] != null) i,
  ];

  void _set(int? i) {
    if (i == _index) return;
    setState(() {
      if (i != null) _painted = i;
      _index = i;
    });
    if (_still) {
      _hover.value = i == null ? 0 : 1;
    } else {
      i == null ? _hover.reverse() : _hover.forward();
    }
  }

  int? _indexFor(double dx, double width) {
    final slot = (width - _BarsPainter.left - _BarsPainter.right) / widget.values.length;
    if (slot <= 0) return null;
    final i = ((dx - _BarsPainter.left) / slot).floor();
    return i >= 0 && i < widget.values.length && widget.values[i] != null ? i : null;
  }

  void _step(int delta) {
    final months = _months;
    if (months.isEmpty) return;
    final at = _index == null ? months.length - 1 : (months.indexOf(_index!) + delta).clamp(0, months.length - 1);
    _set(months[at]);
  }

  String _monthName(int i) => '${dashMonthNames[i]} ${widget.year}${i == widget.partial ? ' so far' : ''}';

  String? _change(int i) {
    final v = widget.values;
    if (!widget.compare || i == 0 || i == widget.partial || v[i] == null || v[i - 1] == null || v[i - 1]! <= 0) return null;
    final pct = (v[i]! - v[i - 1]!) / v[i - 1]! * 100;
    return '${pct >= 0 ? '▲' : '▼'} ${pct.abs().round()}% on ${dashMonthNames[i - 1]}';
  }

  /// "▲ 41% on Apr 2025 ($280,098)"; a part month is never compared with a whole one, so it only gives last year's.
  String? _lastYear(int i) {
    final p = widget.prior;
    if (p == null || i >= p.length) return null;
    final then = '${dashMonthNames[i]} ${widget.year - 1}';
    final v = widget.values[i];
    if (i == widget.partial || v == null || p[i] <= 0) {
      return '$then${i == widget.partial ? ' (whole month)' : ''}: ${widget.format(p[i])}';
    }
    final pct = (v - p[i]) / p[i] * 100;
    return '${pct >= 0 ? '▲' : '▼'} ${pct.abs().round()}% on $then (${widget.format(p[i])})';
  }

  String _describe(int i) =>
      ['${_monthName(i)}: ${widget.format(widget.values[i] ?? 0)}', ?_change(i), ?_lastYear(i)].join('. ');

  String _describe2(int i) => [_describe(i), ...?widget.detail?.call(i)].join('. ');

  String _summary() => [for (final i in _months) '${dashMonthNames[i]} ${(widget.axisFormat ?? _axisMoney)(widget.values[i]!)}'].join(', ');

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final font = DefaultTextStyle.of(context).style.fontFamily;
    return Semantics(
      container: true,
      label: w.label,
      value: _index == null ? _summary() : _describe2(_index!),
      hint: 'Left and right arrow keys move between months',
      child: FocusableActionDetector(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowLeft): _MonthStep(-1),
          SingleActivator(LogicalKeyboardKey.arrowRight): _MonthStep(1),
          SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
        },
        actions: {
          _MonthStep: CallbackAction<_MonthStep>(
            onInvoke: (i) {
              _step(i.delta);
              return null;
            },
          ),
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              _set(null);
              return null;
            },
          ),
        },
        onShowFocusHighlight: (v) {
          setState(() => _focused = v);
          // Keyboard focus starts on the latest month; leaving clears the pick.
          v ? _step(0) : _set(null);
        },
        child: ExcludeSemantics(
          child: LayoutBuilder(
            builder: (context, c) => MouseRegion(
              onHover: (e) => _set(_indexFor(e.localPosition.dx, c.maxWidth)),
              onExit: (_) {
                if (!_focused) _set(null);
              },
              child: Container(
                foregroundDecoration: dashFocusRing(_focused, BorderRadius.circular(8)),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    RepaintBoundary(
                      child: AnimatedBuilder(
                        animation: Listenable.merge([_intro, _hover]),
                        builder: (context, _) => CustomPaint(
                          size: Size(c.maxWidth, c.maxHeight),
                          painter: _BarsPainter(
                            values: w.values,
                            color: w.color,
                            partial: w.partial,
                            average: w.average,
                            best: w.best,
                            inner: w.inner,
                            innerColor: w.innerColor,
                            axisFormat: w.axisFormat ?? _axisMoney,
                            labelFormat: w.labelFormat,
                            maxValue: w.maxValue,
                            index: _painted,
                            hover: _hover.value,
                            intro: Curves.easeOutCubic.transform(_intro.value),
                            fontFamily: font,
                          ),
                        ),
                      ),
                    ),
                    if (_index != null) _tooltip(c, _index!),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tooltip(BoxConstraints c, int i) {
    final slot = (c.maxWidth - _BarsPainter.left - _BarsPainter.right) / widget.values.length;
    final cx = _BarsPainter.left + slot * (i + 0.5);
    const tipW = 220.0;
    // Beside the month rather than over it, so the bar and its label stay in sight.
    final right = cx + slot / 2 + 6 + tipW <= c.maxWidth;
    final left = right ? cx + slot / 2 + 4 : math.max(0.0, cx - slot / 2 - 4 - tipW);
    final change = _change(i);
    final last = _lastYear(i);
    final more = widget.detail?.call(i) ?? const <String>[];
    const dim = TextStyle(fontSize: 12, fontWeight: FontWeight.w600, height: 1.3, color: Color(0xFFCBD5E1));
    return Positioned(
      left: left,
      top: 0,
      width: tipW,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: _hover,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: DashUi.ink.withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 10, offset: const Offset(0, 3)),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_monthName(i), style: dim),
                const SizedBox(height: 2),
                Text(
                  widget.format(widget.values[i] ?? 0),
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    height: 1.25,
                    color: Colors.white,
                    fontFeatures: DashText.tabular,
                  ),
                ),
                if (change != null)
                  Text(
                    change,
                    style: dim.copyWith(
                      color: change.startsWith('▲') ? const Color(0xFF6EE7B7) : const Color(0xFFFCA5A5),
                    ),
                  ),
                if (last != null)
                  Text(
                    last,
                    style: last.startsWith('▲')
                        ? dim.copyWith(color: const Color(0xFF6EE7B7))
                        : (last.startsWith('▼') ? dim.copyWith(color: const Color(0xFFFCA5A5)) : dim),
                  ),
                for (final line in more) Text(line, style: dim),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  static const double left = 48, right = 4, top = 12, bottom = 34;

  final List<double?> values;
  final Color color;
  final int? partial;
  final double? average;
  final int? best;
  final List<double?>? inner;
  final Color? innerColor;
  final String Function(double) axisFormat;
  final String Function(double)? labelFormat;
  final double? maxValue;
  final int? index;
  final double hover;
  final double intro;
  final String? fontFamily;
  const _BarsPainter({
    required this.values,
    required this.color,
    required this.partial,
    required this.average,
    required this.best,
    required this.inner,
    required this.innerColor,
    required this.axisFormat,
    required this.labelFormat,
    required this.maxValue,
    required this.index,
    required this.hover,
    required this.intro,
    required this.fontFamily,
  });

  /// The top of the axis: 1, 2, 2.5 or 5 times a power of ten, so the four gridlines are round figures.
  static double niceMax(double max) {
    if (max <= 0) return 1;
    final exp = math.pow(10, (math.log(max) / math.ln10).floor()).toDouble();
    for (final m in const [1, 2, 2.5, 5, 10]) {
      if (m * exp >= max) return m * exp;
    }
    return 10 * exp;
  }

  TextPainter _text(String t, TextStyle style, {double? maxWidth}) => TextPainter(
    text: TextSpan(
      text: t,
      style: style.copyWith(fontFamily: fontFamily),
    ),
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.center,
  )..layout(maxWidth: maxWidth ?? double.infinity);

  @override
  void paint(Canvas canvas, Size size) {
    // Figures over the bars need a line of room above the tallest one.
    final labelled = labelFormat != null;
    final plot = Rect.fromLTRB(left, top + (labelled ? 24 : 0), size.width - right, size.height - bottom);
    if (plot.width <= 0 || plot.height <= 0) return;
    final n = values.length;
    final slot = plot.width / n;
    final focusing = index != null && hover > 0.001;
    // A chart with figures over its bars steps its gridlines by a round amount ($10k, 25%), as many as it needs; the
    // others keep four.
    final top0 = values.whereType<double>().fold<double>(0, math.max);
    var lines = 4;
    var maxV = maxValue ?? niceMax(top0);
    if (labelled) {
      var step = niceMax((maxValue ?? top0) / 4);
      lines = math.max(1, ((maxValue ?? top0) / step - 1e-9).ceil());
      // A short chart keeps its side labels apart: twice the step until there are 22 px between them.
      while (lines > 1 && plot.height / lines < 22) {
        step = niceMax(step * 2);
        lines = math.max(1, ((maxValue ?? top0) / step - 1e-9).ceil());
      }
      maxV = step * lines;
    }
    double y(double v) => plot.bottom - (v / maxV).clamp(0.0, 1.0) * plot.height;

    if (focusing) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(plot.left + index! * slot + 2, plot.top - 6, slot - 4, plot.height + 6),
          const Radius.circular(10),
        ),
        Paint()..color = const Color(0xFFEFF6FF).withValues(alpha: hover),
      );
    }

    // Gridlines and the money up the side.
    for (var i = 0; i <= lines; i++) {
      final v = maxV * i / lines;
      final gy = y(v);
      canvas.drawLine(
        Offset(plot.left, gy),
        Offset(plot.right, gy),
        Paint()
          ..color = i == 0 ? DashUi.line : DashUi.faint
          ..strokeWidth = 1,
      );
      final tp = _text(
        axisFormat(v),
        const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: DashUi.subtle,
          fontFeatures: DashText.tabular,
        ),
      );
      tp.paint(canvas, Offset(left - 8 - tp.width, gy - tp.height / 2));
    }

    // Month names, with "so far" under the month in progress.
    for (var i = 0; i < n; i++) {
      final cx = plot.left + slot * (i + 0.5);
      final focus = focusing && index == i;
      final has = values[i] != null;
      final tp = _text(
        slot < 28 ? dashMonthNames[i][0] : dashMonthNames[i],
        TextStyle(
          fontSize: 12.5,
          fontWeight: focus ? FontWeight.w800 : FontWeight.w600,
          color: focus ? DashUi.ink : (has ? DashUi.slate : const Color(0xFFCBD5E1)),
        ),
        maxWidth: slot,
      );
      tp.paint(canvas, Offset(cx - tp.width / 2, plot.bottom + 7));
      if (i == partial && has && slot >= 34) {
        final so = _text(
          'so far',
          const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: DashUi.subtle),
          maxWidth: slot,
        );
        so.paint(canvas, Offset(cx - so.width / 2, plot.bottom + 7 + tp.height));
      }
    }

    // The bars, one after another.
    final stagger = 0.4 / n;
    for (var i = 0; i < n; i++) {
      final v = values[i];
      if (v == null) continue;
      final cx = plot.left + slot * (i + 0.5);
      final isFocus = focusing && index == i;
      final dim = focusing && !isFocus ? 1 - 0.5 * hover : 1.0;
      final t = Curves.easeOutCubic.transform(((intro - i * stagger) / 0.6).clamp(0.0, 1.0));
      final w = math.min(slot * 0.58, 36.0) + (isFocus ? 4 * hover : 0);
      if (v <= 0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(cx - w / 2, plot.bottom - 3, w, 3), const Radius.circular(2)),
          Paint()..color = DashUi.line,
        );
        continue;
      }
      final h = math.max(3.0, (plot.bottom - y(v)) * t);
      final rect = Rect.fromLTWH(cx - w / 2, plot.bottom - h, w, h);
      final r = Radius.circular(math.min(8, w / 2));
      final rrect = RRect.fromRectAndCorners(
        rect,
        topLeft: r,
        topRight: r,
        bottomLeft: const Radius.circular(2),
        bottomRight: const Radius.circular(2),
      );
      if (isFocus) {
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = color.withValues(alpha: 0.35 * hover)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
        );
      }
      final part = i == partial;
      final alpha = dim * (part ? 0.35 : 1.0);
      canvas.drawRRect(
        rrect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              color.withValues(alpha: alpha),
              Color.lerp(color, Colors.white, 0.4)!.withValues(alpha: alpha),
            ],
          ).createShader(rect),
      );
      // The part of the bar drawn solid inside it, from the bottom.
      final iv = inner == null || i >= inner!.length ? null : inner![i];
      if (iv != null && iv > 0) {
        final ih = math.min(h, (plot.bottom - y(math.min(iv, v))) * t);
        final irect = Rect.fromLTWH(cx - w / 2, plot.bottom - ih, w, ih);
        final ic = innerColor ?? color;
        canvas.save();
        canvas.clipRRect(rrect);
        canvas.drawRect(
          irect,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [ic.withValues(alpha: alpha), Color.lerp(ic, Colors.white, 0.2)!.withValues(alpha: alpha)],
            ).createShader(irect),
        );
        canvas.restore();
      }
      // The month in progress keeps an outline: a part month, not a collapse.
      if (part) {
        canvas.drawRRect(
          rrect.deflate(0.75),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..color = color.withValues(alpha: dim),
        );
      }
      // The figure over the bar fades in as the bar finishes growing.
      var markAt = plot.bottom - h;
      if (labelled && slot >= 30 && t > 0.6) {
        final lp = _text(
          labelFormat!(v),
          TextStyle(
            fontSize: 11,
            fontWeight: isFocus || best == i ? FontWeight.w800 : FontWeight.w700,
            color: (isFocus || best == i ? DashUi.ink : DashUi.slate).withValues(alpha: dim * ((t - 0.6) / 0.4).clamp(0.0, 1.0)),
            fontFeatures: DashText.tabular,
          ),
          maxWidth: slot + 8,
        );
        lp.paint(canvas, Offset(cx - lp.width / 2, markAt - 4 - lp.height));
        markAt -= 4 + lp.height;
      }
      if (best == i && t > 0.98) {
        final c = Offset(cx, markAt - 10);
        final path = Path()
          ..moveTo(c.dx, c.dy - 4.5)
          ..lineTo(c.dx + 4.5, c.dy)
          ..lineTo(c.dx, c.dy + 4.5)
          ..lineTo(c.dx - 4.5, c.dy)
          ..close();
        canvas.drawPath(path, Paint()..color = dashBestMark.withValues(alpha: dim));
      }
    }

    // The dashed average of the finished months.
    final avg = average;
    if (avg != null && avg > 0 && avg <= maxV) {
      final ay = y(avg);
      final paint = Paint()
        ..color = dashAverageLine.withValues(alpha: 0.9 * intro)
        ..strokeWidth = 1.3
        ..strokeCap = StrokeCap.round;
      for (var x = plot.left; x < plot.right; x += 9) {
        canvas.drawLine(Offset(x, ay), Offset(math.min(x + 5, plot.right), ay), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BarsPainter old) =>
      old.intro != intro ||
      old.hover != hover ||
      old.index != index ||
      old.values != values ||
      old.color != color ||
      old.partial != partial ||
      old.average != average ||
      old.best != best ||
      old.inner != inner ||
      old.innerColor != innerColor ||
      old.labelFormat != labelFormat ||
      old.maxValue != maxValue ||
      old.fontFamily != fontFamily;
}

// =============================================================================
// A MONTHLY CHART'S STORY
// =============================================================================

/// The words over a monthly chart: [headline] figures and a [callout] naming the finding.
class DashStory {
  final List<Widget> headline;
  final String callout;
  final Color calloutColor;
  const DashStory(this.headline, this.callout, this.calloutColor);
}

/// The story of twelve monthly [values] for [year]: the [figure] that answers the chart, the change on last year over
/// the same finished months (given [prior]), then the best month (the lowest, when lower is better) and how the latest
/// finished month compares with the average of the finished ones, or with [average] when the chart's dashed line is a
/// different figure (a weighted per-job average, say), in [points] when the values are percentages. A month in
/// progress is never compared, and a year with too little to compare says so in words.
DashStory dashMonthStory({
  required List<double> values,
  required int year,
  required double figure,
  required String Function(double) figureFormat,
  required String figureLabel,
  Color figureColor = DashUi.ink,
  List<double>? prior,
  double? average,
  bool points = false,
  required String Function(double) format,
  String unit = '',
  String bestWord = 'Best month',
  bool higherIsBetter = true,
  List<Widget> extra = const [],
}) {
  final now = DashClock.now();
  final last = year < now.year ? 11 : (year == now.year ? now.month - 1 : -1);
  final partial = year == now.year ? now.month - 1 : null;
  final finished = [
    for (var i = 0; i <= last && i < values.length; i++)
      if (i != partial && values[i] != 0) i,
  ];

  // Every finished month that had something last year, including one with nothing this year: leaving those out
  // would make the change read better than it is.
  final both = prior == null
      ? const <int>[]
      : [
          for (var i = 0; i <= last && i < values.length; i++)
            if (i != partial && i < prior.length && prior[i] > 0) i,
        ];
  final before = both.fold<double>(0, (a, i) => a + prior![i]);
  final change = both.isEmpty || before <= 0
      ? null
      : (both.fold<double>(0, (a, i) => a + values[i]) - before) / before * 100;

  final String callout;
  var color = DashUi.slate;
  if (finished.isEmpty) {
    callout = last < 0 || values.every((v) => v == 0)
        ? 'Nothing recorded for $year yet'
        : 'The first month is still in progress';
  } else if (finished.length == 1) {
    callout = 'Only ${dashMonthNames[finished.first]} is a whole month so far: ${format(values[finished.first])}$unit';
  } else {
    var best = finished.first;
    for (final i in finished) {
      if (higherIsBetter ? values[i] > values[best] : values[i] < values[best]) best = i;
    }
    final avg = average ?? finished.fold<double>(0, (a, i) => a + values[i]) / finished.length;
    final latest = finished.last;
    // A rate is compared in points ("3 points under"): a percent of a percent ("7% under" for 40% against 43%) misleads.
    final vs = points ? values[latest] - avg : (avg != 0 ? (values[latest] - avg) / avg.abs() * 100 : 0.0);
    final gap = points ? dashCount(vs.abs().round(), 'point') : '${vs.abs().round()}%';
    callout =
        '$bestWord: ${dashMonthNames[best]}, ${format(values[best])}$unit'
        '${latest != best && vs.abs() >= (points ? 1 : 5) ? ' · ${dashMonthNames[latest]} was $gap ${vs < 0 ? 'under' : 'over'} the average' : ''}';
    color = DashUi.emeraldText;
  }
  return DashStory(
    [
      DashStoryStat(figure, figureFormat, figureLabel, figureColor),
      if (change != null)
        DashStoryStat(
          change.abs(),
          (v) => '${change >= 0 ? '▲' : '▼'} ${v.round()}%',
          'on ${year - 1}, same months',
          (change >= 0) == higherIsBetter ? DashUi.emeraldText : DashUi.redText,
        ),
      ...extra,
    ],
    callout,
    color,
  );
}
