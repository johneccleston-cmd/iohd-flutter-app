part of 'kpi_dashboard_screen.dart';

// =============================================================================
// WON ESTIMATE vs FINAL JOB (the sales chart's "Sold vs final" view)
// =============================================================================
//
// Each estimate Heather or Zac won in the year beside the job it became, once that job is closed: what was sold against
// what the job finally came to. The pairing is the server's (salesKpis, `estimateVsJob`): Service Fusion keeps no
// estimate -> job link in what we sync, so the job is the one for the same customer and address, created around the win,
// that shares priced line items with the estimate.

/// One closed job beside the won estimate(s) it came from.
class _EstJobPair {
  final String jobId;
  final List<String> estimateIds;
  final String customer;
  final String estimateDate; // "2026-04-10"
  final double estimate;
  final double job;
  const _EstJobPair(this.jobId, this.estimateIds, this.customer, this.estimateDate, this.estimate, this.job);

  double get change => job - estimate;

  /// January = 0; -1 when the date is missing.
  int get month => (DateTime.tryParse(estimateDate)?.month ?? 0) - 1;
}

/// The `estimateVsJob` part of the sales figures: every won estimate dated in the year whose job has closed, and how many
/// won estimates have a job still open, a cancelled job, or no job found.
class _EstVsJob {
  final List<_EstJobPair> rows;
  final int openJobs;
  final int cancelled;
  final int unmatched;
  const _EstVsJob({required this.rows, required this.openJobs, required this.cancelled, required this.unmatched});

  static _EstVsJob? fromJson(dynamic j) {
    if (j is! Map) return null;
    final rows = j['rows'] is List ? j['rows'] as List : const [];
    return _EstVsJob(
      rows: [
        for (final r in rows)
          if (r is Map)
            _EstJobPair(
              _str(r['jobId']),
              [for (final e in (r['estimateIds'] is List ? r['estimateIds'] as List : const [])) _str(e)],
              _str(r['customer']).trim().isEmpty ? 'A customer' : _str(r['customer']).trim(),
              _str(r['estimateDate']),
              _num(r['estimate']) ?? 0,
              _num(r['job']) ?? 0,
            ),
      ],
      openJobs: int.tryParse(_str(j['openJobs'])) ?? 0,
      cancelled: int.tryParse(_str(j['cancelled'])) ?? 0,
      unmatched: int.tryParse(_str(j['unmatched'])) ?? 0,
    );
  }

  double get sold => rows.fold(0, (t, r) => t + r.estimate);
  double get finalTotal => rows.fold(0, (t, r) => t + r.job);

  /// A change under a dollar is the same total (rounding).
  int get higher => rows.where((r) => r.change >= 1).length;
  int get lower => rows.where((r) => r.change <= -1).length;
  int get same => rows.length - higher - lower;
}

/// "+$3,838" / "−$1,200" / "$0".
String _signedMoney(double v) => v.abs() < 1 ? '\$0' : '${v > 0 ? '+' : '−'}${_wholeMoney(v.abs())}';

/// "+$3.8k" over a bar pair.
String _signedBar(double v) => v.abs() < 1 ? '\$0' : '${v > 0 ? '+' : '−'}${_barMoney(v.abs())}';

/// "+2.4%" / "−11%".
String _signedPct(double change, double base) {
  final p = change.abs() / base * 100;
  return '${change >= 0 ? '+' : '−'}${p >= 10 ? p.round() : _fmtNum((p * 10).round() / 10)}%';
}

Color _changeColor(double change) => change.abs() < 1 ? DashUi.slate : (change > 0 ? DashUi.emeraldText : DashUi.redText);

/// Did the jobs finish where they were sold? The headline answers it (sold, final, the change and its %), the callout
/// says how many finished higher, lower and at the estimate and names the biggest move; under it each month (of the
/// estimate's date) is a pair of bars, sold beside final, with the month's change over them in green (up) or red (down).
/// "List jobs" opens every pair, biggest change first.
class _SoldVsFinalView extends StatelessWidget {
  final _EstVsJob data;
  final int year;
  final String name;
  const _SoldVsFinalView({required this.data, required this.year, required this.name});

  @override
  Widget build(BuildContext context) {
    final d = data;
    final now = DashClock.now();
    final thisYear = year == now.year;
    final sold = d.sold, fin = d.finalTotal, change = fin - sold;
    final notCharted = [
      if (d.openJobs > 0) '${d.openJobs} still open',
      if (d.unmatched > 0) '${d.unmatched} with no job found',
      if (d.cancelled > 0) '${d.cancelled} cancelled',
    ];
    final String callout;
    var calloutColor = DashUi.slate;
    if (d.rows.isEmpty) {
      callout = 'No estimate won in $year has a closed job${thisYear ? ' yet' : ''}${notCharted.isEmpty ? '' : ' · ${notCharted.join(', ')}'}';
    } else {
      final biggest = d.rows.reduce((a, b) => b.change.abs() > a.change.abs() ? b : a);
      calloutColor = _changeColor(change);
      callout = [
        '${d.higher} finished higher, ${d.lower} lower, ${d.same} at the estimate',
        if (biggest.change.abs() >= 1) 'biggest move: ${biggest.customer} ${_signedMoney(biggest.change)}',
      ].join(' · ');
    }

    final shown = year < now.year ? 12 : (year > now.year ? 0 : now.month);
    final soldBy = List<double>.filled(12, 0), finBy = List<double>.filled(12, 0);
    final nBy = List<int>.filled(12, 0), upBy = List<int>.filled(12, 0), downBy = List<int>.filled(12, 0);
    for (final r in d.rows) {
      final m = r.month;
      if (m < 0 || m > 11) continue;
      soldBy[m] += r.estimate;
      finBy[m] += r.job;
      nBy[m]++;
      if (r.change >= 1) upBy[m]++;
      if (r.change <= -1) downBy[m]++;
    }

    final pctText = sold > 0 ? _signedPct(change, sold) : null;
    return Semantics(
      label: '${_wholeMoney(sold)} sold on ${d.rows.length} closed jobs from estimates won in $year, '
          '${_wholeMoney(fin)} final, ${_signedMoney(change)}${pctText == null ? '' : ' ($pctText)'}. $callout.',
      child: DashStoryFrame(
        headline: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            _StoryStat(sold, _wholeMoney, 'sold', DashUi.slate),
            const SizedBox(width: 22),
            _StoryStat(fin, _wholeMoney, 'final', DashUi.sky),
            const SizedBox(width: 22),
            _StoryStat(change, _signedMoney, pctText == null ? 'change' : '($pctText)', _changeColor(change)),
          ],
        ),
        callout: callout,
        calloutColor: calloutColor,
        action: d.rows.isEmpty
            ? null
            : TextButton.icon(
                onPressed: () => showDialog<void>(context: context, builder: (_) => _SoldVsFinalDialog(data: d, year: year, name: name)),
                icon: const Icon(Icons.list_alt_rounded, size: 18),
                label: const Text('List jobs'),
                style: TextButton.styleFrom(foregroundColor: DashUi.blue),
              ),
        chart: d.rows.isEmpty
            ? DashEmptyNote(callout)
            : _PairBars(sold: soldBy, fin: finBy, count: nBy, up: upBy, down: downBy, shown: shown, year: year),
        legend: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            dashKeyItem(dashKeyBox(DashUi.line, border: DashUi.muted), 'Won estimate total'),
            const SizedBox(width: 16),
            dashKeyItem(dashKeyBox(DashUi.sky), 'Final job total'),
            const SizedBox(width: 16),
            dashKeyItem(const Text('+\$', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: DashUi.emeraldText)), 'final came in higher'),
            const SizedBox(width: 12),
            dashKeyItem(const Text('−\$', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: DashUi.redText)), 'lower'),
            // Won estimates the chart leaves out, so the totals are not read as every win.
            if (d.rows.isNotEmpty && notCharted.isNotEmpty) ...[
              const SizedBox(width: 16),
              Text('Not charted: ${notCharted.join(', ')}', maxLines: 1, style: DashText.meta),
            ],
          ],
        ),
      ),
    );
  }
}

/// Twelve months of paired bars from zero: the won estimate total (light, outlined) beside the final job total (solid
/// sky), growing in one month after another, the month's change over each pair. Hovering a month (or the arrow keys
/// once the chart has focus) lifts it and shows its figures beside it.
class _PairBars extends StatefulWidget {
  final List<double> sold;
  final List<double> fin;
  final List<int> count;
  final List<int> up;
  final List<int> down;

  /// Months that have happened (12 for a past year).
  final int shown;
  final int year;
  const _PairBars({required this.sold, required this.fin, required this.count, required this.up, required this.down, required this.shown, required this.year});

  @override
  State<_PairBars> createState() => _PairBarsState();
}

class _PairBarsState extends State<_PairBars> with SingleTickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000));
  int? _hover;
  bool _focused = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _intro.value = 1;
    } else if (!_intro.isAnimating && _intro.value == 0) {
      _intro.forward();
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  String _tip(int m) {
    final w = widget;
    if (w.count[m] == 0) return '${dashMonthNames[m]}: no closed jobs from estimates dated this month';
    final change = w.fin[m] - w.sold[m];
    final pct = w.sold[m] > 0 ? ' (${_signedPct(change, w.sold[m])})' : '';
    final same = w.count[m] - w.up[m] - w.down[m];
    return '${dashMonthNames[m]} ${w.year}\n'
        'Sold ${_wholeMoney(w.sold[m])} · final ${_wholeMoney(w.fin[m])}\n'
        'Change ${_signedMoney(change)}$pct\n'
        '${w.count[m]} ${w.count[m] == 1 ? 'job' : 'jobs'}: ${w.up[m]} higher, ${w.down[m]} lower, $same the same';
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final g = DashGeo.of(context);
    var top = 0.0;
    for (var m = 0; m < 12; m++) {
      top = math.max(top, math.max(w.sold[m], w.fin[m]));
    }
    if (top <= 0) top = 1;
    final last = math.max(0, w.shown - 1);
    return Focus(
      onFocusChange: (f) => setState(() {
        _focused = f;
        _hover = f ? (_hover ?? last) : null;
      }),
      onKeyEvent: (node, e) {
        if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
        final k = e.logicalKey;
        if (k != LogicalKeyboardKey.arrowLeft && k != LogicalKeyboardKey.arrowRight) return KeyEventResult.ignored;
        setState(() => _hover = ((_hover ?? last) + (k == LogicalKeyboardKey.arrowRight ? 1 : -1)).clamp(0, last));
        return KeyEventResult.handled;
      },
      child: LayoutBuilder(
        builder: (context, c) {
          final colW = c.maxWidth / 12;
          final labelH = g.line(11) + 4;
          final monthH = g.line(11) + 6;
          // 3 = the lifted month's border, top and bottom.
          final barArea = math.max(0.0, c.maxHeight - labelH - monthH - 3);
          final barW = math.min(18.0, math.max(3.0, (colW - 12) / 2));
          final showLabels = colW >= 38;
          return MouseRegion(
            onExit: (_) {
              if (!_focused) setState(() => _hover = null);
            },
            child: AnimatedBuilder(
              animation: _intro,
              builder: (context, _) => Stack(
                clipBehavior: Clip.none,
                children: [
                  // The zero line, so months with nothing still read as months.
                  Positioned(left: 0, right: 0, top: labelH + barArea + 1.5, child: Container(height: 1, color: DashUi.line)),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var m = 0; m < 12; m++)
                        Expanded(
                          child: MouseRegion(
                            onEnter: (_) => setState(() => _hover = m),
                            child: Semantics(
                              label: m < w.shown ? _tip(m).replaceAll('\n', ', ') : null,
                              child: _month(m, top, barArea, barW, labelH, monthH, showLabels),
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (_hover != null && _hover! < w.shown) _tooltip(_hover!, colW, c.maxWidth),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _month(int m, double top, double barArea, double barW, double labelH, double monthH, bool showLabels) {
    final w = widget;
    final happened = m < w.shown;
    // Each month grows in a little after the one before.
    final t = Curves.easeOutCubic.transform(((_intro.value * 1.55) - m * 0.05).clamp(0.0, 1.0));
    final hSold = happened ? barArea * (w.sold[m] / top) * t : 0.0;
    final hFin = happened ? barArea * (w.fin[m] / top) * t : 0.0;
    final change = w.fin[m] - w.sold[m];
    final lifted = _hover == m;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      decoration: BoxDecoration(
        color: lifted ? DashUi.faint : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: lifted && _focused ? DashUi.blue : Colors.transparent, width: 1.5),
      ),
      child: Column(
        children: [
          SizedBox(
            height: labelH,
            child: showLabels && happened && w.count[m] > 0
                ? Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Opacity(
                        opacity: t,
                        child: Text(
                          _signedBar(change),
                          maxLines: 1,
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _changeColor(change), fontFeatures: DashText.tabular),
                        ),
                      ),
                    ),
                  )
                : null,
          ),
          SizedBox(
            height: barArea,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  width: barW,
                  height: hSold,
                  decoration: BoxDecoration(
                    color: DashUi.line,
                    border: hSold > 2 ? Border.all(color: DashUi.muted, width: 1.2) : null,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                  ),
                ),
                const SizedBox(width: 3),
                Container(
                  width: barW,
                  height: hFin,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [lifted ? DashUi.blue : DashUi.sky, DashUi.sky.withValues(alpha: 0.72)],
                    ),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: monthH,
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  dashMonthNames[m].length > 3 ? dashMonthNames[m].substring(0, 3) : dashMonthNames[m],
                  maxLines: 1,
                  style: TextStyle(fontSize: 11, fontWeight: lifted ? FontWeight.w800 : FontWeight.w600, color: happened ? DashUi.slate : DashUi.muted),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tooltip(int m, double colW, double width) {
    const tipW = 240.0;
    // Beside the month: to its right in the first half of the year, to its left after.
    final x = m < 6 ? (m + 1) * colW + 4 : m * colW - tipW - 4;
    return Positioned(
      left: x.clamp(0.0, math.max(0.0, width - tipW)),
      top: 0,
      width: tipW,
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: DashUi.ink,
              borderRadius: BorderRadius.circular(10),
              boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 4))],
            ),
            child: Text(_tip(m), style: const TextStyle(fontSize: 12, height: 1.4, color: Colors.white)),
          ),
        ),
      ),
    );
  }
}

/// Every closed job beside the estimate it was sold on, biggest change first. A job number opens the job.
class _SoldVsFinalDialog extends StatelessWidget {
  final _EstVsJob data;
  final int year;
  final String name;
  const _SoldVsFinalDialog({required this.data, required this.year, required this.name});

  @override
  Widget build(BuildContext context) {
    const head = TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _muted, letterSpacing: 0.6);
    final rows = data.rows;
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840, maxHeight: 680),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 12, 12),
              child: Row(
                children: [
                  const Icon(Icons.compare_arrows_rounded, size: 20, color: DashUi.sky),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('$name · Won estimates vs final job', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: _ink)),
                        Text(
                          '${rows.length} closed ${rows.length == 1 ? 'job' : 'jobs'} from estimates won in $year, biggest change first',
                          style: const TextStyle(fontSize: 12.5, color: _muted),
                        ),
                      ],
                    ),
                  ),
                  IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close_rounded, size: 20, color: _slate), tooltip: 'Close'),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 4, 24, 6),
              child: Row(
                children: [
                  Expanded(flex: 6, child: Text('CUSTOMER', style: head)),
                  Expanded(flex: 3, child: Text('ESTIMATE DATE', style: head, textAlign: TextAlign.right)),
                  Expanded(flex: 3, child: Text('SOLD', style: head, textAlign: TextAlign.right)),
                  Expanded(flex: 3, child: Text('FINAL', style: head, textAlign: TextAlign.right)),
                  Expanded(flex: 3, child: Text('CHANGE', style: head, textAlign: TextAlign.right)),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: rows.length,
                itemBuilder: (context, i) {
                  final r = rows[i];
                  final c = r.change;
                  final pct = r.estimate > 0 && c.abs() >= 1 ? ' (${_signedPct(c, r.estimate)})' : '';
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                    decoration: const BoxDecoration(border: Border(top: BorderSide(color: _line))),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 6,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(r.customer, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _ink)),
                              Wrap(
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  FlatLink('Job #${r.jobId}', tip: 'Open job ${r.jobId}', onTap: () {
                                    final router = GoRouter.of(context);
                                    Navigator.of(context).pop();
                                    router.go('/jobs/${Uri.encodeComponent(r.jobId)}');
                                  }),
                                  if (r.estimateIds.isNotEmpty)
                                    Text(
                                      ' · from estimate ${r.estimateIds.map((e) => '#$e').join(', ')}',
                                      style: const TextStyle(fontSize: 12, color: _muted),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        Expanded(flex: 3, child: Text(_prettyDate(r.estimateDate), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13.5, color: _slate))),
                        Expanded(
                          flex: 3,
                          child: Text(_wholeMoney(r.estimate), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13.5, color: _slate, fontFeatures: DashText.tabular)),
                        ),
                        Expanded(
                          flex: 3,
                          child: Text(_wholeMoney(r.job), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: _ink, fontFeatures: DashText.tabular)),
                        ),
                        Expanded(
                          flex: 3,
                          child: Text(
                            '${_signedMoney(c)}$pct',
                            textAlign: TextAlign.right,
                            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: _changeColor(c), fontFeatures: DashText.tabular),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
