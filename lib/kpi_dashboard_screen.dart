import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';
import 'widgets/status_pill.dart';

part 'employee_kpi_screen.dart';

class KPIDashboardScreen extends StatelessWidget {
  const KPIDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const KPIDashboardContent();
  }
}

class KPIDashboardContent extends StatefulWidget {
  const KPIDashboardContent({super.key});

  @override
  State<KPIDashboardContent> createState() => _KPIDashboardContentState();
}

// =============================================================================
// HELPERS
// =============================================================================

const _ink = Color(0xFF0F172A);
const _slate = Color(0xFF64748B);
const _muted = Color(0xFF94A3B8);
const _line = Color(0xFFE5E7EB);
const _faint = Color(0xFFF1F5F9);
const _gold = Color(0xFFF59E0B);

String _str(dynamic v) => v?.toString().trim() ?? '';

double? _num(dynamic v) => v == null ? null : double.tryParse(v.toString());

String _fmtNum(double v) {
  final s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// "2 yrs 8 mo", "1 yr", "5 months", "Less than a month".
String _fmtTenure(double? years) {
  if (years == null) return '—';
  final total = (years * 12).round();
  if (total <= 0) return 'Less than a month';
  if (total < 12) return '$total ${total == 1 ? 'month' : 'months'}';
  final y = total ~/ 12, m = total % 12;
  final yPart = '$y ${y == 1 ? 'yr' : 'yrs'}';
  return m == 0 ? yPart : '$yPart $m mo';
}

/// "Admin", "Warehouse", "Lead Technician": the API sends raw role values in any case.
String _prettyRole(String raw) {
  final words = raw.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  return words.map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase()).join(' ');
}

Color _roleColor(String title) {
  final t = title.toLowerCase();
  if (t.contains('tech')) return DashUi.blue;
  if (t.contains('sales')) return DashUi.emeraldDeep;
  if (t.contains('admin') || t.contains('manager')) return DashUi.amber;
  if (t.contains('office')) return DashUi.indigo;
  return _slate;
}

bool _reduceMotion(BuildContext context) => MediaQuery.maybeOf(context)?.disableAnimations ?? false;

Color _scoreColor(double? s) {
  if (s == null) return _muted;
  if (s >= 90) return const Color(0xFF10B981);
  if (s >= 80) return const Color(0xFF2563EB);
  return _gold;
}

/// Whole completed years ("2 yrs"), so it never disagrees with the exact tenure shown beside it.
String? _milestone(double? y) {
  if (y == null || y < 1) return null;
  final n = y.floor();
  return '$n ${n == 1 ? 'yr' : 'yrs'}';
}

/// A failure with a message that is safe to show as is.
class _KpiLoadError implements Exception {
  final String message;
  const _KpiLoadError(this.message);
}

// =============================================================================
// MODEL
// =============================================================================

class _EmployeeUser {
  final String id;
  final String name;
  final String jobTitle; // the raw role: colours and layouts key off it
  final String displayTitle; // what to print ("Commercial Estimator"); falls back to the role
  final String avatarUrl;
  final double? integrityScore; // null = no score recorded
  final double? yearsWorked; // null = unknown
  final double? moraleScore; // 1-5, null until morale is tracked (the API doesn't send it yet)

  const _EmployeeUser({
    required this.id,
    required this.name,
    required this.jobTitle,
    required this.displayTitle,
    required this.avatarUrl,
    required this.integrityScore,
    required this.yearsWorked,
    required this.moraleScore,
  });

  /// Only skips a user when the API explicitly says they're inactive.
  static bool isInactive(Map<String, dynamic> j) =>
      j['is_active'] == false ||
      j['isActive'] == false ||
      j['active'] == false ||
      _str(j['status']).toLowerCase() == 'inactive';

  factory _EmployeeUser.fromJson(Map<String, dynamic> json) {
    String firstNonEmpty(List<dynamic> options, String fallback) {
      for (final o in options) {
        final s = _str(o);
        if (s.isNotEmpty) return s;
      }
      return fallback;
    }

    final name = firstNonEmpty([
      json['name'],
      json['full_name'],
      '${_str(json['first_name'])} ${_str(json['last_name'])}',
    ], 'Unnamed');

    final jobTitle = _prettyRole(firstNonEmpty([json['jobTitle'], json['job_title'], json['title'], json['role']], 'Employee'));
    final display = _str(json['displayTitle']);
    return _EmployeeUser(
      id: firstNonEmpty([json['id'], json['user_id']], name),
      name: name,
      jobTitle: jobTitle,
      displayTitle: display.isEmpty ? jobTitle : display,
      avatarUrl: firstNonEmpty(
        [json['avatarUrl'], json['avatar_url'], json['profile_image']],
        'https://ui-avatars.com/api/?name=${Uri.encodeQueryComponent(name)}&background=E2E8F0&color=475569&size=512',
      ),
      integrityScore: _num(json['integrityScore'] ?? json['integrity_score'] ?? json['score']),
      yearsWorked: _num(json['yearsWorked'] ?? json['years_worked'] ?? json['tenure']),
      moraleScore: _num(json['moraleScore'] ?? json['morale_score']),
    );
  }
}

/// A user plus their score-based rank.
class _Entry {
  final _EmployeeUser user;
  final int? rank;
  const _Entry(this.user, this.rank);
}

/// Loads active employees, sorted by score, with ranks (ties share a rank).
Future<List<_Entry>> _loadEntries() async {
  final http.Response response;
  try {
    response = await http.get(
      Uri.parse('$kApiBaseUrl/users'),
      headers: AuthSession.instance.headers(),
    ).timeout(const Duration(seconds: 60));
  } on TimeoutException {
    throw const _KpiLoadError('The request timed out.');
  } catch (_) {
    throw const _KpiLoadError("Couldn't reach the server.");
  }

  if (response.statusCode == 401) {
    AuthSession.instance.logout();
    throw const _KpiLoadError('Your session expired. Please sign in again.');
  }
  if (response.statusCode != 200) {
    throw _KpiLoadError('The server had a problem loading employees (code ${response.statusCode}).');
  }

  final dynamic body = json.decode(response.body);
  final dynamic raw = (body is List) ? body : (body is Map ? (body['data'] ?? body['users']) : null);
  final List<dynamic> dataList = raw is List ? raw : const [];

  final users = <_EmployeeUser>[];
  for (final item in dataList) {
    if (item is! Map) continue;
    final map = Map<String, dynamic>.from(item);
    if (_EmployeeUser.isInactive(map)) continue;
    users.add(_EmployeeUser.fromJson(map));
  }

  // Always sort by Score desc (unscored last) -> tenure desc -> name
  users.sort((a, b) {
    final sa = a.integrityScore, sb = b.integrityScore;
    if (sa == null && sb != null) return 1;
    if (sa != null && sb == null) return -1;
    if (sa != null && sb != null && sa != sb) return sb.compareTo(sa);
    final ya = a.yearsWorked ?? 0, yb = b.yearsWorked ?? 0;
    if (ya != yb) return yb.compareTo(ya);
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });

  // Ties share a rank (1, 1, 3, ...); unscored users are unranked.
  final entries = <_Entry>[];
  int? prevRank;
  double? prevScore;
  for (var i = 0; i < users.length; i++) {
    final s = users[i].integrityScore;
    int? rank;
    if (s != null) {
      if (prevScore != null && s == prevScore) {
        rank = prevRank;
      } else {
        rank = i + 1;
        prevRank = rank;
        prevScore = s;
      }
    }
    entries.add(_Entry(users[i], rank));
  }
  return entries;
}

// =============================================================================
// SCREEN STATE
// =============================================================================

class _KPIDashboardContentState extends State<KPIDashboardContent> {
  /// Width of one card slot (card 360 + 20 gap); used for the "1–4 of 9" counter and the arrows.
  static const double _slot = 380;

  bool _isLoading = true;
  String? _errorMessage;

  List<_Entry> _entries = [];
  double? _teamAvgScore;
  double? _avgTenure;
  double? _avgMorale; // average of the morale scores that exist; null while none are tracked

  /// Cards that already played their entrance animation (so they don't replay on scroll-back).
  final Set<String> _seen = {};

  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _fetchAndSortUsers();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (mounted) setState(() {});
  }

  bool get _canLeft => _scroll.hasClients && _scroll.offset > 4;
  bool get _canRight => _scroll.hasClients && _scroll.offset < _scroll.position.maxScrollExtent - 4;

  void _page(int dir) {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final target = (pos.pixels + dir * _slot * 2).clamp(pos.minScrollExtent, pos.maxScrollExtent);
    _scroll.animateTo(
      target,
      duration: _reduceMotion(context) ? Duration.zero : const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  /// "1–4 of 9", from what is actually on screen.
  String get _rangeLabel {
    final n = _entries.length;
    if (!_scroll.hasClients) return '$n employees';
    final pos = _scroll.position;
    final first = (pos.pixels / _slot).floor() + 1;
    final last = ((pos.pixels + pos.viewportDimension) / _slot).floor().clamp(first, n);
    if (first <= 1 && last >= n) return '$n employees';
    return '${first.clamp(1, n)}–$last of $n';
  }

  Future<void> _fetchAndSortUsers() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final entries = await _loadEntries();
      final users = entries.map((e) => e.user).toList();

      final scores = users.map((u) => u.integrityScore).whereType<double>().toList();
      final tenures = users.map((u) => u.yearsWorked).whereType<double>().toList();
      final morales = users.map((u) => u.moraleScore).whereType<double>().toList();

      if (!mounted) return;
      setState(() {
        _entries = entries;
        _teamAvgScore = scores.isEmpty ? null : scores.reduce((a, b) => a + b) / scores.length;
        _avgTenure = tenures.isEmpty ? null : tenures.reduce((a, b) => a + b) / tenures.length;
        _avgMorale = morales.isEmpty ? null : morales.reduce((a, b) => a + b) / morales.length;
        _seen.clear();
        _isLoading = false;
      });
      // The arrows, counter and edge fade need the list's extent, which exists only after its first layout.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } on _KpiLoadError catch (e) {
      _fail(e.message);
    } catch (_) {
      _fail("Couldn't load the team list.");
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _errorMessage = message;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final loaded = !_isLoading && _errorMessage == null && _entries.isNotEmpty;
    // Full page like payroll: dark banner on top, flat content underneath.
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageBanner(
            title: 'Team KPIs',
            actions: [
              if (loaded) ...[
                Text(_rangeLabel, style: const TextStyle(color: Colors.white70, fontSize: 12.5, fontWeight: FontWeight.w600)),
                IconButton(
                  tooltip: 'Previous employees',
                  color: Colors.white,
                  disabledColor: Colors.white38,
                  onPressed: _canLeft ? () => _page(-1) : null,
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                IconButton(
                  tooltip: 'Next employees',
                  color: Colors.white,
                  disabledColor: Colors.white38,
                  onPressed: _canRight ? () => _page(1) : null,
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
              ],
            ],
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_isLoading) return const _KpiSkeleton();

    if (_errorMessage != null) {
      return DashErrorPanel(
        title: "Couldn't load the team",
        message: _errorMessage!,
        onRetry: _fetchAndSortUsers,
      );
    }

    if (_entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.groups_outlined, size: 40, color: _muted),
            const SizedBox(height: 10),
            const Text('No active employees yet', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _ink)),
            const SizedBox(height: 4),
            const Text('Add people in Team admin and they will show up here.', style: TextStyle(fontSize: 13, color: _slate)),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _fetchAndSortUsers,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Refresh'),
            ),
          ],
        ),
      );
    }

    final integrity = _teamAvgScore;
    final moraleColor = _avgMorale == null ? _muted : (_avgMorale! >= 4 ? DashUi.emerald : (_avgMorale! >= 3 ? DashUi.amber : DashUi.red));
    final integrityColor = integrity == null ? _muted : (integrity >= 90 ? DashUi.emerald : (integrity >= 75 ? DashUi.amber : DashUi.red));
    final cards = <Widget>[
      _HeroCard(
        index: 0,
        icon: Icons.verified_rounded,
        color: integrityColor,
        label: 'Team integrity',
        value: integrity,
        format: (v) => '${_fmtNum(v)}%',
        visual: _RingVisual(progress: (integrity ?? 0) / 100, color: integrityColor, icon: Icons.shield_rounded),
      ),
      _HeroCard(
        index: 1,
        icon: Icons.monitor_heart_rounded,
        color: moraleColor,
        label: 'Employee morale',
        value: _avgMorale,
        format: (v) => '${_fmtNum(v)} / 5',
        emptyText: 'Not tracked yet',
        visual: _avgMorale == null ? null : _StarsVisual(score: _avgMorale!, color: moraleColor),
      ),
      _HeroCard(
        index: 2,
        icon: Icons.groups_rounded,
        color: DashUi.blue,
        label: 'Employees',
        value: _entries.length.toDouble(),
        format: (v) => v.round().toString(),
        visual: _FacesVisual(names: [for (final e in _entries) e.user.name], color: DashUi.blue),
      ),
      _HeroCard(
        index: 3,
        icon: Icons.hourglass_bottom_rounded,
        color: DashUi.indigo,
        label: 'Avg tenure',
        value: _avgTenure,
        format: (v) => '${_fmtNum(v)} yrs',
        visual: Icon(Icons.workspace_premium_rounded, size: 46, color: DashUi.indigo.withValues(alpha: 0.22)),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: LayoutBuilder(
            builder: (context, c) {
              if (c.maxWidth >= 1000) {
                return Row(
                  children: [
                    for (var i = 0; i < cards.length; i++) ...[
                      if (i > 0) const SizedBox(width: 14),
                      Expanded(child: cards[i]),
                    ],
                  ],
                );
              }
              return Column(
                children: [
                  Row(children: [Expanded(child: cards[0]), const SizedBox(width: 14), Expanded(child: cards[1])]),
                  const SizedBox(height: 14),
                  Row(children: [Expanded(child: cards[2]), const SizedBox(width: 14), Expanded(child: cards[3])]),
                ],
              );
            },
          ),
        ),

        // ---- Cards (Expands into all remaining vertical space) ----
        Expanded(
          child: Listener(
            // Vertical mouse wheel scrolls the row sideways
            onPointerSignal: (e) {
              if (e is PointerScrollEvent && _scroll.hasClients && e.scrollDelta.dy.abs() > e.scrollDelta.dx.abs()) {
                final pos = _scroll.position;
                _scroll.jumpTo((pos.pixels + e.scrollDelta.dy).clamp(pos.minScrollExtent, pos.maxScrollExtent));
              }
            },
            child: Stack(
              children: [
                ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(
                    scrollbars: false,
                    dragDevices: {
                      PointerDeviceKind.touch,
                      PointerDeviceKind.mouse,
                      PointerDeviceKind.trackpad,
                      PointerDeviceKind.stylus,
                    },
                  ),
                  child: ListView.builder(
                    controller: _scroll,
                    scrollDirection: Axis.horizontal,
                    // Clipped to the page so cards never run past the tiles above; the padding leaves
                    // room for the hover lift and shadow inside the clip.
                    padding: const EdgeInsets.fromLTRB(8, 12, 32, 14),
                    itemCount: _entries.length,
                    itemBuilder: (context, index) {
                      final e = _entries[index];
                      final key = e.user.id;
                      return _EmployeeFullHeightCard(
                        key: ValueKey(key),
                        user: e.user,
                        rank: e.rank,
                        teamAvg: _teamAvgScore,
                        teamSize: _entries.length,
                        index: index,
                        animate: _seen.add(key),
                      );
                    },
                  ),
                ),
                // Soft edge fade: tells you there are more cards off to the right.
                if (_canRight)
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    width: 48,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              const Color(0xFFE2E8F0).withValues(alpha: 0),
                              const Color(0xFFE2E8F0).withValues(alpha: 0.9),
                            ],
                          ),
                        ),
                      ),
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

/// Loading placeholder shaped like the page: four tiles over a row of cards.
class _KpiSkeleton extends StatelessWidget {
  const _KpiSkeleton();

  @override
  Widget build(BuildContext context) {
    return SkeletonPulse(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                for (var i = 0; i < 4; i++) ...[
                  if (i > 0) const SizedBox(width: 14),
                  const Expanded(child: SkeletonBox(h: 82, r: 18)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.topLeft,
                maxWidth: 4 * 380,
                child: Row(
                  children: [
                    for (var i = 0; i < 4; i++)
                      const Padding(
                        padding: EdgeInsets.only(right: 20, bottom: 8),
                        child: SizedBox(width: 360, height: double.infinity, child: SkeletonBox(r: 18)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// TOP SCORECARDS
// =============================================================================

/// A scorecard with some life in it: it slides up and fades in one after another, lifts under the cursor, and a soft
/// shine sweeps across every few seconds (staggered, so the row ripples). All of it stops under reduced motion.
class _HeroCard extends StatefulWidget {
  final int index; // position in the row: sets the entrance delay and the shine offset
  final IconData icon;
  final Color color;
  final String label;
  final double? value;
  final String Function(double) format;
  final String emptyText;
  final Widget? visual;

  const _HeroCard({
    required this.index,
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.format,
    this.emptyText = '—',
    this.visual,
  });

  @override
  State<_HeroCard> createState() => _HeroCardState();
}

class _HeroCardState extends State<_HeroCard> with TickerProviderStateMixin {
  late final AnimationController _enter = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
  late final AnimationController _shine = AnimationController(vsync: this, duration: const Duration(seconds: 7));
  Timer? _delay;
  bool _hover = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (_reduceMotion(context)) {
      _enter.value = 1;
      return;
    }
    _delay = Timer(Duration(milliseconds: 90 * widget.index), () {
      if (!mounted) return;
      _enter.forward();
      _shine.repeat();
    });
  }

  @override
  void dispose() {
    _delay?.cancel();
    _enter.dispose();
    _shine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = _reduceMotion(context);
    final body = _HeroCardBody(
      icon: widget.icon,
      color: widget.color,
      label: widget.label,
      value: widget.value,
      format: widget.format,
      emptyText: widget.emptyText,
      visual: widget.visual,
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedBuilder(
        animation: _enter,
        builder: (context, child) {
          final t = Curves.easeOutBack.transform(_enter.value.clamp(0.0, 1.0));
          return Opacity(
            opacity: Curves.easeOut.transform(_enter.value.clamp(0.0, 1.0)),
            child: Transform.translate(offset: Offset(0, (1 - t) * 22), child: child),
          );
        },
        child: AnimatedSlide(
          offset: Offset(0, _hover && !reduce ? -0.05 : 0),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          child: Stack(
            children: [
              body,
              if (!reduce)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: AnimatedBuilder(
                        animation: _shine,
                        // The sweep takes the first ~22% of the cycle; each card starts a little later than the last.
                        builder: (context, _) => CustomPaint(painter: _ShinePainter(((_shine.value + widget.index * 0.07) % 1.0) / 0.22)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A slanted white highlight that crosses the card once while [t] goes 0 to 1 (nothing drawn outside that range).
class _ShinePainter extends CustomPainter {
  final double t;
  const _ShinePainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    if (t < 0 || t > 1) return;
    final band = size.width * 0.22;
    final x = -band + (size.width + band * 2) * Curves.easeInOut.transform(t);
    const slant = 22.0;
    final path = Path()
      ..moveTo(x, 0)
      ..lineTo(x + band, 0)
      ..lineTo(x + band - slant, size.height)
      ..lineTo(x - slant, size.height)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: 0.55), Colors.white.withValues(alpha: 0)],
        ).createShader(Rect.fromLTWH(x - slant, 0, band, size.height)),
    );
  }

  @override
  bool shouldRepaint(covariant _ShinePainter old) => old.t != t;
}

/// The card itself: icon chip and label, a big count-up number, and an optional picture on the right.
class _HeroCardBody extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final double? value; // null shows [emptyText]
  final String Function(double) format;
  final String emptyText;
  final Widget? visual;

  const _HeroCardBody({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.format,
    this.emptyText = '—',
    this.visual,
  });

  @override
  Widget build(BuildContext context) {
    final v = value;
    final reduce = _reduceMotion(context);
    final number = v == null
        ? Text(emptyText, style: TextStyle(fontSize: emptyText.length > 2 ? 18 : 30, fontWeight: FontWeight.w800, color: _muted))
        : TweenAnimationBuilder<double>(
            tween: Tween(begin: reduce ? v : 0, end: v),
            duration: reduce ? Duration.zero : const Duration(milliseconds: 900),
            curve: Curves.easeOutCubic,
            builder: (context, x, _) => Text(
              format(x),
              maxLines: 1,
              style: TextStyle(fontSize: 30, height: 1.05, fontWeight: FontWeight.w800, letterSpacing: -1, color: color, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          );
    return Semantics(
      label: '$label: ${v == null ? emptyText : format(v)}',
      excludeSemantics: true,
      child: Container(
        height: 82,
        padding: const EdgeInsets.fromLTRB(16, 8, 14, 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            // Solid colours (tint blended onto white) so the shadow underneath never shows through the fill.
            colors: [
              Color.alphaBlend(color.withValues(alpha: 0.16), Colors.white),
              Color.alphaBlend(color.withValues(alpha: 0.04), Colors.white),
            ],
          ),
          border: Border.all(color: color.withValues(alpha: 0.28)),
          boxShadow: [BoxShadow(color: color.withValues(alpha: 0.12), blurRadius: 14, spreadRadius: -2, offset: const Offset(0, 4))],
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                        child: Icon(icon, size: 15, color: Colors.white),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          label.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, letterSpacing: 0.8, color: _slate),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: number),
                ],
              ),
            ),
            if (visual != null) ...[const SizedBox(width: 12), visual!],
          ],
        ),
      ),
    );
  }
}

/// A progress ring that fills on load, with an icon in the middle.
class _RingVisual extends StatelessWidget {
  final double progress; // 0..1
  final Color color;
  final IconData icon;
  const _RingVisual({required this.progress, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    final p = progress.clamp(0.0, 1.0);
    final reduce = _reduceMotion(context);
    return SizedBox(
      width: 52,
      height: 52,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: reduce ? p : 0, end: p),
        duration: reduce ? Duration.zero : const Duration(milliseconds: 900),
        curve: Curves.easeOutCubic,
        builder: (context, x, child) => CustomPaint(painter: _RingPainter(progress: x, color: color), child: child),
        child: Center(child: Icon(icon, size: 20, color: color)),
      ),
    );
  }
}

/// Five stars, filled to the score (half stars included).
class _StarsVisual extends StatelessWidget {
  final double score; // 0..5
  final Color color;
  const _StarsVisual({required this.score, required this.color});

  @override
  Widget build(BuildContext context) {
    final reduce = _reduceMotion(context);
    // The stars fill left to right as the number counts up, and each one pops as it fills.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: reduce ? score : 0, end: score),
      duration: reduce ? Duration.zero : const Duration(milliseconds: 1100),
      curve: Curves.easeOutCubic,
      builder: (context, s, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 5; i++)
            Transform.scale(
              scale: reduce ? 1 : 1 + 0.35 * math.sin(((s - i).clamp(0.0, 1.0)) * math.pi),
              child: Icon(
                s >= i + 0.75 ? Icons.star_rounded : (s >= i + 0.25 ? Icons.star_half_rounded : Icons.star_outline_rounded),
                size: 19,
                color: color,
              ),
            ),
        ],
      ),
    );
  }
}

/// Overlapping initials for the first few people, with "+N" for the rest.
class _FacesVisual extends StatelessWidget {
  final List<String> names;
  final Color color;
  const _FacesVisual({required this.names, required this.color});

  @override
  Widget build(BuildContext context) {
    const shown = 4, size = 32.0, step = 22.0;
    final n = math.min(names.length, shown);
    final extra = names.length - n;
    final count = n + (extra > 0 ? 1 : 0);
    final reduce = _reduceMotion(context);
    // Each bubble bounces in a beat after the one before it (one tween, staggered with Interval).
    Widget bubble(int i, String text, Color bg) => Positioned(
          left: i * step,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: reduce ? 1 : 0, end: 1),
            duration: reduce ? Duration.zero : const Duration(milliseconds: 1000),
            curve: Interval(math.min(0.1 * i + 0.25, 0.6), 1.0, curve: Curves.elasticOut),
            builder: (context, s, child) => Transform.scale(scale: s, child: child),
            child: Container(
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: bg, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
              child: Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.white)),
            ),
          ),
        );
    final palette = [color, DashUi.emerald, DashUi.indigo, DashUi.amber];
    return SizedBox(
      width: step * (count - 1) + size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < n; i++) bubble(i, names[i].trim().isEmpty ? '?' : names[i].trim()[0].toUpperCase(), palette[i % palette.length]),
          if (extra > 0) bubble(n, '+$extra', _slate),
        ],
      ),
    );
  }
}

// =============================================================================
// SCORE RING
// =============================================================================

class _RingPainter extends CustomPainter {
  final double progress; // 0..1
  final Color color;
  const _RingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 7.0;
    final center = size.center(Offset.zero);
    final radius = (math.min(size.width, size.height) - stroke) / 2;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = color.withValues(alpha: 0.15)
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    if (progress <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      progress * 2 * math.pi,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => old.progress != progress || old.color != color;
}

// =============================================================================
// CARD
// =============================================================================

class _EmployeeFullHeightCard extends StatefulWidget {
  final _EmployeeUser user;
  final int? rank;
  final double? teamAvg;
  final int teamSize;
  final int index;
  final bool animate;

  const _EmployeeFullHeightCard({
    super.key,
    required this.user,
    required this.rank,
    required this.teamAvg,
    required this.teamSize,
    required this.index,
    required this.animate,
  });

  @override
  State<_EmployeeFullHeightCard> createState() => _EmployeeFullHeightCardState();
}

class _EmployeeFullHeightCardState extends State<_EmployeeFullHeightCard> with SingleTickerProviderStateMixin {
  static const double _radius = 18;

  late final AnimationController _shine; // rotates the gold border on rank #1
  bool _hovered = false;
  bool _focused = false; // keyboard focus gets the same lift as hover
  Offset _tilt = Offset.zero; // cursor position within the card, -1..1 on each axis

  @override
  void initState() {
    super.initState();
    _shine = AnimationController(vsync: this, duration: const Duration(seconds: 4));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncShine();
  }

  @override
  void didUpdateWidget(covariant _EmployeeFullHeightCard old) {
    super.didUpdateWidget(old);
    _syncShine();
  }

  void _syncShine() {
    if (widget.rank == 1 && !_reduceMotion(context)) {
      if (!_shine.isAnimating) _shine.repeat();
    } else {
      _shine.stop();
    }
  }

  void _open() => context.go(
        '/hr/kpis/${Uri.encodeComponent(widget.user.id)}',
        extra: _EmployeeKpiArgs(_Entry(widget.user, widget.rank), widget.teamAvg, widget.teamSize),
      );

  @override
  void dispose() {
    _shine.dispose();
    super.dispose();
  }

  Color? get _trophyColor {
    switch (widget.rank) {
      case 1:
        return _gold;
      case 2:
        return const Color(0xFF94A3B8);
      case 3:
        return const Color(0xFFB45309);
      default:
        return null;
    }
  }

  Matrix4 _matrix(double h, Offset tilt) {
    final perspective = Matrix4.identity()..setEntry(3, 2, 0.0011);
    final s = 1 + 0.02 * h;
    return Matrix4.translationValues(10 * h, -8 * h, 0) *
        perspective *
        Matrix4.rotationX(-tilt.dy * 0.06 * h) *
        Matrix4.rotationY(tilt.dx * 0.06 * h) *
        Matrix4.diagonal3Values(s, s, 1);
  }

  /// Border, shadow and (for #1) the animated gold ring around the content.
  Widget _frame(double h, Widget content) {
    final isFirst = widget.rank == 1;
    final shadow = [
      BoxShadow(
        color: (isFirst ? _gold : Colors.black).withValues(alpha: (isFirst ? 0.18 : 0.03) + (isFirst ? 0.04 : 0.11) * h),
        blurRadius: 8 + 16 * h,
        offset: Offset((isFirst ? 3 : 8) * h, 2 + 8 * h),
      ),
    ];

    if (isFirst) {
      return AnimatedBuilder(
        animation: _shine,
        builder: (context, _) => Container(
          padding: const EdgeInsets.all(2.5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_radius + 2.5),
            gradient: SweepGradient(
              colors: const [Color(0xFFF59E0B), Color(0xFFFDE68A), Color(0xFFF59E0B), Color(0xFFD97706), Color(0xFFF59E0B)],
              transform: GradientRotation(_shine.value * 2 * math.pi),
            ),
            boxShadow: shadow,
          ),
          child: ClipRRect(borderRadius: BorderRadius.circular(_radius), child: content),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_radius),
        border: Border.all(color: Color.lerp(_line, const Color(0xFF38BDF8), h)!, width: 1 + h),
        boxShadow: shadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: content,
    );
  }

  @override
  Widget build(BuildContext context) {
    final reduce = _reduceMotion(context);
    final lifted = _hovered || _focused;
    final u = widget.user;
    final tenureText = u.yearsWorked == null ? 'tenure unknown' : 'tenure ${_fmtTenure(u.yearsWorked)}';
    final scoreText = u.integrityScore == null ? 'no integrity score' : 'integrity score ${_fmtNum(u.integrityScore!)} percent';

    final card = Padding(
      padding: const EdgeInsets.only(right: 20),
      child: SizedBox(
        width: 360,
        child: LayoutBuilder(
          builder: (context, c) {
            return Semantics(
              button: true,
              label: '${u.name}, ${u.displayTitle}, $tenureText, $scoreText. Opens their KPI page.',
              excludeSemantics: true,
              onTap: _open,
              child: FocusableActionDetector(
                mouseCursor: SystemMouseCursors.click,
                actions: {
                  ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
                    _open();
                    return null;
                  }),
                },
                onFocusChange: (f) {
                  if (f && mounted) Scrollable.ensureVisible(context, duration: reduce ? Duration.zero : const Duration(milliseconds: 200), alignment: 0.1);
                },
                onShowFocusHighlight: (f) => setState(() => _focused = f),
                child: MouseRegion(
                  onEnter: (_) => setState(() => _hovered = true),
                  onExit: (_) => setState(() {
                    _hovered = false;
                    _tilt = Offset.zero;
                  }),
                  onHover: (e) => setState(() {
                    _tilt = Offset(
                      (e.localPosition.dx / c.maxWidth * 2 - 1).clamp(-1.0, 1.0),
                      (e.localPosition.dy / c.maxHeight * 2 - 1).clamp(-1.0, 1.0),
                    );
                  }),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _open,
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(end: lifted ? 1.0 : 0.0),
                      duration: reduce ? Duration.zero : const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      builder: (context, h, _) => TweenAnimationBuilder<Offset>(
                        tween: Tween<Offset>(end: reduce ? Offset.zero : _tilt),
                        duration: const Duration(milliseconds: 90),
                        builder: (context, tilt, _) => Transform(
                          alignment: Alignment.center,
                          // No lift/tilt with reduced motion; the border and shadow still show hover and focus.
                          transform: _matrix(reduce ? 0 : h, tilt),
                          child: _frame(
                            h,
                            Stack(
                              fit: StackFit.expand,
                              children: [
                                ColoredBox(color: Colors.white, child: _content(context)),
                                // Glare that follows the cursor
                                if (!reduce)
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          gradient: RadialGradient(
                                            center: Alignment(tilt.dx, tilt.dy),
                                            radius: 0.85,
                                            colors: [
                                              Colors.white.withValues(alpha: 0.22 * h),
                                              Colors.white.withValues(alpha: 0),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
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
          },
        ),
      ),
    );

    // Staggered slide/fade-in the first time a card is built (skipped with reduced motion)
    final animateIn = widget.animate && !reduce;
    final entering = TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: animateIn ? 0.0 : 1.0, end: 1.0),
      duration: Duration(milliseconds: 500 + math.min(widget.index, 8) * 90),
      curve: Curves.easeOutCubic,
      child: card,
      builder: (context, t, child) {
        if (t >= 1) return child!;
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.translate(offset: Offset(50 * (1 - t), 0), child: child),
        );
      },
    );

    // On tall windows cap the card height instead of stretching the gaps between its sections.
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 660), child: entering),
    );
  }

  Widget _content(BuildContext context) {
    final score = widget.user.integrityScore;
    final scoreColor = _scoreColor(score);
    final rank = widget.rank;
    final trophy = _trophyColor;
    final isFirst = rank == 1;
    final milestone = _milestone(widget.user.yearsWorked);
    final reduce = _reduceMotion(context);

    double? delta;
    if (score != null && widget.teamAvg != null) delta = score - widget.teamAvg!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // HEADER PHOTO
        Expanded(
          flex: 4,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(color: _faint),
              AnimatedScale(
                scale: _hovered && !reduce ? 1.06 : 1.0,
                duration: reduce ? Duration.zero : const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                child: Image.network(
                  widget.user.avatarUrl,
                  fit: BoxFit.cover,
                  alignment: const Alignment(0.0, -0.4), // Focal alignment shifted down for face visibility
                  frameBuilder: (context, child, frame, wasSync) {
                    if (wasSync) return child;
                    return AnimatedOpacity(
                      opacity: frame == null ? 0 : 1,
                      duration: const Duration(milliseconds: 300),
                      child: child,
                    );
                  },
                  errorBuilder: (context, error, stackTrace) => const Center(
                    child: Icon(Icons.person, size: 64, color: Color(0xFFCBD5E1)),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 48,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black.withValues(alpha: 0.22), Colors.transparent],
                    ),
                  ),
                ),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height: 70,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black.withValues(alpha: 0.35), Colors.transparent],
                    ),
                  ),
                ),
              ),
              if (rank != null)
                Positioned(
                  top: 16,
                  right: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: isFirst ? const Color(0xFFFEF3C7) : Colors.white.withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 4, offset: const Offset(0, 2)),
                      ],
                    ),
                    child: Text(
                      'Rank #$rank',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: isFirst ? const Color(0xFFD97706) : const Color(0xFF475569),
                      ),
                    ),
                  ),
                ),
              if (trophy != null)
                Positioned(
                  top: 14,
                  left: 16,
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.95), shape: BoxShape.circle),
                    child: Icon(Icons.emoji_events_rounded, color: trophy, size: 22),
                  ),
                ),
              if (milestone != null)
                Positioned(
                  bottom: 12,
                  left: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.workspace_premium_rounded, size: 15, color: Color(0xFFFDE68A)),
                        const SizedBox(width: 5),
                        Text(
                          milestone,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),

        // INFO & METRICS
        Expanded(
          flex: 5,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 18),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  children: [
                    Text(
                      widget.user.name,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1A1C1E)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                      decoration: BoxDecoration(
                        color: _roleColor(widget.user.jobTitle).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        widget.user.displayTitle,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: _roleColor(widget.user.jobTitle)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const Divider(color: _faint, height: 1),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 18),
                  decoration: BoxDecoration(color: const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(12)),
                  child: Column(
                    children: [
                      const Text(
                        'COMPANY TENURE',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _muted, letterSpacing: 0.6),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _fmtTenure(widget.user.yearsWorked),
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                      ),
                    ],
                  ),
                ),

                // Animated score ring + count-up + delta vs team average
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: widget.animate && !reduce ? 0.0 : 1.0, end: 1.0),
                  duration: const Duration(milliseconds: 1100),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, _) {
                    return Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                      decoration: BoxDecoration(
                        color: scoreColor.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: scoreColor.withValues(alpha: 0.25)),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 58,
                            height: 58,
                            child: CustomPaint(
                              painter: _RingPainter(
                                progress: score == null ? 0 : (score / 100).clamp(0.0, 1.0) * t,
                                color: scoreColor,
                              ),
                              child: Center(child: Icon(Icons.verified_rounded, size: 20, color: scoreColor)),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text(
                                  'INTEGRITY SCORE',
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _slate, letterSpacing: 0.8),
                                ),
                                Text(
                                  score == null ? '—' : '${_fmtNum(score * t)}%',
                                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: scoreColor, height: 1.1),
                                ),
                                if (delta != null)
                                  Text(
                                    delta.abs() < 0.05
                                        ? 'At team average'
                                        : '${delta >= 0 ? '▲' : '▼'} ${delta.abs().toStringAsFixed(1)} vs team avg',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w700,
                                      color: delta.abs() < 0.05
                                          ? _slate
                                          : (delta >= 0 ? const Color(0xFF059669) : const Color(0xFFB45309)),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}