import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'theme/app_theme.dart';
import 'widgets/app_dialog.dart';
import 'widgets/app_ribbon.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';

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
  if (res.statusCode != 200) throw Exception("Couldn't load your details (server error ${res.statusCode}).");
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

/// The page's content column, shared by the identity header and the sections so their left edges line up.
const double _kMaxWidth = 1040;

/// The signed-in person's own page, opened from the account menu in the top bar: the standard ribbon (Refresh,
/// Sign out), a compact identity header with the integrity score, then Account, Sign-in and security (Change PIN)
/// and My badges as flat, hairline-ruled sections.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _activity = RibbonActivity();
  _MyDetails? _details;
  bool _loading = true;
  bool _loadedOnce = false;
  String? _error;
  String _loadedFor = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _activity.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final name = AuthSession.instance.name;
    _loadedFor = name;
    setState(() {
      _loading = true;
      _error = null;
    });
    // The ribbon's refresh light runs only when a reload keeps the old details on screen, not on the first load.
    _activity.setRefreshing(_loadedOnce);
    try {
      final d = name.isEmpty ? null : await _loadMyDetails(name);
      if (!mounted || _loadedFor != name) return;
      setState(() {
        _details = d;
        _loading = false;
        _loadedOnce = true;
      });
      _activity
        ..setRefreshing(false)
        ..landed();
    } catch (e) {
      if (!mounted || _loadedFor != name) return;
      setState(() {
        _loading = false;
        _loadedOnce = true;
        _error = _friendlyError(e);
      });
      _activity.setRefreshing(false);
    }
  }

  /// Plain words for a failed load; never the raw exception (which can carry the URL).
  static String _friendlyError(Object e) {
    if (e is TimeoutException) return "Couldn't load your details: the server took too long to answer.";
    if (e is http.ClientException) return "Couldn't load your details: the server can't be reached. Check your connection.";
    if (e is FormatException) return "Couldn't load your details: the server sent something unexpected.";
    if (e is Exception) return e.toString().replaceFirst('Exception: ', '');
    return "Couldn't load your profile.";
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
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PageBanner(
                title: 'My Profile',
                icon: Icons.person_rounded,
                activity: _activity,
                actions: [
                  PageBanner.refresh(onPressed: _loading ? null : _load),
                  // Below 360 px the labelled button would squeeze the title, so it becomes an icon with a tooltip.
                  if (MediaQuery.sizeOf(context).width < 360)
                    IconButton(
                      tooltip: 'Sign out',
                      onPressed: session.logout,
                      icon: const Icon(Icons.logout_rounded, size: 20),
                      color: Colors.white,
                      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
                      padding: EdgeInsets.zero,
                    )
                  else
                    PageBanner.button(icon: Icons.logout_rounded, label: 'Sign out', onPressed: session.logout),
                ],
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, c) => Scrollbar(
                    child: SingleChildScrollView(child: _content(session, c.maxWidth)),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _content(AuthSession session, double width) {
    final narrow = width < 600;
    final side = narrow ? 16.0 : 32.0;
    final inner = math.min(width, _kMaxWidth) - side * 2;
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
    final username = d != null && d.username.isNotEmpty ? d.username : '—';

    final account = _Section(
      title: 'Account',
      children: [
        _InfoRow(Icons.person_outline_rounded, 'Name', session.name.isEmpty ? '—' : session.name),
        _InfoRow(Icons.work_outline_rounded, 'Role', title.isEmpty ? '—' : title),
        _InfoRow(Icons.alternate_email_rounded, 'Username', _loading ? 'Loading…' : username, quiet: _loading),
        _InfoRow(
          session.isAdmin ? Icons.admin_panel_settings_outlined : Icons.shield_outlined,
          'Access',
          session.isAdmin ? 'Administrator: every page and action' : 'Standard: the pages an admin switched on',
        ),
      ],
    );
    final security = _Section(
      title: 'Sign-in and security',
      children: [
        _InfoRow(Icons.schedule_rounded, 'Signed in until', expires == null ? '—' : _when(expires),
            caption: expires == null ? null : 'On this device'),
        _InfoRow(Icons.password_rounded, 'PIN', '4 digits',
            caption: 'Also used in the tech app',
            trailing: _QuietButton(icon: Icons.lock_reset_rounded, label: 'Change PIN', onPressed: _changePin)),
      ],
    );

    final body = Padding(
      padding: EdgeInsets.fromLTRB(side, narrow ? 20 : 28, side, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            _ErrorBar(message: _error!, narrow: narrow, onRetry: _loading ? null : _load),
            const SizedBox(height: 24),
          ],
          if (inner >= 760)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _Rise(delayMs: 80, child: account)),
                const SizedBox(width: 40),
                Expanded(child: _Rise(delayMs: 140, child: security)),
              ],
            )
          else ...[
            _Rise(delayMs: 80, child: account),
            const SizedBox(height: 28),
            _Rise(delayMs: 140, child: security),
          ],
          SizedBox(height: narrow ? 28 : 36),
          _Badges(badges: session.badges, years: fullYears),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _IdentityHeader(
          name: session.name,
          title: title,
          tenure: tenure,
          isAdmin: session.isAdmin,
          photoUrl: d?.photoUrl,
          score: d?.integrityScore,
          scoreLoading: _loading,
          scoreFailed: _error != null && d == null,
          narrow: narrow,
          side: side,
        ),
        Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: _kMaxWidth), child: body)),
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

/// Fades a block in and lifts it a few pixels, [delayMs] after the page opens, so the page settles top to bottom.
/// Runs once; nothing moves when the system asks for less motion.
class _Rise extends StatelessWidget {
  final int delayMs;
  final Widget child;
  const _Rise({required this.delayMs, required this.child});

  static const _runMs = 380;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final total = delayMs + _runMs;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      builder: (context, t, child) {
        final p = Curves.easeOutCubic.transform(((t * total - delayMs) / _runMs).clamp(0.0, 1.0));
        return Opacity(opacity: p, child: Transform.translate(offset: Offset(0, 8 * (1 - p)), child: child));
      },
      child: child,
    );
  }
}

/// Who is signed in, on a quiet band under the ribbon: photo, name, role, tenure and admin tag, with the integrity
/// score to the right (under it on a phone-width window).
class _IdentityHeader extends StatelessWidget {
  final String name;
  final String title;
  final String? tenure;
  final bool isAdmin;
  final String? photoUrl;
  final double? score;
  final bool scoreLoading;
  final bool scoreFailed;
  final bool narrow;
  final double side;
  const _IdentityHeader({
    required this.name,
    required this.title,
    required this.tenure,
    required this.isAdmin,
    required this.photoUrl,
    required this.score,
    required this.scoreLoading,
    required this.scoreFailed,
    required this.narrow,
    required this.side,
  });

  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    return (parts.length == 1 ? parts.first[0] : parts.first[0] + parts.last[0]).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final avatar = _Avatar(initials: _initials, photoUrl: photoUrl, size: narrow ? 56 : 72);
    final hasMeta = tenure != null || isAdmin;
    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          header: true,
          child: Text(
            name.isEmpty ? 'My profile' : name,
            maxLines: narrow ? 2 : 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: narrow ? 20 : 24, fontWeight: FontWeight.w800, color: DashUi.ink, letterSpacing: -0.5, height: 1.2),
          ),
        ),
        if (title.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: narrow ? 14 : 15, fontWeight: FontWeight.w500, color: DashUi.slate, height: 1.35)),
        ],
        if (hasMeta) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (tenure != null) _Meta(Icons.event_available_outlined, tenure!),
              if (isAdmin) const _AdminTag(),
            ],
          ),
        ],
      ],
    );
    final scoreBlock = _ScoreBlock(score: score, loading: scoreLoading, failed: scoreFailed);

    final content = narrow
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [avatar, const SizedBox(width: 14), Expanded(child: identity)]),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.only(top: 14),
                decoration: const BoxDecoration(border: Border(top: BorderSide(color: DashUi.line))),
                alignment: Alignment.centerLeft,
                child: scoreBlock,
              ),
            ],
          )
        : Row(
            children: [
              avatar,
              const SizedBox(width: 20),
              Expanded(child: identity),
              const SizedBox(width: 24),
              Container(width: 1, height: 56, color: DashUi.line),
              const SizedBox(width: 24),
              scoreBlock,
            ],
          );

    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.subtleFillLight,
        border: Border(bottom: BorderSide(color: DashUi.line)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _kMaxWidth),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: side, vertical: narrow ? 18 : 24),
            child: _Rise(delayMs: 0, child: content),
          ),
        ),
      ),
    );
  }
}

/// The photo in a white ring with a hairline edge; initials on navy when there is no photo or it won't load.
class _Avatar extends StatelessWidget {
  final String initials;
  final String? photoUrl;
  final double size;
  const _Avatar({required this.initials, required this.photoUrl, required this.size});

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      color: DashUi.ink,
      child: Text(initials,
          style: TextStyle(fontSize: size * 0.36, fontWeight: FontWeight.w700, color: Colors.white, letterSpacing: 0.5)),
    );
    final url = photoUrl;
    return ExcludeSemantics(
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: DashUi.line),
        ),
        child: ClipOval(
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
        ),
      ),
    );
  }
}

/// A small icon and a fact, on the identity header.
class _Meta extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Meta(this.icon, this.text);

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 16, color: DashUi.subtle),
      const SizedBox(width: 6),
      Flexible(child: Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.slate))),
    ]);
  }
}

class _AdminTag extends StatelessWidget {
  const _AdminTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 3, 9, 3),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: DashUi.line),
      ),
      child: const Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.verified_user_outlined, size: 14, color: DashUi.ink),
        SizedBox(width: 5),
        Text('Administrator', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: DashUi.ink)),
      ]),
    );
  }
}

/// Where a score sits: its word and colours, with the same 90 and 75 cut-offs as the KPI profile cards. [ring] draws
/// the ring; [text] is the AA-safe shade for the word.
({String word, Color ring, Color text}) _scoreTier(double score) {
  if (score >= 90) return (word: 'Excellent', ring: DashUi.emerald, text: DashUi.emeraldText);
  if (score >= 75) return (word: 'Solid', ring: DashUi.amber, text: DashUi.amberText);
  return (word: 'Needs attention', ring: DashUi.red, text: DashUi.redText);
}

/// The integrity score: a small ring, its label, the percent and the tier word. The ring sweeps up and the number
/// counts up when the score arrives; both jump to the end when the system asks for less motion.
class _ScoreBlock extends StatelessWidget {
  final double? score;
  final bool loading;
  final bool failed; // the users list didn't load, so the score is unknown rather than missing
  const _ScoreBlock({required this.score, required this.loading, required this.failed});

  static const _scale = 'Scored out of 100: 90 and up is Excellent, 75 to 89 is Solid, under 75 needs attention.';

  @override
  Widget build(BuildContext context) {
    final value = score;
    final tier = value == null ? null : _scoreTier(value);
    final ring = tier?.ring ?? DashUi.muted;
    final still = MediaQuery.disableAnimationsOf(context);

    Widget block(double t) => Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 44,
            height: 44,
            child: CustomPaint(
              painter: _RingPainter(progress: value == null ? 0 : value / 100 * t, color: ring),
              child: Center(child: Icon(Icons.verified_rounded, size: 18, color: ring)),
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Integrity score', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: DashUi.slate)),
              const SizedBox(height: 1),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Text(
                  value == null ? (loading ? '…' : '—') : '${(value * t).round()}%',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: DashUi.ink,
                    letterSpacing: -0.5,
                    height: 1.15,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                if (tier != null || !loading) ...[
                  const SizedBox(width: 8),
                  // The word arrives as the count lands, so "53% Excellent" never shows on the way up.
                  Opacity(
                    opacity: value == null ? 1 : ((t - 0.55) / 0.45).clamp(0.0, 1.0),
                    child: _TierTag(tier?.word ?? (failed ? 'Unavailable' : 'Not scored yet'),
                        fg: tier?.text ?? DashUi.subtle, tint: tier?.ring ?? DashUi.muted),
                  ),
                ],
              ]),
            ],
          ),
        ]);

    return Tooltip(
      message: value == null && loading
          ? 'Loading your score'
          : (value == null && failed ? "Couldn't load your score. Try again." : _scale),
      child: Semantics(
        container: true,
        label: value == null
            ? (failed ? 'Integrity score: not available' : 'Integrity score: not scored yet')
            : 'Integrity score: ${value.round()} percent, ${tier!.word}',
        child: ExcludeSemantics(
          child: still
              ? block(1)
              : TweenAnimationBuilder<double>(
                  key: ValueKey(value), // a score arriving after the page loads sweeps up again
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 1200),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, _) => block(t),
                ),
        ),
      ),
    );
  }
}

class _TierTag extends StatelessWidget {
  final String text;
  final Color fg;
  final Color tint;
  const _TierTag(this.text, {required this.fg, required this.tint});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: tint.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
      child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress; // 0..1
  final Color color;
  const _RingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 4.0;
    final arc = (Offset.zero & size).deflate(stroke / 2);
    canvas.drawArc(
      arc,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = color.withValues(alpha: 0.18),
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

/// A section heading with an optional note on the right, then its rows under a hairline.
class _Section extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final bool ruled;
  final List<Widget> children;
  const _Section({required this.title, required this.children, this.trailing, this.ruled = true});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(title,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: DashUi.ink, letterSpacing: -0.2)),
              ),
            ),
            ?trailing,
          ]),
        ),
        if (ruled) const Divider(height: 1, thickness: 1, color: DashUi.line),
        ...children,
      ],
    );
  }
}

/// One fact: an 18px icon, its label, the value (with an optional quieter [caption] under it) and an optional
/// action at the end. Label and value stack when the column is narrow.
class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String? caption;
  final Widget? trailing;
  final bool quiet; // the value is a placeholder ("Loading…")
  const _InfoRow(this.icon, this.label, this.value, {this.caption, this.trailing, this.quiet = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: DashUi.line))),
      child: LayoutBuilder(
        builder: (context, c) {
          // The label column grows with the text size so "Signed in until" never runs into its value.
          final labelWidth = MediaQuery.textScalerOf(context).scale(128).clamp(128.0, 200.0);
          final stack = c.maxWidth < labelWidth + 292;
          final labelW = Text(label,
              style: TextStyle(fontSize: stack ? 12.5 : 13.5, fontWeight: FontWeight.w600, color: DashUi.slate, height: 1.3));
          final valueW = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(value,
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w500, color: quiet ? DashUi.subtle : DashUi.ink, height: 1.35)),
              if (caption != null)
                Text(caption!, style: const TextStyle(fontSize: 12.5, color: DashUi.subtle, height: 1.3)),
            ],
          );
          return Row(
            children: [
              Icon(icon, size: 18, color: DashUi.subtle),
              const SizedBox(width: 12),
              if (stack)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [labelW, const SizedBox(height: 2), valueW],
                  ),
                )
              else ...[
                SizedBox(width: labelWidth, child: labelW),
                Expanded(child: valueW),
              ],
              if (trailing != null) ...[const SizedBox(width: 12), trailing!],
            ],
          );
        },
      ),
    );
  }
}

/// A compact outlined button for an action that belongs to a row (Change PIN, Try again), so the row stays one line
/// tall. The text style sits on the label so it keeps the app's font.
class _QuietButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  const _QuietButton({required this.icon, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 17),
      label: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
      style: OutlinedButton.styleFrom(
        foregroundColor: DashUi.ink,
        backgroundColor: Colors.white,
        side: const BorderSide(color: DashUi.line),
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}

/// A failed load: the reason, with Try again beside it (under it on a phone-width window).
class _ErrorBar extends StatelessWidget {
  final String message;
  final bool narrow;
  final VoidCallback? onRetry;
  const _ErrorBar({required this.message, required this.narrow, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final notice = AppNotice(message, kind: AppNoticeKind.error);
    final retry = _QuietButton(icon: Icons.refresh_rounded, label: 'Try again', onPressed: onRetry);
    if (narrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [notice, const SizedBox(height: 8), retry],
      );
    }
    return Row(children: [Expanded(child: notice), const SizedBox(width: 12), retry]);
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

/// "My badges": the years-with-IOHD badge, then the five recognition badges (earned ones in their colour, the rest
/// locked) in a compact grid. [badges] is null when this sign-in predates badges.
class _Badges extends StatelessWidget {
  final Set<String>? badges;
  final int? years;
  const _Badges({required this.badges, required this.years});

  @override
  Widget build(BuildContext context) {
    final earned = badges == null ? 0 : _badgeDefs.where((b) => badges!.contains(b.key)).length;
    final tiles = <Widget>[
      if (years != null && years! >= 1)
        _BadgeTile(
          label: '$years ${years == 1 ? 'Year' : 'Years'}',
          caption: 'With IOHD',
          meaning: '$years ${years == 1 ? 'year' : 'years'} with IOHD.',
          icon: Icons.military_tech_rounded,
          from: const Color(0xFFF87171),
          to: const Color(0xFFB91C1C),
          earned: true,
          number: '$years',
        ),
      for (final b in _badgeDefs)
        _BadgeTile(
          label: b.label,
          caption: badges == null || badges!.contains(b.key) ? b.meaning : 'Not earned yet',
          meaning: b.meaning,
          icon: b.icon,
          from: b.from,
          to: b.to,
          earned: badges?.contains(b.key) ?? false,
        ),
    ];
    return _Section(
      title: 'My badges',
      ruled: false,
      trailing: badges == null ? null : _EarnedMeter(earned: earned, total: _badgeDefs.length),
      children: [
        if (badges == null)
          const _Rise(
            delayMs: 200,
            child: Padding(
              padding: EdgeInsets.only(bottom: 14),
              child: AppNotice('Sign out and back in once to load your badges.'),
            ),
          )
        else if (earned == 0)
          const _Rise(
            delayMs: 200,
            child: Padding(
              padding: EdgeInsets.only(bottom: 14),
              child: Text('No badges yet. An admin awards them for great KPIs, and they show up here.',
                  style: TextStyle(fontSize: 14, color: DashUi.slate)),
            ),
          ),
        const SizedBox(height: 4),
        LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth >= 840 ? 3 : (c.maxWidth >= 520 ? 2 : 1);
            const gap = 24.0;
            final w = ((c.maxWidth - gap * (cols - 1)) / cols).floorToDouble();
            return Wrap(
              spacing: gap,
              runSpacing: 14,
              children: [
                for (var i = 0; i < tiles.length; i++)
                  SizedBox(width: w, child: _Rise(delayMs: 220 + i * 45, child: tiles[i])),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// "2 of 5 earned" with a five-step meter beside it.
class _EarnedMeter extends StatelessWidget {
  final int earned;
  final int total;
  const _EarnedMeter({required this.earned, required this.total});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      ExcludeSemantics(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < total; i++)
            Container(
              width: 14,
              height: 4,
              margin: EdgeInsets.only(left: i == 0 ? 0 : 3),
              decoration: BoxDecoration(color: i < earned ? DashUi.ink : DashUi.line, borderRadius: BorderRadius.circular(2)),
            ),
        ]),
      ),
      const SizedBox(width: 10),
      Text('$earned of $total earned', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.slate)),
    ]);
  }
}

/// One badge: a 40px disc (its colour, softly tinted, when earned; a lock when not), the name and one line about it.
/// Hovering lifts the disc a touch and the tooltip says what the badge is for.
class _BadgeTile extends StatefulWidget {
  final String label;
  final String caption;
  final String meaning;
  final IconData icon;
  final Color from;
  final Color to;
  final bool earned;
  final String? number; // shown instead of the icon (the years badge)
  const _BadgeTile({
    required this.label,
    required this.caption,
    required this.meaning,
    required this.icon,
    required this.from,
    required this.to,
    required this.earned,
    this.number,
  });

  @override
  State<_BadgeTile> createState() => _BadgeTileState();
}

class _BadgeTileState extends State<_BadgeTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final still = MediaQuery.disableAnimationsOf(context);
    final disc = Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: w.earned ? w.from.withValues(alpha: 0.18) : DashUi.faint,
        border: Border.all(color: w.earned ? w.from.withValues(alpha: 0.45) : DashUi.line),
      ),
      child: w.number != null
          ? Text(w.number!, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: w.to, height: 1))
          : Icon(w.earned ? w.icon : Icons.lock_outline_rounded, size: w.earned ? 20 : 17, color: w.earned ? w.to : DashUi.muted),
    );
    return Semantics(
      label: '${w.label}, ${w.earned ? 'earned' : 'not earned yet'}. ${w.meaning}',
      child: ExcludeSemantics(
        child: Tooltip(
          message: w.earned ? w.meaning : 'Not earned yet. ${w.meaning}',
          child: MouseRegion(
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: Row(children: [
              AnimatedScale(
                scale: _hover && !still ? 1.08 : 1,
                duration: still ? Duration.zero : const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                child: disc,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(w.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w700, color: w.earned ? DashUi.ink : DashUi.subtle, height: 1.3)),
                    const SizedBox(height: 1),
                    Text(w.caption,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, color: DashUi.subtle, height: 1.3)),
                  ],
                ),
              ),
            ]),
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
