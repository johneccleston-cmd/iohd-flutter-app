import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'app_dialog.dart';
import 'dashboard_kit.dart';
import 'focus_ring.dart';

// The Custom range picker for pay-week screens (Payroll). Pay weeks run Monday to Sunday and the server widens any
// range to whole weeks, so this picks whole weeks: a click picks the week the day is in, a second click picks the last
// week, and the band shows exactly the dates the report will cover. Quick picks on the left, two months side by side
// (one on a narrow window), and the chosen dates with their week count next to Apply.
//
//   final r = await showPayWeekRangePicker(context, initial: range, firstDate: DateTime(2020), lastDate: limit);

Future<DateTimeRange?> showPayWeekRangePicker(
  BuildContext context, {
  required DateTimeRange initial,
  required DateTime firstDate,
  required DateTime lastDate,
  DateTime? today,
}) {
  return showDialog<DateTimeRange>(
    context: context,
    builder: (_) => PayWeekRangeDialog(initial: initial, firstDate: firstDate, lastDate: lastDate, today: today),
  );
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime _add(DateTime d, int n) => DateTime(d.year, d.month, d.day + n); // calendar math, safe across DST
DateTime _monday(DateTime d) => _add(_day(d), -(d.weekday - 1));
DateTime _sunday(DateTime d) => _add(_monday(d), 6);
int _between(DateTime a, DateTime b) =>
    DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

class PayWeekRangeDialog extends StatefulWidget {
  final DateTimeRange initial;
  final DateTime firstDate;
  final DateTime lastDate;

  /// Today, for tests; the real date otherwise.
  final DateTime? today;

  const PayWeekRangeDialog({
    super.key,
    required this.initial,
    required this.firstDate,
    required this.lastDate,
    this.today,
  });

  @override
  State<PayWeekRangeDialog> createState() => _PayWeekRangeDialogState();
}

class _Quick {
  final String label;
  final DateTimeRange range;
  const _Quick(this.label, this.range);
}

class _PayWeekRangeDialogState extends State<PayWeekRangeDialog> {
  late DateTime _start = _monday(widget.initial.start); // always a Monday
  late DateTime _end = _sunday(widget.initial.end); // always a Sunday
  DateTime? _anchor; // the first week clicked, while the last one is still to pick
  DateTime? _hover; // Monday of the week under the mouse
  late DateTime _month; // first of the month shown on the left
  int _slide = 0; // which way the months last moved, for the slide

  DateTime get _today => _day(widget.today ?? DateTime.now());

  @override
  void initState() {
    super.initState();
    _month = DateTime(_end.year, _end.month - 1, 1);
  }

  List<_Quick> get _quick {
    final t = _today;
    final wk = _monday(t);
    DateTimeRange weeks(DateTime a, DateTime b) => DateTimeRange(start: _monday(a), end: _sunday(b));
    final q = ((t.month - 1) ~/ 3) * 3 + 1;
    return [
      _Quick('This week', weeks(wk, wk)),
      _Quick('Last week', weeks(_add(wk, -7), _add(wk, -7))),
      _Quick('Last 2 weeks', weeks(_add(wk, -14), _add(wk, -7))),
      _Quick('Last 4 weeks', weeks(_add(wk, -28), _add(wk, -7))),
      _Quick('This month', weeks(DateTime(t.year, t.month, 1), t)),
      _Quick('Last month', weeks(DateTime(t.year, t.month - 1, 1), DateTime(t.year, t.month, 0))),
      _Quick('This quarter', weeks(DateTime(t.year, q, 1), t)),
      _Quick('Year to date', weeks(DateTime(t.year, 1, 1), t)),
      _Quick('Last year', weeks(DateTime(t.year - 1, 1, 1), DateTime(t.year - 1, 12, 31))),
    ];
  }

  bool _weekOpen(DateTime monday) =>
      !monday.isAfter(_day(widget.lastDate)) && !_add(monday, 6).isBefore(_day(widget.firstDate));

  /// The range the band shows: the chosen one, or (while picking the last week) the anchor to the hovered week.
  DateTimeRange get _shown {
    final a = _anchor;
    if (a == null) return DateTimeRange(start: _start, end: _end);
    final h = _hover ?? a;
    final lo = h.isBefore(a) ? h : a, hi = h.isBefore(a) ? a : h;
    return DateTimeRange(start: lo, end: _add(hi, 6));
  }

  void _tapWeek(DateTime monday) {
    if (!_weekOpen(monday)) return;
    setState(() {
      final a = _anchor;
      if (a == null) {
        _anchor = monday;
        _start = monday;
        _end = _add(monday, 6);
      } else {
        final lo = monday.isBefore(a) ? monday : a, hi = monday.isBefore(a) ? a : monday;
        _start = lo;
        _end = _add(hi, 6);
        _anchor = null;
      }
    });
  }

  void _pickQuick(_Quick q) {
    setState(() {
      _start = q.range.start;
      _end = q.range.end;
      _anchor = null;
      final want = DateTime(_end.year, _end.month - 1, 1);
      _slide = want.isAfter(_month) ? 1 : (want.isBefore(_month) ? -1 : _slide);
      _month = want;
    });
  }

  void _shift(int months) => setState(() {
    _slide = months.sign;
    _month = DateTime(_month.year, _month.month + months, 1);
  });

  void _apply() {
    if (_anchor != null) return;
    Navigator.of(context).pop(DateTimeRange(start: _start, end: _end));
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): _apply,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _apply,
      },
      child: Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shadowColor: Colors.black.withValues(alpha: 0.18),
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: DashUi.line)),
        child: LayoutBuilder(
          builder: (context, c) {
            final k = MediaQuery.textScalerOf(context).scale(1);
            final two = c.maxWidth >= 840 * k;
            final rail = c.maxWidth >= 540 * k;
            return ConstrainedBox(
              constraints: BoxConstraints(maxWidth: two ? 840 * k : (rail ? 540 * k : 400)),
              child: SelectionContainer.disabled(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(),
                    const Divider(height: 1, color: DashUi.line),
                    Flexible(
                      child: SingleChildScrollView(
                        child: IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (rail) ...[
                                _rail(),
                                const VerticalDivider(width: 1, color: DashUi.line),
                              ],
                              Expanded(child: _months(two, still)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const Divider(height: 1, color: DashUi.line),
                    _footer(),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 18, 16, 16),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.date_range_rounded, size: 19, color: DashUi.ink),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Pick pay weeks',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: DashUi.ink, letterSpacing: -0.3),
            ),
          ),
          IconButton(
            tooltip: 'Close',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.close_rounded, size: 19, color: DashUi.subtle),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  // ---- Quick picks ------------------------------------------------------------

  Widget _rail() {
    final fmt = DateFormat('MMM d');
    return Container(
      width: 176 * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.4),
      color: const Color(0xFFFAFAFA),
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final q in _quick)
            Builder(
              builder: (context) {
                final on = _anchor == null && q.range.start == _start && q.range.end == _end;
                final open = _weekOpen(q.range.start);
                final dates = q.range.start.year != q.range.end.year || q.range.start.year != _today.year
                    ? '${DateFormat('MMM d, yy').format(q.range.start)} – ${DateFormat('MMM d, yy').format(q.range.end)}'
                    : '${fmt.format(q.range.start)} – ${fmt.format(q.range.end)}';
                return Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: FocusRing(
                    borderRadius: BorderRadius.circular(9),
                    child: Semantics(
                      button: true,
                      selected: on,
                      label: '${q.label}, $dates',
                      excludeSemantics: true,
                      child: InkWell(
                        onTap: open ? () => _pickQuick(q) : null,
                        borderRadius: BorderRadius.circular(9),
                        mouseCursor: open ? SystemMouseCursors.click : SystemMouseCursors.basic,
                        hoverColor: DashUi.rowHover,
                        splashFactory: NoSplash.splashFactory,
                        child: AnimatedContainer(
                          duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 140),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: on ? Colors.white : Colors.white.withValues(alpha: 0),
                            borderRadius: BorderRadius.circular(9),
                            border: Border.all(color: on ? DashUi.line : DashUi.line.withValues(alpha: 0)),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  q.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                                    color: open ? DashUi.ink : DashUi.muted,
                                  ),
                                ),
                              ),
                              if (on) const Icon(Icons.check_rounded, size: 16, color: DashUi.ink),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  // ---- Calendars --------------------------------------------------------------

  static const double _cell = 40;
  static const double _rowH = 38;

  Widget _months(bool two, bool still) {
    final first = DateTime(widget.firstDate.year, widget.firstDate.month, 1);
    final last = DateTime(widget.lastDate.year, widget.lastDate.month, 1);
    final left = two ? _month : DateTime(_month.year, _month.month + 1, 1);
    final right = DateTime(left.year, left.month + 1, 1);
    final canBack = left.isAfter(first);
    final canNext = (two ? right : left).isBefore(last);

    Widget month(DateTime m, {required bool back, required bool next}) => _monthGrid(m, back: back, next: next);

    final body = two
        ? Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              month(left, back: canBack, next: false),
              const SizedBox(width: 36),
              month(right, back: false, next: canNext),
            ],
          )
        : month(left, back: canBack, next: canNext);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 18),
      child: Center(
        child: ClipRect(
          child: AnimatedSwitcher(
            duration: still ? Duration.zero : const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) {
              final incoming = child.key == ValueKey(left);
              final dx = (incoming ? 0.06 : -0.06) * _slide;
              return FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween<Offset>(begin: Offset(dx, 0), end: Offset.zero).animate(anim),
                  child: child,
                ),
              );
            },
            layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
            child: KeyedSubtree(key: ValueKey(left), child: body),
          ),
        ),
      ),
    );
  }

  Widget _monthGrid(DateTime m, {required bool back, required bool next}) {
    final firstDay = DateTime(m.year, m.month, 1);
    final lastDay = DateTime(m.year, m.month + 1, 0);
    final gridStart = _monday(firstDay);
    final rows = ((_between(gridStart, lastDay) + 1) / 7).ceil();
    return SizedBox(
      width: _cell * 7,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 34,
            child: Row(
              children: [
                _arrow(Icons.chevron_left_rounded, 'Previous month', back ? () => _shift(-1) : null, show: back),
                Expanded(
                  child: Text(
                    DateFormat('MMMM yyyy').format(m),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: DashUi.ink, letterSpacing: -0.2),
                  ),
                ),
                _arrow(Icons.chevron_right_rounded, 'Next month', next ? () => _shift(1) : null, show: next),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final d in const ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'])
                SizedBox(
                  width: _cell,
                  child: Text(
                    d,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: DashUi.subtle),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          // Always six rows tall, so the dialog doesn't jump as the months change.
          SizedBox(
            height: _rowH * 6,
            child: Column(
              children: [for (var r = 0; r < rows; r++) _weekRow(_add(gridStart, r * 7), m)],
            ),
          ),
        ],
      ),
    );
  }

  Widget _arrow(IconData icon, String tip, VoidCallback? onTap, {required bool show}) {
    if (!show) return const SizedBox(width: 32);
    return IconButton(
      tooltip: tip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      padding: EdgeInsets.zero,
      icon: Icon(icon, size: 22, color: DashUi.ink),
    );
  }

  Widget _weekRow(DateTime monday, DateTime month) {
    final shown = _shown;
    final sunday = _add(monday, 6);
    final open = _weekOpen(monday);
    final inRange = !monday.isBefore(shown.start) && !sunday.isAfter(shown.end);
    final picking = _anchor != null;
    final isFirst = inRange && monday == shown.start;
    final isLast = inRange && sunday == shown.end;
    final hovered = _hover == monday && open;
    final still = MediaQuery.disableAnimationsOf(context);

    // A pay week is one pill; weeks in the range stack into a band whose ends round off.
    final band = inRange
        ? DashUi.ink.withValues(alpha: picking ? 0.05 : 0.075)
        : (hovered ? DashUi.rowStripe : Colors.white.withValues(alpha: 0));
    final radius = BorderRadius.vertical(
      top: Radius.circular(!inRange || isFirst ? 10 : 0),
      bottom: Radius.circular(!inRange || isLast ? 10 : 0),
    );
    final label = 'Pay week ${DateFormat('MMM d').format(monday)} to ${DateFormat('MMM d, yyyy').format(sunday)}';

    return MouseRegion(
      cursor: open ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = monday),
      onExit: (_) {
        if (_hover == monday) setState(() => _hover = null);
      },
      child: FocusRing(
        borderRadius: BorderRadius.circular(10),
        child: Semantics(
          button: true,
          selected: inRange && !picking,
          enabled: open,
          label: label,
          excludeSemantics: true,
          child: InkWell(
            onTap: open ? () => _tapWeek(monday) : null,
            onFocusChange: (f) {
              if (f) setState(() => _hover = monday);
            },
            mouseCursor: open ? SystemMouseCursors.click : SystemMouseCursors.basic,
            borderRadius: BorderRadius.circular(10),
            hoverColor: Colors.transparent,
            focusColor: Colors.transparent,
            splashFactory: NoSplash.splashFactory,
            child: AnimatedContainer(
              duration: still ? Duration.zero : const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              height: _rowH,
              decoration: BoxDecoration(color: band, borderRadius: radius),
              child: Row(
                children: [
                  for (var i = 0; i < 7; i++)
                    _dayCell(_add(monday, i), month, open,
                        cap: (isFirst && i == 0) || (isLast && i == 6), picking: picking),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _dayCell(DateTime d, DateTime month, bool open, {required bool cap, required bool picking}) {
    final inMonth = d.month == month.month && d.year == month.year;
    final today = d == _today;
    final dayOpen = !d.isBefore(_day(widget.firstDate)) && !d.isAfter(_day(widget.lastDate));
    final Color fg = cap
        ? Colors.white
        : (!inMonth || !open || !dayOpen ? DashUi.muted : DashUi.ink);
    return SizedBox(
      width: _cell,
      height: _rowH,
      child: Center(
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: cap ? (picking ? DashUi.slate : DashUi.ink) : null,
            shape: BoxShape.circle,
            border: today && !cap ? Border.all(color: DashUi.ink, width: 1.4) : null,
          ),
          child: Text(
            '${d.day}',
            style: TextStyle(
              fontSize: 13,
              fontWeight: cap || today ? FontWeight.w800 : (inMonth ? FontWeight.w600 : FontWeight.w500),
              color: fg,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }

  // ---- Footer -------------------------------------------------------------------

  Widget _footer() {
    final picking = _anchor != null;
    final s = _start, e = _end;
    final dates = s.year != e.year
        ? '${DateFormat('MMM d, yyyy').format(s)} – ${DateFormat('MMM d, yyyy').format(e)}'
        : '${DateFormat('MMM d').format(s)} – ${DateFormat('MMM d, yyyy').format(e)}';
    final weeks = (_between(s, e) + 1) ~/ 7;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 14, 18, 16),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 4,
              children: [
                Text(
                  picking ? 'Pick the last week' : dates,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: picking ? DashUi.slate : DashUi.ink,
                    letterSpacing: -0.2,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (!picking)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                    decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(99)),
                    child: Text(
                      weeks == 1 ? '1 pay week' : '$weeks pay weeks',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.slate),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          AppButton.ghost('Cancel', () => Navigator.of(context).maybePop()),
          const SizedBox(width: 8),
          AppButton.ink('Apply', picking ? null : _apply),
        ],
      ),
    );
  }
}
