import 'package:flutter/material.dart';

import 'config/auth_session.dart';

const Color _brandRed = Color(0xFFCC0007);
const Color _ink = Color(0xFF181B1F);
const Color _slate = Color(0xFF5B6572);
const Color _line = Color(0xFFE4E7EC);

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _pin = TextEditingController();
  final _pinFocus = FocusNode();

  bool _busy = false;
  bool _showPin = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _pin.dispose();
    _pinFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
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
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Container(
              padding: const EdgeInsets.fromLTRB(32, 32, 32, 28),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _line),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 24, offset: const Offset(0, 8)),
                ],
              ),
              child: AutofillGroup(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: _brandRed, borderRadius: BorderRadius.circular(12)),
                          child: const Icon(Icons.garage_rounded, size: 24, color: Colors.white),
                        ),
                        const SizedBox(width: 12),
                        const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('IOHD',
                                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _ink, height: 1.1)),
                            Text('Operations Hub', style: TextStyle(fontSize: 12.5, color: _slate)),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),
                    const Text('Sign in', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: _ink)),
                    const SizedBox(height: 4),
                    const Text('Use your username and PIN.', style: TextStyle(fontSize: 13.5, color: _slate)),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _username,
                      autofocus: true,
                      enabled: !_busy,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.username],
                      onSubmitted: (_) => _pinFocus.requestFocus(),
                      decoration: const InputDecoration(
                        labelText: 'Username',
                        prefixIcon: Icon(Icons.person_outline_rounded),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _pin,
                      focusNode: _pinFocus,
                      enabled: !_busy,
                      obscureText: !_showPin,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'PIN',
                        prefixIcon: const Icon(Icons.lock_outline_rounded),
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          tooltip: _showPin ? 'Hide PIN' : 'Show PIN',
                          icon: Icon(_showPin ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                          onPressed: () => setState(() => _showPin = !_showPin),
                        ),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEF2F2),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFFECACA)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.error_outline_rounded, size: 18, color: Color(0xFFB91C1C)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(_error!,
                                  style: const TextStyle(fontSize: 13, color: Color(0xFFB91C1C), height: 1.3)),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: _brandRed,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                            )
                          : const Text('Sign in', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
