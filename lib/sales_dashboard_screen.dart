import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart' hide TextDirection;
import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/app_dialog.dart';
import 'widgets/estimate_list_dialog.dart';
import 'widgets/dashboard_layout.dart';

class SalesDashboardScreen extends StatelessWidget {
  const SalesDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      title: 'Sales',
      builder: (context, selectedYear) => SalesDashboardContent(selectedYear: selectedYear),
    );
  }
}

class SalesDashboardContent extends StatefulWidget {
  final int selectedYear;
  const SalesDashboardContent({super.key, required this.selectedYear});

  @override
  State<SalesDashboardContent> createState() => _SalesDashboardContentState();
}

// =============================================================================
// HELPERS
// =============================================================================

const _monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
final _whole = NumberFormat('#,##0');

String _money(num v) => '${v < 0 ? '-' : ''}\$${_whole.format(v.abs())}';

String _trimZero(double v) {
  final s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

String _compactMoney(num v) {
  final a = v.abs();
  final sign = v < 0 ? '-' : '';
  if (a >= 1000000) return '$sign\$${_trimZero(a / 1000000)}M';
  if (a >= 1000) return '$sign\$${_trimZero(a / 1000)}k';
  return '$sign\$${a.round()}';
}

double _d(dynamic v) => v == null ? 0.0 : (v is num ? v.toDouble() : double.tryParse(v.toString()) ?? 0.0);
int _i(dynamic v) => v == null ? 0 : (v is num ? v.toInt() : int.tryParse(v.toString()) ?? 0);

TextPainter _layoutText(String text, TextStyle style, {double maxWidth = double.infinity, TextAlign align = TextAlign.left}) {
  return TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textAlign: align,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: maxWidth);
}

class _Scale {
  final double max;
  final double step;
  const _Scale(this.max, this.step);
  int get ticks => (max / step).round();
}

_Scale _niceScale(double maxV) {
  if (maxV <= 0) return const _Scale(10000, 2500);
  final raw = maxV / 4;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  final nice = norm <= 1 ? 1.0 : (norm <= 2 ? 2.0 : (norm <= 5 ? 5.0 : 10.0));
  final step = nice * mag;
  var top = (maxV / step).ceil() * step;
  if (top < maxV * 1.08) top += step;
  return _Scale(top, step);
}

// =============================================================================
// MODELS
// =============================================================================

class _Month {
  final int monthNum;
  final double wonValue;
  final int wonCount;
  final int closedCount;
  final int sentCount;
  const _Month(this.monthNum, this.wonValue, this.wonCount, this.closedCount, this.sentCount);

  double get winRate => closedCount > 0 ? wonCount / closedCount * 100 : 0;
}

class _Person {
  final String name;
  final String role;
  final String imageUrl;
  final double wonValue;
  final int wonCount;
  final int sentCount;
  final int lostCount;
  final double largestDeal;
  final double winRate;

  /// Won value per month, January first (always 12 entries).
  final List<double> monthlyWon;

  const _Person({
    required this.name,
    required this.role,
    required this.imageUrl,
    required this.wonValue,
    required this.wonCount,
    required this.sentCount,
    required this.lostCount,
    required this.largestDeal,
    required this.winRate,
    required this.monthlyWon,
  });

  factory _Person.fromJson(Map<String, dynamic> j) => _Person(
        name: (j['name'] ?? 'Unknown').toString(),
        role: (j['role'] ?? '').toString(),
        imageUrl: (j['imageUrl'] ?? '').toString(),
        wonValue: _d(j['wonValue']),
        wonCount: _i(j['wonCount']),
        sentCount: _i(j['sentCount']),
        lostCount: _i(j['lostCount']),
        largestDeal: _d(j['largestDeal']),
        monthlyWon: [
          for (final v in (j['monthlyWon'] as List<dynamic>? ?? const [])) _d(v),
        ],
        winRate: _d(j['winRate']),
      );
}

// =============================================================================
// SCREEN STATE
// =============================================================================

class _SalesDashboardContentState extends State<SalesDashboardContent> {
  bool _isLoading = true;
  String? _errorMessage;

  double _wonValue = 0;
  int _wonCount = 0;
  double _winRate = 0;
  double _largestDeal = 0;
  double _priorWonValue = 0;

  /// Always 12 entries, January first.
  List<_Month> _months = [];
  List<double> _priorMonths = List.filled(12, 0);
  List<_Person> _people = [];
  List<_DoorType> _doors = [];

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(covariant SalesDashboardContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedYear != widget.selectedYear) _fetch();
  }

  Future<void> _fetch() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await http
          .get(
            Uri.parse('$kApiBaseUrl/api/dashboards/sales?year=${widget.selectedYear}'),
            headers: AuthSession.instance.headers(),
          )
          .timeout(const Duration(seconds: 60)); // free-tier hosts can take ~30s+ to wake up

      if (response.statusCode != 200) {
        throw Exception('The server returned status ${response.statusCode}.');
      }

      final body = json.decode(response.body) as Map<String, dynamic>;
      final s = (body['summary'] as Map<String, dynamic>?) ?? const <String, dynamic>{};

      List<_Month> parseMonths(dynamic raw) {
        final byNum = <int, _Month>{};
        for (final e in (raw as List<dynamic>? ?? const [])) {
          final m = _i(e['month_num']);
          byNum[m] = _Month(m, _d(e['won_value']), _i(e['won_count']), _i(e['closed_count']), _i(e['sent_count']));
        }
        return List.generate(12, (i) => byNum[i + 1] ?? _Month(i + 1, 0, 0, 0, 0));
      }

      final months = parseMonths(body['monthly']);
      final prior = parseMonths(body['priorMonthly']).map((m) => m.wonValue).toList();
      final people = ((body['people'] as List<dynamic>?) ?? const [])
          .map((e) => _Person.fromJson(e as Map<String, dynamic>))
          .toList();

      if (!mounted) return;
      setState(() {
        _wonValue = _d(s['wonValue']);
        _wonCount = _i(s['wonCount']);
        _winRate = _d(s['winRate']);
        _largestDeal = _d(s['largestDeal']);
        _priorWonValue = _d(s['priorWonValue']);
        _months = months;
        _priorMonths = prior;
        _people = people;
        _doors = ((body['doorTypes'] as List<dynamic>?) ?? const [])
            .map((e) => _DoorType.fromJson(e as Map<String, dynamic>))
            .toList();
        _isLoading = false;
      });
    } on TimeoutException {
      if (mounted) {
        setState(() {
          _errorMessage = 'The dashboard took too long to load.';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  List<double> _wonTrend() => _trendOf([for (final m in _months) m.wonValue], widget.selectedYear);

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const _SalesSkeleton();
    if (_errorMessage != null) {
      return DashErrorPanel(title: "Couldn't load sales", message: _errorMessage!, onRetry: _fetch);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 86,
          child: Row(
            children: [
              Expanded(
                child: AnimatedMetricCard(
                  title: 'Won revenue',
                  value: _wonValue,
                  format: _money,
                  valueColor: DashUi.sky,
                  index: 0,
                  trend: _wonTrend(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AnimatedMetricCard(
                  title: 'Win rate',
                  value: _winRate,
                  format: (v) => '${v.toStringAsFixed(1)}%',
                  valueColor: DashUi.emeraldDeep,
                  index: 1,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AnimatedMetricCard(
                  title: 'Deals won',
                  value: _wonCount.toDouble(),
                  format: (v) => _whole.format(v.round()),
                  valueColor: DashUi.ink,
                  index: 2,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AnimatedMetricCard(
                  title: 'Largest deal won',
                  value: _largestDeal,
                  format: _money,
                  valueColor: DashUi.blue,
                  index: 3,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < _people.length; i++) ...[
                Expanded(
                  flex: 3,
                  child: _SalesPersonCard(person: _people[i], rank: i + 1, year: widget.selectedYear, index: i),
                ),
                const SizedBox(width: 16),
              ],
              Expanded(
                flex: 6,
                child: Column(
                  children: [
                    Expanded(flex: 11, child: _DoorTypePanel(doors: _doors, year: widget.selectedYear)),
                    const SizedBox(height: 16),
                    Expanded(
                      flex: 9,
                      child: _MonthlyWonChart(
                        data: _months,
                        prior: _priorMonths,
                        year: widget.selectedYear,
                        total: _wonValue,
                        priorTotal: _priorWonValue,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
// =============================================================================
// PERSON CARD (tall card, same structure as the KPI screen's employee cards)
// =============================================================================

/// Monthly series trimmed to what's happened so far, starting just before the first non-zero month.
List<double> _trendOf(List<double> monthly, int year) {
  final now = DateTime.now();
  final upTo = year == now.year ? now.month : monthly.length;
  final pts = monthly.take(upTo).toList();
  final first = pts.indexWhere((v) => v > 0);
  if (first < 0) return pts;
  return pts.sublist(math.max(0, first - 1));
}

class _SalesPersonCard extends StatelessWidget {
  static const _gold = Color(0xFFF59E0B);

  final _Person person;
  final int rank;
  final int year;
  final int index;
  const _SalesPersonCard({required this.person, required this.rank, required this.year, required this.index});

  @override
  Widget build(BuildContext context) {
    final p = person;
    final leader = rank == 1 && p.wonValue > 0;

    return HoverLift(
      lift: 4,
      builder: (context, hovering) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: leader ? _gold : (hovering ? DashUi.sky.withValues(alpha: 0.55) : DashUi.line),
            width: leader ? 2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: (leader ? _gold : Colors.black).withValues(alpha: hovering ? 0.16 : 0.04),
              blurRadius: hovering ? 24 : 10,
              offset: Offset(0, hovering ? 10 : 3),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        // Tall windows: big photo, then name, then stats. Short windows: a slim avatar header instead
        // of the photo, so the stats keep their full size instead of being squeezed or scrolled.
        child: LayoutBuilder(
          builder: (context, c) {
            // Rough natural height of the stats, used only to choose a layout; they size to content.
            const statsEst = 332.0;

            if (c.maxHeight >= 590) {
              // Lots of height: centered avatar and name, any spare space becomes breathing room.
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _roomyHeader(leader)),
                  _stats(),
                ],
              );
            }

            // Otherwise: avatar on the left, name/role/rank on the right. The avatar takes whatever
            // height the stats leave over (56..150), and the stats shrink only if they still don't fit.
            final avatar = (c.maxHeight - statsEst - 32).clamp(56.0, 150.0).toDouble();
            // Anything still left over is spread between the stat blocks instead of sitting at the bottom.
            final extra = ((c.maxHeight - (math.max(avatar, 80.0) + 24) - statsEst) / 3).clamp(0.0, 22.0).toDouble();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _stripHeader(leader, avatar),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.topCenter,
                    child: SizedBox(width: c.maxWidth, child: _stats(extra: extra)),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
  Widget _rankPill(bool leader, {bool short = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: leader ? const Color(0xFFFEF3C7) : DashUi.faint,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leader) ...[const Icon(Icons.emoji_events_rounded, size: 14, color: _gold), const SizedBox(width: 4)],
            Text(
              short ? '#$rank' : 'Rank #$rank',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: leader ? const Color(0xFFD97706) : DashUi.slate),
            ),
          ],
        ),
      );

  /// Centered circular avatar, name and role (used when there is plenty of height).
  Widget _roomyHeader(bool leader) {
    return LayoutBuilder(builder: (context, c) => _roomyHeaderBody(leader, c.maxHeight));
  }

  Widget _roomyHeaderBody(bool leader, double height) {
    final p = person;
    // Avatar grows with the spare height (72..170 including its ring) so tall windows don't leave a small icon in a void.
    // Matches the side-by-side layout (about 150) where the two meet, then keeps growing with the space.
    final spare = height - 100;
    final avatar = (spare * (1 - ((height - 258) / 1000).clamp(0.0, 0.25))).clamp(72.0, 230.0) - 6; // minus the ring
    return Stack(
      children: [
        Center(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DashAvatar(
                  name: p.name,
                  imageUrl: p.imageUrl,
                  size: avatar,
                  ringColor: leader ? _gold : DashUi.line,
                  ringWidth: leader ? 3 : 1.5,
                ),
                const SizedBox(height: 10),
                Text(
                  p.name,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1A1C1E)),
                ),
                Text(
                  p.role,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: DashUi.slate),
                ),
              ],
            ),
          ),
        ),
        Positioned(top: 14, right: 14, child: _rankPill(leader)),
      ],
    );
  }

  /// Avatar on the left, name, role and rank on the right (used when there isn't height for a centered header).
  Widget _stripHeader(bool leader, double avatar) {
    final p = person;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
      child: Row(
        children: [
          DashAvatar(
            name: p.name,
            imageUrl: p.imageUrl,
            size: avatar - (leader ? 6 : 3), // the ring is drawn outside the image
            ringColor: leader ? _gold : DashUi.line,
            ringWidth: leader ? 3 : 1.5,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold, color: Color(0xFF1A1C1E)),
                ),
                Text(
                  p.role,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: DashUi.slate),
                ),
                const SizedBox(height: 8),
                _rankPill(leader),
              ],
            ),
          ),
        ],
      ),
    );
  }
  /// The metrics: won revenue, four tiles and the win-rate ring. Designed for a fixed height.
  /// [extra] is spare height to spread across the gaps between the blocks.
  Widget _stats({double extra = 0}) {
    final p = person;
    final closed = p.wonCount + p.lostCount;

    return Builder(
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 4, 22, 16),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _tap(
                context,
                _Drill.won,
                (h) => _hoverShell(
                  h,
                  DashUi.sky,
                  SizedBox(
                    height: 86,
                    child: AnimatedMetricCard(
                      title: 'Won revenue',
                      value: p.wonValue,
                      format: _money,
                      valueColor: DashUi.sky,
                      index: index,
                      trend: _trendOf(p.monthlyWon, year),
                    ),
                  ),
                ),
              ),
              SizedBox(height: 8 + extra),
              Row(
                children: [
                  Expanded(child: _tile(context, _Drill.won, 'DEALS WON', _whole.format(p.wonCount), DashUi.ink)),
                  const SizedBox(width: 10),
                  Expanded(child: _tile(context, _Drill.sent, 'ESTIMATES SENT', _whole.format(p.sentCount), DashUi.ink)),
                ],
              ),
              SizedBox(height: 8 + extra),
              Row(
                children: [
                  Expanded(child: _tile(context, _Drill.largest, 'LARGEST DEAL', _compactMoney(p.largestDeal), DashUi.blue)),
                  const SizedBox(width: 10),
                  Expanded(child: _tile(context, _Drill.lost, 'LOST', _whole.format(p.lostCount), DashUi.red)),
                ],
              ),
              SizedBox(height: 12 + extra),
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: 1),
                duration: const Duration(milliseconds: 1100),
                curve: Curves.easeOutCubic,
                builder: (context, t, _) => _tap(
                  context,
                  _Drill.closed,
                  (h) => _hoverShell(
                    h,
                    DashUi.emeraldDeep,
                    Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                  decoration: BoxDecoration(
                    color: DashUi.emeraldDeep.withValues(alpha: h ? 0.15 : 0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: DashUi.emeraldDeep.withValues(alpha: h ? 0.8 : 0.25),
                      width: h ? 1.5 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 58,
                        height: 58,
                        child: CustomPaint(
                          painter: _RingPainter(progress: (p.winRate / 100).clamp(0.0, 1.0) * t, color: DashUi.emeraldDeep),
                          child: const Center(child: Icon(Icons.trending_up_rounded, size: 20, color: DashUi.emeraldDeep)),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'WIN RATE',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: DashUi.slate, letterSpacing: 0.8),
                            ),
                            Text(
                              closed == 0 ? '—' : '${(p.winRate * t).toStringAsFixed(1)}%',
                              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: DashUi.emeraldDeep, height: 1.1),
                            ),
                            Text(
                              closed == 0 ? 'No closed estimates yet' : '${p.wonCount} won of $closed closed',
                              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: DashUi.slate),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                  ),
                ),
              ),
            ],
          ),
        ),
    );
  }

  /// Makes any piece of the card open the list of estimates behind its number.
  /// [builder] receives whether the cursor is over it, so the piece can show a hover state.
  Widget _tap(BuildContext context, _Drill drill, Widget Function(bool hovering) builder) => _DrillTap(
        drill: drill,
        onTap: () => showDialog(
          context: context,
          builder: (_) => _personListDialog(person: person, year: year, drill: drill),
        ),
        builder: builder,
      );

  /// Adds the "opens something" arrow in the corner while hovered.
  Widget _hoverShell(bool hovering, Color color, Widget child) => Stack(
        fit: StackFit.passthrough,
        children: [
          child,
          Positioned(
            top: 8,
            right: 10,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: hovering ? 1 : 0,
                duration: const Duration(milliseconds: 150),
                child: Icon(Icons.arrow_outward_rounded, size: 16, color: color),
              ),
            ),
          ),
        ],
      );

  Widget _tile(BuildContext context, _Drill drill, String label, String value, Color color) => _tap(
        context,
        drill,
        (h) => _hoverShell(
          h,
          color,
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 14),
            decoration: BoxDecoration(
              color: h ? color.withValues(alpha: 0.09) : const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: h ? color.withValues(alpha: 0.7) : Colors.transparent, width: 1.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    label,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.bold,
                      color: h ? color : DashUi.muted,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: color,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

/// Click target with a pointer cursor, a tooltip and a hover flag for its child.
class _DrillTap extends StatefulWidget {
  final _Drill drill;
  final VoidCallback onTap;
  final Widget Function(bool hovering) builder;
  const _DrillTap({required this.drill, required this.onTap, required this.builder});

  @override
  State<_DrillTap> createState() => _DrillTapState();
}

class _DrillTapState extends State<_DrillTap> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'See the ${widget.drill.what}',
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: widget.builder(_hovering),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  final Color color;
  const _RingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 6.0;
    final rect = Rect.fromLTWH(stroke / 2, stroke / 2, size.width - stroke, size.height - stroke);
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..color = color.withValues(alpha: 0.15)
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    if (progress > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2 * progress,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => old.progress != progress || old.color != color;
}

// =============================================================================
// DRILL-DOWN (click any metric on a person's card to see the estimates behind it)
// =============================================================================

enum _Drill { won, sent, lost, closed, largest }

extension _DrillX on _Drill {
  /// Value of the backend's `filter` query parameter.
  String get filter => switch (this) {
        _Drill.won || _Drill.largest => 'won',
        _Drill.sent => 'sent',
        _Drill.lost => 'lost',
        _Drill.closed => 'closed',
      };

  String get title => switch (this) {
        _Drill.won => 'Won estimates',
        _Drill.sent => 'Estimates sent',
        _Drill.lost => 'Lost estimates',
        _Drill.closed => 'Closed estimates (won and lost)',
        _Drill.largest => 'Won estimates, largest first',
      };

  /// Used in the hover tooltip: "See the won estimates".
  String get what => switch (this) {
        _Drill.won => 'won estimates',
        _Drill.sent => 'estimates sent',
        _Drill.lost => 'lost estimates',
        _Drill.closed => 'closed estimates',
        _Drill.largest => 'won estimates, largest first',
      };

  Color get color => switch (this) {
        _Drill.won => DashUi.sky,
        _Drill.sent => DashUi.ink,
        _Drill.lost => DashUi.red,
        _Drill.closed => DashUi.emeraldDeep,
        _Drill.largest => DashUi.blue,
      };

  IconData get icon => switch (this) {
        _Drill.won => Icons.check_circle_outline_rounded,
        _Drill.sent => Icons.send_rounded,
        _Drill.lost => Icons.highlight_off_rounded,
        _Drill.closed => Icons.rule_rounded,
        _Drill.largest => Icons.emoji_events_outlined,
      };

  bool get valueFirst => this == _Drill.largest;
}

/// The estimates behind one metric on a person's card.
EstimateListDialog _personListDialog({required _Person person, required int year, required _Drill drill}) {
  return EstimateListDialog(
    year: year,
    heading: '${person.name} · ${drill.title}',
    color: drill.color,
    icon: drill.icon,
    uri: Uri.parse(
      '$kApiBaseUrl/api/dashboards/sales/estimates'
      '?year=$year&owner=${Uri.encodeQueryComponent(person.name)}&filter=${drill.filter}',
    ),
    initialSort: drill.valueFirst ? EstimateListSort.value : EstimateListSort.newest,
  );
}

/// The estimates containing one door style from the pie chart.
EstimateListDialog _doorListDialog({
  required String doorType,
  required int year,
  required Color color,
  required bool revenueView,
}) {
  return EstimateListDialog(
    year: year,
    heading: '$doorType estimates',
    totalLabel: 'in door lines',
    color: color,
    icon: Icons.sensor_door_outlined,
    uri: Uri.parse(
      '$kApiBaseUrl/api/dashboards/sales/door-estimates'
      '?year=$year&type=${Uri.encodeQueryComponent(doorType)}',
    ),
    initialSort: revenueView ? EstimateListSort.value : EstimateListSort.newest,
    outcomeFilter: true,
    initialOutcome: revenueView ? 'won' : 'all',
  );
}
// =============================================================================
// DOOR TYPES (pie chart that cycles between win rate and revenue every 8 seconds)
// =============================================================================

class _DoorType {
  final String type;
  final int sentCount;
  final int wonCount;
  final int lostCount;
  final double revenue;
  const _DoorType({
    required this.type,
    required this.sentCount,
    required this.wonCount,
    required this.lostCount,
    required this.revenue,
  });

  factory _DoorType.fromJson(Map<String, dynamic> j) => _DoorType(
        type: (j['type'] ?? 'Unspecified').toString(),
        sentCount: _i(j['sentCount']),
        wonCount: _i(j['wonCount']),
        lostCount: _i(j['lostCount']),
        revenue: _d(j['revenue']),
      );
}

enum _DoorView { winRate, revenue }

const _doorPalette = [
  DashUi.sky,
  DashUi.indigo,
  DashUi.emeraldDeep,
  DashUi.amber,
  DashUi.blue,
  Color(0xFF8B5CF6),
  Color(0xFF0D9488),
  Color(0xFFDB2777),
  Color(0xFF475569),
  Color(0xFF65A30D),
];

class _DoorSlice {
  final String label;
  final Color color;
  final int won;
  final int lost;
  final int sent;
  final double revenue;
  const _DoorSlice({
    required this.label,
    required this.color,
    required this.won,
    required this.lost,
    required this.sent,
    required this.revenue,
  });

  int get closed => won + lost;
  double get winRate => closed > 0 ? won / closed * 100 : 0;

  /// What the slice's size means in each view: deals won, or won revenue.
  double sizeFor(_DoorView v) => v == _DoorView.winRate ? won.toDouble() : revenue;
}

/// The top [limit] styles for [view], biggest first. Lines with no style ("Unspecified") are left out.
List<_DoorSlice> _doorSlices(List<_DoorType> allDoors, _DoorView view, int limit) {
  final doors = allDoors.where((d) => d.type != 'Unspecified').toList();

  // Colors follow revenue rank, so a style keeps its color in both views.
  final ranked = [...doors]..sort((a, b) => b.revenue.compareTo(a.revenue));
  Color colorOf(String type) {
    final i = ranked.indexWhere((d) => d.type == type);
    return _doorPalette[(i < 0 ? 0 : i) % _doorPalette.length];
  }

  final all = [
    for (final d in doors)
      _DoorSlice(label: d.type, color: colorOf(d.type), won: d.wonCount, lost: d.lostCount, sent: d.sentCount, revenue: d.revenue),
  ]..sort((a, b) {
      final c = b.sizeFor(view).compareTo(a.sizeFor(view));
      return c != 0 ? c : b.sent.compareTo(a.sent);
    });

  return all.take(limit).toList();
}
class _DoorTypePanel extends StatefulWidget {
  final List<_DoorType> doors;
  final int year;
  const _DoorTypePanel({required this.doors, required this.year});

  @override
  State<_DoorTypePanel> createState() => _DoorTypePanelState();
}

class _DoorTypePanelState extends State<_DoorTypePanel> with SingleTickerProviderStateMixin {
  static const _cycle = Duration(seconds: 8);

  late final AnimationController _intro;
  Timer? _timer;
  _DoorView _view = _DoorView.winRate;
  int? _hover;
  bool _panelHover = false;

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..forward();
    _restartTimer();
  }

  @override
  void didUpdateWidget(covariant _DoorTypePanel old) {
    super.didUpdateWidget(old);
    if (!identical(old.doors, widget.doors)) {
      _hover = null;
      _intro.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _intro.dispose();
    super.dispose();
  }

  void _openDoor(_DoorSlice s) {
    showDialog(
      context: context,
      builder: (_) => _doorListDialog(
        doorType: s.label,
        year: widget.year,
        color: s.color,
        revenueView: _view == _DoorView.revenue,
      ),
    );
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_cycle, (_) {
      if (!mounted || _panelHover) return;
      _setView(_view == _DoorView.winRate ? _DoorView.revenue : _DoorView.winRate);
    });
  }

  void _setView(_DoorView v) {
    if (v == _view) return;
    setState(() {
      _view = v;
      _hover = null;
    });
    _intro.forward(from: 0);
    _restartTimer();
  }

  int? _hitTest(Offset p, double size, List<_DoorSlice> slices, double total) {
    final c = Offset(size / 2, size / 2);
    final d = p - c;
    final outer = size / 2 - 6;
    final dist = d.distance;
    if (dist < outer * 0.6 - 2 || dist > outer + 8) return null;
    var angle = math.atan2(d.dy, d.dx) + math.pi / 2;
    if (angle < 0) angle += math.pi * 2;
    var acc = 0.0;
    for (var i = 0; i < slices.length; i++) {
      acc += slices[i].sizeFor(_view) / total * math.pi * 2;
      if (angle <= acc) return slices[i].sizeFor(_view) > 0 ? i : null;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final isRate = _view == _DoorView.winRate;

    return MouseRegion(
      onEnter: (_) => _panelHover = true,
      onExit: (_) => _panelHover = false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
        decoration: DashUi.panel(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isRate ? 'Win rate by door type' : 'Revenue by door type',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: DashUi.slate),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isRate
                          ? 'Top 10 Clopay styles · ${widget.year} · sized by deals won'
                          : 'Top 10 Clopay styles · door lines on won estimates · ${widget.year}',
                      style: const TextStyle(fontSize: 12, color: DashUi.muted, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
                SizedBox(
                  width: 230,
                  child: AppSegmented<_DoorView>(
                    value: _view,
                    options: const [(_DoorView.winRate, 'Win rate'), (_DoorView.revenue, 'Revenue YTD')],
                    onChanged: _setView,
                    activeColor: DashUi.sky,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(child: LayoutBuilder(builder: (context, c) => _body(c))),
          ],
        ),
      ),
    );
  }

  Widget _body(BoxConstraints c) {
    final slices = _doorSlices(widget.doors, _view, 10);
    final total = slices.fold<double>(0, (s, x) => s + x.sizeFor(_view));

    if (widget.doors.isEmpty || total <= 0) {
      return Center(
        child: Text(
          'No door styles found on ${widget.year} estimates yet.',
          style: const TextStyle(fontSize: 14, color: DashUi.muted, fontWeight: FontWeight.w500),
        ),
      );
    }

    final size = math.min(c.maxHeight, c.maxWidth * 0.42).toDouble();
    final hovered = (_hover != null && _hover! < slices.length) ? slices[_hover!] : null;

    return Row(
      children: [
        SizedBox(
          width: size,
          height: size,
          child: MouseRegion(
            cursor: _hover != null ? SystemMouseCursors.click : MouseCursor.defer,
            onHover: (e) {
              final i = _hitTest(e.localPosition, size, slices, total);
              if (i != _hover) setState(() => _hover = i);
            },
            onExit: (_) {
              if (_hover != null) setState(() => _hover = null);
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) {
                final i = _hitTest(d.localPosition, size, slices, total);
                if (i != null) _openDoor(slices[i]);
              },
              child: Stack(
              children: [
                AnimatedBuilder(
                  animation: _intro,
                  builder: (context, _) => CustomPaint(
                    size: Size.square(size),
                    painter: _DonutPainter(
                      slices: slices,
                      view: _view,
                      total: total,
                      hover: _hover,
                      intro: Curves.easeOutCubic.transform(_intro.value),
                    ),
                  ),
                ),
                IgnorePointer(child: Center(child: _center(slices, hovered, size))),
              ],
            ),
            ),
          ),
        ),
        const SizedBox(width: 24),
        Expanded(child: _legend(slices, total)),
      ],
    );
  }

  Widget _center(List<_DoorSlice> slices, _DoorSlice? hovered, double size) {
    final isRate = _view == _DoorView.winRate;
    final won = slices.fold(0, (s, x) => s + x.won);
    final lost = slices.fold(0, (s, x) => s + x.lost);
    final overallRate = won + lost > 0 ? won / (won + lost) * 100 : 0.0;
    final revenue = slices.fold(0.0, (s, x) => s + x.revenue);

    final String top;
    final String big;
    final String bottom;
    if (hovered != null) {
      top = hovered.label;
      if (isRate) {
        big = hovered.closed == 0 ? '—' : '${hovered.winRate.toStringAsFixed(0)}%';
        bottom = '${hovered.won}/${hovered.closed} won';
      } else {
        big = _compactMoney(hovered.revenue);
        bottom = '${hovered.won} ${hovered.won == 1 ? 'estimate' : 'estimates'} won';
      }
    } else if (isRate) {
      top = slices.length >= 10 ? 'TOP 10' : 'ALL DOORS';
      big = '${overallRate.toStringAsFixed(0)}%';
      bottom = '$won/${won + lost} won';
    } else {
      top = 'DOOR REVENUE';
      big = _compactMoney(revenue);
      bottom = 'won in ${widget.year}';
    }

    // The hole is about 60% of the donut; keep the text well inside it and shrink to fit.
    return SizedBox(
      width: size * 0.5,
      height: size * 0.5,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 110),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // On a small donut the caption would cross the ring, so only show it when hovering.
              if (size >= 150 || hovered != null)
                Text(
                  top,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: DashUi.muted, letterSpacing: 0.6),
                ),
              Text(
                big,
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: DashUi.ink, height: 1.15),
              ),
              Text(
                bottom,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: DashUi.slate),
              ),
              if (hovered != null)
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Text('Click for list', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: DashUi.sky)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static const _rowH = 27.0;
  static const _rowHMin = 21.0;

  /// One column when everything fits; otherwise two columns, with rows tightened (down to [_rowHMin])
  /// so all of the top 10 are visible without scrolling.
  Widget _legend(List<_DoorSlice> slices, double total) {
    return LayoutBuilder(builder: (context, box) {
      final n = slices.length;
      final single = n * _rowH <= box.maxHeight;
      final half = (n / 2).ceil();
      final tightH = box.maxHeight / half;

      if (!single && box.maxWidth >= 340 && tightH >= _rowHMin) {
        final rowH = math.min(_rowH, tightH);
        final colW = (box.maxWidth - 12) / 2;
        Widget col(int from, int to) => Expanded(
              child: Column(
                children: [
                  for (var i = from; i < to; i++)
                    _legendRow(slices[i], i, total, compact: true, rowH: rowH, showCount: colW >= 215),
                ],
              ),
            );
        // Centered against the donut so the two line up.
        return Align(
          alignment: Alignment.centerLeft,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [col(0, half), const SizedBox(width: 12), col(half, n)],
          ),
        );
      }

      return ListView.builder(
        physics: const ClampingScrollPhysics(),
        itemCount: n,
        itemBuilder: (context, i) => _legendRow(slices[i], i, total, compact: false, rowH: _rowH),
      );
    });
  }
  Widget _legendRow(_DoorSlice s, int i, double total, {required bool compact, required double rowH, bool showCount = true}) {
    final isRate = _view == _DoorView.winRate;
    final active = _hover == i;
    final dim = _hover != null && !active;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = i),
      onExit: (_) => setState(() => _hover = null),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openDoor(s),
        child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: dim ? 0.45 : 1,
        child: Container(
          height: rowH,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: active ? DashUi.faint : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(color: s.color, borderRadius: BorderRadius.circular(3))),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  s.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, fontWeight: active ? FontWeight.w800 : FontWeight.w600, color: DashUi.ink),
                ),
              ),
              if (isRate) ...[
                if (showCount) ...[
                  Text('${s.won}/${s.closed}', style: const TextStyle(fontSize: 11.5, color: DashUi.muted, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                ],
                SizedBox(
                  width: 38,
                  child: Text(
                    s.closed == 0 ? '—' : '${s.winRate.toStringAsFixed(0)}%',
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: DashUi.emeraldDeep),
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 46,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: (s.winRate / 100).clamp(0.0, 1.0),
                        minHeight: 5,
                        backgroundColor: DashUi.line,
                        valueColor: const AlwaysStoppedAnimation(DashUi.emeraldDeep),
                      ),
                    ),
                  ),
                ],
              ] else ...[
                if (!compact) ...[
                  Text(
                    total > 0 ? '${(s.revenue / total * 100).toStringAsFixed(0)}%' : '',
                    style: const TextStyle(fontSize: 11.5, color: DashUi.muted, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 10),
                ],
                SizedBox(
                  width: 52,
                  child: Text(
                    _compactMoney(s.revenue),
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: DashUi.sky),
                  ),
                ),
              ],
            ],
          ),
        ),
        ),
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  final List<_DoorSlice> slices;
  final _DoorView view;
  final double total;
  final int? hover;
  final double intro;

  const _DonutPainter({
    required this.slices,
    required this.view,
    required this.total,
    required this.hover,
    required this.intro,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outer = size.width / 2 - 6;
    final stroke = outer * 0.4;
    final base = outer - stroke / 2;
    final gap = slices.where((s) => s.sizeFor(view) > 0).length > 1 ? 0.03 : 0.0;
    final limit = -math.pi / 2 + intro * math.pi * 2;

    var start = -math.pi / 2;
    for (var i = 0; i < slices.length; i++) {
      final v = slices[i].sizeFor(view);
      if (v <= 0) continue;
      final full = v / total * math.pi * 2;
      final a0 = start + gap / 2;
      final a1 = math.min(start + full - gap / 2, limit);
      start += full;
      if (a1 <= a0) continue;

      final active = hover == i;
      final dim = hover != null && !active;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: base + (active ? 3 : 0)),
        a0,
        a1 - a0,
        false,
        Paint()
          ..color = slices[i].color.withValues(alpha: dim ? 0.35 : 1)
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke + (active ? 6 : 0),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.slices != slices || old.view != view || old.hover != hover || old.intro != intro || old.total != total;
}

// =============================================================================
// MONTHLY WON CHART
// =============================================================================

class _MonthlyWonChart extends StatefulWidget {
  final List<_Month> data;
  final List<double> prior;
  final int year;
  final double total;

  /// Won value for the same stretch of the previous year (to today's date), for the comparison chip.
  final double priorTotal;
  const _MonthlyWonChart({
    required this.data,
    required this.prior,
    required this.year,
    required this.total,
    required this.priorTotal,
  });

  @override
  State<_MonthlyWonChart> createState() => _MonthlyWonChartState();
}

class _MonthlyWonChartState extends State<_MonthlyWonChart> with TickerProviderStateMixin {
  late final AnimationController _intro;
  late final AnimationController _hover;
  int? _index;

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..forward();
    _hover = AnimationController(vsync: this, duration: const Duration(milliseconds: 160));
  }

  @override
  void didUpdateWidget(covariant _MonthlyWonChart old) {
    super.didUpdateWidget(old);
    if (!identical(old.data, widget.data)) {
      _index = null;
      _hover.value = 0;
      _intro.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    _hover.dispose();
    super.dispose();
  }

  void _setActive(int? i) {
    if (i == _index) return;
    setState(() => _index = i);
    if (i != null) {
      _hover.forward();
    } else {
      _hover.reverse();
    }
  }

  int? _indexFor(double dx, double width) {
    final plotW = width - _WonChartPainter.leftGutter;
    if (plotW <= 0) return null;
    final i = ((dx - _WonChartPainter.leftGutter) / (plotW / 12)).floor();
    return (i < 0 || i >= 12) ? null : i;
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final maxV = [...w.data.map((m) => m.wonValue), ...w.prior].fold<double>(0, math.max);
    final scale = _niceScale(maxV);
    final now = DateTime.now();
    final currentMonth = w.year == now.year ? now.month - 1 : null;

    return LayoutBuilder(builder: (context, box) {
    final compact = box.maxHeight < 230;
    return Container(
      padding: EdgeInsets.fromLTRB(20, compact ? 12 : 18, 20, compact ? 10 : 14),
      decoration: DashUi.panel(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (compact) _compactHeader() else Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Won revenue by month', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: DashUi.slate)),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _compactMoney(w.total),
                        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: DashUi.ink, height: 1.1),
                      ),
                      const SizedBox(width: 10),
                      Text('Total for ${w.year}', style: const TextStyle(fontSize: 13, color: DashUi.muted, fontWeight: FontWeight.w500)),
                      if (w.priorTotal > 0) ...[
                        const SizedBox(width: 10),
                        _vsPriorChip((w.total - w.priorTotal) / w.priorTotal * 100, w.year - 1),
                      ],
                    ],
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _legend(
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(3),
                        gradient: const LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Color(0xFF0369A1), Color(0xFF0284C7)],
                        ),
                      ),
                    ),
                    '${w.year}',
                  ),
                  const SizedBox(width: 16),
                  _legend(
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: List.generate(
                        3,
                        (i) => Container(width: 4, height: 2.5, margin: EdgeInsets.only(right: i == 2 ? 0 : 2), color: DashUi.amber),
                      ),
                    ),
                    '${w.year - 1}',
                  ),
                ],
              ),
            ],
          ),
          SizedBox(height: compact ? 6 : 16),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) => MouseRegion(
                onHover: (e) => _setActive(_indexFor(e.localPosition.dx, c.maxWidth)),
                onExit: (_) => _setActive(null),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _setActive(_indexFor(d.localPosition.dx, c.maxWidth)),
                  onHorizontalDragUpdate: (d) => _setActive(_indexFor(d.localPosition.dx, c.maxWidth)),
                  child: AnimatedBuilder(
                    animation: Listenable.merge([_intro, _hover]),
                    builder: (context, _) => CustomPaint(
                      size: Size.infinite,
                      painter: _WonChartPainter(
                        data: w.data,
                        prior: w.prior,
                        year: w.year,
                        scale: scale,
                        currentMonth: currentMonth,
                        index: _index,
                        intro: _intro.value,
                        hover: Curves.easeOutCubic.transform(_hover.value),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    });
  }

  /// One-line header for short panels: title, total, comparison and legend side by side.
  Widget _compactHeader() {
    final w = widget;
    return Row(
      children: [
        const Text('Won revenue by month', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.slate)),
        const SizedBox(width: 10),
        Text(_compactMoney(w.total), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: DashUi.ink)),
        if (w.priorTotal > 0) ...[
          const SizedBox(width: 8),
          _vsPriorChip((w.total - w.priorTotal) / w.priorTotal * 100, w.year - 1),
        ],
        const Spacer(),
        _legend(Container(width: 10, height: 10, decoration: BoxDecoration(color: DashUi.sky, borderRadius: BorderRadius.circular(3))), '${w.year}'),
        const SizedBox(width: 12),
        _legend(Container(width: 12, height: 2.5, color: DashUi.amber), '${w.year - 1}'),
      ],
    );
  }

  Widget _vsPriorChip(double pct, int priorYear) {
    final up = pct >= 0;
    final color = up ? DashUi.emeraldDeep : DashUi.red;
    return Tooltip(
      message: 'Compared with the same period of $priorYear',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Text(
          '${up ? '▲' : '▼'} ${pct.abs().toStringAsFixed(0)}% vs $priorYear',
          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: color),
        ),
      ),
    );
  }

  Widget _legend(Widget swatch, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          swatch,
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: DashUi.slate)),
        ],
      );
}

class _WonChartPainter extends CustomPainter {
  static const double leftGutter = 46;
  static const double bottomGutter = 26;
  static const double topPad = 6;

  final List<_Month> data;
  final List<double> prior;
  final int year;
  final _Scale scale;
  final int? currentMonth;
  final int? index;
  final double intro;
  final double hover;

  const _WonChartPainter({
    required this.data,
    required this.prior,
    required this.year,
    required this.scale,
    required this.currentMonth,
    required this.index,
    required this.intro,
    required this.hover,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final plotW = size.width - leftGutter;
    final plotH = size.height - bottomGutter - topPad;
    if (plotW <= 0 || plotH <= 0) return;
    final slot = plotW / 12;

    double yFor(double v) => topPad + plotH * (1 - (v / scale.max).clamp(0.0, 1.0));
    double xFor(int i) => leftGutter + slot * (i + 0.5);

    // Grid + y labels
    final grid = Paint()
      ..color = DashUi.line
      ..strokeWidth = 1;
    for (var t = 0; t <= scale.ticks; t++) {
      final y = yFor(t * scale.step);
      canvas.drawLine(Offset(leftGutter, y), Offset(size.width, y), grid);
      final tp = _layoutText(
        _compactMoney(t * scale.step),
        const TextStyle(fontSize: 11, color: DashUi.muted, fontWeight: FontWeight.w500),
        maxWidth: leftGutter - 8,
        align: TextAlign.right,
      );
      tp.paint(canvas, Offset(leftGutter - 8 - tp.width, y - tp.height / 2));
    }

    // Bars
    final barW = math.min(slot * 0.52, 38.0);
    for (var i = 0; i < 12; i++) {
      final local = Curves.easeOutCubic.transform(((intro - i * 0.04) / 0.52).clamp(0.0, 1.0));
      final v = data[i].wonValue * local;
      final focused = index == i;
      final dimmed = index != null && !focused;

      // Month label
      final isNow = currentMonth == i;
      final label = _layoutText(
        _monthNames[i],
        TextStyle(
          fontSize: 11.5,
          color: focused || isNow ? DashUi.ink : DashUi.muted,
          fontWeight: focused || isNow ? FontWeight.w800 : FontWeight.w500,
        ),
      );
      label.paint(canvas, Offset(xFor(i) - label.width / 2, size.height - bottomGutter + 8));

      if (v <= 0) continue;
      final top = yFor(v);
      final rect = RRect.fromRectAndCorners(
        Rect.fromLTRB(xFor(i) - barW / 2, top, xFor(i) + barW / 2, topPad + plotH),
        topLeft: const Radius.circular(5),
        topRight: const Radius.circular(5),
      );
      final colors = focused ? const [Color(0xFF075985), Color(0xFF38BDF8)] : const [Color(0xFF0369A1), Color(0xFF0284C7)];
      canvas.drawRRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [for (final c in colors) c.withValues(alpha: dimmed ? 0.4 : 1)],
          ).createShader(rect.outerRect),
      );
    }

    // Prior-year line (dashed)
    if (prior.any((v) => v > 0)) {
      final path = Path();
      for (var i = 0; i < 12; i++) {
        final p = Offset(xFor(i), yFor(prior[i]));
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      final line = Paint()
        ..color = DashUi.amber.withValues(alpha: 0.85 * intro)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round;
      for (final m in path.computeMetrics()) {
        var d = 0.0;
        while (d < m.length) {
          canvas.drawPath(m.extractPath(d, math.min(d + 5, m.length)), line);
          d += 9;
        }
      }
      for (var i = 0; i < 12; i++) {
        canvas.drawCircle(Offset(xFor(i), yFor(prior[i])), index == i ? 3.6 : 2.4, Paint()..color = DashUi.amber.withValues(alpha: intro));
      }
    }

    if (index != null && hover > 0) _paintTooltip(canvas, size, xFor(index!), plotH);
  }

  void _paintTooltip(Canvas canvas, Size size, double cx, double plotH) {
    final i = index!;
    final m = data[i];

    final head = _layoutText('${_monthNames[i]} $year', const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: DashUi.ink));
    final rows = <(String, String, Color)>[
      ('Won', _money(m.wonValue), DashUi.sky),
      ('Deals', '${m.wonCount} · ${m.winRate.toStringAsFixed(0)}% win', DashUi.slate),
      ('${year - 1}', _money(prior[i]), DashUi.amber),
    ];
    final labels = [for (final r in rows) _layoutText(r.$1, const TextStyle(fontSize: 12, color: DashUi.muted, fontWeight: FontWeight.w600))];
    final values = [
      for (final r in rows) _layoutText(r.$2, TextStyle(fontSize: 12, color: r.$3, fontWeight: FontWeight.w800)),
    ];

    final labelW = labels.map((t) => t.width).reduce(math.max);
    final valueW = values.map((t) => t.width).reduce(math.max);
    final w = math.max(head.width, labelW + 14 + valueW) + 24;
    final h = 12 + head.height + 6 + rows.length * 17 + 8;

    final barTop = math.min(
      data[i].wonValue <= 0 ? plotH : topPad + plotH * (1 - (data[i].wonValue / scale.max).clamp(0.0, 1.0)),
      plotH,
    );
    final x = (cx - w / 2).clamp(leftGutter, math.max(leftGutter, size.width - w)).toDouble();
    final y = (barTop - h - 10).clamp(0.0, math.max(0.0, size.height - bottomGutter - h)).toDouble();

    final box = RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), const Radius.circular(10));
    canvas.save();
    canvas.drawRRect(box.shift(const Offset(0, 3)), Paint()
      ..color = const Color(0x1A0F172A).withValues(alpha: 0.1 * hover)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
    canvas.drawRRect(box, Paint()..color = Colors.white.withValues(alpha: hover));
    canvas.drawRRect(
      box,
      Paint()
        ..color = DashUi.line.withValues(alpha: hover)
        ..style = PaintingStyle.stroke,
    );
    canvas.restore();

    if (hover < 0.6) return;
    head.paint(canvas, Offset(x + 12, y + 10));
    var ry = y + 10 + head.height + 6;
    for (var r = 0; r < rows.length; r++) {
      labels[r].paint(canvas, Offset(x + 12, ry));
      values[r].paint(canvas, Offset(x + w - 12 - values[r].width, ry));
      ry += 17;
    }
  }

  @override
  bool shouldRepaint(covariant _WonChartPainter old) =>
      old.data != data ||
      old.prior != prior ||
      old.index != index ||
      old.intro != intro ||
      old.hover != hover ||
      old.scale.max != scale.max;
}

// =============================================================================
// LOADING SKELETON
// =============================================================================

class _SalesSkeleton extends StatelessWidget {
  const _SalesSkeleton();

  Widget _metric() => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: DashUi.panel(radius: 12),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [SkeletonBox(h: 12, w: 120), SizedBox(height: 12), SkeletonBox(h: 26, w: 170)],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return SkeletonPulse(
      child: Column(
        children: [
          SizedBox(
            height: 86,
            child: Row(children: [_metric(), const SizedBox(width: 12), _metric(), const SizedBox(width: 12), _metric(), const SizedBox(width: 12), _metric()]),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < 2; i++) ...[
                  Expanded(
                    flex: 3,
                    child: Container(
                      decoration: DashUi.panel(radius: 18),
                      clipBehavior: Clip.antiAlias,
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 4, child: SkeletonBox(r: 0)),
                          Expanded(
                            flex: 7,
                            child: Padding(
                              padding: EdgeInsets.all(22),
                              child: SingleChildScrollView(
                                physics: NeverScrollableScrollPhysics(),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SkeletonBox(h: 20, w: 150),
                                    SizedBox(height: 10),
                                    SkeletonBox(h: 14, w: 100),
                                    SizedBox(height: 24),
                                    SkeletonBox(h: 86, r: 12),
                                    SizedBox(height: 10),
                                    SkeletonBox(h: 56, r: 12),
                                    SizedBox(height: 10),
                                    SkeletonBox(h: 56, r: 12),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                ],
                Expanded(
                  flex: 6,
                  child: Column(
                    children: [
                      for (final flex in const [11, 9]) ...[
                        Expanded(
                          flex: flex,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(20),
                            decoration: DashUi.panel(),
                            child: const Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SkeletonBox(h: 12, w: 160),
                                SizedBox(height: 14),
                                Expanded(child: SkeletonBox(r: 10)),
                              ],
                            ),
                          ),
                        ),
                        if (flex == 11) const SizedBox(height: 16),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
