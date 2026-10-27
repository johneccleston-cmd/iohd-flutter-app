import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'theme/app_theme.dart';
import 'widgets/app_dialog.dart';
import 'widgets/dashboard_kit.dart';

/// What the users list knows about the signed-in person. The sign-in answer has no photo, username or start date.
class _MyDetails {
  final String username;
  final String jobTitle;
  final String? photoUrl; // null: show initials
  final double? yearsWorked;
  final double? integrityScore; // 0..100, null when the backend sent none
  const _MyDetails({required this.username, required this.jobTitle, this.photoUrl, this.yearsWorked, this.integrityScore});
}

/// GET /users (any signed-in office user), then the row whose name is the signed-in person's.
/// Null when they aren't listed (the owner login is left out of that list on purpose).
Future<_MyDetails?> _loadMyDetails(String name) async {
  final res = await http
      .get(Uri.parse('$kApiBaseUrl/users'), headers: AuthSession.instance.headers())
      .timeout(const Duration(seconds: 20));
  if (res.statusCode == 401) {
    AuthSession.instance.logout(); // sends the app back to the sign-in screen
    throw Exception('Your session expired. Please sign in again.');
  }
  if (res.statusCode != 200) throw Exception('Server error (${res.statusCode})');
  final body = json.decode(res.body);
  final list = body is List ? body : (body is Map && body['users'] is List ? body['users'] as List : const []);
  for (final u in list) {
    if (u is! Map || (u['name'] ?? '').toString().trim().toLowerCase() != name.trim().toLowerCase()) continue;
    final url = (u['avatarUrl'] ?? u['avatar_url'] ?? '').toString().trim();
    final title = (u['displayTitle'] ?? u['jobTitle'] ?? '').toString().trim();
    return _MyDetails(
      username: (u['id'] ?? '').toString().trim(),
      jobTitle: title,
      // The users list invents an initials image for people with no photo; that is not a photo.
      photoUrl: url.isNotEmpty && !url.contains('ui-avatars.com') ? url : null,
      yearsWorked: double.tryParse((u['yearsWorked'] ?? '').toString()),
      integrityScore: double.tryParse((u['integrityScore'] ?? u['integrity_score'] ?? '').toString())?.clamp(0, 100).toDouble(),
    );
  }
  return null;
}

/// The signed-in person's own page, opened from the account menu in the top bar: who they are, how long they stay
/// signed in, the pages they can open, and changing their own PIN.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  _MyDetails? _details;
  bool _loading = true;
  String? _error;
  String _loadedFor = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final name = AuthSession.instance.name;
    _loadedFor = name;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = name.isEmpty ? null : await _loadMyDetails(name);
      if (!mounted || _loadedFor != name) return;
      setState(() {
        _details = d;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || _loadedFor != name) return;
      setState(() {
        _loading = false;
        _error = e is Exception ? e.toString().replaceFirst('Exception: ', '') : "Couldn't load your profile.";
      });
    }
  }

  Future<void> _changePin() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ChangePinDialog(username: _details?.username ?? ''),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Your PIN was changed. Use the new one next time you sign in.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      child: ListenableBuilder(
        listenable: AuthSession.instance,
        builder: (context, _) {
          final session = AuthSession.instance;
          if (session.name != _loadedFor && session.isLoggedIn) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && session.name != _loadedFor) _load();
            });
          }
          return LayoutBuilder(
            builder: (context, c) {
              return Scrollbar(
                child: SingleChildScrollView(child: _content(session, c.maxWidth < 600)),
              );
            },
          );
        },
      ),
    );
  }

  Widget _content(AuthSession session, bool narrow) {
    final d = _details;
    final title = d != null && d.jobTitle.isNotEmpty ? d.jobTitle : session.role;
    final years = d?.yearsWorked;
    final fullYears = years?.floor();
    final tenure = years == null
        ? null
        : years < 1
            ? 'Joined within the last year'
            : '$fullYears ${fullYears == 1 ? 'year' : 'years'} with IOHD';
    final expires = session.expiresAt;

    final account = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('Account', Icons.person_rounded),
        _InfoRow('Name', session.name.isEmpty ? '—' : session.name),
        _InfoRow('Role', title.isEmpty ? '—' : title),
        _InfoRow('Username', _loading ? 'Loading…' : (d != null && d.username.isNotEmpty ? d.username : '—')),
        _InfoRow('Access', session.isAdmin ? 'Administrator: every page and action' : 'Standard: the pages an admin switched on'),
      ],
    );
    final signIn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('Sign-in', Icons.lock_rounded),
        _InfoRow('Signed in until', expires == null ? '—' : _when(expires)),
        _InfoRow(
          'PIN',
          '4 digits, also used in the tech app',
          trailing: AppButton.ink('Change PIN', _changePin, icon: Icons.lock_reset_rounded),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Hero(
          name: session.name,
          title: title,
          tenure: tenure,
          isAdmin: session.isAdmin,
          photoUrl: d?.photoUrl,
          score: d?.integrityScore,
          scoreLoading: _loading,
          narrow: narrow,
          onSignOut: session.logout,
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Padding(
              padding: EdgeInsets.fromLTRB(narrow ? 16 : 32, 28, narrow ? 16 : 32, 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null) ...[
                    AppNotice(_error!, kind: AppNoticeKind.error),
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerLeft, child: AppButton.ghost('Try again', _load)),
                    const SizedBox(height: 16),
                  ],
                  _Badges(badges: session.badges, years: fullYears),
                  const SizedBox(height: 36),
                  narrow
                      ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [account, const SizedBox(height: 28), signIn])
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [Expanded(child: account), const SizedBox(width: 48), Expanded(child: signIn)],
                        ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  static String _when(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    return '${_months[t.month - 1]} ${t.day} at $h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
  }
}

/// The dark band at the top: big photo with a red ring, name, role and tenure chips, and Sign out.
class _Hero extends StatelessWidget {
  final String name;
  final String title;
  final String? tenure;
  final bool isAdmin;
  final String? photoUrl;
  final double? score;
  final bool scoreLoading;
  final bool narrow;
  final VoidCallback onSignOut;
  const _Hero({
    required this.name,
    required this.title,
    required this.tenure,
    required this.isAdmin,
    required this.photoUrl,
    required this.score,
    required this.scoreLoading,
    required this.narrow,
    required this.onSignOut,
  });

  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    return (parts.length == 1 ? parts.first[0] : parts.first[0] + parts.last[0]).toUpperCase();
  }

  Widget _chip(IconData icon, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: const Color(0xFFCBD5E1)),
          const SizedBox(width: 6),
          Flexible(child: Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final size = narrow ? 84.0 : 112.0;
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      color: const Color(0xFF1E293B),
      child: Text(_initials, style: TextStyle(fontSize: size * 0.34, fontWeight: FontWeight.w800, color: Colors.white)),
    );
    final url = photoUrl;
    final photo = ClipOval(
      child: url == null
          ? fallback
          : Image.network(
              url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              alignment: const Alignment(0, -0.4), // keeps the face in frame
              errorBuilder: (context, error, stackTrace) => fallback,
              loadingBuilder: (context, child, progress) => progress == null ? child : fallback,
            ),
    );
    final avatar = Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(colors: [Color(0xFFEF4444), Color(0xFFCC0007)], begin: Alignment.topLeft, end: Alignment.bottomRight),
        boxShadow: [BoxShadow(color: const Color(0xFFCC0007).withValues(alpha: 0.45), blurRadius: 28)],
      ),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: const BoxDecoration(color: DashUi.ink, shape: BoxShape.circle),
        child: photo,
      ),
    );

    final chips = Wrap(spacing: 8, runSpacing: 8, children: [
      if (title.isNotEmpty) _chip(Icons.work_outline_rounded, title),
      if (tenure != null) _chip(Icons.cake_outlined, tenure!),
      if (isAdmin) _chip(Icons.verified_user_outlined, 'Administrator'),
    ]);
    final scorePill = _ScorePill(score: score, loading: scoreLoading);

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(name.isEmpty ? 'My profile' : name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: narrow ? 26 : 34, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: -0.8)),
        const SizedBox(height: 10),
        // The chips, with the integrity score off to their right (under them when the window is narrow).
        if (narrow) ...[
          chips,
          const SizedBox(height: 12),
          scorePill,
        ] else
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Flexible(child: chips),
            const SizedBox(width: 16),
            scorePill,
          ]),
      ],
    );

    final signOut = OutlinedButton.icon(
      onPressed: onSignOut,
      icon: const Icon(Icons.logout_rounded, size: 18),
      label: const Text('Sign out', style: TextStyle(fontWeight: FontWeight.w700)),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );

    final pad = EdgeInsets.fromLTRB(narrow ? 16 : 40, narrow ? 24 : 36, narrow ? 16 : 40, narrow ? 24 : 36);
    return Semantics(
      header: true,
      label: name,
      child: ClipRect(
        child: Container(
          width: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [DashUi.ink, Color(0xFF1E293B)], begin: Alignment.topLeft, end: Alignment.bottomRight),
          ),
          child: Stack(
            children: [
              // Slats and a soft red glow: the same garage-door motif as the sign-in screen.
              const Positioned.fill(child: _MovingSlats()),
              Padding(
                padding: pad,
                child: narrow
                    ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          ExcludeSemantics(child: avatar),
                          const SizedBox(width: 16),
                          Expanded(child: text),
                        ]),
                        const SizedBox(height: 18),
                        signOut,
                      ])
                    : Row(children: [
                        ExcludeSemantics(child: avatar),
                        const SizedBox(width: 28),
                        Expanded(child: text),
                        const SizedBox(width: 16),
                        signOut,
                      ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The sign-in screen's motif: slats drifting down and fading toward the bottom, and a soft red glow that wanders.
/// Still when the system asks for less motion.
class _MovingSlats extends StatefulWidget {
  const _MovingSlats();

  @override
  State<_MovingSlats> createState() => _MovingSlatsState();
}

class _MovingSlatsState extends State<_MovingSlats> with SingleTickerProviderStateMixin {
  late final AnimationController _ambient = AnimationController(vsync: this, duration: const Duration(seconds: 18));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _ambient.stop();
    } else if (!_ambient.isAnimating) {
      _ambient.repeat();
    }
  }

  @override
  void dispose() {
    _ambient.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ambient,
        builder: (context, _) => CustomPaint(painter: _SlatsPainter(_ambient.value)),
      ),
    );
  }
}

class _SlatsPainter extends CustomPainter {
  final double t; // 0..1, loops
  const _SlatsPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final glow = Offset(
      size.width * (0.14 + 0.06 * math.sin(t * math.pi * 2)),
      size.height * (0.5 + 0.18 * math.cos(t * math.pi * 2)),
    );
    final radius = size.height * 1.3;
    canvas.drawCircle(
      glow,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [AppTheme.brandRed.withValues(alpha: 0.32), AppTheme.brandRed.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: glow, radius: radius)),
    );

    const gap = 46.0;
    final offset = t * gap * 4 % gap;
    for (var y = -gap + offset; y < size.height; y += gap) {
      final fade = (1 - (y / size.height)).clamp(0.0, 1.0);
      final line = Paint()
        ..color = Colors.white.withValues(alpha: 0.10 * fade + 0.02)
        ..strokeWidth = 1.5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
      canvas.drawLine(Offset(0, y + 3), Offset(size.width, y + 3), line..color = Colors.black.withValues(alpha: 0.12 * fade));
    }
  }

  @override
  bool shouldRepaint(covariant _SlatsPainter old) => old.t != t;
}

/// Where a score sits: its word and colour, with the same 90 and 75 cut-offs and colours as the KPI profile cards.
({String word, Color from}) _scoreTier(double score) {
  if (score >= 90) return (word: 'Excellent', from: const Color(0xFF34D399));
  if (score >= 75) return (word: 'Solid', from: const Color(0xFFFBBF24));
  return (word: 'Needs attention', from: const Color(0xFFF87171));
}

/// The integrity score, drawn like the KPI profile cards draw it (a tinted pill: small ring, label, bold percent),
/// on the dark hero. The ring sweeps up and the number counts up; both jump to the end when the system asks for
/// less motion.
class _ScorePill extends StatelessWidget {
  final double? score;
  final bool loading;
  const _ScorePill({required this.score, required this.loading});

  @override
  Widget build(BuildContext context) {
    final value = score;
    final tier = value == null ? null : _scoreTier(value);
    final color = tier?.from ?? const Color(0xFF94A3B8);
    final still = MediaQuery.disableAnimationsOf(context);

    Widget pill(double t) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              width: 38,
              height: 38,
              child: CustomPaint(
                painter: _RingPainter(progress: value == null ? 0 : value / 100 * t, color: color),
                child: Center(child: Icon(Icons.verified_rounded, size: 15, color: color)),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Integrity score', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFCBD5E1))),
                Text(
                  value == null ? (loading ? '…' : '—') : '${(value * t).round()}%',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: color, height: 1.15),
                ),
              ],
            ),
          ]),
        );

    return Tooltip(
      message: tier?.word ?? (loading ? 'Loading your score' : 'Not scored yet'),
      child: Semantics(
        container: true,
        label: value == null ? 'Integrity score: not scored yet' : 'Integrity score: ${value.round()} percent, ${tier!.word}',
        child: ExcludeSemantics(
          child: still
              ? pill(1)
              : TweenAnimationBuilder<double>(
                  key: ValueKey(value), // a score arriving after the page loads sweeps up again
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 1400),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, _) => pill(t),
                ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress; // 0..1
  final Color color;
  const _RingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 4.5;
    final arc = (Offset.zero & size).deflate(stroke / 2);
    canvas.drawArc(
      arc,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = color.withValues(alpha: 0.22),
    );
    if (progress <= 0) return;
    canvas.drawArc(
      arc,
      -math.pi / 2,
      math.pi * 2 * progress.clamp(0.0, 1.0),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress || old.color != color;
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final IconData icon;
  const _SectionTitle(this.text, this.icon);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Semantics(
        header: true,
        child: Row(children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(color: const Color(0xFFFCEEEE), borderRadius: BorderRadius.circular(9)),
            child: Icon(icon, size: 17, color: AppTheme.brandRed),
          ),
          const SizedBox(width: 10),
          Text(text, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: DashUi.ink, letterSpacing: -0.3)),
        ]),
      ),
    );
  }
}

/// One label/value line with a rule under it; [trailing] is an action for that line.
class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Widget? trailing;
  const _InfoRow(this.label, this.value, {this.trailing});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: DashUi.line))),
      child: LayoutBuilder(
        builder: (context, c) {
          final stack = c.maxWidth < 420;
          final labelW = Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: DashUi.slate));
          final valueW = Text(value, style: const TextStyle(fontSize: 15, color: DashUi.ink));
          if (stack) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [labelW, const SizedBox(height: 2), valueW, if (trailing != null) ...[const SizedBox(height: 8), trailing!]],
            );
          }
          return Row(
            children: [
              SizedBox(width: 130, child: labelW),
              Expanded(child: valueW),
              if (trailing != null) ...[const SizedBox(width: 12), trailing!],
            ],
          );
        },
      ),
    );
  }
}

/// A recognition badge. Same names, icons and colours as the Team screen, where an admin switches them on.
class _BadgeDef {
  final String key;
  final String label;
  final String meaning;
  final IconData icon;
  final Color from;
  final Color to;
  const _BadgeDef(this.key, this.label, this.meaning, this.icon, this.from, this.to);
}

const List<_BadgeDef> _badgeDefs = [
  _BadgeDef('five_star', '5-Star Reviews', 'Consistently rated 5 stars by customers.', Icons.star_rounded, Color(0xFFFBBF24), Color(0xFFD97706)),
  _BadgeDef('no_recalls', 'Callback-Free', 'No callbacks since go-live.', Icons.verified_rounded, Color(0xFF34D399), Color(0xFF059669)),
  _BadgeDef('top_producer', 'Top Producer', 'Labor per day ahead of the rest of the team.', Icons.trending_up_rounded, Color(0xFF38BDF8), Color(0xFF0369A1)),
  _BadgeDef('zero_strikes', 'Zero Strikes', 'No inventory strikes.', Icons.inventory_2_rounded, Color(0xFF2DD4BF), Color(0xFF0F766E)),
  _BadgeDef('team_favorite', 'Team Favorite', 'Top-rated by teammates.', Icons.groups_rounded, Color(0xFF818CF8), Color(0xFF4F46E5)),
];

/// "My badges": the five recognition badges as medallions (earned ones in colour, the rest locked), plus the
/// years-with-IOHD medallion. [badges] is null when this sign-in predates badges.
class _Badges extends StatelessWidget {
  final Set<String>? badges;
  final int? years;
  const _Badges({required this.badges, required this.years});

  @override
  Widget build(BuildContext context) {
    final earned = badges == null ? 0 : _badgeDefs.where((b) => badges!.contains(b.key)).length;
    final tiles = <Widget>[
      if (years != null && years! >= 1)
        _Medallion(
          label: '$years ${years == 1 ? 'Year' : 'Years'}',
          caption: 'With IOHD',
          icon: Icons.military_tech_rounded,
          from: const Color(0xFFF87171),
          to: const Color(0xFFB91C1C),
          earned: true,
          number: '$years',
        ),
      for (final b in _badgeDefs)
        _Medallion(
          label: b.label,
          caption: badges == null || badges!.contains(b.key) ? b.meaning : 'Not earned yet',
          icon: b.icon,
          from: b.from,
          to: b.to,
          earned: badges?.contains(b.key) ?? false,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          const Expanded(child: _SectionTitle('My badges', Icons.emoji_events_rounded)),
          if (badges != null)
            Text('$earned of ${_badgeDefs.length} earned',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: DashUi.slate)),
        ]),
        const SizedBox(height: 14),
        if (badges == null)
          const Padding(
            padding: EdgeInsets.only(bottom: 14),
            child: AppNotice('Sign out and back in once to load your badges.'),
          )
        else if (earned == 0)
          const Padding(
            padding: EdgeInsets.only(bottom: 14),
            child: Text('No badges yet. An admin awards them for great KPIs, and they show up here.',
                style: TextStyle(fontSize: 15, color: DashUi.slate)),
          ),
        Wrap(
          spacing: 12,
          runSpacing: 20,
          children: [for (var i = 0; i < tiles.length; i++) _PopIn(delay: i, child: tiles[i])],
        ),
      ],
    );
  }
}

/// Fades and springs a medallion in, one after another. Instant when the system asks for less motion.
class _PopIn extends StatelessWidget {
  final int delay;
  final Widget child;
  const _PopIn({required this.delay, required this.child});

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 420 + delay * 90),
      curve: Curves.easeOutBack,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.scale(scale: 0.6 + 0.4 * t, child: child),
      ),
      child: child,
    );
  }
}

class _Medallion extends StatelessWidget {
  final String label;
  final String caption;
  final IconData icon;
  final Color from;
  final Color to;
  final bool earned;
  final String? number; // shown instead of the icon (the years medallion)
  const _Medallion({
    required this.label,
    required this.caption,
    required this.icon,
    required this.from,
    required this.to,
    required this.earned,
    this.number,
  });

  @override
  Widget build(BuildContext context) {
    const size = 84.0;
    final disc = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: earned ? LinearGradient(colors: [from, to], begin: Alignment.topLeft, end: Alignment.bottomRight) : null,
        color: earned ? null : DashUi.faint,
        border: Border.all(color: earned ? Colors.white : DashUi.line, width: 3),
        boxShadow: earned ? [BoxShadow(color: to.withValues(alpha: 0.38), blurRadius: 18, offset: const Offset(0, 7))] : null,
      ),
      child: number != null
          ? Text(number!, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, color: Colors.white))
          : Icon(earned ? icon : Icons.lock_outline_rounded, size: earned ? 40 : 28, color: earned ? Colors.white : DashUi.muted),
    );
    return Semantics(
      label: '$label, ${earned ? 'earned' : 'not earned yet'}. $caption',
      child: ExcludeSemantics(
        child: Tooltip(
          message: caption,
          child: SizedBox(
            width: 132,
            child: Column(
              children: [
                disc,
                const SizedBox(height: 10),
                Text(label,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: earned ? DashUi.ink : DashUi.subtle)),
                const SizedBox(height: 2),
                Text(caption, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: DashUi.slate, height: 1.3)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Change my PIN: current PIN, then the new one twice. [username] is blank for accounts the users list leaves out
/// (the owner login), who type it.
class _ChangePinDialog extends StatefulWidget {
  final String username;
  const _ChangePinDialog({required this.username});

  @override
  State<_ChangePinDialog> createState() => _ChangePinDialogState();
}

class _ChangePinDialogState extends State<_ChangePinDialog> {
  late final _user = TextEditingController(text: widget.username);
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  final _newFocus = FocusNode();
  final _confirmFocus = FocusNode();
  bool _show = false;
  bool _busy = false;
  String? _error;

  bool get _askUser => widget.username.isEmpty;

  @override
  void dispose() {
    _user.dispose();
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    _newFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  bool get _valid =>
      (!_askUser || _user.text.trim().isNotEmpty) &&
      _current.text.isNotEmpty &&
      RegExp(r'^\d{4}$').hasMatch(_new.text) &&
      _new.text == _confirm.text &&
      !_busy;

  String? get _hint {
    if (_new.text.isNotEmpty && _new.text.length < 4) return 'Use exactly 4 digits.';
    if (_confirm.text.isNotEmpty && _new.text.length == 4 && _new.text != _confirm.text) return "The PINs don't match yet.";
    return null;
  }

  Future<void> _save() async {
    if (!_valid) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AuthSession.instance.changePin(_user.text, _current.text, _new.text, temporary: false);
      if (mounted) Navigator.pop(context, true);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  InputDecoration _dec(String hint, {bool toggle = false}) => appFieldDecoration(hint: hint).copyWith(
        counterText: '',
        suffixIcon: toggle
            ? IconButton(
                tooltip: _show ? 'Hide PINs' : 'Show PINs',
                icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 19),
                onPressed: () => setState(() => _show = !_show),
              )
            : null,
      );

  Widget _pinField(String label, TextEditingController c,
      {FocusNode? focus, FocusNode? next, bool autofocus = false, bool toggle = false, bool last = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppFieldLabel(label),
        TextField(
          controller: c,
          focusNode: focus,
          autofocus: autofocus,
          enabled: !_busy,
          obscureText: !_show,
          keyboardType: TextInputType.number,
          maxLength: 8, // an older PIN may be longer than 4; the new one is checked to be exactly 4
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          textInputAction: last ? TextInputAction.done : TextInputAction.next,
          onChanged: (_) => setState(() => _error = null),
          onSubmitted: (_) => last ? _save() : next?.requestFocus(),
          decoration: _dec(label == 'Current PIN' ? 'Your PIN now' : (last ? 'Type it again' : '4 digits'), toggle: toggle),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      title: 'Change PIN',
      subtitle: 'You stay signed in on this device.',
      icon: Icons.lock_reset_rounded,
      width: 440,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_askUser) ...[
            const AppFieldLabel('Username'),
            TextField(
              controller: _user,
              autofocus: true,
              enabled: !_busy,
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() => _error = null),
              decoration: _dec('Your sign-in username'),
            ),
            const SizedBox(height: 14),
          ],
          _pinField('Current PIN', _current, autofocus: !_askUser, next: _newFocus, toggle: true),
          const SizedBox(height: 14),
          _pinField('New PIN', _new, focus: _newFocus, next: _confirmFocus),
          const SizedBox(height: 14),
          _pinField('Confirm new PIN', _confirm, focus: _confirmFocus, last: true),
          if (_hint != null || _error != null) ...[
            const SizedBox(height: 12),
            AppNotice(_error ?? _hint!, kind: _error != null ? AppNoticeKind.error : AppNoticeKind.warning),
          ],
        ],
      ),
      actions: [
        AppButton.ghost('Cancel', _busy ? null : () => Navigator.pop(context)),
        AppButton.ink(_busy ? 'Saving…' : 'Save PIN', _valid ? _save : null, icon: Icons.check_rounded),
      ],
    );
  }
}
