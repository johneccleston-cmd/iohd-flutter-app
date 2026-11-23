import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../config/auth_session.dart';
import '../utils/charge_presets.dart';
import '../utils/sales_tax_catalog.dart';

// The Tax, Discounts & Fees settings (backend: src/taxSettings.js): the discount and fee presets the Products &
// Services panel offers, the out-of-state tax's start, and Arkansas rate changes typed in ahead of a catalog update. One
// shared copy ([TaxSettingsStore]) for the panel and the screen. Nothing here is ever sent to Service Fusion.

class TaxSettingsException implements Exception {
  final String message;
  final int status;
  const TaxSettingsException(this.message, {this.status = 0});

  /// The server doesn't have the settings yet (a backend older than this screen).
  bool get notOnServer => status == 404;

  /// Someone else saved first.
  bool get isConflict => status == 409;

  @override
  String toString() => message;
}

class TaxSettingsApi {
  static Uri get _uri => Uri.parse('$kApiBaseUrl/api/tax-settings');

  static Future<Map<String, dynamic>> _call(String method, {Map<String, dynamic>? body}) async {
    http.Response res;
    try {
      final req = http.Request(method, _uri)..headers.addAll(AuthSession.instance.headers());
      if (body != null) req.body = json.encode(body);
      res = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 20)));
    } on TimeoutException {
      throw const TaxSettingsException('The server took too long to answer. Try again.');
    } catch (_) {
      throw const TaxSettingsException('Could not reach the server.');
    }
    if (res.statusCode == 401) {
      AuthSession.instance.logout();
      throw const TaxSettingsException('Your session expired. Please sign in again.', status: 401);
    }
    Map<String, dynamic> data = const {};
    try {
      final d = json.decode(res.body);
      if (d is Map) data = Map<String, dynamic>.from(d);
    } catch (_) {}
    if (res.statusCode == 404 && data['error'] == null) {
      throw const TaxSettingsException('The server doesn\'t have the Tax, Discounts & Fees settings yet.', status: 404);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw TaxSettingsException((data['error'] ?? 'Server error (${res.statusCode}).').toString(), status: res.statusCode);
    }
    return data;
  }

  static Future<TaxSettings> load() async => TaxSettings.fromJson(await _call('GET'));

  /// Saves [s] over the server's version [version] (null: nothing was saved yet). A 409 means someone else saved first.
  static Future<TaxSettings> save(TaxSettings s) async =>
      TaxSettings.fromJson(await _call('PUT', body: {'version': s.version, 'settings': s.settingsJson()}));
}

/// The settings everyone reads: the built-in list until the server's arrive (or when it can't be reached: the panel
/// still works with the built-in list). The typed-in rate changes go to the catalog ([ArkansasTax.changes]).
class TaxSettingsStore extends ValueNotifier<TaxSettings> {
  TaxSettingsStore._() : super(TaxSettings.builtIn);
  static final instance = TaxSettingsStore._();

  Future<void>? _loading;
  bool loaded = false;

  /// Loads once (again after [refresh]); quietly keeps the built-in list if it fails.
  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> refresh() => _loading = _load();

  Future<void> _load() async {
    try {
      set(await TaxSettingsApi.load());
      loaded = true;
    } catch (_) {
      // The panel keeps the built-in list; the screen shows why.
    }
  }

  void set(TaxSettings s) {
    ArkansasTax.changes = s.rateChanges;
    value = s;
  }

  @visibleForTesting
  void debugReset([TaxSettings s = TaxSettings.builtIn]) {
    _loading = null;
    loaded = false;
    set(s);
  }
}
