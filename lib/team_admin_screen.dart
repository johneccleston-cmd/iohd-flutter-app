import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'config/api_config.dart';
import 'widgets/dashboard_kit.dart';

// ---------------------------------------------------------------------------
// Team admin: every login in the users table, editable in place.
//
// Left: the roster (search, Active / Inactive / All, grouped by kind of work).
// Right: one person. Edits collect into a draft; the save bar shows how many fields changed, and
// pay-affecting changes (weight, eligibility, role, status, name) get a review step before saving.
//
// Data: /api/admin/users (see src/admin_users.js). Saves are transactional, audited, and guarded by
// a version check so two people editing the same employee can't overwrite each other.
// Ctrl+S (Cmd+S on Mac) saves.
//
// When desktop logins land, send the session token as `x-user-token` in _headers() and gate the
// route on the admin role; the server routes already use requireAdmin.
// ---------------------------------------------------------------------------

class _T {
  static const wash = Color(0xFFF8FAFC);
  static const field = Color(0xFFF8FAFC);
  static const changedFill = Color(0xFFEEF2FF);
  static const amberBg = Color(0xFFFFFBEB);
  static const amberLine = Color(0xFFFDE68A);
  static const amberFg = Color(0xFF92400E);
  static const goodBg = Color(0xFFECFDF5);
  static const goodFg = Color(0xFF047857);
  static const badBg = Color(0xFFFEF2F2);
  static const badFg = Color(0xFFB91C1C);
  static const skyBg = Color(0xFFF0F9FF);
}

const List<FontFeature> _figures = [FontFeature.tabularFigures()];
const Duration _timeout = Duration(seconds: 20);

const Set<String> _boolKeys = {
  'is_commission_eligible',
  'is_callback_eligible',
  'is_lead',
  'can_collect_payment',
  'five_star',
  'no_recalls',
};
const Set<String> _nullableText = {'email', 'tech_id', 'avatar_url'};
const Set<String> _sensitive = {
  'name',
  'role',
  'status',
  'tech_weight',
  'is_commission_eligible',
  'is_callback_eligible',
};

const Map<String, String> _labels = {
  'name': 'Name',
  'username': 'Username',
  'email': 'Email',
  'role': 'Role',
  'status': 'Status',
  'year_joined': 'Year joined',
  'tenure_tier': 'Tenure tier',
  'tool_allowance': 'Tool allowance',
  'tech_weight': 'Commission weight',
  'is_commission_eligible': 'Commission eligible',
  'is_callback_eligible': 'Callback pay eligible',
  'is_lead': 'Lead',
  'can_collect_payment': 'Can collect payment',
  'five_star': '5-Star badge',
  'no_recalls': 'No-recalls badge',
  'inventory_strikes': 'Inventory strikes',
  'warehouse_strikes': 'Warehouse strikes',
  'tech_id': 'Service Fusion tech ID',
  'avatar_url': 'Photo URL',
};

const List<(double, String)> _weightPresets = [
  (0.0, 'No share'),
  (0.5, 'Half'),
  (1.0, 'Standard'),
  (1.5, 'Lead'),
];

double _d(dynamic v) {
  if (v is num) return v.toDouble();
  return double.tryParse(v?.toString() ?? '') ?? 0.0;
}

String _s(dynamic v) => v?.toString() ?? '';

bool _isActiveStatus(dynamic v) {
  final s = _s(v).trim().toLowerCase();
  return s.isEmpty || s == 'active';
}

String _fmtW(double w) {
  var s = w.toStringAsFixed(2);
  if (s.endsWith('0')) s = s.substring(0, s.length - 1);
  return s;
}

bool _same(dynamic a, dynamic b) {
  if (a is num && b is num) return (a - b).abs() < 1e-9;
  return a == b;
}

String _shortDay(String? iso) {
  if (iso == null || iso.length < 10) return '';
  final d = DateTime.tryParse(iso.substring(0, 10));
  return d == null ? '' : DateFormat('MMM d').format(d);
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

class _Role {
  final String name;
  final bool grantsAdmin;
  const _Role(this.name, this.grantsAdmin);
}

class _Emp {
  final Map<String, dynamic> raw;
  _Emp(this.raw);

  int get id => _d(raw['id']).round();
  String get name => _s(raw['name']).trim();
  String get username => _s(raw['username']).trim();
  String get role => _s(raw['role']).trim();
  bool get active => _isActiveStatus(raw['status']);
  double get weight => raw['tech_weight'] == null ? 1.0 : _d(raw['tech_weight']);
  bool get commissionEligible => raw['is_commission_eligible'] == true;
  bool get callbackEligible => raw['is_callback_eligible'] == true;
  bool get hasPin => raw['has_pin'] == true;
  bool get needsPinChange => raw['needs_pin_change'] == true;
  String get version => _s(raw['version']);
  String get avatarUrl => _s(raw['avatar_url']).trim();
  String? get lastWorkDate => raw['last_work_date'] == null ? null : _s(raw['last_work_date']);
  int get workDays90 => _d(raw['work_days_90']).round();
  bool get isField => role.toLowerCase().contains('tech');
  bool get unmatched => active && isField && workDays90 == 0;

  /// The group a person is listed under in the roster.
  int get group {
    final r = role.toLowerCase();
    if (r.contains('tech')) return 0;
    if (r.contains('sales')) return 1;
    if (r.contains('warehouse')) return 3;
    if (r.contains('office') || r.contains('admin') || r.contains('owner')) return 2;
    return 4;
  }

  /// Keeps the 90-day match stats, which the save endpoint doesn't recompute.
  _Emp mergedFrom(Map<String, dynamic> fresh) {
    final m = Map<String, dynamic>.from(fresh);
    m.putIfAbsent('last_work_date', () => raw['last_work_date']);
    m.putIfAbsent('work_days_90', () => raw['work_days_90']);
    return _Emp(m);
  }
}

const List<String> _groupNames = ['Field team', 'Sales', 'Office and admin', 'Warehouse', 'Other'];

class _Change {
  final String field;
  final String label;
  final String? oldValue;
  final String? newValue;
  final String? note;
  final String by;
  final DateTime? at;

  _Change(Map<String, dynamic> j)
      : field = _s(j['field']),
        label = _s(j['label']),
        oldValue = j['old_value'] == null ? null : _s(j['old_value']),
        newValue = j['new_value'] == null ? null : _s(j['new_value']),
        note = j['note'] == null ? null : _s(j['note']),
        by = _s(j['changed_by_name']),
        at = DateTime.tryParse(_s(j['changed_at']))?.toLocal();
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class TeamAdminScreen extends StatefulWidget {
  const TeamAdminScreen({super.key});

  @override
  State<TeamAdminScreen> createState() => _TeamAdminScreenState();
}

enum _Filter { active, inactive, all }

class _TeamAdminScreenState extends State<TeamAdminScreen> {
  List<_Emp> _users = [];
  List<_Role> _roles = const [];
  bool _loading = true;
  String? _error;

  int? _selectedId;
  final Map<String, dynamic> _draft = {};
  Map<String, String> _fieldErrors = {};
  bool _saving = false;

  List<_Change>? _history;
  bool _historyLoading = false;
  int _historyReq = 0;

  String _query = '';
  _Filter _filter = _Filter.active;
  final _searchCtl = TextEditingController();
  final _detailScroll = ScrollController();

  final _nameCtl = TextEditingController();
  final _usernameCtl = TextEditingController();
  final _emailCtl = TextEditingController();
  final _yearCtl = TextEditingController();
  final _techIdCtl = TextEditingController();
  final _avatarCtl = TextEditingController();
  final _allowanceCtl = TextEditingController();
  final _weightCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [
      _searchCtl, _nameCtl, _usernameCtl, _emailCtl, _yearCtl,
      _techIdCtl, _avatarCtl, _allowanceCtl, _weightCtl,
    ]) {
      c.dispose();
    }
    _detailScroll.dispose();
    super.dispose();
  }

  Map<String, String> _headers() => {
        'Authorization': 'Bearer $kAuthToken',
        'Content-Type': 'application/json',
        // 'x-user-token': <session token>,  // add once desktop logins exist
      };

  Uri _uri(String path) => Uri.parse('$kApiBaseUrl/api/admin/users$path');

  _Emp? get _selected {
    for (final u in _users) {
      if (u.id == _selectedId) return u;
    }
    return null;
  }

  bool get _dirty => _draft.isNotEmpty;

  // ---- Data -----------------------------------------------------------------

  Future<void> _load({bool keepSelection = true}) async {
    setState(() {
      _loading = _users.isEmpty;
      _error = null;
    });
    try {
      final res = await http.get(_uri(''), headers: _headers()).timeout(_timeout);
      final body = jsonDecode(res.body);
      if (res.statusCode != 200 || body is! Map || body['success'] != true) {
        throw Exception(body is Map ? (body['error'] ?? 'Server returned ${res.statusCode}') : 'Server returned ${res.statusCode}');
      }
      final roles = ((body['roles'] as List?) ?? const [])
          .whereType<Map>()
          .map((r) => _Role(_s(r['name']), r['grantsAdmin'] == true))
          .toList();
      final users = ((body['users'] as List?) ?? const [])
          .whereType<Map>()
          .map((u) => _Emp(Map<String, dynamic>.from(u)))
          .toList();
      if (!mounted) return;
      setState(() {
        _roles = roles;
        _users = users;
        _loading = false;
      });
      final keep = keepSelection && _selected != null;
      if (keep) {
        _openEmployee(_selected!, force: true);
      } else {
        final visible = _visible();
        if (visible.isNotEmpty) _openEmployee(visible.first, force: true);
      }
    } on TimeoutException {
      _fail('The server took too long to answer. Check your connection and try again.');
    } catch (e) {
      _fail('Couldn\'t load employees. ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  Future<void> _refresh() async {
    if (_dirty) {
      final leave = await _confirmDiscard();
      if (leave != true) return;
    }
    await _load();
  }

  void _fail(String msg) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = msg;
    });
  }

  Future<void> _loadHistory(int id) async {
    final req = ++_historyReq;
    setState(() {
      _historyLoading = true;
      _history = null;
    });
    try {
      final res = await http.get(_uri('/$id/history'), headers: _headers()).timeout(_timeout);
      final body = jsonDecode(res.body);
      if (!mounted || req != _historyReq) return;
      final list = (body is Map && body['success'] == true)
          ? ((body['history'] as List?) ?? const []).whereType<Map>().map((h) => _Change(Map<String, dynamic>.from(h))).toList()
          : <_Change>[];
      setState(() {
        _history = list;
        _historyLoading = false;
      });
    } catch (_) {
      if (!mounted || req != _historyReq) return;
      setState(() {
        _history = const [];
        _historyLoading = false;
      });
    }
  }

  // ---- Draft ----------------------------------------------------------------

  String _canonRole(String r) {
    for (final role in _roles) {
      if (role.name.toLowerCase() == r.trim().toLowerCase()) return role.name;
    }
    return r.trim();
  }

  bool _grantsAdmin(String role) =>
      _roles.any((r) => r.name.toLowerCase() == role.toLowerCase() && r.grantsAdmin);

  dynamic _norm(String key, dynamic v) {
    if (_boolKeys.contains(key)) return v == true;
    switch (key) {
      case 'tech_weight':
        return v == null ? 1.0 : _d(v);
      case 'tool_allowance':
        return _d(v);
      case 'tenure_tier':
      case 'inventory_strikes':
      case 'warehouse_strikes':
        return _d(v).round();
      case 'year_joined':
        return v == null ? null : _d(v).round();
      case 'status':
        return _isActiveStatus(v) ? 'Active' : 'Inactive';
      case 'role':
        return _canonRole(_s(v));
      default:
        return _s(v).trim();
    }
  }

  dynamic _base(String key) => _norm(key, _selected?.raw[key]);

  dynamic _value(String key) => _draft.containsKey(key) ? _draft[key] : _base(key);

  void _set(String key, dynamic v) {
    setState(() {
      if (_same(v, _base(key))) {
        _draft.remove(key);
      } else {
        _draft[key] = v;
      }
      _fieldErrors.remove(key);
    });
  }

  void _fillControllers(_Emp e) {
    _nameCtl.text = e.name;
    _usernameCtl.text = e.username;
    _emailCtl.text = _s(e.raw['email']);
    final y = _norm('year_joined', e.raw['year_joined']);
    _yearCtl.text = y == null ? '' : '$y';
    _techIdCtl.text = _s(e.raw['tech_id']);
    _avatarCtl.text = e.avatarUrl;
    final a = _d(e.raw['tool_allowance']);
    _allowanceCtl.text = a == 0 ? '' : a.toStringAsFixed(a == a.roundToDouble() ? 0 : 2);
    final w = e.weight;
    _weightCtl.text = _weightPresets.any((p) => _same(p.$1, w)) ? '' : _fmtW(w);
  }

  Future<void> _openEmployee(_Emp e, {bool force = false}) async {
    if (!force && e.id == _selectedId) return;
    if (!force && _dirty) {
      final leave = await _confirmDiscard();
      if (leave != true) return;
    }
    setState(() {
      _selectedId = e.id;
      _draft.clear();
      _fieldErrors = {};
    });
    _fillControllers(e);
    if (_detailScroll.hasClients) _detailScroll.jumpTo(0);
    _loadHistory(e.id);
  }

  void _discard() {
    final e = _selected;
    if (e == null) return;
    setState(() {
      _draft.clear();
      _fieldErrors = {};
    });
    _fillControllers(e);
  }

  Map<String, dynamic> _payload() {
    final out = <String, dynamic>{};
    _draft.forEach((k, v) {
      out[k] = (_nullableText.contains(k) && v is String && v.isEmpty) ? null : v;
    });
    return out;
  }

  void _replaceUser(_Emp updated) {
    final i = _users.indexWhere((u) => u.id == updated.id);
    if (i >= 0) _users[i] = updated;
  }

  // ---- Save -----------------------------------------------------------------

  Future<void> _save() async {
    final e = _selected;
    if (e == null || !_dirty || _saving) return;

    if (_draft.keys.any(_sensitive.contains)) {
      final ok = await _confirmReview(e);
      if (ok != true) return;
    }

    setState(() {
      _saving = true;
      _fieldErrors = {};
    });
    try {
      final res = await http
          .patch(_uri('/${e.id}'), headers: _headers(), body: jsonEncode({'changes': _payload(), 'version': e.version}))
          .timeout(_timeout);
      final body = jsonDecode(res.body);
      if (!mounted) return;

      if (res.statusCode == 200 && body is Map && body['success'] == true) {
        final updated = e.mergedFrom(Map<String, dynamic>.from(body['user'] as Map));
        final renamed = _d(body['renamedRows']).round();
        setState(() {
          _replaceUser(updated);
          _draft.clear();
          _saving = false;
        });
        _fillControllers(updated);
        _loadHistory(updated.id);
        _toast(renamed > 0
            ? 'Saved ${updated.name}. Renamed $renamed past work-day and ledger rows to match.'
            : 'Saved ${updated.name}.');
        return;
      }

      setState(() => _saving = false);
      if (res.statusCode == 409 && body is Map && body['conflict'] == true && body['user'] is Map) {
        await _showConflict(e, Map<String, dynamic>.from(body['user'] as Map));
        return;
      }
      final msg = body is Map ? _s(body['error']) : 'Save failed (${res.statusCode}).';
      final field = body is Map ? body['field'] : null;
      if (field is String && field.isNotEmpty) setState(() => _fieldErrors = {field: msg});
      _toast(msg.isEmpty ? 'Save failed (${res.statusCode}).' : msg, error: true);
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('The server took too long to answer. Your changes are still here; try saving again.', error: true);
    } catch (err) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('Couldn\'t save. Your changes are still here. ($err)', error: true);
    }
  }

  Future<void> _resetPin() async {
    final e = _selected;
    if (e == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => _dialog(
        title: 'Reset ${e.name.split(' ').first}\'s PIN?',
        body: const Text(
          'Their current PIN stops working right away. You\'ll get a temporary PIN to give them, '
          'and they\'ll choose a new one the next time they log in.',
          style: TextStyle(fontSize: 14, color: DashUi.slate, height: 1.45),
        ),
        actions: [
          _ghostButton('Cancel', () => Navigator.pop(ctx, false)),
          _inkButton('Reset PIN', () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final res = await http.post(_uri('/${e.id}/reset-pin'), headers: _headers()).timeout(_timeout);
      final body = jsonDecode(res.body);
      if (!mounted) return;
      if (res.statusCode == 200 && body is Map && body['success'] == true) {
        setState(() => _replaceUser(e.mergedFrom(Map<String, dynamic>.from(body['user'] as Map))));
        _loadHistory(e.id);
        await _showPin(e.name, _s(body['tempPin']));
      } else {
        _toast(body is Map ? _s(body['error']) : 'Couldn\'t reset the PIN.', error: true);
      }
    } catch (err) {
      if (mounted) _toast('Couldn\'t reset the PIN. ($err)', error: true);
    }
  }

  Future<void> _addEmployee() async {
    if (_dirty) {
      final leave = await _confirmDiscard();
      if (leave != true) return;
      _discard();
    }
    if (!mounted) return;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _AddEmployeeDialog(
        roles: _roles,
        submit: (data) async {
          final res = await http.post(_uri(''), headers: _headers(), body: jsonEncode(data)).timeout(_timeout);
          final body = jsonDecode(res.body);
          if (res.statusCode == 200 && body is Map && body['success'] == true) {
            return Map<String, dynamic>.from(body);
          }
          throw _ApiError(body is Map ? _s(body['error']) : 'Server returned ${res.statusCode}',
              body is Map ? body['field'] as String? : null);
        },
      ),
    );
    if (result == null || !mounted) return;
    final created = _Emp(Map<String, dynamic>.from(result['user'] as Map));
    setState(() {
      _users = [..._users, created]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      _filter = _Filter.active;
    });
    await _openEmployee(created, force: true);
    if (mounted) await _showPin(created.name, _s(result['tempPin']));
  }

  // ---- Dialogs --------------------------------------------------------------

  Future<bool?> _confirmDiscard() {
    final e = _selected;
    final n = _draft.length;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => _dialog(
        title: 'Discard $n unsaved ${n == 1 ? 'change' : 'changes'}?',
        body: Text(
          'Your edits to ${e?.name ?? 'this employee'} haven\'t been saved.',
          style: const TextStyle(fontSize: 14, color: DashUi.slate),
        ),
        actions: [
          _ghostButton('Keep editing', () => Navigator.pop(ctx, false)),
          _inkButton('Discard changes', () => Navigator.pop(ctx, true), danger: true),
        ],
      ),
    );
  }

  Future<bool?> _confirmReview(_Emp e) {
    final keys = _labels.keys.where(_draft.containsKey).toList();
    final notes = <String>[];
    if (_draft.containsKey('tech_weight') || _draft.containsKey('is_commission_eligible')) {
      notes.add('Open jobs recalculate on the next Service Fusion sync, about 3 minutes. Jobs already paid keep their old weight.');
    }
    if (_draft.containsKey('name')) {
      notes.add('Past work days and ledger rows are renamed too. Service Fusion must use the new name, or new jobs won\'t match.');
    }
    if (_draft['status'] == 'Inactive') {
      notes.add('${e.name.split(' ').first} won\'t be able to log in, and drops off the dashboards.');
    }
    if (_draft.containsKey('role') && _grantsAdmin(_s(_draft['role'])) && !_grantsAdmin(_s(_base('role')))) {
      notes.add('${_draft['role']} can open admin screens, including this one.');
    }

    return showDialog<bool>(
      context: context,
      builder: (ctx) => _dialog(
        title: 'Review changes to ${e.name}',
        width: 520,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: DashUi.line),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < keys.length; i++)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                      decoration: BoxDecoration(
                        border: i == 0 ? null : const Border(top: BorderSide(color: DashUi.line)),
                        color: _sensitive.contains(keys[i]) ? _T.wash : Colors.white,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(_labels[keys[i]]!,
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.slate)),
                          ),
                          Text(_display(keys[i], _base(keys[i])),
                              style: const TextStyle(
                                  fontSize: 13.5,
                                  color: DashUi.muted,
                                  decoration: TextDecoration.lineThrough,
                                  fontFeatures: _figures)),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Icon(Icons.arrow_forward_rounded, size: 14, color: DashUi.muted),
                          ),
                          Text(_display(keys[i], _draft[keys[i]]),
                              style: const TextStyle(
                                  fontSize: 13.5, fontWeight: FontWeight.w800, color: DashUi.ink, fontFeatures: _figures)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            for (final n in notes) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(Icons.info_outline_rounded, size: 15, color: DashUi.slate),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(n, style: const TextStyle(fontSize: 12.5, color: DashUi.slate, height: 1.4))),
                ],
              ),
            ],
          ],
        ),
        actions: [
          _ghostButton('Back', () => Navigator.pop(ctx, false)),
          _inkButton('Save changes', () => Navigator.pop(ctx, true)),
        ],
      ),
    );
  }

  Future<void> _showConflict(_Emp e, Map<String, dynamic> fresh) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => _dialog(
        title: '${e.name} was changed by someone else',
        body: const Text(
          'Someone saved changes to this employee after you opened them. Reload to see the latest, '
          'then make your edits again.',
          style: TextStyle(fontSize: 14, color: DashUi.slate, height: 1.45),
        ),
        actions: [_inkButton('Reload employee', () => Navigator.pop(ctx))],
      ),
    );
    if (!mounted) return;
    final updated = e.mergedFrom(fresh);
    setState(() {
      _replaceUser(updated);
      _draft.clear();
    });
    _fillControllers(updated);
    _loadHistory(updated.id);
  }

  Future<void> _showPin(String name, String pin) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => _dialog(
        title: 'Temporary PIN for ${name.split(' ').first}',
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(vertical: 22),
              decoration: BoxDecoration(color: _T.wash, borderRadius: BorderRadius.circular(14), border: Border.all(color: DashUi.line)),
              child: SelectableText(
                pin,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 38, fontWeight: FontWeight.w800, letterSpacing: 10, color: DashUi.ink, fontFeatures: _figures),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Give this to $name. They\'ll choose their own PIN the first time they log in. '
              'This PIN isn\'t stored anywhere you can see it again.',
              style: const TextStyle(fontSize: 13, color: DashUi.slate, height: 1.45),
            ),
          ],
        ),
        actions: [
          _ghostButton('Copy PIN', () {
            Clipboard.setData(ClipboardData(text: pin));
            _toast('PIN copied.');
          }),
          _inkButton('Done', () => Navigator.pop(ctx)),
        ],
      ),
    );
  }

  void _toast(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        width: 460,
        backgroundColor: error ? _T.badFg : DashUi.ink,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600)),
      ));
  }

  String _display(String key, dynamic v) {
    if (v == null || (v is String && v.trim().isEmpty)) return 'None';
    if (_boolKeys.contains(key)) return v == true ? 'On' : 'Off';
    if (key == 'tech_weight') return '${_fmtW(_d(v))}×';
    if (key == 'tool_allowance') return dashMoney(_d(v));
    return '$v';
  }

  String _displayAudit(String field, String? v) {
    if (v == null || v.isEmpty) return 'None';
    if (_boolKeys.contains(field)) return v == 'true' ? 'On' : (v == 'false' ? 'Off' : v);
    if (field == 'tech_weight') return '${_fmtW(_d(v))}×';
    if (field == 'tool_allowance') return dashMoney(_d(v));
    return v;
  }

  // ---- Build ----------------------------------------------------------------

  List<_Emp> _visible() {
    final q = _query.trim().toLowerCase();
    final list = _users.where((u) {
      if (_filter == _Filter.active && !u.active) return false;
      if (_filter == _Filter.inactive && u.active) return false;
      if (q.isEmpty) return true;
      return u.name.toLowerCase().contains(q) || u.username.toLowerCase().contains(q) || u.role.toLowerCase().contains(q);
    }).toList();
    list.sort((a, b) {
      final g = a.group.compareTo(b.group);
      return g != 0 ? g : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: _T.wash,
          body: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(),
                const SizedBox(height: 18),
                if (_loading)
                  const Expanded(child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)))
                else if (_error != null && _users.isEmpty)
                  Expanded(child: _errorState())
                else ...[
                  _scorecards(),
                  const SizedBox(height: 16),
                  Expanded(
                    child: LayoutBuilder(builder: (context, c) {
                      final rosterW = c.maxWidth >= 1200 ? 340.0 : 296.0;
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(width: rosterW, child: _roster()),
                          const SizedBox(width: 16),
                          Expanded(child: _detail()),
                        ],
                      );
                    }),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Team',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: DashUi.ink, letterSpacing: -0.6)),
              SizedBox(height: 2),
              Text('Everyone with a login. Changes save to the database and reach payroll and the apps on the next sync.',
                  style: TextStyle(fontSize: 13, color: DashUi.slate, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
        Tooltip(
          message: 'Reload',
          child: IconButton(
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded, color: DashUi.slate),
          ),
        ),
        const SizedBox(width: 6),
        _inkButton('Add employee', _users.isEmpty ? null : _addEmployee, icon: Icons.person_add_alt_1_rounded),
      ],
    );
  }

  Widget _errorState() {
    return Center(
      child: Container(
        width: 460,
        padding: const EdgeInsets.all(28),
        decoration: DashUi.panel(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 34, color: DashUi.slate),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, color: DashUi.slate, height: 1.45)),
            const SizedBox(height: 16),
            _inkButton('Try again', () => _load()),
          ],
        ),
      ),
    );
  }

  Widget _scorecards() {
    final active = _users.where((u) => u.active).toList();
    final unmatched = active.where((u) => u.unmatched).length;
    return Row(
      children: [
        Expanded(child: _score(Icons.groups_rounded, DashUi.blue, 'Active employees', '${active.length}')),
        const SizedBox(width: 12),
        Expanded(
            child: _score(Icons.payments_rounded, DashUi.emeraldDeep, 'Commission eligible',
                '${active.where((u) => u.commissionEligible).length}')),
        const SizedBox(width: 12),
        Expanded(
            child: _score(Icons.replay_rounded, DashUi.indigo, 'Callback pay eligible',
                '${active.where((u) => u.callbackEligible).length}')),
        const SizedBox(width: 12),
        Expanded(
          child: _score(
            Icons.link_off_rounded,
            unmatched > 0 ? DashUi.amber : DashUi.muted,
            'Techs with no matched jobs',
            '$unmatched',
            onTap: unmatched == 0
                ? null
                : () {
                    final first = _users.firstWhere((u) => u.unmatched);
                    setState(() {
                      _filter = _Filter.active;
                      _query = '';
                      _searchCtl.clear();
                    });
                    _openEmployee(first);
                  },
          ),
        ),
      ],
    );
  }

  Widget _score(IconData icon, Color color, String label, String value, {VoidCallback? onTap}) {
    final card = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: DashUi.panel(radius: 14),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 20, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, color: DashUi.slate, fontWeight: FontWeight.w600)),
                Text(value,
                    style: const TextStyle(
                        fontSize: 24, fontWeight: FontWeight.w800, color: DashUi.ink, height: 1.15, fontFeatures: _figures)),
              ],
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return card;
    return MouseRegion(cursor: SystemMouseCursors.click, child: GestureDetector(onTap: onTap, child: card));
  }

  // ---- Roster ---------------------------------------------------------------

  Widget _roster() {
    final list = _visible();
    final counts = {
      _Filter.active: _users.where((u) => u.active).length,
      _Filter.inactive: _users.where((u) => !u.active).length,
      _Filter.all: _users.length,
    };

    final children = <Widget>[];
    int? lastGroup;
    for (final u in list) {
      if (u.group != lastGroup) {
        lastGroup = u.group;
        children.add(Padding(
          padding: EdgeInsets.fromLTRB(16, children.isEmpty ? 6 : 16, 16, 6),
          child: Text(_groupNames[u.group],
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.muted)),
        ));
      }
      children.add(_rosterRow(u));
    }

    return Container(
      decoration: DashUi.panel(),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            child: TextField(
              controller: _searchCtl,
              onChanged: (v) => setState(() => _query = v),
              style: const TextStyle(fontSize: 14, color: DashUi.ink),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: _T.wash,
                hintText: 'Search name, username or role',
                hintStyle: const TextStyle(fontSize: 13.5, color: DashUi.muted),
                prefixIcon: const Icon(Icons.search_rounded, size: 19, color: DashUi.muted),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 17, color: DashUi.muted),
                        onPressed: () => setState(() {
                          _query = '';
                          _searchCtl.clear();
                        }),
                      ),
                contentPadding: const EdgeInsets.symmetric(vertical: 11),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: DashUi.line)),
                enabledBorder:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: DashUi.line)),
                focusedBorder:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: DashUi.ink)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: _segmented<_Filter>(
              value: _filter,
              options: [
                (_Filter.active, 'Active ${counts[_Filter.active]}'),
                (_Filter.inactive, 'Inactive ${counts[_Filter.inactive]}'),
                (_Filter.all, 'All ${counts[_Filter.all]}'),
              ],
              onChanged: (f) => setState(() => _filter = f),
            ),
          ),
          const Divider(height: 1, color: DashUi.line),
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _query.isEmpty ? 'No one here.' : 'No one matches "$_query".',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 13.5, color: DashUi.muted),
                      ),
                    ),
                  )
                : ListView(padding: const EdgeInsets.only(bottom: 10), children: children),
          ),
        ],
      ),
    );
  }

  Widget _rosterRow(_Emp u) {
    final selected = u.id == _selectedId;
    final editing = selected && _dirty;
    final w = selected ? _d(_value('tech_weight')) : u.weight;
    final eligible = selected ? _value('is_commission_eligible') == true : u.commissionEligible;
    final attention = u.active && (u.unmatched || !u.hasPin);

    return _Hoverable(
      onTap: () => _openEmployee(u),
      builder: (hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: selected ? DashUi.faint : (hover ? _T.wash : Colors.transparent),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? DashUi.line : Colors.transparent),
        ),
        child: Opacity(
          opacity: u.active ? 1 : 0.55,
          child: Row(
            children: [
              DashAvatar(name: u.name, imageUrl: u.avatarUrl, size: 34),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(u.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
                                  color: DashUi.ink)),
                        ),
                        if (editing) ...[
                          const SizedBox(width: 6),
                          Container(width: 6, height: 6, decoration: const BoxDecoration(color: DashUi.indigo, shape: BoxShape.circle)),
                        ],
                      ],
                    ),
                    Text(u.active ? (u.role.isEmpty ? 'No role' : u.role) : '${u.role}, inactive',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: DashUi.slate, fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
              if (attention)
                Tooltip(
                  message: u.unmatched ? 'No Service Fusion work matched in 90 days' : 'No PIN set',
                  child: const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: Icon(Icons.error_outline_rounded, size: 16, color: DashUi.amber),
                  ),
                ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: eligible ? _T.goodBg : DashUi.faint,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('${_fmtW(w)}×',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: eligible ? _T.goodFg : DashUi.muted,
                        fontFeatures: _figures)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Detail ---------------------------------------------------------------

  Widget _detail() {
    final e = _selected;
    if (e == null) {
      return Container(
        decoration: DashUi.panel(),
        alignment: Alignment.center,
        child: const Text('Pick someone on the left to see and edit their details.',
            style: TextStyle(fontSize: 14, color: DashUi.muted)),
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: ListView(
            controller: _detailScroll,
            padding: const EdgeInsets.only(bottom: 110),
            children: [
              _hero(e),
              const SizedBox(height: 14),
              _weightSection(),
              const SizedBox(height: 14),
              _roleSection(),
              const SizedBox(height: 14),
              _profileSection(),
              const SizedBox(height: 14),
              _recordSection(),
              const SizedBox(height: 14),
              _loginSection(e),
              const SizedBox(height: 14),
              _historySection(),
            ],
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            ignoring: !_dirty,
            child: AnimatedSlide(
              offset: _dirty ? Offset.zero : const Offset(0, 1.4),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: _dirty ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: _saveBar(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _saveBar() {
    final n = _draft.length;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      padding: const EdgeInsets.fromLTRB(18, 10, 10, 10),
      decoration: BoxDecoration(
        color: DashUi.ink,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: DashUi.ink.withValues(alpha: 0.25), blurRadius: 24, offset: const Offset(0, 8))],
      ),
      child: Row(
        children: [
          const Icon(Icons.edit_rounded, size: 17, color: Colors.white70),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$n unsaved ${n == 1 ? 'change' : 'changes'}',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white),
            ),
          ),
          TextButton(
            onPressed: _saving ? null : _discard,
            style: TextButton.styleFrom(foregroundColor: Colors.white70),
            child: const Text('Discard', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 6),
          FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: DashUi.ink,
              disabledBackgroundColor: Colors.white70,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: DashUi.ink))
                : const Text('Save changes', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }

  Widget _hero(_Emp e) {
    final name = _s(_value('name'));
    final role = _s(_value('role'));
    final active = _value('status') == 'Active';
    final year = _value('year_joined');

    Widget health;
    if (e.workDays90 > 0) {
      health = _note(
        Icons.link_rounded,
        'Last on a job ${_shortDay(e.lastWorkDate)}. ${e.workDays90} work ${e.workDays90 == 1 ? 'day' : 'days'} matched from Service Fusion in the last 90 days.',
        fg: DashUi.slate,
        bg: _T.wash,
      );
    } else if (e.unmatched) {
      health = _note(
        Icons.link_off_rounded,
        'No Service Fusion work matched in the last 90 days. If they\'ve been on jobs, their name here probably doesn\'t match Service Fusion exactly.',
        fg: _T.amberFg,
        bg: _T.amberBg,
        line: _T.amberLine,
      );
    } else {
      health = const SizedBox.shrink();
    }

    return Container(
      decoration: DashUi.panel(),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              DashAvatar(
                name: name,
                imageUrl: _s(_value('avatar_url')),
                size: 64,
                ringColor: active ? DashUi.emerald : DashUi.line,
                ringWidth: 2.5,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name.isEmpty ? 'Unnamed' : name,
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: DashUi.ink, letterSpacing: -0.4)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _chip('@${_s(_value('username'))}', DashUi.slate, DashUi.faint),
                        _chip(role.isEmpty ? 'No role' : role, DashUi.ink, DashUi.faint),
                        if (_grantsAdmin(role)) _chip('Admin access', DashUi.indigo, const Color(0xFFEEF2FF)),
                        if (_value('is_lead') == true) _chip('Lead', _T.goodFg, _T.goodBg),
                        if (year != null) _chip('Joined $year', DashUi.slate, DashUi.faint),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 210,
                child: _segmented<String>(
                  value: active ? 'Active' : 'Inactive',
                  options: const [('Active', 'Active'), ('Inactive', 'Inactive')],
                  onChanged: (v) => _set('status', v),
                  activeColor: active ? DashUi.emeraldDeep : _T.badFg,
                ),
              ),
            ],
          ),
          if (_fieldErrors['status'] != null) ...[
            const SizedBox(height: 10),
            _note(Icons.error_outline_rounded, _fieldErrors['status']!, fg: _T.badFg, bg: _T.badBg),
          ],
          if (health is! SizedBox) ...[const SizedBox(height: 14), health],
        ],
      ),
    );
  }

  Widget _weightSection() {
    final w = _d(_value('tech_weight'));
    final eligible = _value('is_commission_eligible') == true;
    final isPreset = _weightPresets.any((p) => _same(p.$1, w));
    final role = _s(_value('role')).toLowerCase();
    final suggestLead = role.contains('lead') && !_same(w, 1.5);

    return _section(
      title: 'Commission weight',
      subtitle: 'Their share of a job compared with everyone else who worked the same days.',
      trailing: _changedTag('tech_weight'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Opacity(
            opacity: eligible ? 1 : 0.6,
            child: Row(
              children: [
                for (final p in _weightPresets) ...[
                  Expanded(child: _weightTile(p.$1, p.$2, _same(p.$1, w))),
                  const SizedBox(width: 10),
                ],
                Expanded(child: _customWeightTile(!isPreset)),
              ],
            ),
          ),
          if (_fieldErrors['tech_weight'] != null) ...[
            const SizedBox(height: 10),
            _note(Icons.error_outline_rounded, _fieldErrors['tech_weight']!, fg: _T.badFg, bg: _T.badBg),
          ],
          if (suggestLead) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.lightbulb_outline_rounded, size: 16, color: DashUi.slate),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text('Lead technicians usually run at 1.5.',
                      style: TextStyle(fontSize: 12.5, color: DashUi.slate, fontWeight: FontWeight.w500)),
                ),
                TextButton(
                  onPressed: () {
                    _weightCtl.clear();
                    _set('tech_weight', 1.5);
                  },
                  child: const Text('Use 1.5', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          const Divider(height: 1, color: DashUi.line),
          _toggleRow('is_commission_eligible', 'Commission eligible',
              'Earns job commission and shows up on payroll. Weight only counts when this is on.'),
          const Divider(height: 1, color: DashUi.line),
          _toggleRow('is_callback_eligible', 'Callback pay eligible', 'Gets the flat callback rate when sent out on a callback.'),
          const SizedBox(height: 10),
          const Text(
            'Open jobs pick up changes on the next Service Fusion sync, about 3 minutes. Jobs already paid keep the weight they were paid at.',
            style: TextStyle(fontSize: 12, color: DashUi.muted, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _weightTile(double value, String label, bool selected) {
    return _Hoverable(
      onTap: () {
        _weightCtl.clear();
        _set('tech_weight', value);
      },
      builder: (hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: 88,
        decoration: BoxDecoration(
          color: selected ? DashUi.ink : (hover ? _T.wash : Colors.white),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? DashUi.ink : (hover ? DashUi.muted : DashUi.line)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_fmtW(value),
                style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                    color: selected ? Colors.white : DashUi.ink,
                    fontFeatures: _figures)),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w600, color: selected ? Colors.white70 : DashUi.slate)),
          ],
        ),
      ),
    );
  }

  Widget _customWeightTile(bool selected) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      height: 88,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: selected ? DashUi.ink : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: selected ? DashUi.ink : DashUi.line),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextField(
            controller: _weightCtl,
            textAlign: TextAlign.center,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d{0,1}(\.\d{0,2})?'))],
            cursorColor: selected ? Colors.white : DashUi.ink,
            style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: selected ? Colors.white : DashUi.ink,
                fontFeatures: _figures),
            decoration: InputDecoration(
              isDense: true,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              hintText: '–',
              hintStyle: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: selected ? Colors.white38 : DashUi.line),
            ),
            onChanged: (t) {
              final v = double.tryParse(t);
              if (v != null) _set('tech_weight', v);
            },
          ),
          Text('Custom',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: selected ? Colors.white70 : DashUi.slate)),
        ],
      ),
    );
  }

  Widget _roleSection() {
    final role = _s(_value('role'));
    final options = [..._roles];
    if (role.isNotEmpty && !options.any((r) => r.name == role)) options.add(_Role(role, false));

    return _section(
      title: 'Role and access',
      trailing: _changedTag('role'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _fieldLabel('Role'),
          DropdownButtonFormField<String>(
            value: role.isEmpty ? null : role,
            isExpanded: true,
            borderRadius: BorderRadius.circular(12),
            dropdownColor: Colors.white,
            hint: const Text('Choose a role'),
            decoration: _dec('role'),
            style: const TextStyle(fontSize: 14, color: DashUi.ink, fontWeight: FontWeight.w600),
            items: [
              for (final r in options)
                DropdownMenuItem(
                  value: r.name,
                  child: Row(
                    children: [
                      Expanded(child: Text(r.name)),
                      if (r.grantsAdmin)
                        const Text('Admin access',
                            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: DashUi.indigo)),
                    ],
                  ),
                ),
            ],
            onChanged: (v) {
              if (v != null) _set('role', v);
            },
          ),
          if (_grantsAdmin(role)) ...[
            const SizedBox(height: 8),
            const Text('This role can open admin screens, including this one.',
                style: TextStyle(fontSize: 12, color: DashUi.indigo, fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: 10),
          const Divider(height: 1, color: DashUi.line),
          _toggleRow('is_lead', 'Lead', 'Shows the lead badge in the tech app.'),
          const Divider(height: 1, color: DashUi.line),
          _toggleRow('can_collect_payment', 'Can collect payment', 'Can take card payments on jobs in the tech app.'),
        ],
      ),
    );
  }

  Widget _profileSection() {
    final nameChanged = _draft.containsKey('name');
    return _section(
      title: 'Profile',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _grid([
            _textField('name', 'Name', _nameCtl,
                helper: nameChanged
                    ? 'Must match Service Fusion exactly. Past work days and ledger rows are renamed when you save.'
                    : 'Must match Service Fusion exactly. That\'s how jobs find this person.',
                helperColor: nameChanged ? _T.amberFg : null),
            _textField('username', 'Username', _usernameCtl, helper: 'What they type to log in.'),
            _textField('email', 'Email', _emailCtl, type: TextInputType.emailAddress, hint: 'name@integritydoornwa.com'),
            _textField('year_joined', 'Year joined', _yearCtl,
                type: TextInputType.number,
                formatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
                hint: '${DateTime.now().year}'),
            _textField('tech_id', 'Service Fusion tech ID', _techIdCtl, hint: 'Optional'),
            _textField('avatar_url', 'Photo URL', _avatarCtl, hint: 'https://'),
          ]),
        ],
      ),
    );
  }

  Widget _recordSection() {
    return _section(
      title: 'Pay and record',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _grid([
            _textField('tool_allowance', 'Tool allowance', _allowanceCtl,
                prefix: '\$ ',
                type: const TextInputType.numberWithOptions(decimal: true),
                formatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d{0,6}(\.\d{0,2})?'))],
                hint: '0'),
            _stepperField('tenure_tier', 'Tenure tier', 0, 10),
            _stepperField('inventory_strikes', 'Inventory strikes', 0, 999),
            _stepperField('warehouse_strikes', 'Warehouse strikes', 0, 999),
          ]),
          const SizedBox(height: 10),
          const Divider(height: 1, color: DashUi.line),
          _toggleRow('five_star', '5-Star badge', 'Shown on their profile in the tech app.'),
          const Divider(height: 1, color: DashUi.line),
          _toggleRow('no_recalls', 'No-recalls badge', 'Shown on their profile in the tech app.'),
        ],
      ),
    );
  }

  Widget _loginSection(_Emp e) {
    final (String label, Color fg, Color bg) = !e.hasPin
        ? ('No PIN yet', _T.amberFg, _T.amberBg)
        : e.needsPinChange
            ? ('Must choose a new PIN at next login', DashUi.sky, _T.skyBg)
            : ('PIN set', _T.goodFg, _T.goodBg);
    return _section(
      title: 'Login',
      child: Row(
        children: [
          _chip(label, fg, bg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Logs in as ${e.username.isEmpty ? 'no username' : e.username}. PINs are stored encrypted, so nobody can look one up.',
              style: const TextStyle(fontSize: 12.5, color: DashUi.slate),
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: _resetPin,
            icon: const Icon(Icons.key_rounded, size: 16),
            label: Text(e.hasPin ? 'Reset PIN' : 'Set temporary PIN', style: const TextStyle(fontWeight: FontWeight.w700)),
            style: OutlinedButton.styleFrom(
              foregroundColor: DashUi.ink,
              side: const BorderSide(color: DashUi.line),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _historySection() {
    Widget body;
    if (_historyLoading) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    } else if ((_history ?? const []).isEmpty) {
      body = const Text('No changes recorded yet. Every edit made here is logged with who made it and when.',
          style: TextStyle(fontSize: 13, color: DashUi.muted));
    } else {
      final fmt = DateFormat('MMM d, y  h:mm a');
      body = Column(
        children: [
          for (var i = 0; i < _history!.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(border: i == 0 ? null : const Border(top: BorderSide(color: DashUi.line))),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _historyLine(_history![i]),
                        if (_history![i].note != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(_history![i].note!, style: const TextStyle(fontSize: 12, color: DashUi.muted)),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(_history![i].at == null ? '' : fmt.format(_history![i].at!),
                          style: const TextStyle(fontSize: 12, color: DashUi.slate, fontFeatures: _figures)),
                      Text(_history![i].by, style: const TextStyle(fontSize: 12, color: DashUi.muted)),
                    ],
                  ),
                ],
              ),
            ),
        ],
      );
    }
    return _section(title: 'Change history', child: body);
  }

  Widget _historyLine(_Change c) {
    const labelStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.ink);
    if (c.field == 'created') {
      return Text('Added to the team as ${c.newValue ?? ''}', style: labelStyle);
    }
    if (c.field == 'pin') return const Text('PIN reset', style: labelStyle);
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: '${c.label}  ', style: labelStyle),
        TextSpan(
            text: _displayAudit(c.field, c.oldValue),
            style: const TextStyle(fontSize: 13, color: DashUi.muted, fontFeatures: _figures)),
        const TextSpan(text: '  to  ', style: TextStyle(fontSize: 12, color: DashUi.muted)),
        TextSpan(
            text: _displayAudit(c.field, c.newValue),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.ink, fontFeatures: _figures)),
      ]),
    );
  }

  // ---- Building blocks ------------------------------------------------------

  Widget _section({required String title, String? subtitle, Widget? trailing, required Widget child}) {
    return Container(
      decoration: DashUi.panel(),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: DashUi.ink)),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(subtitle, style: const TextStyle(fontSize: 12.5, color: DashUi.muted, fontWeight: FontWeight.w500)),
                    ],
                  ],
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }

  Widget _changedTag(String key) {
    if (!_draft.containsKey(key)) return const SizedBox.shrink();
    return Text('was ${_display(key, _base(key))}',
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.indigo, fontFeatures: _figures));
  }

  Widget _grid(List<Widget> items) {
    return LayoutBuilder(builder: (context, c) {
      final two = c.maxWidth >= 560;
      final w = two ? (c.maxWidth - 16) / 2 : c.maxWidth;
      return Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [for (final i in items) SizedBox(width: w, child: i)],
      );
    });
  }

  Widget _fieldLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: DashUi.slate)),
      );

  InputDecoration _dec(String key, {String? hint, String? prefix}) {
    final changed = _draft.containsKey(key);
    OutlineInputBorder b(Color c, [double w = 1]) =>
        OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: c, width: w));
    return InputDecoration(
      isDense: true,
      filled: true,
      fillColor: changed ? _T.changedFill : _T.field,
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 14, color: DashUi.muted, fontWeight: FontWeight.w500),
      prefixText: prefix,
      prefixStyle: const TextStyle(fontSize: 14, color: DashUi.slate, fontWeight: FontWeight.w600),
      errorText: _fieldErrors[key],
      errorMaxLines: 3,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: b(DashUi.line),
      enabledBorder: b(changed ? DashUi.indigo.withValues(alpha: 0.45) : DashUi.line),
      focusedBorder: b(DashUi.ink, 1.4),
      errorBorder: b(_T.badFg),
      focusedErrorBorder: b(_T.badFg, 1.4),
    );
  }

  Widget _textField(
    String key,
    String label,
    TextEditingController ctl, {
    String? helper,
    Color? helperColor,
    String? hint,
    String? prefix,
    TextInputType? type,
    List<TextInputFormatter>? formatters,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel(label),
        TextField(
          controller: ctl,
          keyboardType: type,
          inputFormatters: formatters,
          style: const TextStyle(fontSize: 14, color: DashUi.ink, fontWeight: FontWeight.w600),
          decoration: _dec(key, hint: hint, prefix: prefix),
          onChanged: (t) {
            final v = t.trim();
            switch (key) {
              case 'year_joined':
                _set(key, v.isEmpty ? null : int.tryParse(v));
                break;
              case 'tool_allowance':
                _set(key, double.tryParse(v) ?? 0.0);
                break;
              default:
                _set(key, v);
            }
          },
        ),
        if (helper != null && _fieldErrors[key] == null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(helper,
                style: TextStyle(
                    fontSize: 12,
                    color: helperColor ?? DashUi.muted,
                    fontWeight: helperColor == null ? FontWeight.w500 : FontWeight.w600,
                    height: 1.35)),
          ),
      ],
    );
  }

  Widget _stepperField(String key, String label, int min, int max) {
    final v = _d(_value(key)).round();
    final changed = _draft.containsKey(key);
    Widget btn(IconData icon, int next) {
      final enabled = next >= min && next <= max;
      return IconButton(
        onPressed: enabled ? () => _set(key, next) : null,
        icon: Icon(icon, size: 18),
        color: DashUi.ink,
        disabledColor: DashUi.line,
        visualDensity: VisualDensity.compact,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel(label),
        Container(
          height: 46,
          decoration: BoxDecoration(
            color: changed ? _T.changedFill : _T.field,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: changed ? DashUi.indigo.withValues(alpha: 0.45) : DashUi.line),
          ),
          child: Row(
            children: [
              btn(Icons.remove_rounded, v - 1),
              Expanded(
                child: Text('$v',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: DashUi.ink, fontFeatures: _figures)),
              ),
              btn(Icons.add_rounded, v + 1),
            ],
          ),
        ),
        if (_fieldErrors[key] != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_fieldErrors[key]!, style: const TextStyle(fontSize: 12, color: _T.badFg)),
          ),
      ],
    );
  }

  Widget _toggleRow(String key, String title, String subtitle) {
    final on = _value(key) == true;
    final changed = _draft.containsKey(key);
    return InkWell(
      onTap: () => _set(key, !on),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: DashUi.ink)),
                      if (changed) ...[
                        const SizedBox(width: 8),
                        Container(width: 6, height: 6, decoration: const BoxDecoration(color: DashUi.indigo, shape: BoxShape.circle)),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, style: const TextStyle(fontSize: 12.5, color: DashUi.slate)),
                  if (_fieldErrors[key] != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(_fieldErrors[key]!, style: const TextStyle(fontSize: 12, color: _T.badFg)),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Switch(
              value: on,
              onChanged: (v) => _set(key, v),
              activeTrackColor: DashUi.emeraldDeep,
              inactiveTrackColor: DashUi.line,
              inactiveThumbColor: Colors.white,
              trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
            ),
          ],
        ),
      ),
    );
  }

  Widget _note(IconData icon, String text, {required Color fg, required Color bg, Color? line}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: line == null ? null : Border.all(color: line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12.5, color: fg, fontWeight: FontWeight.w600, height: 1.4))),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared small widgets
// ---------------------------------------------------------------------------

Widget _chip(String text, Color fg, Color bg) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
    child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
  );
}

Widget _segmented<V>({
  required V value,
  required List<(V, String)> options,
  required ValueChanged<V> onChanged,
  Color activeColor = DashUi.ink,
}) {
  return Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(10)),
    child: Row(
      children: [
        for (final o in options)
          Expanded(
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => onChanged(o.$1),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: o.$1 == value ? Colors.white : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: o.$1 == value ? DashUi.line : Colors.transparent),
                  ),
                  child: Text(
                    o.$2,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: o.$1 == value ? FontWeight.w800 : FontWeight.w600,
                      color: o.$1 == value ? activeColor : DashUi.slate,
                      fontFeatures: _figures,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

Widget _inkButton(String label, VoidCallback? onPressed, {IconData? icon, bool danger = false}) {
  final style = FilledButton.styleFrom(
    backgroundColor: danger ? _T.badFg : DashUi.ink,
    foregroundColor: Colors.white,
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
  );
  final text = Text(label, style: const TextStyle(fontWeight: FontWeight.w700));
  return icon == null
      ? FilledButton(onPressed: onPressed, style: style, child: text)
      : FilledButton.icon(onPressed: onPressed, style: style, icon: Icon(icon, size: 18), label: text);
}

Widget _ghostButton(String label, VoidCallback? onPressed) {
  return TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      foregroundColor: DashUi.slate,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
    ),
    child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
  );
}

Widget _dialog({required String title, required Widget body, required List<Widget> actions, double width = 440}) {
  return Dialog(
    backgroundColor: Colors.white,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: width),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: DashUi.ink, letterSpacing: -0.3)),
            const SizedBox(height: 14),
            Flexible(child: SingleChildScrollView(child: body)),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  actions[i],
                ],
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _Hoverable extends StatefulWidget {
  final VoidCallback onTap;
  final Widget Function(bool hover) builder;
  const _Hoverable({required this.onTap, required this.builder});

  @override
  State<_Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<_Hoverable> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: widget.builder(_hover),
      ),
    );
  }
}

class _ApiError implements Exception {
  final String message;
  final String? field;
  _ApiError(this.message, this.field);
  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// Add employee
// ---------------------------------------------------------------------------

class _AddEmployeeDialog extends StatefulWidget {
  final List<_Role> roles;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> data) submit;
  const _AddEmployeeDialog({required this.roles, required this.submit});

  @override
  State<_AddEmployeeDialog> createState() => _AddEmployeeDialogState();
}

class _AddEmployeeDialogState extends State<_AddEmployeeDialog> {
  final _name = TextEditingController();
  final _username = TextEditingController();
  String _role = 'Technician';
  double _weight = 1.0;
  bool _eligible = true;
  bool _usernameTouched = false;
  bool _busy = false;
  String? _error;
  String? _errorField;

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    super.dispose();
  }

  String _suggest(String name) {
    final parts = name.trim().toLowerCase().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '';
    String clean(String s) => s.replaceAll(RegExp(r'[^a-z0-9]'), '');
    final first = clean(parts.first);
    if (parts.length == 1) return first;
    return (first.isEmpty ? '' : first.substring(0, 1)) + clean(parts.last);
  }

  void _roleChanged(String role) {
    final r = role.toLowerCase();
    setState(() {
      _role = role;
      if (r.contains('lead')) {
        _weight = 1.5;
        _eligible = true;
      } else if (r.contains('tech')) {
        _weight = 1.0;
        _eligible = true;
      } else {
        _weight = 0;
        _eligible = false;
      }
    });
  }

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
      _errorField = null;
    });
    try {
      final result = await widget.submit({
        'name': _name.text.trim(),
        'username': _username.text.trim(),
        'role': _role,
        'tech_weight': _weight,
        'is_commission_eligible': _eligible,
        'is_lead': _role.toLowerCase().contains('lead'),
      });
      if (mounted) Navigator.pop(context, result);
    } on _ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
        _errorField = e.field;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Couldn\'t add this employee. ($e)';
      });
    }
  }

  InputDecoration _dec(String field, String hint) => InputDecoration(
        isDense: true,
        filled: true,
        fillColor: _T.field,
        hintText: hint,
        hintStyle: const TextStyle(color: DashUi.muted, fontSize: 14),
        errorText: _errorField == field ? _error : null,
        errorMaxLines: 3,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: DashUi.line)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: DashUi.line)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: DashUi.ink)),
      );

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6, top: 14),
        child: Text(t, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: DashUi.slate)),
      );

  @override
  Widget build(BuildContext context) {
    final canSubmit = !_busy && _name.text.trim().isNotEmpty && _username.text.trim().length >= 2;
    return _dialog(
      title: 'Add employee',
      width: 480,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('They\'ll get a temporary PIN and choose their own at first login.',
              style: TextStyle(fontSize: 13, color: DashUi.slate)),
          _label('Full name, exactly as in Service Fusion'),
          TextField(
            controller: _name,
            autofocus: true,
            decoration: _dec('name', 'First Last'),
            onChanged: (v) => setState(() {
              if (!_usernameTouched) _username.text = _suggest(v);
            }),
          ),
          _label('Username'),
          TextField(
            controller: _username,
            decoration: _dec('username', 'jsmith'),
            onChanged: (_) => setState(() => _usernameTouched = true),
          ),
          _label('Role'),
          DropdownButtonFormField<String>(
            value: widget.roles.any((r) => r.name == _role) ? _role : null,
            isExpanded: true,
            borderRadius: BorderRadius.circular(12),
            dropdownColor: Colors.white,
            decoration: _dec('role', 'Choose a role'),
            items: [for (final r in widget.roles) DropdownMenuItem(value: r.name, child: Text(r.name))],
            onChanged: (v) {
              if (v != null) _roleChanged(v);
            },
          ),
          _label('Commission weight'),
          _segmented<double>(
            value: _weight,
            options: [for (final p in _weightPresets) (p.$1, '${_fmtW(p.$1)}  ${p.$2}')],
            onChanged: (v) => setState(() => _weight = v),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Expanded(
                child: Text('Commission eligible',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: DashUi.ink)),
              ),
              Switch(
                value: _eligible,
                onChanged: (v) => setState(() => _eligible = v),
                activeTrackColor: DashUi.emeraldDeep,
                inactiveTrackColor: DashUi.line,
                inactiveThumbColor: Colors.white,
                trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
              ),
            ],
          ),
          if (_error != null && _errorField == null) ...[
            const SizedBox(height: 6),
            Text(_error!, style: const TextStyle(fontSize: 12.5, color: _T.badFg, fontWeight: FontWeight.w600)),
          ],
        ],
      ),
      actions: [
        _ghostButton('Cancel', _busy ? null : () => Navigator.pop(context)),
        _inkButton(_busy ? 'Adding…' : 'Add employee', canSubmit ? _go : null),
      ],
    );
  }
}
