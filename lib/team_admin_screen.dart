import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'config/api_config.dart';
import 'config/access.dart';
import 'config/auth_session.dart';
import 'utils/avatar_image.dart';
import 'widgets/animated_select.dart';
import 'widgets/app_dialog.dart';
import 'widgets/dashboard_kit.dart';

// ---------------------------------------------------------------------------
// Team admin: every login in the users table, editable in place.
//
// Left: the roster (search, grouped by kind of work, inactive people at the bottom).
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
  static const field = Colors.white;
  static const changedFill = Color(0xFFEEF2FF);
  static const amberBg = Color(0xFFFFFBEB);
  static const amberFg = Color(0xFF92400E);
  static const goodBg = Color(0xFFECFDF5);
  static const goodFg = Color(0xFF047857);
  static const badBg = Color(0xFFFEF2F2);
  static const badFg = Color(0xFFB91C1C);
}

const List<FontFeature> _figures = [FontFeature.tabularFigures()];
const Duration _timeout = Duration(seconds: 20);

const Set<String> _boolKeys = {
  'is_commission_eligible',
  'is_sales_commission_eligible',
  'is_callback_eligible',
  'is_lead',
  'can_collect_payment',
  'can_see_commissions',
  'five_star',
  'no_recalls',
  'badge_top_producer',
  'badge_zero_strikes',
  'badge_team_favorite',
};
const Set<String> _nullableText = {'email', 'tech_id', 'avatar_url', 'job_title'};
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
  'job_title': 'Job title',
  'status': 'Status',
  'year_joined': 'Year joined',
  'hire_date': 'Date joined',
  'tenure_tier': 'Tenure tier',
  'tool_allowance': 'Tool allowance',
  'tech_weight': 'Commission weight',
  'is_commission_eligible': 'Commission eligible',
  'is_sales_commission_eligible': 'Sales commission',
  'is_callback_eligible': 'Callback pay eligible',
  'is_lead': 'Lead',
  'can_collect_payment': 'Can collect payment',
  'can_see_commissions': 'Can see commissions',
  'five_star': '5-Star Reviews badge',
  'no_recalls': 'Callback-Free badge',
  'badge_top_producer': 'Top Producer badge',
  'badge_zero_strikes': 'Zero Strikes badge',
  'badge_team_favorite': 'Team Favorite badge',
  'access_denied': 'Access',
  'inventory_strikes': 'Inventory strikes',
  'warehouse_strikes': 'Warehouse strikes',
  'tech_id': 'Service Fusion tech ID',
  'avatar_url': 'Photo',
};

/// Draft value for `access_denied` is the list of keys that are ALLOWED (what the pills show); the
/// server stores the opposite, the keys switched off. Keys come from config/access.dart.
List<String> _allowedFrom(dynamic denied) => [
  for (final k in kAllAccessKeys)
    if (denied is! List || !denied.contains(k)) k,
];

/// Admins (John and Ryan) see everything, so they get no permissions card. This is the Admin and
/// Owner roles only: Sales Account Manager (Heather) is not an admin.
bool _isOwnerAdmin(String role) => const {'admin', 'owner'}.contains(role.trim().toLowerCase());

/// What people are actually called, and the system role each one runs on. The role drives pay, permissions and the
/// admin check, so picking a title sets both; the first title listed for a role is what that role is called by default.
const List<(String, String)> _roleTitles = [
  ('Owner', 'Owner'),
  ('Admin', 'Admin'),
  ('Lead Technician', 'Lead Technician'),
  ('Technician', 'Technician'),
  ('Residential Technician', 'Technician'),
  ('Warehouse Technician', 'Warehouse'),
  ('Office Manager', 'Office Manager'),
  ('Sales Account Manager', 'Office Manager'),
  ('Commercial Estimator', 'Sales Rep'),
  ('Office', 'Office'),
];

/// The title a person shows as: their job title when it is one of the known ones (or any custom one already saved),
/// otherwise the default title of their role.
String? _titleFor(String jobTitle, String role) {
  final t = jobTitle.trim();
  if (t.isNotEmpty) return t;
  for (final o in _roleTitles) {
    if (o.$2.toLowerCase() == role.trim().toLowerCase()) return o.$1;
  }
  return null;
}

/// A badge, named for the KPI it recognises. Set by hand on the Team screen; shown next to the photo and in the tech app.
class _Badge {
  final String key;
  final String label;
  final String meaning;
  final IconData icon;
  final Color color;
  final Color fg;
  final Color bg;
  const _Badge(this.key, this.label, this.meaning, this.icon, this.color, this.fg, this.bg);
}

const List<_Badge> _badges = [
  _Badge(
    'is_lead',
    'Lead',
    'Leads a crew. Shows in the tech app; pay comes from the commission weight.',
    Icons.workspace_premium_rounded,
    DashUi.indigo,
    DashUi.indigo,
    Color(0xFFEEF2FF),
  ),
  _Badge(
    'five_star',
    '5-Star Reviews',
    'Customer rating KPI: consistently rated 5 stars in customer reviews.',
    Icons.star_rounded,
    DashUi.amber,
    Color(0xFF92400E),
    Color(0xFFFFFBEB),
  ),
  _Badge(
    'no_recalls',
    'Callback-Free',
    'Callback streak KPI: no callbacks since go-live.',
    Icons.verified_rounded,
    DashUi.emeraldDeep,
    DashUi.emeraldDeep,
    Color(0xFFECFDF5),
  ),
  _Badge(
    'badge_top_producer',
    'Top Producer',
    'Labor per day KPI: ahead of the rest of the team.',
    Icons.trending_up_rounded,
    DashUi.sky,
    Color(0xFF0369A1),
    Color(0xFFF0F9FF),
  ),
  _Badge(
    'badge_zero_strikes',
    'Zero Strikes',
    'Inventory KPI: no inventory strikes.',
    Icons.inventory_2_rounded,
    DashUi.emeraldDeep,
    DashUi.emeraldDeep,
    Color(0xFFECFDF5),
  ),
  _Badge(
    'badge_team_favorite',
    'Team Favorite',
    'Peer rating KPI: top-rated by teammates.',
    Icons.groups_rounded,
    DashUi.indigo,
    DashUi.indigo,
    Color(0xFFEEF2FF),
  ),
];

const List<(double, String)> _weightPresets = [(0.0, 'No share'), (1.0, 'Standard'), (1.5, 'Lead')];

double _d(dynamic v) {
  if (v is num) return v.toDouble();
  return double.tryParse(v?.toString() ?? '') ?? 0.0;
}

String _s(dynamic v) => v?.toString() ?? '';

bool _isActiveStatus(dynamic v) {
  final s = _s(v).trim().toLowerCase();
  return s.isEmpty || s == 'active';
}

/// 0, 1, 1.5, 1.25 (no trailing zeros), so the roster, editor, history and Add dialog all agree.
String _fmtW(double w) {
  if (w == w.roundToDouble()) return w.toStringAsFixed(0);
  return w.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
}

/// Roles come back in whatever casing the database holds ("ADMIN", "warehouse"); show the canonical one.
String _roleLabel(String role, List<_Role> roles) {
  final r = role.trim();
  if (r.isEmpty) return 'No role';
  for (final x in roles) {
    if (x.name.toLowerCase() == r.toLowerCase()) return x.name;
  }
  return r[0].toUpperCase() + r.substring(1).toLowerCase();
}

/// The job title if one is set, else the role: what the person is called, as opposed to what they can do.
String _titleLabel(String jobTitle, String role, List<_Role> roles) =>
    _titleFor(jobTitle, role) ?? _roleLabel(role, roles);

/// "dash_financial.view" -> "Dashboards · Financial (view)".
String _accessKeyLabel(String key) {
  for (final g in kAccessGroups) {
    for (final r in g.items) {
      for (final a in AccessAction.values) {
        if (r.actions.contains(a) && r.keyFor(a) == key) {
          return a == AccessAction.view
              ? '${g.title} · ${r.label}'
              : '${g.title} · ${r.label} (${a.label.toLowerCase()})';
        }
      }
    }
  }
  return key;
}

bool _same(dynamic a, dynamic b) {
  if (a is List && b is List) return a.length == b.length && a.every(b.contains);
  if (a is num && b is num) return (a - b).abs() < 1e-9;
  return a == b;
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
  String get jobTitle => _s(raw['job_title']).trim();
  bool get active => _isActiveStatus(raw['status']);
  double get weight => raw['tech_weight'] == null ? 1.0 : _d(raw['tech_weight']);
  bool get commissionEligible => raw['is_commission_eligible'] == true;
  bool get callbackEligible => raw['is_callback_eligible'] == true;
  bool get hasPin => raw['has_pin'] == true;
  bool get needsPinChange => raw['needs_pin_change'] == true;
  String get version => _s(raw['version']);
  String get avatarUrl => _s(raw['avatar_url']).trim();
  int get workDays90 => _d(raw['work_days_90']).round();
  bool get isField => role.toLowerCase().contains('tech');
  bool get unmatched => active && isField && workDays90 == 0;

  /// The group a person is listed under in the roster. Inactive people always go last.
  int get group {
    if (!active) return 5;
    final r = role.toLowerCase();
    if (r.contains('tech')) return 0;
    // Sales by role or by job title, so Heather (Office Manager, "Sales Account Manager") sits with Zac.
    final isSales =
        r.contains('sales') || jobTitle.toLowerCase().contains('sales') || raw['is_sales_commission_eligible'] == true;
    if (isSales) return 1;
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

const List<String> _groupNames = ['Field team', 'Sales', 'Office and admin', 'Warehouse', 'Other', 'Inactive'];

class _Resp {
  final int status;
  final Map<String, dynamic> body;
  const _Resp(this.status, this.body);
  bool get ok => status == 200 && body['success'] == true;
  String error(String fallback) {
    final e = _s(body['error']);
    return e.isNotEmpty ? e : fallback;
  }
}

/// One place for every call: auth headers, a timeout, 401 = sign out, and a readable message when the
/// server (or Render in front of it) answers with something that isn't our JSON.
Future<_Resp> _send(String method, Uri uri, {Object? body}) async {
  final h = AuthSession.instance.headers();
  final http.Response res;
  try {
    final Future<http.Response> req = switch (method) {
      'GET' => http.get(uri, headers: h),
      'POST' => http.post(uri, headers: h, body: body == null ? null : jsonEncode(body)),
      _ => http.patch(uri, headers: h, body: jsonEncode(body)),
    };
    res = await req.timeout(_timeout);
  } on TimeoutException {
    throw _ApiError('The server took too long to answer. Check your connection and try again.', null);
  } catch (_) {
    throw _ApiError("Couldn't reach the server. Check your connection and try again.", null);
  }
  if (res.statusCode == 401) {
    AuthSession.instance.logout();
    throw _ApiError('Your session expired. Please sign in again.', null);
  }
  Map<String, dynamic> data = const {};
  try {
    final d = jsonDecode(res.body);
    if (d is Map) data = Map<String, dynamic>.from(d);
  } catch (_) {}
  if (data.isEmpty && res.statusCode != 200) {
    throw _ApiError('The server had a problem (${res.statusCode}). Try again in a moment.', null);
  }
  return _Resp(res.statusCode, data);
}

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
  String? _historyError;
  int _historyReq = 0;
  bool _pinBusy = false;
  // Which collapsible blocks are open, so their chevrons keep in step when the screen rebuilds.
  final Set<String> _openTiles = {};
  bool _refreshing = false;

  String _query = '';
  String _filter = 'all'; // all | field | office | inactive
  final _searchCtl = TextEditingController();
  final _detailScroll = ScrollController();
  final _weightCtl = TextEditingController();

  final _firstCtl = TextEditingController();
  final _lastCtl = TextEditingController();
  final _usernameCtl = TextEditingController();
  final _emailCtl = TextEditingController();
  final _yearCtl = TextEditingController();
  final _techIdCtl = TextEditingController();
  final _jobTitleCtl = TextEditingController();
  final _allowanceCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [
      _searchCtl,
      _firstCtl,
      _lastCtl,
      _usernameCtl,
      _emailCtl,
      _yearCtl,
      _techIdCtl,
      _jobTitleCtl,
      _allowanceCtl,
      _weightCtl,
    ]) {
      c.dispose();
    }
    _detailScroll.dispose();
    super.dispose();
  }

  /// True when [e] is the person signed in to this app. The server refuses to let you deactivate
  /// yourself or drop your own admin access; the screen says so up front instead.
  bool _isMe(_Emp e) {
    final me = AuthSession.instance.name.trim().toLowerCase();
    return me.isNotEmpty && me == e.name.toLowerCase();
  }

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
      final res = await _send('GET', _uri(''));
      final body = res.body;
      if (!res.ok) throw _ApiError(res.error('Server returned ${res.status}.'), null);
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
      // Keep the person you were on (and any edits in progress); otherwise start with nobody picked.
      final keep = keepSelection && _selected != null;
      if (keep && !_dirty) {
        _openEmployee(_selected!, force: true);
      } else if (!keep) {
        setState(() => _selectedId = null);
      }
    } on _ApiError catch (e) {
      _fail("Couldn't load employees. ${e.message}");
    } catch (e) {
      _fail("Couldn't load employees. ${e.toString().replaceFirst('Exception: ', '')}");
    }
  }

  /// Reload the roster without losing the person you're on or what you've typed.
  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final before = _draft.length;
    await _load();
    if (!mounted) return;
    setState(() => _refreshing = false);
    if (_error == null) {
      _toast(
        before > 0
            ? 'Refreshed. Your $before unsaved ${before == 1 ? 'change is' : 'changes are'} still here.'
            : 'Team refreshed.',
      );
    }
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
      _historyError = null;
      _history = null;
    });
    try {
      final res = await _send('GET', _uri('/$id/history'));
      if (!mounted || req != _historyReq) return;
      if (!res.ok) throw _ApiError(res.error("Couldn't load the change history."), null);
      final list = ((res.body['history'] as List?) ?? const [])
          .whereType<Map>()
          .map((h) => _Change(Map<String, dynamic>.from(h)))
          .toList();
      setState(() {
        _history = list;
        _historyLoading = false;
      });
    } catch (e) {
      if (!mounted || req != _historyReq) return;
      setState(() {
        _history = null;
        _historyLoading = false;
        _historyError = e is _ApiError ? e.message : "Couldn't load the change history.";
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

  bool _grantsAdmin(String role) => _roles.any((r) => r.name.toLowerCase() == role.toLowerCase() && r.grantsAdmin);

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
      case 'access_denied':
        return _allowedFrom(v);
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
      // Admins see everything and get no permissions card, so edits to it can't be saved by accident.
      if (key == 'role' && _isOwnerAdmin(_s(_value('role')))) _draft.remove('access_denied');
    });
  }

  /// The name is stored as one string ("First Last", matching Service Fusion). Split at the first space for the two boxes.
  void _setNameBoxes(String full) {
    final t = full.trim();
    final i = t.indexOf(' ');
    _firstCtl.text = i < 0 ? t : t.substring(0, i);
    _lastCtl.text = i < 0 ? '' : t.substring(i + 1).trim();
  }

  void _nameBoxesChanged() => _set('name', '${_firstCtl.text.trim()} ${_lastCtl.text.trim()}'.trim());

  void _fillControllers(_Emp e) {
    _setNameBoxes(e.name);
    _usernameCtl.text = e.username;
    _emailCtl.text = _s(e.raw['email']);
    final y = _norm('year_joined', e.raw['year_joined']);
    _yearCtl.text = y == null ? '' : '$y';
    _techIdCtl.text = _s(e.raw['tech_id']);
    _jobTitleCtl.text = _s(e.raw['job_title']);
    final a = _d(e.raw['tool_allowance']);
    _allowanceCtl.text = a == 0 ? '' : a.toStringAsFixed(a == a.roundToDouble() ? 0 : 2);
    _weightCtl.text = _fmtW(e.weight);
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
      if (k == 'access_denied' && _isOwnerAdmin(_s(_value('role')))) return;
      if (k == 'access_denied' && v is List) {
        out[k] = [
          for (final key in kAllAccessKeys)
            if (!v.contains(key)) key,
        ];
      } else {
        out[k] = (_nullableText.contains(k) && v is String && v.isEmpty) ? null : v;
      }
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
      final res = await _send('PATCH', _uri('/${e.id}'), body: {'changes': _payload(), 'version': e.version});
      final body = res.body;
      if (!mounted) return;

      if (res.ok) {
        final updated = e.mergedFrom(Map<String, dynamic>.from(body['user'] as Map));
        final renamed = _d(body['renamedRows']).round();
        setState(() {
          _replaceUser(updated);
          _draft.clear();
          _saving = false;
        });
        _fillControllers(updated);
        _loadHistory(updated.id);
        _toast(
          renamed > 0
              ? 'Saved ${updated.name}. Renamed $renamed past work-day and ledger rows to match.'
              : 'Saved ${updated.name}.',
        );
        return;
      }

      setState(() => _saving = false);
      if (res.status == 409 && body['conflict'] == true && body['user'] is Map) {
        await _showConflict(e, Map<String, dynamic>.from(body['user'] as Map));
        return;
      }
      final msg = res.error('Save failed (${res.status}).');
      final field = body['field'];
      if (field is String && field.isNotEmpty) setState(() => _fieldErrors = {field: msg});
      _toast(msg, error: true);
    } on _ApiError catch (err) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('${err.message} Your changes are still here.', error: true);
    } catch (err) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast("Couldn't save. Your changes are still here.", error: true);
    }
  }

  Future<void> _resetPin() async {
    final e = _selected;
    if (e == null) return;
    if (_pinBusy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => _dialog(
        title: 'Reset ${e.name.split(' ').first}\'s PIN?',
        icon: Icons.key_rounded,
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
    if (ok != true || !mounted) return;
    setState(() => _pinBusy = true);
    try {
      final res = await _send('POST', _uri('/${e.id}/reset-pin'));
      if (!mounted) return;
      if (res.ok) {
        setState(() => _replaceUser(e.mergedFrom(Map<String, dynamic>.from(res.body['user'] as Map))));
        _loadHistory(e.id);
        await _showPin(e.name, _s(res.body['tempPin']));
      } else {
        _toast(res.error("Couldn't reset the PIN."), error: true);
      }
    } on _ApiError catch (err) {
      if (mounted) _toast(err.message, error: true);
    } catch (_) {
      if (mounted) _toast("Couldn't reset the PIN.", error: true);
    } finally {
      if (mounted) setState(() => _pinBusy = false);
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
          final res = await _send('POST', _uri(''), body: data);
          if (res.ok) return res.body;
          final f = res.body['field'];
          throw _ApiError(res.error('Server returned ${res.status}.'), f is String ? f : null);
        },
      ),
    );
    if (result == null || !mounted) return;
    final created = _Emp(Map<String, dynamic>.from(result['user'] as Map));
    setState(() {
      _users = [..._users, created]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
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
        icon: Icons.undo_rounded,
        iconColor: _T.badFg,
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
      notes.add(
        'Open jobs recalculate on the next Service Fusion sync, about 3 minutes. Jobs already paid keep their old weight.',
      );
    }
    if (_draft.containsKey('name')) {
      notes.add(
        'Past work days and ledger rows are renamed too. Service Fusion must use the new name, or new jobs won\'t match.',
      );
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
        icon: Icons.fact_check_outlined,
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
                            child: Text(
                              _labels[keys[i]]!,
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.slate),
                            ),
                          ),
                          Text(
                            _display(keys[i], _base(keys[i])),
                            style: const TextStyle(
                              fontSize: 13.5,
                              color: DashUi.muted,
                              decoration: TextDecoration.lineThrough,
                              fontFeatures: _figures,
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Icon(Icons.arrow_forward_rounded, size: 14, color: DashUi.muted),
                          ),
                          Text(
                            _display(keys[i], _draft[keys[i]]),
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w800,
                              color: DashUi.ink,
                              fontFeatures: _figures,
                            ),
                          ),
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
                  Expanded(
                    child: Text(n, style: const TextStyle(fontSize: 12.5, color: DashUi.slate, height: 1.4)),
                  ),
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
    final kept = Map<String, dynamic>.from(_draft);
    await showDialog<void>(
      context: context,
      builder: (ctx) => _dialog(
        title: '${e.name} was changed by someone else',
        icon: Icons.sync_problem_rounded,
        body: Text(
          'Someone saved changes to this employee after you opened them. We\'ll load the latest and keep your '
          '${kept.length} unsaved ${kept.length == 1 ? 'edit' : 'edits'} on top. Check them, then save again.',
          style: const TextStyle(fontSize: 14, color: DashUi.slate, height: 1.45),
        ),
        actions: [_inkButton('Load latest, keep my edits', () => Navigator.pop(ctx))],
      ),
    );
    if (!mounted) return;
    final updated = e.mergedFrom(fresh);
    setState(() {
      _replaceUser(updated);
      _draft.clear();
    });
    _fillControllers(updated);
    // Put the edits back on top of the fresh row (anything that now matches it drops out).
    setState(() {
      kept.forEach((k, v) {
        if (!_same(v, _base(k))) _draft[k] = v;
      });
    });
    _syncControllersToDraft();
    _loadHistory(updated.id);
  }

  void _syncControllersToDraft() {
    String text(dynamic v) => v == null ? '' : '$v';
    for (final k in _draft.keys) {
      final v = _draft[k];
      switch (k) {
        case 'name':
          _setNameBoxes(text(v));
        case 'username':
          _usernameCtl.text = text(v);
        case 'email':
          _emailCtl.text = text(v);
        case 'year_joined':
          _yearCtl.text = text(v);
        case 'tech_id':
          _techIdCtl.text = text(v);
        case 'job_title':
          _jobTitleCtl.text = text(v);
        case 'tool_allowance':
          _allowanceCtl.text = _d(v) == 0 ? '' : _fmtW(_d(v));
        case 'tech_weight':
          _weightCtl.text = _fmtW(_d(v));
      }
    }
  }

  Future<void> _showPin(String name, String pin) {
    var copied = false;
    return showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => _dialog(
          title: 'Temporary PIN for ${name.split(' ').first}',
          icon: Icons.key_rounded,
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(vertical: 22),
                decoration: BoxDecoration(
                  color: _T.wash,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: DashUi.line),
                ),
                child: SelectableText(
                  pin,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 38,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 10,
                    color: DashUi.ink,
                    fontFeatures: _figures,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Give this to $name. They\'ll choose their own PIN the first time they log in. '
                'This PIN isn\'t stored anywhere you can see it again.'
                '${pin.startsWith('0') ? ' It starts with a zero, so read out every digit.' : ''}',
                style: const TextStyle(fontSize: 13, color: DashUi.slate, height: 1.45),
              ),
            ],
          ),
          actions: [
            _ghostButton(copied ? 'Copied' : 'Copy PIN', () {
              Clipboard.setData(ClipboardData(text: pin));
              setLocal(() => copied = true);
            }),
            _inkButton('Done', () => Navigator.pop(ctx)),
          ],
        ),
      ),
    );
  }

  void _toast(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          width: 460,
          backgroundColor: error ? _T.badFg : DashUi.ink,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      );
  }

  // ---- Photo ----------------------------------------------------------------

  bool _photoBusy = false;

  /// Pick a picture, crop it to a small square, upload it, and put its address in the draft. Like every other edit it
  /// only takes effect when "Save changes" is pressed.
  Future<void> _changePhoto() async {
    final e = _selected;
    if (e == null || _photoBusy) return;
    List<PlatformFile> picked;
    try {
      picked = await FilePicker.pickFiles(type: FileType.image);
    } catch (_) {
      _toast("Couldn't open the file picker.", error: true);
      return;
    }
    if (picked.isEmpty || !mounted) return;
    setState(() => _photoBusy = true);
    try {
      final png = await squareAvatarPng(await picked.first.readAsBytes());
      final res = await http
          .post(
            _uri('/${e.id}/avatar'),
            headers: {...AuthSession.instance.headers(json: false), 'Content-Type': 'image/png'},
            body: png,
          )
          .timeout(const Duration(seconds: 60));
      if (res.statusCode == 401) {
        AuthSession.instance.logout();
        return;
      }
      Map<String, dynamic> body = const {};
      try {
        final d = jsonDecode(res.body);
        if (d is Map) body = Map<String, dynamic>.from(d);
      } catch (_) {}
      final url = _s(body['url']);
      if (res.statusCode == 200 && url.isNotEmpty) {
        if (mounted && _selectedId == e.id) _set('avatar_url', url);
      } else {
        final msg = _s(body['error']);
        _toast(msg.isNotEmpty ? msg : "Couldn't upload the photo (${res.statusCode}).", error: true);
      }
    } on FormatException {
      _toast("That file couldn't be read as a picture. Try a JPEG or PNG.", error: true);
    } on TimeoutException {
      _toast('The upload took too long. Check your connection and try again.', error: true);
    } catch (_) {
      _toast("Couldn't upload the photo. Check your connection and try again.", error: true);
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  String _display(String key, dynamic v) {
    if (v == null || (v is String && v.trim().isEmpty)) return 'None';
    if (_boolKeys.contains(key)) return v == true ? 'On' : 'Off';
    if (key == 'tech_weight') return '${_fmtW(_d(v))}×';
    if (key == 'tool_allowance') return dashMoney(_d(v));
    if (key == 'access_denied' && v is List) return '${v.length} of ${kAllAccessKeys.length} allowed';
    if (key == 'avatar_url') return '$v'.contains('/api/avatars/') ? 'Uploaded photo' : 'Photo';
    return '$v';
  }

  String _displayAudit(String field, String? v) {
    if (v == null || v.isEmpty) return 'None';
    if (field == 'status') return v.toLowerCase() == 'inactive' ? 'Inactive' : 'Active';
    if (field == 'role') return _roleLabel(v, _roles);
    if (_boolKeys.contains(field)) return v == 'true' ? 'On' : (v == 'false' ? 'Off' : v);
    if (field == 'tech_weight') return '${_fmtW(_d(v))}×';
    if (field == 'tool_allowance') return dashMoney(_d(v));
    if (field == 'avatar_url') return v.contains('/api/avatars/') ? 'Uploaded photo' : 'Photo';
    return v;
  }

  // ---- Build ----------------------------------------------------------------

  List<_Emp> _visible() {
    final q = _query.trim().toLowerCase();
    final list = _users.where((u) {
      final inFilter = switch (_filter) {
        'field' => u.active && u.isField,
        'office' => u.active && !u.isField,
        'inactive' => !u.active,
        _ => true,
      };
      if (!inFilter) return false;
      if (q.isEmpty) return true;
      return u.name.toLowerCase().contains(q) ||
          u.username.toLowerCase().contains(q) ||
          _roleLabel(u.role, _roles).toLowerCase().contains(q) ||
          u.jobTitle.toLowerCase().contains(q);
    }).toList();
    list.sort((a, b) {
      final g = a.group.compareTo(b.group);
      return g != 0 ? g : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Browser/Android Back with unsaved edits asks first. (Clicking another menu item can't be
      // intercepted from here, so the save bar stays visible as the reminder.)
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await _confirmDiscard();
        if (leave == true && mounted) {
          _discard();
          if (context.mounted) Navigator.of(context).maybePop();
        }
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: Colors.white,
            // One screen, not floating cards: a slim bar on top, then the roster as a sidebar and the person filling the
            // rest of the window, edge to edge.
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  constraints: const BoxConstraints(minHeight: 56),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                  decoration: const BoxDecoration(
                    color: DashUi.ink, // the header banner colour every dashboard uses
                    boxShadow: [BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 2))],
                  ),
                  child: _header(),
                ),
                if (_loading)
                  const Expanded(child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)))
                else if (_error != null && _users.isEmpty)
                  Expanded(child: _errorState())
                else
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, c) {
                        final rosterW = c.maxWidth >= 1200 ? 340.0 : 296.0;
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(width: rosterW, child: _roster()),
                            Expanded(child: _detail()),
                          ],
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: const Text(
              'TEAM',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.2),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Refresh the team',
          onPressed: (_loading || _refreshing) ? null : _refresh,
          icon: _refreshing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.refresh_rounded, color: Colors.white, size: 20),
        ),
        const SizedBox(width: 8),
        // White on the dark banner (the usual dark button would disappear into it).
        FilledButton.icon(
          onPressed: _users.isEmpty ? null : _addEmployee,
          icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
          label: const Text('Add employee', style: TextStyle(fontWeight: FontWeight.w700)),
          style: FilledButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: DashUi.ink,
            disabledBackgroundColor: Colors.white24,
            disabledForegroundColor: Colors.white54,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
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
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: DashUi.slate, height: 1.45),
            ),
            const SizedBox(height: 16),
            _inkButton('Try again', () => _load()),
          ],
        ),
      ),
    );
  }

  // ---- Roster ---------------------------------------------------------------

  Widget _roster() {
    final list = _visible();

    final children = <Widget>[];
    int? lastGroup;
    for (final u in list) {
      if (u.group != lastGroup) {
        lastGroup = u.group;
        children.add(
          Padding(
            padding: EdgeInsets.fromLTRB(16, children.isEmpty ? 6 : 16, 16, 6),
            child: Text(
              _groupNames[u.group],
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.muted),
            ),
          ),
        );
      }
      children.add(_rosterRow(u));
    }

    return Container(
      decoration: const BoxDecoration(
        color: _T.wash,
        border: Border(right: BorderSide(color: DashUi.line)),
      ),
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
                fillColor: Colors.white,
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
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: DashUi.line),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: DashUi.line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: DashUi.ink),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Wrap(
              spacing: 4,
              runSpacing: 6,
              children: [
                for (final f in [
                  ('all', 'All', _users.length),
                  ('field', 'Field', _users.where((u) => u.active && u.isField).length),
                  ('office', 'Office', _users.where((u) => u.active && !u.isField).length),
                  ('inactive', 'Inactive', _users.where((u) => !u.active).length),
                ])
                  ChoiceChip(
                    label: Text(
                      '${f.$2} ${f.$3}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: _filter == f.$1 ? Colors.white : DashUi.slate,
                      ),
                    ),
                    selected: _filter == f.$1,
                    onSelected: (_) => setState(() => _filter = f.$1),
                    showCheckmark: false,
                    selectedColor: DashUi.ink,
                    backgroundColor: DashUi.faint,
                    side: BorderSide.none,
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
              ],
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
    final problems = [
      if (u.active && u.unmatched)
        'No Service Fusion work matched in 90 days. Check the name matches Service Fusion exactly.',
      if (u.active && !u.hasPin) 'No PIN set yet.',
    ];
    final attention = problems.isNotEmpty;
    // Only people on commission get a weight badge; for everyone else it would just say 0×.
    final showWeight = eligible || w > 0 || u.isField;
    final eligibleNoShare = eligible && w == 0;
    // Not eligible means no share, whatever weight is stored (it is ignored), so say "Off" instead of "1×".
    final badgeText = eligible ? '${_fmtW(w)}×' : 'Off';

    return _Hoverable(
      onTap: () => _openEmployee(u),
      builder: (hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: selected ? DashUi.faint : (hover ? _T.wash : DashUi.faint.withValues(alpha: 0)),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? DashUi.line : DashUi.line.withValues(alpha: 0)),
        ),
        child: Opacity(
          opacity: u.active ? 1 : 0.72,
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
                          child: Text(
                            u.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
                              color: DashUi.ink,
                            ),
                          ),
                        ),
                        if (editing) ...[
                          const SizedBox(width: 6),
                          Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(color: DashUi.indigo, shape: BoxShape.circle),
                          ),
                        ],
                      ],
                    ),
                    Text(
                      u.active
                          ? _titleLabel(u.jobTitle, u.role, _roles)
                          : '${_titleLabel(u.jobTitle, u.role, _roles)}, inactive',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: DashUi.slate, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
              if (attention)
                Tooltip(
                  message: problems.join('\n'),
                  child: const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: Icon(Icons.error_outline_rounded, size: 16, color: DashUi.amber),
                  ),
                ),
              if (showWeight)
                Tooltip(
                  message: eligibleNoShare
                      ? 'Commission eligible, but a weight of 0 earns nothing.'
                      : (!eligible ? 'Not commission eligible, so no share of job commission.' : ''),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: eligibleNoShare ? _T.amberBg : (eligible ? _T.goodBg : DashUi.faint),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      badgeText,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: eligibleNoShare ? _T.amberFg : (eligible ? _T.goodFg : DashUi.muted),
                        fontFeatures: _figures,
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

  // ---- Detail ---------------------------------------------------------------

  Widget _detail() {
    final e = _selected;
    if (e == null) {
      return Container(
        alignment: Alignment.center,
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.groups_2_outlined, size: 40, color: DashUi.muted),
            SizedBox(height: 10),
            Text(
              'Pick someone on the left',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: DashUi.ink),
            ),
            SizedBox(height: 6),
            Text(
              'See and edit their profile, pay weight, permissions and change history.',
              style: TextStyle(fontSize: 13, color: DashUi.slate),
            ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: ListView(
            controller: _detailScroll,
            padding: const EdgeInsets.only(bottom: 110),
            children: [
              // One panel, not five cards: the sections are told apart by a thin rule, so the page reads as a
              // single record for this person.
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _hero(e),
                  _sectionRule(),
                  _profileSection(e),
                  _sectionRule(),
                  _weightSection(),
                  if (!_isOwnerAdmin(_s(_value('role')))) ...[_sectionRule(), _permissionsSection()],
                  _sectionRule(),
                  _historySection(),
                ],
              ),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$n unsaved ${n == 1 ? 'change' : 'changes'}${_draft.keys.any(_sensitive.contains) ? ' · affects pay or access' : ''}',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white),
                ),
                Text(
                  _draft.keys.map((k) => _labels[k] ?? k).join(', '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.white60),
                ),
              ],
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
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: DashUi.ink),
                  )
                : const Text('Save changes', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }

  /// Why this person has a warning icon in the roster, spelled out.
  List<String> _attentionFor(_Emp e) => [
    if (e.active && e.unmatched)
      'No Service Fusion work matched this name in the last 90 days. If they are working, check the name matches '
          'Service Fusion exactly.',
    if (e.active && !e.hasPin) 'No PIN yet. Use "Set temporary PIN" below so they can log in.',
  ];

  /// The avatar, with a small camera badge. Click to upload (or replace/remove when there is one already).
  Widget _photoControl(String name, bool active) {
    final url = _s(_value('avatar_url'));
    final avatar = Stack(
      clipBehavior: Clip.none,
      children: [
        DashAvatar(
          name: name,
          imageUrl: url,
          size: 96,
          ringColor: _draft.containsKey('avatar_url') ? DashUi.indigo : (active ? DashUi.emerald : DashUi.line),
          ringWidth: 2.5,
        ),
        if (_photoBusy)
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.75), shape: BoxShape.circle),
              child: const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.4, color: DashUi.ink),
                ),
              ),
            ),
          ),
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: DashUi.line),
            ),
            child: const Icon(Icons.photo_camera_outlined, size: 16, color: DashUi.slate),
          ),
        ),
      ],
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: url.isEmpty
          ? Tooltip(
              message: 'Upload a photo',
              child: GestureDetector(onTap: _photoBusy ? null : _changePhoto, child: avatar),
            )
          : PopupMenuButton<String>(
              tooltip: 'Change photo',
              enabled: !_photoBusy,
              padding: EdgeInsets.zero,
              color: Colors.white,
              onSelected: (v) => v == 'remove' ? _set('avatar_url', '') : _changePhoto(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'upload', child: Text('Replace photo…')),
                PopupMenuItem(value: 'remove', child: Text('Remove photo')),
              ],
              child: avatar,
            ),
    );
  }

  Widget _hero(_Emp e) {
    final name = _s(_value('name'));
    final role = _s(_value('role'));
    final active = _value('status') == 'Active';
    final year = _value('year_joined');
    final joined = DateTime.tryParse(_s(_value('hire_date')));

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, c) {
              final narrow = c.maxWidth < 520;
              final me = _isMe(e);
              // One deliberate button instead of a toggle next to the name; the review step still follows.
              final status = Tooltip(
                message: me ? "You can't deactivate your own account." : '',
                child: active
                    ? OutlinedButton.icon(
                        onPressed: me ? null : () => _set('status', 'Inactive'),
                        icon: const Icon(Icons.person_off_outlined, size: 17),
                        label: const Text('Deactivate…', style: TextStyle(fontWeight: FontWeight.w700)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _T.badFg,
                          side: BorderSide(color: me ? DashUi.line : _T.badFg.withValues(alpha: 0.4)),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      )
                    : FilledButton.icon(
                        onPressed: () => _set('status', 'Active'),
                        icon: const Icon(Icons.person_add_alt_1_rounded, size: 17),
                        label: const Text('Reactivate', style: TextStyle(fontWeight: FontWeight.w700)),
                        style: FilledButton.styleFrom(
                          backgroundColor: DashUi.emeraldDeep,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
              );
              final identity = Row(
                children: [
                  _photoControl(name, active),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name.isEmpty ? 'Unnamed' : name,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: DashUi.ink,
                            letterSpacing: -0.4,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            _chip('@${_s(_value('username'))}', DashUi.slate, DashUi.faint),
                            _chip(_titleLabel(_s(_value('job_title')), role, _roles), DashUi.ink, DashUi.faint),
                            if (_grantsAdmin(role)) _chip('Admin access', DashUi.indigo, const Color(0xFFEEF2FF)),
                            if (joined != null)
                              _chip('Joined ${DateFormat.yMMMd().format(joined)}', DashUi.slate, DashUi.faint)
                            else if (year != null)
                              _chip('Joined $year', DashUi.slate, DashUi.faint),
                            for (final b in _badges)
                              if (_value(b.key) == true) _chip(b.label, b.fg, b.bg),
                            if (!active) _chip('Inactive', _T.badFg, _T.badBg),
                            if (_isMe(e)) _chip('You', DashUi.emeraldDeep, _T.goodBg),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              );
              if (narrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [identity, const SizedBox(height: 14), status],
                );
              }
              return Row(
                children: [
                  Expanded(child: identity),
                  const SizedBox(width: 12),
                  status,
                ],
              );
            },
          ),
          if (_attentionFor(e).isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final msg in _attentionFor(e))
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _note(Icons.error_outline_rounded, msg, fg: _T.amberFg, bg: _T.amberBg),
              ),
          ],
          if (_fieldErrors['status'] != null) ...[
            const SizedBox(height: 10),
            _note(Icons.error_outline_rounded, _fieldErrors['status']!, fg: _T.badFg, bg: _T.badBg),
          ],
        ],
      ),
    );
  }

  Widget _weightSection() {
    final e = _selected!;
    final w = _d(_value('tech_weight'));
    final eligible = _value('is_commission_eligible') == true;
    final isField = _s(_value('role')).toLowerCase().contains('tech');
    final isPreset = _weightPresets.any((p) => _same(p.$1, w));
    final suggestLead = _s(_value('role')).toLowerCase().contains('lead') && !_same(w, 1.5);
    // Office, sales, warehouse and admin people aren't on job commission, so the pay controls start collapsed.
    final offCommission = !isField && !eligible && w == 0;

    void pick(double v) => _set('tech_weight', v);

    final weightControls = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Opacity(
          opacity: eligible ? 1 : 0.6,
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.start,
            children: [
              SizedBox(
                width: 380,
                child: _segmented<double>(
                  value: w,
                  options: [for (final p in _weightPresets) (p.$1, '${_fmtW(p.$1)}×  ${p.$2}')],
                  onChanged: pick,
                ),
              ),
              if (!isPreset)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Custom: ${_fmtW(w)}×',
                    style: const TextStyle(fontSize: 12.5, color: DashUi.slate, fontWeight: FontWeight.w600),
                  ),
                ),
              if (suggestLead)
                TextButton(
                  onPressed: () => pick(1.5),
                  child: const Text('Set to 1.5× (lead rate)', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
            ],
          ),
        ),
        if (_fieldErrors['tech_weight'] != null) ...[
          const SizedBox(height: 8),
          _note(Icons.error_outline_rounded, _fieldErrors['tech_weight']!, fg: _T.badFg, bg: _T.badBg),
        ],
        if (eligible && w == 0) ...[
          const SizedBox(height: 10),
          _note(
            Icons.warning_amber_rounded,
            'Commission eligible with a weight of 0 earns nothing. Set a weight, or turn eligibility off.',
            fg: _T.amberFg,
            bg: _T.amberBg,
            line: const Color(0xFFFDE68A),
          ),
        ] else if (!eligible && w > 0 && isField) ...[
          const SizedBox(height: 10),
          _note(
            Icons.info_outline_rounded,
            'The weight is ignored while Commission eligible is off.',
            fg: DashUi.slate,
            bg: _T.wash,
          ),
        ],
        const SizedBox(height: 10),
        _toggleRow(
          'is_commission_eligible',
          'Commission eligible',
          'Earns job commission and shows up on payroll. Weight only counts when this is on.',
        ),
        _toggleRow(
          'is_sales_commission_eligible',
          'Sales commission',
          'Paid a percent of labor on Won estimates they own, after the job closes. Leave Commission eligible off for sales reps.',
        ),
        _toggleRow(
          'is_callback_eligible',
          'Callback pay eligible',
          'Gets the flat callback rate when sent out on a callback.',
        ),
      ],
    );

    return _section(
      title: 'Commission',
      subtitle: offCommission
          ? '${e.name.split(' ').first} is not on job commission.'
          : 'Weight is their share of a job compared with everyone else who worked the same days.',
      trailing: _changedTag('tech_weight'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Collapsed for everyone until opened; the line under the title says what is on.
          _dropdownTile(
            key: ValueKey('comm-${e.id}'),
            title: 'Commission settings',
            summary: [
              if (eligible) 'Job commission ${_fmtW(w)}×',
              if (_value('is_sales_commission_eligible') == true) 'Sales commission',
              if (_value('is_callback_eligible') == true) 'Callback pay',
              if (!eligible && _value('is_sales_commission_eligible') != true && _value('is_callback_eligible') != true)
                'Nothing on',
            ].join('  ·  '),
            child: weightControls,
          ),
        ],
      ),
    );
  }

  Widget _permissionsSection() {
    final allowed = (_value('access_denied') as List).cast<String>().toSet();
    final isTech = isTechnicianRole(_s(_value('role')));

    void apply(Set<String> next) => _set('access_denied', [
      for (final k in kAllAccessKeys)
        if (next.contains(k)) k,
    ]);

    // Turns one cell on or off and keeps View in step: Create/Update/Delete need View, and
    // switching View off clears the rest of the row.
    void setCell(Set<String> next, AccessResource r, AccessAction a, bool on) {
      if (on) {
        next.add(r.keyFor(a));
        next.add(r.keyFor(AccessAction.view));
      } else {
        next.remove(r.keyFor(a));
        if (a == AccessAction.view) {
          for (final x in r.actions) {
            next.remove(r.keyFor(x));
          }
        }
      }
    }

    void toggleCell(AccessResource r, AccessAction a) {
      final next = {...allowed};
      setCell(next, r, a, !allowed.contains(r.keyFor(a)));
      apply(next);
    }

    void toggleRow(AccessResource r) {
      final next = {...allowed};
      final all = r.actions.every((a) => allowed.contains(r.keyFor(a)));
      for (final a in r.actions) {
        setCell(next, r, a, !all);
      }
      apply(next);
    }

    void toggleColumn(AccessGroup g, AccessAction a) {
      final rows = g.items.where((r) => r.actions.contains(a)).toList();
      final all = rows.every((r) => allowed.contains(r.keyFor(a)));
      final next = {...allowed};
      for (final r in rows) {
        setCell(next, r, a, !all);
      }
      apply(next);
    }

    return _section(
      title: 'Permissions',
      subtitle: isTech ? null : 'Tick what this person can do. Anything unticked is hidden from their menu or blocked.',
      trailing: _changedTag('access_denied'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Technicians use the tech app, so desktop access doesn't apply to them.
          if (!isTech) ...[
            _subHeader('IOHD Office permissions'),
            for (var i = 0; i < kAccessGroups.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              _accessMatrix(kAccessGroups[i], allowed, toggleCell, toggleRow, toggleColumn),
            ],
            _rule(),
          ],
          _subHeader('IOHD App permissions'),
          _appPermissions(),
        ],
      ),
    );
  }

  /// The tech-app switches as a table of checkboxes, laid out like the office permission groups above.
  Widget _appPermissions() {
    const rows = [
      (
        'can_collect_payment',
        'Collect payment',
        Icons.credit_card_rounded,
        'Can take card payments on jobs in the tech app.',
      ),
      (
        'can_see_commissions',
        'See commissions',
        Icons.payments_outlined,
        'Shows them their own weekly, monthly and year-to-date commission in the tech app. Off by default.',
      ),
    ];
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DashUi.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: _T.wash,
            padding: const EdgeInsets.fromLTRB(14, 6, 0, 6),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Tech app',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: DashUi.slate),
                  ),
                ),
                SizedBox(
                  width: _cellW,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'Allowed',
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: DashUi.slate),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          for (final (key, label, icon, tip) in rows)
            Container(
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: DashUi.line)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Tooltip(
                      message: tip,
                      child: InkWell(
                        onTap: () => _set(key, _value(key) != true),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 9, 8, 9),
                          child: Row(
                            children: [
                              Icon(icon, size: 16, color: DashUi.muted),
                              const SizedBox(width: 9),
                              Flexible(
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                    color: DashUi.ink,
                                  ),
                                ),
                              ),
                              if (_draft.containsKey(key)) ...[const SizedBox(width: 8), _changedTag(key)],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: _cellW,
                    child: Center(
                      child: Semantics(
                        label: label,
                        child: Checkbox(
                          value: _value(key) == true,
                          onChanged: (v) => _set(key, v == true),
                          activeColor: DashUi.emeraldDeep,
                          side: const BorderSide(color: DashUi.muted, width: 1.4),
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _subHeader(String text) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 10),
    child: Text(
      text,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: DashUi.ink),
    ),
  );

  static const double _cellW = 76;

  /// One group as a table: a row per resource, a column per action. Click a column heading to tick or
  /// clear the whole column, or a row's name to tick or clear the whole row.
  Widget _accessMatrix(
    AccessGroup group,
    Set<String> allowed,
    void Function(AccessResource, AccessAction) toggleCell,
    void Function(AccessResource) toggleRow,
    void Function(AccessGroup, AccessAction) toggleColumn,
  ) {
    final used = {for (final r in group.items) ...r.actions};
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DashUi.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: _T.wash,
            padding: const EdgeInsets.fromLTRB(14, 6, 0, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    group.title,
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: DashUi.slate),
                  ),
                ),
                for (final a in AccessAction.values.where(used.contains))
                  SizedBox(
                    width: _cellW,
                    child: used.contains(a)
                        ? Tooltip(
                            message: 'Tick or clear ${a.label.toLowerCase()} for everything in ${group.title}',
                            child: TextButton(
                              onPressed: () => toggleColumn(group, a),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                foregroundColor: DashUi.slate,
                              ),
                              child: Text(a.label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                            ),
                          )
                        : null,
                  ),
              ],
            ),
          ),
          for (final r in group.items)
            Container(
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: DashUi.line)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => toggleRow(r),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 9, 8, 9),
                        child: Row(
                          children: [
                            Icon(r.icon, size: 16, color: DashUi.muted),
                            const SizedBox(width: 9),
                            Flexible(
                              child: Text(
                                r.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  for (final a in AccessAction.values.where(used.contains))
                    SizedBox(
                      width: _cellW,
                      child: r.actions.contains(a)
                          ? Center(
                              child: Semantics(
                                label: '${r.label} ${a.label.toLowerCase()}',
                                child: Checkbox(
                                  value: allowed.contains(r.keyFor(a)),
                                  onChanged: (_) => toggleCell(r, a),
                                  activeColor: DashUi.emeraldDeep,
                                  side: const BorderSide(color: DashUi.muted, width: 1.4),
                                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                            )
                          : const Center(
                              child: Text('\u2013', style: TextStyle(color: DashUi.line, fontSize: 14)),
                            ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _profileSection(_Emp e) {
    final nameChanged = _draft.containsKey('name');
    final role = _s(_value('role'));
    final current = _titleFor(_s(_value('job_title')), role);
    // One list of real role names; each carries the system role it runs on (see _roleTitles).
    var options = [..._roleTitles];
    if (current != null && !options.any((o) => o.$1.toLowerCase() == current.toLowerCase())) {
      options.add((current, role)); // a custom title already saved on this person
    }
    // You can't take admin access away from yourself (the server refuses), so only admin roles are offered.
    final lockedToAdmin = _isMe(e) && _grantsAdmin(_s(_base('role')));
    if (lockedToAdmin) options = options.where((o) => _grantsAdmin(o.$2)).toList();
    final selectedTitle = current == null
        ? null
        : options.firstWhere((o) => o.$1.toLowerCase() == current.toLowerCase(), orElse: () => (current, role)).$1;

    final roleField = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel('Role'),
        AnimatedSelect<String>(
          key: ValueKey('role-${e.id}'),
          value: selectedTitle,
          hint: 'Choose a role',
          changed: _draft.containsKey('role') || _draft.containsKey('job_title'),
          decoration: _dec('role'),
          options: [for (final o in options) SelectOption(o.$1, o.$1, tag: _grantsAdmin(o.$2) ? 'Admin' : null)],
          onChanged: (v) {
            final o = options.firstWhere((x) => x.$1 == v);
            _set('role', o.$2);
            // The role's own name needs no separate title.
            _set('job_title', o.$1.toLowerCase() == o.$2.toLowerCase() ? null : o.$1);
          },
        ),
      ],
    );

    final badges = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _fieldLabel('Badges'),
            const SizedBox(width: 5),
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Tooltip(
                message:
                    'Each badge recognises one KPI. Click to switch it on; it then shows next to the photo and in the '
                    'tech app. Hover a badge to see what it means.',
                child: Icon(Icons.info_outline_rounded, size: 14, color: DashUi.muted),
              ),
            ),
          ],
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [for (final b in _badges) Tooltip(message: b.meaning, child: _badgePill(b))],
        ),
      ],
    );

    return _section(
      title: 'Profile',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Short boxes sized to what goes in them, flowing onto as many rows as the width needs.
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.start,
            children: [
              SizedBox(width: 170, child: _textField('name', 'First name', _firstCtl, onText: _nameBoxesChanged)),
              SizedBox(width: 170, child: _textField('name', 'Last name', _lastCtl, onText: _nameBoxesChanged)),
              SizedBox(width: 170, child: _textField('username', 'Username', _usernameCtl)),
              SizedBox(width: 240, child: roleField),
              SizedBox(
                width: 290,
                child: _textField(
                  'email',
                  'Email',
                  _emailCtl,
                  type: TextInputType.emailAddress,
                  hint: 'name@integritydoornwa.com',
                ),
              ),
              SizedBox(width: 170, child: _dateField('hire_date', 'Date joined')),
              // Only techs have a tool allowance, and it is a small amount, so a small box.
              if (isTechnicianRole(role))
                SizedBox(
                  width: 132,
                  child: _textField(
                    'tool_allowance',
                    'Tool allowance',
                    _allowanceCtl,
                    prefix: r'$ ',
                    type: const TextInputType.numberWithOptions(decimal: true),
                    formatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d{0,6}(\.\d{0,2})?'))],
                    hint: '0',
                  ),
                ),
              // Reset PIN sits with the other short fields; the tooltip says where their PIN stands.
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _fieldLabel(' '),
                  Tooltip(
                    message: !e.hasPin
                        ? 'No PIN yet. Sets a temporary one they must change at login.'
                        : e.needsPinChange
                        ? 'They must choose a new PIN at next login. PINs are stored encrypted.'
                        : 'PIN set. PINs are stored encrypted, so nobody can look one up.',
                    // Drawn by the same input styling as the fields, so it is exactly their height on any font.
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: _pinBusy ? null : _resetPin,
                      // A real read-only field draws the button face, so its height is exactly that of the fields.
                      child: SizedBox(
                        width: e.hasPin ? 132 : 188,
                        child: IgnorePointer(
                          child: TextFormField(
                            key: ValueKey('pin-${e.id}-${e.hasPin}-$_pinBusy'),
                            initialValue: _pinBusy ? 'Working…' : (e.hasPin ? 'Reset PIN' : 'Set temporary PIN'),
                            readOnly: true,
                            showCursor: false,
                            enableInteractiveSelection: false,
                            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink),
                            decoration: _dec('reset_pin').copyWith(
                              prefixIcon: const SizedBox(
                                width: 34,
                                height: 0,
                                child: OverflowBox(
                                  maxHeight: 24,
                                  child: Icon(Icons.key_rounded, size: 16, color: DashUi.ink),
                                ),
                              ),
                              prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 0, maxHeight: 0),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (nameChanged) ...[
            const SizedBox(height: 8),
            const Text(
              'The name must match Service Fusion exactly. Past work days and ledger rows are renamed when you save.',
              style: TextStyle(fontSize: 12, color: _T.amberFg, fontWeight: FontWeight.w600, height: 1.35),
            ),
          ],
          const SizedBox(height: 14),
          badges,
          if (lockedToAdmin) ...[
            const SizedBox(height: 8),
            const Text(
              "You can't remove your own admin access.",
              style: TextStyle(fontSize: 12, color: DashUi.slate, fontWeight: FontWeight.w600),
            ),
          ] else if (_grantsAdmin(role)) ...[
            const SizedBox(height: 8),
            const Text(
              'This role can open admin screens, including this one.',
              style: TextStyle(fontSize: 12, color: DashUi.indigo, fontWeight: FontWeight.w600),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionRule() => const Divider(height: 1, color: DashUi.line);

  Widget _rule() => const Padding(
    padding: EdgeInsets.symmetric(vertical: 10),
    child: Divider(height: 1, color: DashUi.line),
  );

  Widget _badgePill(_Badge b) {
    final (key, label, icon, color) = (b.key, b.label, b.icon, b.color);
    final on = _value(key) == true;
    final changed = _draft.containsKey(key);
    return _Hoverable(
      onTap: () => _set(key, !on),
      builder: (hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: on ? color.withValues(alpha: 0.08) : (hover ? _T.wash : Colors.white),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: changed
                ? DashUi.indigo
                : (on ? color.withValues(alpha: 0.45) : (hover ? DashUi.muted : DashUi.line)),
            width: changed ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: on ? color : DashUi.muted),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: on ? DashUi.ink : DashUi.slate),
            ),
          ],
        ),
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
    } else if (_historyError != null) {
      body = Row(
        children: [
          const Icon(Icons.error_outline_rounded, size: 18, color: _T.badFg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(_historyError!, style: const TextStyle(fontSize: 13, color: _T.badFg)),
          ),
          TextButton(
            onPressed: () => _selectedId == null ? null : _loadHistory(_selectedId!),
            child: const Text('Try again'),
          ),
        ],
      );
    } else if ((_history ?? const []).isEmpty) {
      body = const Text(
        'No changes recorded yet. Every edit made here is logged with who made it and when.',
        style: TextStyle(fontSize: 13, color: DashUi.muted),
      );
    } else {
      final fmt = DateFormat('MMM d, y  h:mm a');
      body = Column(
        children: [
          if (_history!.length >= 60)
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Showing the latest 60 changes.', style: TextStyle(fontSize: 12, color: DashUi.muted)),
              ),
            ),
          for (var i = 0; i < _history!.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                border: i == 0 ? null : const Border(top: BorderSide(color: DashUi.line)),
              ),
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
                      Text(
                        _history![i].at == null ? '' : fmt.format(_history![i].at!),
                        style: const TextStyle(fontSize: 12, color: DashUi.slate, fontFeatures: _figures),
                      ),
                      Text(_history![i].by, style: const TextStyle(fontSize: 12, color: DashUi.muted)),
                    ],
                  ),
                ],
              ),
            ),
        ],
      );
    }
    // Collapsed until asked for: it is long, rarely needed, and used to push everything else off the screen. The key
    // ties the open/closed state to the person, so choosing someone else starts collapsed again.
    final count = _history?.length;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: ValueKey('history-${_selectedId ?? 0}'),
        tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        shape: const Border(),
        collapsedShape: const Border(),
        trailing: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: _T.wash,
            shape: BoxShape.circle,
            border: Border.all(color: DashUi.line),
          ),
          child: const Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: DashUi.ink),
        ),
        title: Row(
          children: [
            const Text(
              'Change history',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: DashUi.ink),
            ),
            if (count != null && count > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(20)),
                child: Text(
                  count >= 60 ? '60+' : '$count',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: DashUi.slate,
                    fontFeatures: _figures,
                  ),
                ),
              ),
            ],
          ],
        ),
        children: [body],
      ),
    );
  }

  Widget _historyLine(_Change c) {
    const labelStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.ink);
    if (c.field == 'created') {
      return Text('Added to the team as ${c.newValue ?? ''}', style: labelStyle);
    }
    if (c.field == 'pin') return const Text('PIN reset', style: labelStyle);
    if (c.field == 'avatar_url') {
      final removed = c.newValue == null || c.newValue!.isEmpty;
      return Text(
        removed ? 'Photo removed' : (c.oldValue == null || c.oldValue!.isEmpty ? 'Photo added' : 'Photo changed'),
        style: labelStyle,
      );
    }
    if (c.field == 'access_denied') {
      // Stored as the list of keys switched OFF; say what actually changed in words.
      Set<String> keys(String? v) =>
          (v == null || v.isEmpty) ? <String>{} : v.split(',').map((k) => k.trim()).where((k) => k.isNotEmpty).toSet();
      final before = keys(c.oldValue);
      final after = keys(c.newValue);
      final off = after.difference(before).map(_accessKeyLabel).toList();
      final on = before.difference(after).map(_accessKeyLabel).toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Permissions changed', style: labelStyle),
          if (off.isNotEmpty)
            Text(
              'Turned off: ${off.join('; ')}',
              style: const TextStyle(fontSize: 12.5, color: DashUi.slate, height: 1.35),
            ),
          if (on.isNotEmpty)
            Text(
              'Turned on: ${on.join('; ')}',
              style: const TextStyle(fontSize: 12.5, color: DashUi.slate, height: 1.35),
            ),
          if (off.isEmpty && on.isEmpty)
            const Text('No visible change', style: TextStyle(fontSize: 12.5, color: DashUi.muted)),
        ],
      );
    }
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: '${c.label}  ', style: labelStyle),
          TextSpan(
            text: _displayAudit(c.field, c.oldValue),
            style: const TextStyle(fontSize: 13, color: DashUi.muted, fontFeatures: _figures),
          ),
          const TextSpan(
            text: '  to  ',
            style: TextStyle(fontSize: 12, color: DashUi.muted),
          ),
          TextSpan(
            text: _displayAudit(c.field, c.newValue),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: DashUi.ink,
              fontFeatures: _figures,
            ),
          ),
        ],
      ),
    );
  }

  // ---- Building blocks ------------------------------------------------------

  Widget _section({required String title, String? subtitle, Widget? trailing, required Widget child}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
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
                    Text(
                      title,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: DashUi.ink),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(fontSize: 12.5, color: DashUi.muted, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget _changedTag(String key) {
    if (!_draft.containsKey(key)) return const SizedBox.shrink();
    return Text(
      'was ${_display(key, _base(key))}',
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.indigo, fontFeatures: _figures),
    );
  }

  Widget _fieldLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 5),
    child: Text(
      text,
      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.slate),
    ),
  );

  InputDecoration _dec(String key, {String? hint, String? prefix}) {
    final changed = _draft.containsKey(key);
    OutlineInputBorder b(Color c, [double w = 1]) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: c, width: w),
    );
    return InputDecoration(
      isDense: true,
      filled: true,
      fillColor: changed ? _T.changedFill : _T.field,
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 13.5, color: DashUi.muted, fontWeight: FontWeight.w500),
      prefixText: prefix,
      prefixStyle: const TextStyle(fontSize: 13.5, color: DashUi.slate, fontWeight: FontWeight.w600),
      errorText: _fieldErrors[key],
      errorMaxLines: 3,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
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
    VoidCallback? onText,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel(label),
        TextField(
          controller: ctl,
          keyboardType: type,
          inputFormatters: formatters,
          style: const TextStyle(fontSize: 13.5, color: DashUi.ink, fontWeight: FontWeight.w600),
          decoration: _dec(key, hint: hint, prefix: prefix),
          onChanged: (t) {
            if (onText != null) return onText();
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
            child: Text(
              helper,
              style: TextStyle(
                fontSize: 12,
                color: helperColor ?? DashUi.muted,
                fontWeight: helperColor == null ? FontWeight.w500 : FontWeight.w600,
                height: 1.35,
              ),
            ),
          ),
      ],
    );
  }

  /// A date shown as text; clicking opens a calendar popup. Stored as YYYY-MM-DD.
  Widget _dateField(String key, String label) {
    final d = DateTime.tryParse(_s(_value(key)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel(label),
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () async {
            final now = DateTime.now();
            final picked = await showDatePicker(
              context: context,
              initialDate: d ?? now,
              firstDate: DateTime(1990),
              lastDate: DateTime(now.year + 1, 12, 31),
              helpText: label.toUpperCase(),
              builder: (context, child) => Theme(
                data: Theme.of(context).copyWith(
                  datePickerTheme: const DatePickerThemeData(
                    backgroundColor: Colors.white,
                    surfaceTintColor: Colors.transparent,
                  ),
                  colorScheme: Theme.of(context).colorScheme.copyWith(
                    primary: DashUi.ink,
                    onPrimary: Colors.white,
                    surface: Colors.white,
                    onSurface: DashUi.ink,
                  ),
                ),
                child: child!,
              ),
            );
            if (picked != null) _set(key, DateFormat('yyyy-MM-dd').format(picked));
          },
          // A real read-only text field draws the box, so it is exactly as tall as the fields beside it.
          child: IgnorePointer(
            child: TextFormField(
              key: ValueKey('$key-${d?.toIso8601String()}'),
              initialValue: d == null ? '' : DateFormat.yMMMd().format(d),
              readOnly: true,
              showCursor: false,
              enableInteractiveSelection: false,
              style: const TextStyle(fontSize: 13.5, color: DashUi.ink, fontWeight: FontWeight.w600),
              decoration: _dec(key, hint: 'Pick a date').copyWith(
                suffixIcon: const SizedBox(
                  width: 30,
                  height: 0,
                  child: OverflowBox(
                    maxHeight: 24,
                    child: Icon(Icons.calendar_month_outlined, size: 18, color: DashUi.slate),
                  ),
                ),
                suffixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 0, maxHeight: 0),
              ),
            ),
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

  /// A collapsible block that looks like one: a bordered, tinted bar with a chevron in a circle on the right, so
  /// it can't be mistaken for plain text. [summary] says what is inside while it is closed.
  Widget _dropdownTile({Key? key, required String title, String summary = '', required Widget child}) {
    // No card, no tint: it sits on the section like everything else. The circled chevron says it opens, and turns.
    final id = (key ?? ValueKey(title)).toString();
    final open = _openTiles.contains(id);
    return KeyedSubtree(
      key: key,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: open,
          onExpansionChanged: (v) => setState(() => v ? _openTiles.add(id) : _openTiles.remove(id)),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 4),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          shape: const Border(),
          collapsedShape: const Border(),
          trailing: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: _T.wash,
              shape: BoxShape.circle,
              border: Border.all(color: DashUi.line),
            ),
            child: AnimatedRotation(
              turns: open ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              child: const Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: DashUi.ink),
            ),
          ),
          title: Text(
            title,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: DashUi.ink),
          ),
          subtitle: summary.isEmpty
              ? null
              : Text(
                  summary,
                  style: const TextStyle(fontSize: 12, color: DashUi.slate, fontWeight: FontWeight.w600),
                ),
          children: [child],
        ),
      ),
    );
  }

  Widget _toggleRow(String key, String title, String subtitle) {
    final on = _value(key) == true;
    final changed = _draft.containsKey(key);
    // One slim line: the name, an info icon holding the explanation, and a small switch at the far end.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _set(key, !on),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.ink),
                ),
                const SizedBox(width: 6),
                Tooltip(
                  message: subtitle,
                  child: const Icon(Icons.info_outline_rounded, size: 15, color: DashUi.muted),
                ),
                if (changed) ...[
                  const SizedBox(width: 8),
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(color: DashUi.indigo, shape: BoxShape.circle),
                  ),
                ],
                const Spacer(),
                Transform.scale(
                  scale: 0.72,
                  child: Switch(
                    value: on,
                    onChanged: (v) => _set(key, v),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    activeTrackColor: DashUi.emeraldDeep,
                    inactiveTrackColor: DashUi.line,
                    inactiveThumbColor: Colors.white,
                    trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_fieldErrors[key] != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(_fieldErrors[key]!, style: const TextStyle(fontSize: 12, color: _T.badFg)),
          ),
      ],
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
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12.5, color: fg, fontWeight: FontWeight.w600, height: 1.4),
            ),
          ),
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
    child: Text(
      text,
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg),
    ),
  );
}

// The look of every pop-up, button and pill selector is the shared one (widgets/app_dialog.dart).
Widget _segmented<V>({
  required V value,
  required List<(V, String)> options,
  required ValueChanged<V> onChanged,
  Color activeColor = DashUi.ink,
}) => AppSegmented<V>(value: value, options: options, onChanged: onChanged, activeColor: activeColor);

Widget _inkButton(String label, VoidCallback? onPressed, {IconData? icon, bool danger = false}) =>
    AppButton.ink(label, onPressed, icon: icon, danger: danger);

Widget _ghostButton(String label, VoidCallback? onPressed) => AppButton.ghost(label, onPressed);

Widget _dialog({
  required String title,
  required Widget body,
  required List<Widget> actions,
  double width = 440,
  IconData? icon,
  Color iconColor = DashUi.ink,
  String? subtitle,
}) => AppDialog(
  title: title,
  subtitle: subtitle,
  icon: icon,
  iconColor: iconColor,
  width: width,
  body: body,
  actions: actions,
);

/// A tappable area that works with the mouse, the keyboard (Tab to reach it, Enter or Space to
/// open it) and shows [builder]'s hover state for either.
class _Hoverable extends StatefulWidget {
  final VoidCallback onTap;
  final Widget Function(bool hover) builder;
  const _Hoverable({required this.onTap, required this.builder});

  @override
  State<_Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<_Hoverable> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (v) => setState(() => _hover = v),
      onShowFocusHighlight: (v) => setState(() => _focus = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: widget.builder(_hover || _focus),
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
  final _email = TextEditingController();
  final _year = TextEditingController(text: '${DateTime.now().year}');
  String _role = 'Technician';
  double _weight = 1.0;
  bool _eligible = true;
  bool _callback = true;
  bool _usernameTouched = false;
  bool _busy = false;
  String? _error;
  String? _errorField;

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _email.dispose();
    _year.dispose();
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
      // Defaults follow how the current team is set up; every one of them can be changed below.
      if (r.contains('lead')) {
        _weight = 1.5;
        _eligible = true;
        _callback = true;
      } else if (r.contains('tech')) {
        _weight = 1.0;
        _eligible = true;
        _callback = true;
      } else {
        _weight = 0;
        _eligible = false;
        _callback = r.contains('warehouse') || r.contains('sales');
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
      final year = int.tryParse(_year.text.trim());
      final result = await widget.submit({
        'name': _name.text.trim(),
        'username': _username.text.trim(),
        'role': _role,
        'tech_weight': _weight,
        'is_commission_eligible': _eligible,
        'is_callback_eligible': _callback,
        'is_lead': _role.toLowerCase().contains('lead'),
        if (_email.text.trim().isNotEmpty) 'email': _email.text.trim(),
        'year_joined': ?year,
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
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: DashUi.line),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: DashUi.line),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: DashUi.ink),
    ),
  );

  Widget _switchRow(String title, bool value, ValueChanged<bool> onChanged) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: DashUi.ink),
        ),
      ),
      Switch(
        value: value,
        onChanged: onChanged,
        activeTrackColor: DashUi.emeraldDeep,
        inactiveTrackColor: DashUi.line,
        inactiveThumbColor: Colors.white,
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ],
  );

  Widget _label(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 6, top: 14),
    child: Text(
      t,
      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: DashUi.slate),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final canSubmit = !_busy && _name.text.trim().isNotEmpty && _username.text.trim().length >= 2;
    return _dialog(
      title: 'Add employee',
      icon: Icons.person_add_alt_1_rounded,
      width: 480,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'They\'ll get a temporary PIN and choose their own at first login.',
            style: TextStyle(fontSize: 13, color: DashUi.slate),
          ),
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _label('Email (optional)'),
                    TextField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: _dec('email', 'name@integritydoornwa.com'),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _label('Year joined'),
                    TextField(
                      controller: _year,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
                      decoration: _dec('year_joined', '${DateTime.now().year}'),
                      onSubmitted: (_) {
                        if (canSubmit) _go();
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
          _label('Role'),
          DropdownButtonFormField<String>(
            initialValue: widget.roles.any((r) => r.name == _role) ? _role : null,
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
            options: [for (final p in _weightPresets) (p.$1, '${_fmtW(p.$1)}×  ${p.$2}')],
            onChanged: (v) => setState(() => _weight = v),
          ),
          const SizedBox(height: 8),
          _switchRow('Commission eligible', _eligible, (v) => setState(() => _eligible = v)),
          _switchRow('Callback pay eligible', _callback, (v) => setState(() => _callback = v)),
          if (_error != null && _errorField == null) ...[
            const SizedBox(height: 6),
            Text(
              _error!,
              style: const TextStyle(fontSize: 12.5, color: _T.badFg, fontWeight: FontWeight.w600),
            ),
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
