import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api_config.dart';

class AuthException implements Exception {
  final String message;
  const AuthException(this.message);

  @override
  String toString() => message;
}

/// Who is signed in to the desktop app.
///
/// The shared [kAuthToken] ships inside every build, so by itself it only says "this is our app".
/// Signing in with a username and PIN gets a per-user token from the backend (`/login`). It is kept in
/// memory only, so closing the app signs you out, and the backend rejects it after 12 hours.
class AuthSession extends ChangeNotifier {
  AuthSession._();
  static final AuthSession instance = AuthSession._();

  String? _userToken;
  int _expiresAtMs = 0;
  String _name = '';
  String _role = '';

  bool get isLoggedIn => _userToken != null && DateTime.now().millisecondsSinceEpoch < _expiresAtMs;
  String get name => _name;
  String get role => _role;

  /// Headers for every API call. Adds the user token when someone is signed in. If the token has
  /// expired the session ends here, which sends the app back to the sign-in screen.
  Map<String, String> headers({bool json = true}) {
    if (_userToken != null && !isLoggedIn) logout();
    return {
      if (json) 'Content-Type': 'application/json',
      if (kAuthToken.isNotEmpty) 'Authorization': 'Bearer $kAuthToken',
      if (isLoggedIn) 'x-user-token': _userToken!,
    };
  }

  Future<void> login(String username, String pin) async {
    final user = username.trim();
    final secret = pin.trim();
    if (user.isEmpty || secret.isEmpty) {
      throw const AuthException('Enter your username and PIN.');
    }

    late http.Response res;
    try {
      // Generous timeout: Render free instances can take a while to wake up.
      res = await http.get(
        Uri.parse('$kApiBaseUrl/login'),
        headers: {
          if (kAuthToken.isNotEmpty) 'Authorization': 'Bearer $kAuthToken',
          'x-username': user,
          'x-pin': secret,
        },
      ).timeout(const Duration(seconds: 60));
    } catch (_) {
      throw const AuthException("Couldn't reach the server. Check your connection and try again.");
    }

    Map<String, dynamic> body = const {};
    try {
      body = json.decode(res.body) as Map<String, dynamic>;
    } catch (_) {}

    switch (res.statusCode) {
      case 200:
        break;
      case 401:
        throw const AuthException('Invalid username or PIN.');
      case 403:
        throw AuthException(body['error']?.toString() ?? 'This account is deactivated.');
      case 429:
        throw AuthException(body['error']?.toString() ?? 'Too many attempts. Try again in 15 minutes.');
      default:
        throw AuthException('Sign-in failed (server error ${res.statusCode}).');
    }

    // Office staff only: the hub shows company financials, payroll and customer data.
    if (body['is_admin'] != true) {
      throw const AuthException('This app is for office staff. Your account does not have access.');
    }

    final token = body['token']?.toString();
    if (token == null || token.isEmpty) {
      throw const AuthException('Sign-in failed. Please try again.');
    }

    _userToken = token;
    _expiresAtMs = _expiryOf(token);
    _name = body['name']?.toString() ?? user;
    _role = body['role']?.toString() ?? '';
    notifyListeners();
  }

  void logout() {
    if (_userToken == null) return;
    _userToken = null;
    _expiresAtMs = 0;
    _name = '';
    _role = '';
    notifyListeners();
  }

  // The token is `<base64url payload>.<signature>`; the payload carries `exp` in milliseconds.
  static int _expiryOf(String token) {
    try {
      final payload = token.split('.').first;
      final data = json.decode(utf8.decode(base64Url.decode(base64Url.normalize(payload)))) as Map<String, dynamic>;
      return (data['exp'] as num).toInt();
    } catch (_) {
      // Unreadable payload: assume the backend's default 12 hour lifetime.
      return DateTime.now().add(const Duration(hours: 12)).millisecondsSinceEpoch;
    }
  }
}
