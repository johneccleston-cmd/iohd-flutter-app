import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'access.dart';
import 'api_config.dart';

/// Technicians (Technician, Lead Technician) use the tech app, not the desktop app, so they can't sign
/// in here and dashboard permissions don't apply to them.
bool isTechnicianRole(String role) => role.toLowerCase().contains('tech');

/// The recognition badges the Team screen can switch on for someone, named as the sign-in answer names them
/// (`has_<key>`; the 5-star one is `has_5star`).
const List<String> kBadgeKeys = ['five_star', 'no_recalls', 'top_producer', 'zero_strikes', 'team_favorite'];

class AuthException implements Exception {
  final String message;
  const AuthException(this.message);

  @override
  String toString() => message;
}

/// The username and PIN were right, but the PIN is a temporary one an admin issued. The person has to choose
/// their own before they get in; nothing is signed in yet. See [AuthSession.changePin].
class PinChangeRequired implements Exception {
  final String username;
  final String tempPin;
  const PinChangeRequired(this.username, this.tempPin);
}

/// Who is signed in to the desktop app.
///
/// The shared [kAuthToken] ships inside every build, so by itself it only says "this is our app".
/// Signing in with a username and PIN gets a per-user token from the backend (`/login`). The office app asks for
/// a 7 day token (`x-client: office`) and keeps it on this device, so refreshing the page or reopening the app
/// stays signed in until it expires, then you sign in again. Signing out clears it.
class AuthSession extends ChangeNotifier {
  AuthSession._();
  static final AuthSession instance = AuthSession._();

  String? _userToken;
  int _expiresAtMs = 0;
  String _name = '';
  String _role = '';
  bool _isAdmin = false;
  Set<String> _denied = {};
  Set<String>? _badges; // null: this saved sign-in predates badges, so they are unknown until the next sign-in

  static const _storeKey = 'iohd_auth_session';

  /// Brings back the saved sign-in (if it hasn't expired) before the first screen is built.
  Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storeKey);
      if (raw == null) return;
      final d = json.decode(raw) as Map<String, dynamic>;
      final token = d['token']?.toString();
      final exp = _expiryOf(token ?? '');
      if (token == null || token.isEmpty || DateTime.now().millisecondsSinceEpoch >= exp) {
        await prefs.remove(_storeKey);
        return;
      }
      _userToken = token;
      _expiresAtMs = exp;
      _name = d['name']?.toString() ?? '';
      _role = d['role']?.toString() ?? '';
      _isAdmin = d['is_admin'] == true;
      _denied = (d['denied'] is List) ? (d['denied'] as List).map((e) => e.toString()).toSet() : {};
      _badges = (d['badges'] is List) ? (d['badges'] as List).map((e) => e.toString()).toSet() : null;
      notifyListeners();
    } catch (_) {
      // Unreadable or unavailable storage: just start signed out.
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _storeKey,
        json.encode({'token': _userToken, 'name': _name, 'role': _role, 'is_admin': _isAdmin, 'denied': _denied.toList(), 'badges': _badges?.toList()}),
      );
    } catch (_) {}
  }

  Future<void> _forget() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_storeKey);
    } catch (_) {}
  }

  bool get isLoggedIn => _userToken != null && DateTime.now().millisecondsSinceEpoch < _expiresAtMs;
  String get name => _name;
  String get role => _role;
  bool get isAdmin => _isAdmin;

  /// The badges this person has earned (see [kBadgeKeys]), or null when they aren't known yet: a sign-in saved
  /// before badges were kept has to be redone once.
  Set<String>? get badges => _badges;

  /// When this sign-in ends and the sign-in screen comes back. Null when signed out.
  DateTime? get expiresAt => isLoggedIn ? DateTime.fromMillisecondsSinceEpoch(_expiresAtMs) : null;

  /// Whether the signed-in user may do [action] on a resource (keys in access.dart). Admins always can;
  /// everyone else can unless the Team screen's permissions matrix switched it off.
  bool can(String resource, AccessAction action) => _isAdmin || !_denied.contains('$resource.${action.name}');

  /// Whether they may open a resource's page.
  bool canView(String resource) => can(resource, AccessAction.view);

  /// True when at least one of [keys] is visible, so the menu that holds them is worth showing.
  bool canViewAny(Iterable<String> keys) => keys.any(canView);

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
          'x-client': 'office',
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

    if (isTechnicianRole(body['role']?.toString() ?? '')) {
      throw const AuthException('Technicians use the tech app. Your account does not have access to this app.');
    }

    // A temporary PIN (new employee or admin reset) is only good for choosing a new one, never for getting in.
    if (body['needs_pin_change'] == true) {
      throw PinChangeRequired(user, secret);
    }

    final token = body['token']?.toString();
    if (token == null || token.isEmpty) {
      throw const AuthException('Sign-in failed. Please try again.');
    }

    _userToken = token;
    _expiresAtMs = _expiryOf(token);
    _name = body['name']?.toString() ?? user;
    _role = body['role']?.toString() ?? '';
    _isAdmin = body['is_admin'] == true;
    final denied = body['access_denied'];
    _denied = denied is List ? denied.map((e) => e.toString()).toSet() : {};
    _badges = {
      for (final k in kBadgeKeys)
        if (body['has_$k'] == true || (k == 'five_star' && body['has_5star'] == true)) k,
    };
    unawaited(_persist());
    notifyListeners();
  }

  /// Replaces a temporary PIN with one the person chose. Exactly 4 digits, because the same PIN signs them in
  /// to the Android app too and that app only takes 4.
  ///
  /// [temporary] is true on first sign-in (the old PIN is the one an admin issued) and false when a signed-in
  /// person changes their own PIN from My Profile; it only changes the wording of the errors.
  Future<void> changePin(String username, String oldPin, String newPin, {bool temporary = true}) async {
    if (!RegExp(r'^\d{4}$').hasMatch(newPin)) {
      throw const AuthException('Your PIN must be exactly 4 digits.');
    }
    if (newPin == oldPin) {
      throw AuthException(temporary ? 'Choose a different PIN from the temporary one.' : 'Choose a different PIN from your current one.');
    }

    late http.Response res;
    try {
      res = await http
          .post(
            Uri.parse('$kApiBaseUrl/update_pin'),
            headers: {
              'Content-Type': 'application/json',
              if (kAuthToken.isNotEmpty) 'Authorization': 'Bearer $kAuthToken',
              'x-username': username.trim(),
              'x-pin': oldPin,
            },
            body: json.encode({'newPin': newPin}),
          )
          .timeout(const Duration(seconds: 60));
    } catch (_) {
      throw const AuthException("Couldn't reach the server. Check your connection and try again.");
    }

    Map<String, dynamic> body = const {};
    try {
      body = json.decode(res.body) as Map<String, dynamic>;
    } catch (_) {}

    switch (res.statusCode) {
      case 200:
        return;
      case 400:
        throw AuthException(body['error']?.toString() ?? 'That PIN was not accepted.');
      case 401:
        throw AuthException(temporary
            ? 'The temporary PIN no longer works. Ask an admin to reset it again.'
            : "That isn't your current PIN.");
      case 429:
        throw AuthException(body['error']?.toString() ?? 'Too many attempts. Try again in 15 minutes.');
      default:
        throw AuthException('Could not save the PIN (server error ${res.statusCode}).');
    }
  }

  void logout() {
    if (_userToken == null) return;
    _userToken = null;
    _expiresAtMs = 0;
    _name = '';
    _role = '';
    _isAdmin = false;
    _denied = {};
    _badges = null;
    unawaited(_forget());
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
