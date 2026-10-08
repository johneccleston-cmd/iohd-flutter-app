import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'config/auth_session.dart';
import 'theme/app_theme.dart';
import 'widgets/dashboard_kit.dart';

// ---------------------------------------------------------------------------
// Sign-in screen (office staff only; the server rejects non-admin accounts).
//
// Wide windows get a two-panel layout: a dark brand panel on the left with a slow "garage door" slat motif, and
// the sign-in form on the right. Narrow windows show only the form, with the logo above it.
// ---------------------------------------------------------------------------

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with TickerProviderStateMixin {
  final _username = TextEditingController();
  final _pin = TextEditingController();
  final _pinFocus = FocusNode();

  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..forward();
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 18),
  )..repeat();

  bool _busy = false;
  bool _showPin = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _pin.dispose();
    _pinFocus.dispose();
    _enter.dispose();
    _ambient.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (_username.text.trim().isEmpty || _pin.text.isEmpty) {
      setState(() => _error = 'Enter your username and PIN.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AuthSession.instance.login(_username.text, _pin.text);
      // The router sees the new session and moves on to the app.
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
      _pin.clear();
      _pinFocus.requestFocus();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduce) {
      _ambient.stop();
      _enter.value = 1;
    }
    return Scaffold(
      backgroundColor: AppTheme.bgColor,
      body: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 960;
          final form = _formPanel(showLogo: !wide);
          if (!wide) return form;
          return Row(
            children: [
              Expanded(flex: 11, child: _BrandPanel(ambient: _ambient)),
              Expanded(flex: 9, child: form),
            ],
          );
        },
      ),
    );
  }

  Widget _formPanel({required bool showLogo}) {
    final curve = CurvedAnimation(parent: _enter, curve: Curves.easeOutCubic);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: AnimatedBuilder(
            animation: curve,
            builder: (context, child) => Opacity(
              opacity: curve.value,
              child: Transform.translate(
                offset: Offset(0, 18 * (1 - curve.value)),
                child: child,
              ),
            ),
            child: AutofillGroup(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (showLogo) ...[
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: _Logo(dark: false),
                    ),
                    const SizedBox(height: 36),
                  ],
                  const Text(
                    'Welcome back',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.primaryText,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Sign in with your username and PIN.',
                    style: TextStyle(
                      fontSize: 14.5,
                      color: AppTheme.secondaryText,
                    ),
                  ),
                  const SizedBox(height: 28),
                  _label('Username'),
                  TextField(
                    controller: _username,
                    autofocus: true,
                    enabled: !_busy,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.username],
                    onSubmitted: (_) => _pinFocus.requestFocus(),
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                    decoration: _input(
                      hint: 'e.g. jsmith',
                      icon: Icons.person_outline_rounded,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _label('PIN'),
                  TextField(
                    controller: _pin,
                    focusNode: _pinFocus,
                    enabled: !_busy,
                    obscureText: !_showPin,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => _submit(),
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                    decoration: _input(
                      hint: '••••',
                      icon: Icons.lock_outline_rounded,
                      suffix: IconButton(
                        tooltip: _showPin ? 'Hide PIN' : 'Show PIN',
                        icon: Icon(
                          _showPin
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          size: 20,
                        ),
                        color: AppTheme.sectionLabel,
                        onPressed: () => setState(() => _showPin = !_showPin),
                      ),
                    ),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    child: _error == null
                        ? const SizedBox(width: double.infinity)
                        : Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFEF2F2),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: const Color(0xFFFECACA),
                                ),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(
                                    Icons.error_outline_rounded,
                                    size: 18,
                                    color: DashUi.red,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _error!,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: DashUi.red,
                                        height: 1.35,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 50,
                    child: FilledButton(
                      onPressed: _busy ? null : _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.brandRed,
                        disabledBackgroundColor: AppTheme.brandRed.withValues(
                          alpha: 0.7,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  'Sign in',
                                  style: TextStyle(
                                    fontSize: 15.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                SizedBox(width: 8),
                                Icon(Icons.arrow_forward_rounded, size: 19),
                              ],
                            ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  const Row(
                    children: [
                      Icon(
                        Icons.shield_outlined,
                        size: 15,
                        color: AppTheme.sectionLabel,
                      ),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Office accounts only. Ask an admin if you need access.',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: AppTheme.sectionLabel,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: AppTheme.primaryText,
      ),
    ),
  );

  InputDecoration _input({
    required String hint,
    required IconData icon,
    Widget? suffix,
  }) {
    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: c, width: w),
    );
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: AppTheme.sectionLabel),
      prefixIcon: Icon(icon, size: 20, color: AppTheme.sectionLabel),
      suffixIcon: suffix,
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(vertical: 15, horizontal: 14),
      border: border(AppTheme.strokeBorder),
      enabledBorder: border(AppTheme.strokeBorder),
      disabledBorder: border(AppTheme.strokeBorder),
      focusedBorder: border(AppTheme.brandRed, 1.6),
    );
  }
}

class _Logo extends StatelessWidget {
  final bool dark;
  const _Logo({required this.dark});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppTheme.brandRed,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: AppTheme.brandRed.withValues(alpha: 0.22),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: const Icon(
            Icons.garage_rounded,
            size: 24,
            color: Colors.white,
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'IOHD Office',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                height: 1.1,
                color: dark ? Colors.white : AppTheme.primaryText,
              ),
            ),
            Text(
              'Office',
              style: TextStyle(
                fontSize: 12.5,
                color: dark ? const Color(0xFF94A3B8) : AppTheme.secondaryText,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The dark left panel: brand, a short line about what the app is for, and a slow drifting slat pattern that
/// reads as a garage door, with a soft red glow.
class _BrandPanel extends StatelessWidget {
  final Animation<double> ambient;
  const _BrandPanel({required this.ambient});

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [DashUi.ink, Color(0xFF1E293B)],
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedBuilder(
              animation: ambient,
              builder: (context, _) =>
                  CustomPaint(painter: _SlatsPainter(ambient.value)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(56, 48, 56, 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _Logo(dark: true),
                  const Spacer(),
                  const Text(
                    'Run the office\nfrom one place.',
                    style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      height: 1.12,
                      letterSpacing: -1,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Jobs, estimates, the calendar, payroll and live dashboards, all in IOHD Office.',
                    style: TextStyle(
                      fontSize: 15.5,
                      color: Color(0xFFCBD5E1),
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 32),
                  const Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _Chip(
                        icon: Icons.calendar_month_outlined,
                        label: 'Calendar & jobs',
                      ),
                      _Chip(
                        icon: Icons.payments_outlined,
                        label: 'Payroll & commissions',
                      ),
                      _Chip(
                        icon: Icons.insights_outlined,
                        label: 'Live dashboards',
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    '© ${DateTime.now().year} IOHD Office',
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _Chip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: const Color(0xFFFCA5A5)),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFFE2E8F0),
            ),
          ),
        ],
      ),
    );
  }
}

class _SlatsPainter extends CustomPainter {
  final double t; // 0..1, loops
  const _SlatsPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    // Soft red glow that slowly drifts.
    final glow = Offset(
      size.width * (0.75 + 0.08 * math.sin(t * math.pi * 2)),
      size.height * (0.28 + 0.06 * math.cos(t * math.pi * 2)),
    );
    canvas.drawCircle(
      glow,
      size.shortestSide * 0.55,
      Paint()
        ..shader =
            RadialGradient(
              colors: [
                AppTheme.brandRed.withValues(alpha: 0.32),
                AppTheme.brandRed.withValues(alpha: 0),
              ],
            ).createShader(
              Rect.fromCircle(center: glow, radius: size.shortestSide * 0.55),
            ),
    );

    // Horizontal slats, like a sectional door, drifting down slowly and fading toward the bottom.
    const gap = 46.0;
    final offset = t * gap * 4 % gap;
    for (var y = -gap + offset; y < size.height; y += gap) {
      final fade = (1 - (y / size.height)).clamp(0.0, 1.0);
      final line = Paint()
        ..color = Colors.white.withValues(alpha: 0.045 * fade + 0.01)
        ..strokeWidth = 1;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
      canvas.drawLine(
        Offset(0, y + 3),
        Offset(size.width, y + 3),
        line..color = Colors.black.withValues(alpha: 0.12 * fade),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SlatsPainter old) => old.t != t;
}
