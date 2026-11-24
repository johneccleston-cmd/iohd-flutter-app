// The company project tracker: internal projects (not customer jobs) with an owner, a status on a short workflow, a
// priority, an optional deadline, notes and file links. Backend: integrity-backend/src/projects.js.
//
// Layout (2026-11-12 redesign): an overview band of workflow stages and attention filters that doubles as the status
// filter; under it a register of projects (grouped by status or owner, sortable headers) beside a detail pane that shows
// the selected project in full, so a long list can be read without opening anything. The status can be moved from the
// pane's workflow track or the row menu (with Undo); everything else is changed in the editor.
// Narrow windows drop the pane and open the details in a dialog instead.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import 'config/access.dart';
import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'widgets/app_dialog.dart';
import 'widgets/app_ribbon.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';
import 'widgets/page_selection.dart';

part 'projects_list.dart';
part 'projects_detail.dart';
part 'projects_editor.dart';

// ─── model ──────────────────────────────────────────────────────────────────

/// The statuses the server accepts, in workflow order. On Hold is a pause, not a step.
const _statuses = ['Planning', 'In Progress', 'In Review', 'On Hold', 'Complete'];
const _workflow = ['Planning', 'In Progress', 'In Review', 'Complete'];
const _priorities = ['Urgent', 'High', 'Medium', 'Low'];

/// Groups by status put the work being done first and finished work last.
const _statusGroupOrder = ['In Progress', 'In Review', 'Planning', 'On Hold', 'Complete'];

/// The server's limits (projects.js cleanProject), so nothing is cut off silently on save.
const _maxName = 200;
const _maxPerson = 100;
const _maxNotes = 20000;
const _maxFiles = 30;

class _ProjectFile {
  final String name;
  final String url;
  const _ProjectFile(this.name, this.url);

  bool get linked => url.trim().isNotEmpty;
  String get label => name.trim().isNotEmpty ? name.trim() : url.trim();

  /// "docs.google.com" for a link, so a row says where the file lives.
  String get host => Uri.tryParse(_withScheme(url))?.host.replaceFirst(RegExp(r'^www\.'), '') ?? '';
}

class _Project {
  final int id;
  final String name, owner, support, requestedBy, priority, status, notes;
  final DateTime? deadline;
  final List<_ProjectFile> files;

  /// updatedAt exactly as the server sent it: sent back with a save so a project someone else changed in between is
  /// refused instead of overwritten (ifUnchangedSince).
  final String updatedAtRaw;
  final DateTime? updatedAt;

  const _Project({
    required this.id,
    required this.name,
    required this.owner,
    required this.support,
    required this.requestedBy,
    required this.priority,
    required this.status,
    required this.notes,
    required this.deadline,
    required this.files,
    required this.updatedAtRaw,
    required this.updatedAt,
  });

  factory _Project.fromJson(Map<String, dynamic> j) {
    String s(String k) => '${j[k] ?? ''}'.trim();
    final updated = '${j['updatedAt'] ?? ''}';
    return _Project(
      id: (j['id'] as num?)?.toInt() ?? 0,
      name: s('name'),
      owner: s('owner'),
      support: s('support'),
      requestedBy: s('requestedBy'),
      priority: s('priority'),
      status: s('status').isEmpty ? 'Planning' : s('status'),
      notes: '${j['notes'] ?? ''}',
      deadline: _parseDay('${j['deadline'] ?? ''}'),
      files: [
        for (final f in (j['files'] as List? ?? const []))
          if (f is Map) _ProjectFile('${f['name'] ?? ''}'.trim(), '${f['url'] ?? ''}'.trim()),
      ],
      updatedAtRaw: updated,
      updatedAt: DateTime.tryParse(updated)?.toLocal(),
    );
  }

  _Project withStatus(String value) => _Project(
    id: id,
    name: name,
    owner: owner,
    support: support,
    requestedBy: requestedBy,
    priority: priority,
    status: value,
    notes: notes,
    deadline: deadline,
    files: files,
    updatedAtRaw: updatedAtRaw,
    updatedAt: updatedAt,
  );

  /// The full body a PUT replaces the project with (the server has no partial update).
  Map<String, dynamic> body({String? status}) => {
    'name': name,
    'owner': owner,
    'support': support,
    'requestedBy': requestedBy,
    'priority': priority,
    'status': status ?? this.status,
    'deadline': deadline == null ? '' : _isoDate(deadline!),
    'notes': notes,
    'files': [
      for (final f in files) {'name': f.name, 'url': f.url},
    ],
  };

  String get title => name.isEmpty ? 'Untitled project' : name;
  bool get isComplete => status == 'Complete';
  bool get unassigned => !isComplete && owner.isEmpty;

  /// Days from today to the deadline (negative = late), or null without one.
  int? get daysLeft {
    final d = deadline;
    if (d == null) return null;
    return d.difference(_today()).inDays;
  }

  bool get overdue => !isComplete && (daysLeft ?? 0) < 0;

  /// Open and due within the next week, today included.
  bool get dueSoon {
    final left = daysLeft;
    return !isComplete && left != null && left >= 0 && left <= 7;
  }

  String get searchText => [name, owner, support, requestedBy, status, priority, notes, for (final f in files) f.name].join('\n').toLowerCase();
}

DateTime _today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

/// "2026-10-23" as a local calendar day (no time zone shift).
DateTime? _parseDay(String s) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(s.trim());
  if (m == null) return null;
  return DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

String _isoDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

final _dayFormat = DateFormat('MMM d, yyyy');
final _shortDayFormat = DateFormat('MMM d');

String _date(DateTime? d) => d == null ? '' : _dayFormat.format(d);

/// "in 18 days", "in 3 weeks", "Due today", "9 days overdue", with the colour it reads in. Null for finished work or no deadline.
(String, Color)? _deadlineNote(_Project p) {
  final days = p.daysLeft;
  if (days == null || p.isComplete) return null;
  if (days < 0) return ('${-days} ${days == -1 ? 'day' : 'days'} overdue', DashUi.redText);
  if (days == 0) return ('Due today', DashUi.amberText);
  if (days == 1) return ('Due tomorrow', DashUi.amberText);
  if (days <= 7) return ('Due in $days days', DashUi.amberText);
  if (days <= 13) return ('in $days days', DashUi.slate);
  if (days <= 60) return ('in ${(days / 7).round()} weeks', DashUi.slate);
  final months = (days / 30.4).round();
  return ('in $months ${months == 1 ? 'month' : 'months'}', DashUi.slate);
}

/// "Today", "Yesterday", "5 days ago", "3 weeks ago", or the date for anything older.
String _ago(DateTime? t) {
  if (t == null) return '';
  final days = _today().difference(DateTime(t.year, t.month, t.day)).inDays;
  if (days <= 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days < 14) return '$days days ago';
  if (days < 56) return '${days ~/ 7} weeks ago';
  return t.year == DateTime.now().year ? _shortDayFormat.format(t) : _dayFormat.format(t);
}

/// The server only takes http(s) links, and people paste "drive.google.com/..." without the scheme.
String _withScheme(String url) {
  final u = url.trim();
  if (u.isEmpty || RegExp(r'^https?://', caseSensitive: false).hasMatch(u)) return u;
  return 'https://${u.replaceFirst(RegExp(r'^/+'), '')}';
}

int _rank(List<String> order, String v) {
  final i = order.indexOf(v);
  return i < 0 ? order.length : i;
}

Future<void> _openLink(BuildContext context, String url) async {
  final uri = Uri.tryParse(_withScheme(url));
  final ok = uri != null && await launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open that file.')));
  }
}

// ─── colours and marks ──────────────────────────────────────────────────────

Color _statusColor(String s) => switch (s) {
  'In Progress' => DashUi.blue,
  'In Review' => DashUi.indigo,
  'On Hold' => DashUi.amber,
  'Complete' => DashUi.emerald,
  _ => DashUi.subtle, // Planning (and anything the server adds later)
};

/// Filled bars out of three, and the colour they're drawn in.
(int, Color) _priorityLevel(String p) => switch (p) {
  'Urgent' => (3, DashUi.red),
  'High' => (3, DashUi.amber),
  'Medium' => (2, DashUi.slate),
  'Low' => (1, DashUi.slate),
  _ => (0, DashUi.slate),
};

/// Avatar colours, picked by name so a person keeps the same one everywhere on the page.
const _personColors = [DashUi.blue, DashUi.emeraldDeep, DashUi.amberText, DashUi.indigo, DashUi.sky, DashUi.redText, DashUi.slate];

Color _personColor(String name) {
  var h = 0;
  for (final c in name.toLowerCase().codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return _personColors[h % _personColors.length];
}

String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '';
  return (parts.first[0] + (parts.length > 1 ? parts.last[0] : '')).toUpperCase();
}

/// A round initials mark. With no name, a dashed-looking empty ring that reads as "nobody yet".
class _PersonMark extends StatelessWidget {
  final String name;
  final double size;
  const _PersonMark(this.name, {this.size = 28});

  @override
  Widget build(BuildContext context) {
    if (name.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: DashUi.muted, width: 1.2),
        ),
        child: Icon(Icons.person_outline_rounded, size: size * 0.56, color: DashUi.subtle),
      );
    }
    final c = _personColor(name);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.withValues(alpha: 0.13), shape: BoxShape.circle),
      child: Text(
        _initials(name),
        style: TextStyle(fontSize: size * 0.4, fontWeight: FontWeight.w800, color: c, height: 1),
      ),
    );
  }
}

/// Status as a tinted pill with a dot. The text stays ink: some status colours fail contrast as text.
class _StatusBadge extends StatelessWidget {
  final String status;
  final bool dense;
  const _StatusBadge(this.status, {super.key, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final c = _statusColor(status);
    return Container(
      padding: EdgeInsets.fromLTRB(dense ? 8 : 10, dense ? 3 : 5, dense ? 10 : 12, dense ? 3 : 5),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: dense ? 12.5 : 13, fontWeight: FontWeight.w700, color: DashUi.ink),
            ),
          ),
        ],
      ),
    );
  }
}

/// Priority as three rising bars and a word. Blank priority draws nothing.
class _PriorityMark extends StatelessWidget {
  final String priority;
  final bool showLabel;
  const _PriorityMark(this.priority, {this.showLabel = true});

  @override
  Widget build(BuildContext context) {
    if (priority.isEmpty) return const SizedBox.shrink();
    final (level, color) = _priorityLevel(priority);
    final urgent = priority == 'Urgent';
    return Semantics(
      label: '$priority priority',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < 3; i++)
            Container(
              width: 4,
              height: 6.0 + i * 4,
              margin: const EdgeInsets.only(right: 2, bottom: 3),
              decoration: BoxDecoration(color: i < level ? color : DashUi.line, borderRadius: BorderRadius.circular(1)),
            ),
          if (showLabel) ...[
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                priority,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, fontWeight: urgent ? FontWeight.w800 : FontWeight.w500, color: urgent ? DashUi.redText : DashUi.ink),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── views, grouping, sorting ───────────────────────────────────────────────

/// What the overview band filters by: a workflow stage, every open/any project, or something that needs attention.
enum _View {
  open('Open', null),
  planning('Planning', 'not started'),
  inProgress('In progress', 'under way'),
  inReview('In review', 'to sign off'),
  onHold('On hold', 'paused'),
  complete('Complete', 'finished'),
  all('All', 'projects'),
  overdue('Overdue', 'past deadline'),
  dueSoon('Due soon', 'next 7 days'),
  unassigned('No owner', 'unassigned');

  final String label;
  final String? caption;
  const _View(this.label, this.caption);

  /// The status this stage stands for, or null for the open/all/attention views.
  String? get status => switch (this) {
    planning => 'Planning',
    inProgress => 'In Progress',
    inReview => 'In Review',
    onHold => 'On Hold',
    complete => 'Complete',
    _ => null,
  };

  bool get attention => this == overdue || this == dueSoon || this == unassigned;

  bool matches(_Project p) => switch (this) {
    open => !p.isComplete,
    all => true,
    overdue => p.overdue,
    dueSoon => p.dueSoon,
    unassigned => p.unassigned,
    _ => p.status == status,
  };
}

enum _Group { status, owner, none }

enum _Sort { priority, name, owner, status, deadline, updated }

/// A row in the register: a group header or a project.
sealed class _Item {
  const _Item();
}

class _GroupItem extends _Item {
  final String key; // what [_ProjectsScreenState._collapsed] holds
  final String label;
  final int count;
  final Color? dot; // status groups
  final String? person; // owner groups ('' = no owner)
  final bool collapsed;
  const _GroupItem({required this.key, required this.label, required this.count, this.dot, this.person, required this.collapsed});
}

class _ProjectItem extends _Item {
  final _Project project;
  final int index; // position among the projects shown, for the entrance stagger
  const _ProjectItem(this.project, this.index);
}

/// A failed call, with a message fit to show the person.
class _ApiError implements Exception {
  final String message;
  final int status;
  final String? code;
  const _ApiError(this.message, this.status, [this.code]);

  /// Someone else saved the project after this copy was loaded (the server's ifUnchangedSince check).
  bool get changedElsewhere => status == 409 && code == 'CHANGED';

  @override
  String toString() => message;
}

/// Raw exception text ("TimeoutException after 0:00:30...") is never shown to the person.
String _friendly(Object e) {
  if (e is _ApiError) return e.message;
  if (e is TimeoutException) return 'The server took too long to answer. Try again.';
  if (e is http.ClientException) return "Couldn't reach the server. Check your connection and try again.";
  return 'Something went wrong. Try again.';
}

typedef _SaveOutcome = ({String? error, bool conflict});

enum _EditorExit { saved, added, deleteRequested }

// ─── screen ─────────────────────────────────────────────────────────────────

class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key});

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> with SingleTickerProviderStateMixin {
  final _session = AuthSession.instance;
  final _activity = RibbonActivity();
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'project search');
  final _listFocus = FocusNode(debugLabel: 'project list');
  final _scroll = ScrollController();

  /// Rows settle in one after another when the first list lands.
  late final AnimationController _entrance = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));

  List<_Project> _projects = [];
  bool _loaded = false; // the first answer has arrived
  bool _loading = true;
  bool _slow = false; // the first load is taking long enough to say why
  Timer? _slowTimer;
  String? _error; // the first load failed: nothing to show
  String? _staleError; // a reload failed: the rows on screen may be out of date
  bool _importing = false;

  int _requestId = 0; // the reload whose answer counts
  int _quietId = 0; // the background check-in whose answer counts
  int _revision = 0; // goes up on every change made here, so an answer asked for before it can't undo it

  String _query = '';
  _View _view = _View.open;
  String? _person; // null = everyone
  _Group _group = _Group.status;
  _Sort _sort = _Sort.priority;
  bool _ascending = true;
  final Set<String> _collapsed = {'status:Complete'}; // finished work starts folded away in the All view
  int? _selectedId;
  final Set<int> _busy = {}; // projects with a status change on its way

  bool get _canCreate => _session.can('projects', AccessAction.create);
  bool get _canUpdate => _session.can('projects', AccessAction.update);
  bool get _canDelete => _session.can('projects', AccessAction.delete);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    _activity.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _listFocus.dispose();
    _scroll.dispose();
    _entrance.dispose();
    _detailTick.dispose();
    super.dispose();
  }

  bool get _reduceMotion => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  // ─── API ──────────────────────────────────────────────────────────────────

  /// One API call. Returns the decoded body; throws [_ApiError] (or a network error, see [_friendly]).
  Future<Map<String, dynamic>> _send(String method, String path, {Map<String, dynamic>? body, Duration timeout = const Duration(seconds: 30)}) async {
    final req = http.Request(method, Uri.parse('$kApiBaseUrl/api$path'))..headers.addAll(_session.headers());
    if (body != null) req.body = json.encode(body);
    final res = await http.Response.fromStream(await req.send().timeout(timeout)).timeout(timeout);
    if (res.statusCode == 401) {
      _session.logout();
      throw const _ApiError('Your session expired. Sign in again.', 401);
    }
    Map<String, dynamic> data = {};
    try {
      data = json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {}
    if (res.statusCode >= 400) {
      throw _ApiError('${data['error'] ?? 'Server error (${res.statusCode})'}', res.statusCode, data['code']?.toString());
    }
    return data;
  }

  /// [fresh] asks the server to pull the old project sheet first (Refresh), which can take a while.
  /// [quiet] is a background check-in after a save: no loading state, and a failure says nothing.
  Future<void> _load({bool fresh = false, bool quiet = false}) async {
    final revision = _revision;
    final id = quiet ? ++_quietId : ++_requestId;
    if (!quiet) {
      _quietId++; // this answer will be newer than any check-in already out
      setState(() {
        _loading = true;
        if (!_loaded) _error = null;
      });
      _activity.setRefreshing(true);
      if (!_loaded) {
        _slowTimer?.cancel();
        _slowTimer = Timer(const Duration(seconds: 8), () {
          if (mounted && _loading && !_loaded) setState(() => _slow = true);
        });
      }
    }
    try {
      final data = await _send('GET', '/projects${fresh ? '?fresh=1' : ''}', timeout: Duration(seconds: fresh ? 60 : 30));
      if (!mounted || id != (quiet ? _quietId : _requestId)) return;
      final list = [
        for (final j in (data['projects'] as List? ?? const []))
          if (j is Map<String, dynamic>) _Project.fromJson(j),
      ];
      if (revision != _revision) {
        // A change made here landed while this was out, so this copy may be older than the screen: keep the screen.
        if (!quiet) {
          setState(() => _loading = false);
          unawaited(_load(fresh: true, quiet: true));
        }
        return;
      }
      final first = !_loaded;
      setState(() {
        _projects = list;
        _loaded = true;
        _loading = quiet ? _loading : false;
        _error = null;
        _staleError = null;
        _slow = false;
        _keepSelectionVisible();
      });
      if (!quiet) _activity.landed();
      if (first) {
        _reduceMotion ? _entrance.value = 1 : _entrance.forward(from: 0);
      }
    } catch (e) {
      if (!mounted || quiet || id != _requestId) return;
      final msg = _friendly(e);
      setState(() {
        _loading = false;
        _slow = false;
        if (_loaded) {
          _staleError = "Couldn't refresh projects: $msg";
        } else {
          _error = msg;
        }
      });
    } finally {
      if (!quiet && mounted && id == _requestId) {
        _slowTimer?.cancel();
        _activity.setRefreshing(false);
      }
    }
  }

  void _toast(String message, {SnackBarAction? action}) {
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(content: Text(message), action: action, behavior: SnackBarBehavior.floating, width: 520));
  }

  void _put(_Project p) {
    final i = _projects.indexWhere((x) => x.id == p.id);
    _projects = [..._projects];
    if (i < 0) {
      _projects.add(p);
    } else {
      _projects[i] = p;
    }
  }

  /// A save or delete went through: show it at once, then check in with the server in the background (which also
  /// refreshes its cached list for the next person, on servers that don't clear it on save).
  void _changed({_Project? saved, int? deletedId}) {
    _revision++;
    setState(() {
      if (saved != null) {
        _put(saved);
        _selectedId = saved.id;
      }
      if (deletedId != null) {
        final shown = _shownProjects;
        final at = shown.indexWhere((p) => p.id == deletedId);
        _projects = _projects.where((p) => p.id != deletedId).toList();
        if (_selectedId == deletedId) {
          final rest = shown.where((p) => p.id != deletedId).toList();
          _selectedId = rest.isEmpty ? null : rest[math.min(math.max(at, 0), rest.length - 1)].id;
        }
      }
    });
    unawaited(_load(fresh: true, quiet: true));
  }

  Future<_SaveOutcome> _save(_Project? existing, Map<String, dynamic> body, {required bool force}) async {
    try {
      final Map<String, dynamic> data;
      if (existing == null) {
        data = await _send('POST', '/projects', body: body);
      } else {
        data = await _send(
          'PUT',
          '/projects/${existing.id}',
          body: {...body, if (!force && existing.updatedAtRaw.isNotEmpty) 'ifUnchangedSince': existing.updatedAtRaw},
        );
      }
      if (!mounted) return (error: null, conflict: false);
      final j = data['project'];
      if (j is Map<String, dynamic>) {
        _changed(saved: _Project.fromJson(j));
      } else {
        // An older server that doesn't send the project back: the background check-in brings it.
        _changed();
      }
      return (error: null, conflict: false);
    } on _ApiError catch (e) {
      if (e.changedElsewhere) {
        unawaited(_load(fresh: true, quiet: true));
        return (
          error: 'Someone else saved this project after you opened it. Save anyway to replace their changes with yours, or cancel to see theirs.',
          conflict: true,
        );
      }
      return (error: e.message, conflict: false);
    } catch (e) {
      return (error: _friendly(e), conflict: false);
    }
  }

  Future<void> _openEditor(_Project? existing) async {
    if (existing == null ? !_canCreate : !_canUpdate) return;
    final exit = await showDialog<_EditorExit>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ProjectEditor(
        project: existing,
        people: _people,
        canDelete: existing != null && _canDelete,
        onSave: (body, {required bool force}) => _save(existing, body, force: force),
      ),
    );
    if (!mounted || exit == null) return;
    switch (exit) {
      case _EditorExit.added:
        _toast('Project added.');
        _revealSelected();
      case _EditorExit.saved:
        _toast('Project saved.');
      case _EditorExit.deleteRequested:
        final p = _byId(existing?.id);
        if (p != null) await _delete(p);
    }
  }

  /// Moves a project along the workflow from the detail pane or the row menu. Shown at once; put back if the save fails.
  Future<void> _setStatus(_Project p, String status, {String? undoTo}) async {
    if (!_canUpdate || p.status == status || _busy.contains(p.id)) return;
    final before = p;
    _revision++;
    setState(() {
      _busy.add(p.id);
      _put(p.withStatus(status));
    });
    try {
      final data = await _send(
        'PUT',
        '/projects/${p.id}',
        body: {
          ...p.body(status: status),
          if (p.updatedAtRaw.isNotEmpty) 'ifUnchangedSince': p.updatedAtRaw,
        },
      );
      if (!mounted) return;
      final j = data['project'];
      final saved = j is Map<String, dynamic> ? _Project.fromJson(j) : p.withStatus(status);
      _revision++;
      setState(() {
        _busy.remove(p.id);
        _put(saved);
      });
      unawaited(_load(fresh: true, quiet: true));
      if (undoTo == null) {
        _toast(
          '"${_clip(saved.title)}" moved to $status.',
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => _setStatus(_byId(saved.id) ?? saved, before.status, undoTo: before.status),
          ),
        );
      } else {
        _toast('Moved back to $status.');
      }
    } catch (e) {
      if (!mounted) return;
      _revision++;
      setState(() {
        _busy.remove(p.id);
        _put(before);
      });
      if (e is _ApiError && e.changedElsewhere) {
        _toast('Someone else changed this project just now, so the status was left as it was. Their version is showing.');
        unawaited(_load(fresh: true));
      } else {
        _toast("Couldn't change the status: ${_friendly(e)}");
      }
    }
  }

  Future<void> _delete(_Project p) async {
    if (!_canDelete) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AppDialog(
        title: 'Delete this project?',
        icon: Icons.delete_outline_rounded,
        iconColor: DashUi.redText,
        body: Text(
          '"${p.title}" will be removed from the tracker for everyone, with its notes and file links. This can\'t be undone.',
          style: const TextStyle(fontSize: 14, color: DashUi.slate, height: 1.45),
        ),
        actions: [AppButton.ghost('Cancel', () => Navigator.of(c).pop(false)), AppButton.ink('Delete project', () => Navigator.of(c).pop(true), danger: true)],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _busy.add(p.id));
    try {
      await _send('DELETE', '/projects/${p.id}');
      if (!mounted) return;
      _busy.remove(p.id);
      _changed(deletedId: p.id);
      _toast('Project deleted.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy.remove(p.id));
      if (e is _ApiError && e.status == 404) {
        _changed(deletedId: p.id);
        _toast('That project was already deleted.');
      } else {
        _toast("Couldn't delete the project: ${_friendly(e)}");
      }
    }
  }

  Future<void> _importSheet() async {
    setState(() => _importing = true);
    try {
      final data = await _send('POST', '/projects/import-sheet', timeout: const Duration(seconds: 60));
      if (!mounted) return;
      _toast('Imported ${data['imported'] ?? 0} projects from the sheet.');
      await _load(fresh: true);
    } catch (e) {
      if (mounted) _toast(_friendly(e));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  // ─── what's shown ─────────────────────────────────────────────────────────

  _Project? _byId(int? id) {
    if (id == null) return null;
    for (final p in _projects) {
      if (p.id == id) return p;
    }
    return null;
  }

  static String _clip(String s) => s.length <= 60 ? s : '${s.substring(0, 57).trimRight()}...';

  /// Everyone named on a project, for the people filter and the editor's suggestions.
  List<String> get _people {
    final names = <String>{
      for (final p in _projects) ...[p.owner, p.support, p.requestedBy],
      _session.name.trim(),
    }..remove('');
    return names.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  /// Owners and support people, with how many open projects each carries.
  List<(String, int)> get _crew {
    final counts = <String, int>{};
    for (final p in _projects) {
      for (final n in {p.owner, p.support}) {
        if (n.isEmpty) continue;
        counts[n] = (counts[n] ?? 0) + (p.isComplete ? 0 : 1);
      }
    }
    final list = counts.entries.map((e) => (e.key, e.value)).toList()
      ..sort((a, b) => b.$2 != a.$2 ? b.$2.compareTo(a.$2) : a.$1.toLowerCase().compareTo(b.$1.toLowerCase()));
    return list;
  }

  bool _matchesPerson(_Project p) {
    final who = _person;
    if (who == null) return true;
    final w = who.toLowerCase();
    return p.owner.toLowerCase() == w || p.support.toLowerCase() == w;
  }

  /// Every search word has to appear somewhere in the project (name, people, status, priority, notes, file names).
  bool _matchesQuery(_Project p) {
    final words = _query.trim().toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    if (words.isEmpty) return true;
    final text = p.searchText;
    return words.every(text.contains);
  }

  /// The projects the search and people filter leave, before the band's view. The band counts these, so every number
  /// on it is what clicking it shows.
  List<_Project> get _scoped => [
    for (final p in _projects)
      if (_matchesPerson(p) && _matchesQuery(p)) p,
  ];

  int _compare(_Project a, _Project b) {
    int byDeadline() {
      final x = a.deadline, y = b.deadline;
      if (x == null || y == null) return x == null ? (y == null ? 0 : 1) : -1; // no deadline last, either direction
      return _ascending ? x.compareTo(y) : y.compareTo(x);
    }

    int byName() => a.title.toLowerCase().compareTo(b.title.toLowerCase());
    final dir = _ascending ? 1 : -1;
    final c = switch (_sort) {
      _Sort.priority => dir * _rank(_priorities, a.priority).compareTo(_rank(_priorities, b.priority)),
      _Sort.name => dir * byName(),
      _Sort.owner => (a.owner.isEmpty != b.owner.isEmpty) ? (a.owner.isEmpty ? 1 : -1) : dir * a.owner.toLowerCase().compareTo(b.owner.toLowerCase()),
      _Sort.status => dir * _rank(_statuses, a.status).compareTo(_rank(_statuses, b.status)),
      _Sort.deadline => byDeadline(),
      _Sort.updated => dir * (b.updatedAt ?? DateTime(1970)).compareTo(a.updatedAt ?? DateTime(1970)),
    };
    if (c != 0) return c;
    // Ties: the nearest deadline, then the name, then the id, so the order never shuffles between reloads.
    if (_sort != _Sort.deadline) {
      final x = a.deadline, y = b.deadline;
      if (x != y) {
        if (x == null || y == null) return x == null ? 1 : -1;
        return x.compareTo(y);
      }
    }
    final n = byName();
    return n != 0 ? n : a.id.compareTo(b.id);
  }

  List<_Project> get _shownProjects {
    final list = [
      for (final p in _scoped)
        if (_view.matches(p)) p,
    ];
    list.sort((a, b) {
      // Unless grouped by status, finished work sinks below open work whatever the sort.
      if (_group != _Group.status && a.isComplete != b.isComplete) return a.isComplete ? 1 : -1;
      return _compare(a, b);
    });
    return list;
  }

  /// The register's rows: group headers (when grouping and there's more than one group) and projects.
  List<_Item> _items(List<_Project> shown) {
    if (_group == _Group.none) return [for (var i = 0; i < shown.length; i++) _ProjectItem(shown[i], i)];
    final groups = <String, List<_Project>>{};
    for (final p in shown) {
      groups.putIfAbsent(_group == _Group.status ? p.status : p.owner, () => []).add(p);
    }
    final keys = groups.keys.toList();
    if (_group == _Group.status) {
      keys.sort((a, b) => _rank(_statusGroupOrder, a).compareTo(_rank(_statusGroupOrder, b)));
    } else {
      // The person with the most open work first; projects with no owner at the end, where they stand out.
      keys.sort((a, b) {
        if (a.isEmpty != b.isEmpty) return a.isEmpty ? 1 : -1;
        final open = groups[b]!.where((p) => !p.isComplete).length.compareTo(groups[a]!.where((p) => !p.isComplete).length);
        return open != 0 ? open : a.toLowerCase().compareTo(b.toLowerCase());
      });
    }
    final single = keys.length == 1;
    final out = <_Item>[];
    var index = 0;
    for (final k in keys) {
      final key = '${_group.name}:$k';
      final folded = !single && _collapsed.contains(key);
      if (!single) {
        out.add(
          _GroupItem(
            key: key,
            label: _group == _Group.status ? k : (k.isEmpty ? 'No owner' : k),
            count: groups[k]!.length,
            dot: _group == _Group.status ? _statusColor(k) : null,
            person: _group == _Group.owner ? k : null,
            collapsed: folded,
          ),
        );
      }
      if (!folded) {
        for (final p in groups[k]!) {
          out.add(_ProjectItem(p, index++));
        }
      }
    }
    return out;
  }

  /// After a load or a filter change, keep the pane on a project the list shows.
  void _keepSelectionVisible() {
    final visible = _visibleProjects();
    if (visible.isEmpty) {
      // Everything left is in folded groups (or nothing matches): keep a selection that still matches, if any.
      if (!_shownProjects.any((p) => p.id == _selectedId)) _selectedId = null;
    } else if (!visible.any((p) => p.id == _selectedId)) {
      _selectedId = visible.first.id;
    }
  }

  void _setView(_View v) {
    setState(() {
      _view = v;
      _keepSelectionVisible();
    });
    _scrollToTop();
  }

  void _setPerson(String? who) {
    setState(() {
      _person = who;
      _keepSelectionVisible();
    });
    _scrollToTop();
  }

  void _setGroup(_Group g) {
    setState(() {
      _group = g;
      _keepSelectionVisible();
    });
    _scrollToTop();
  }

  void _setQuery(String q) {
    setState(() {
      _query = q;
      _keepSelectionVisible();
    });
  }

  void _clearFilters() {
    _search.clear();
    setState(() {
      _query = '';
      _person = null;
      _view = _View.open;
      _keepSelectionVisible();
    });
  }

  void _sortBy(_Sort s) {
    setState(() {
      if (_sort == s) {
        _ascending = !_ascending;
      } else {
        _sort = s;
        _ascending = true;
      }
    });
  }

  void _toggleGroup(String key) {
    setState(() => _collapsed.contains(key) ? _collapsed.remove(key) : _collapsed.add(key));
  }

  void _scrollToTop() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  // ─── keyboard ─────────────────────────────────────────────────────────────

  /// Up and down move through the list (unfolding nothing), keeping the selected row in view.
  void _step(int delta) {
    final shown = _visibleProjects();
    if (shown.isEmpty) return;
    final at = shown.indexWhere((p) => p.id == _selectedId);
    final next = at < 0 ? 0 : (at + delta).clamp(0, shown.length - 1);
    setState(() => _selectedId = shown[next].id);
    _revealSelected();
  }

  /// The projects on screen in order (folded groups left out).
  List<_Project> _visibleProjects() => [
    for (final i in _items(_shownProjects))
      if (i is _ProjectItem) i.project,
  ];

  void _revealSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final scale = MediaQuery.textScalerOf(context);
      final rowH = _ProjectList.rowExtent(scale);
      final groupH = _ProjectList.groupExtent(scale);
      var top = 0.0;
      for (final i in _items(_shownProjects)) {
        if (i is _ProjectItem && i.project.id == _selectedId) break;
        top += i is _GroupItem ? groupH : rowH;
      }
      final pos = _scroll.position;
      final double target;
      if (top < pos.pixels) {
        target = top;
      } else if (top + rowH > pos.pixels + pos.viewportDimension) {
        target = top + rowH - pos.viewportDimension;
      } else {
        return;
      }
      final to = target.clamp(0.0, pos.maxScrollExtent);
      _reduceMotion ? _scroll.jumpTo(to) : _scroll.animateTo(to, duration: const Duration(milliseconds: 160), curve: Curves.easeOutCubic);
    });
  }

  Map<ShortcutActivator, VoidCallback> _shortcuts(bool wide) => {
    const SingleActivator(LogicalKeyboardKey.arrowDown): () => _step(1),
    const SingleActivator(LogicalKeyboardKey.arrowUp): () => _step(-1),
    const SingleActivator(LogicalKeyboardKey.enter): () {
      final p = _byId(_selectedId);
      if (p == null) return;
      if (_canUpdate) {
        _openEditor(p);
      } else if (!wide) {
        _openDetailDialog(p);
      }
    },
    const SingleActivator(LogicalKeyboardKey.delete): () {
      final p = _byId(_selectedId);
      if (p != null) _delete(p);
    },
    const SingleActivator(LogicalKeyboardKey.slash): () => _searchFocus.requestFocus(),
    const SingleActivator(LogicalKeyboardKey.keyF, control: true): () => _searchFocus.requestFocus(),
  };

  // ─── menus ────────────────────────────────────────────────────────────────

  /// Right-click (or the row's More button): what can be done to one project, limited to what this person may do.
  Future<void> _showProjectMenu(_Project p, Offset at, {required bool wide}) async {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final busy = _busy.contains(p.id);
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: DashUi.line),
      ),
      items: [
        if (!wide) _menuItem('open', Icons.article_outlined, 'Open details'),
        if (_canUpdate) _menuItem('edit', Icons.edit_outlined, 'Edit project'),
        if (_canUpdate && !busy) ...[
          const PopupMenuDivider(),
          const PopupMenuItem<String>(
            enabled: false,
            height: 30,
            child: Text(
              'Move to',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.slate, letterSpacing: 0.4),
            ),
          ),
          for (final s in _statuses)
            if (s != p.status)
              PopupMenuItem<String>(
                value: 'status:$s',
                height: 38,
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(color: _statusColor(s), shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 12),
                    Text(s, style: const TextStyle(fontSize: 14, color: DashUi.ink)),
                  ],
                ),
              ),
        ],
        if (_canDelete && !busy) ...[const PopupMenuDivider(), _menuItem('delete', Icons.delete_outline_rounded, 'Delete project', danger: true)],
        if (!_canUpdate && !_canDelete && wide)
          const PopupMenuItem<String>(
            enabled: false,
            child: Text('You can view projects but not change them.', style: TextStyle(fontSize: 13, color: DashUi.slate)),
          ),
      ],
    );
    if (!mounted || choice == null) return;
    final now = _byId(p.id) ?? p;
    if (choice == 'open') {
      _openDetailDialog(now);
    } else if (choice == 'edit') {
      _openEditor(now);
    } else if (choice == 'delete') {
      _delete(now);
    } else if (choice.startsWith('status:')) {
      _setStatus(now, choice.substring(7));
    }
  }

  PopupMenuItem<String> _menuItem(String value, IconData icon, String label, {bool danger = false}) => PopupMenuItem<String>(
    value: value,
    height: 40,
    child: Row(
      children: [
        Icon(icon, size: 18, color: danger ? DashUi.redText : DashUi.slate),
        const SizedBox(width: 12),
        Text(
          label,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: danger ? DashUi.redText : DashUi.ink),
        ),
      ],
    ),
  );

  /// Narrow windows have no detail pane: the same details in a dialog.
  Future<void> _openDetailDialog(_Project p) async {
    setState(() => _selectedId = p.id);
    await showDialog<void>(
      context: context,
      builder: (c) => Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: DashUi.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
          child: ListenableBuilder(
            listenable: _detailTick,
            builder: (_, _) {
              final now = _byId(p.id);
              if (now == null) return const SizedBox(height: 120, child: Center(child: Text('This project was deleted.')));
              return _detailFor(now, onClose: () => Navigator.of(c).pop(), inDialog: true);
            },
          ),
        ),
      ),
    );
  }

  /// Lets an open detail dialog redraw when the project changes behind it (status moved, saved, deleted).
  final _detailTick = ValueNotifier<int>(0);

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _detailTick.value++;
  }

  Widget _detailFor(_Project p, {VoidCallback? onClose, bool inDialog = false}) => _ProjectDetail(
    project: p,
    busy: _busy.contains(p.id),
    canUpdate: _canUpdate,
    canDelete: _canDelete,
    inDialog: inDialog,
    onClose: onClose,
    onEdit: () {
      if (inDialog) onClose?.call();
      _openEditor(p);
    },
    onDelete: () {
      if (inDialog) onClose?.call();
      _delete(p);
    },
    onStatus: (s) => _setStatus(p, s),
    reduceMotion: _reduceMotion,
  );

  // ─── build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageBanner(
            title: 'Projects',
            icon: accessIcon('projects'),
            activity: _activity,
            actions: [
              if (_canCreate) PageBanner.button(icon: Icons.add_rounded, label: 'New project', onPressed: !_loaded ? null : () => _openEditor(null)),
              PageBanner.refresh(onPressed: _loading ? null : () => _load(fresh: true)),
            ],
          ),
          SizedBox(
            height: 3,
            child: _loading ? const LinearProgressIndicator(minHeight: 3, color: DashUi.blue, backgroundColor: DashUi.faint) : null,
          ),
          Expanded(child: PageSheet(child: _body())),
        ],
      ),
    );
  }

  Widget _body() {
    if (!_loaded && _error != null) {
      return Center(
        child: DashErrorPanel(title: "Couldn't load projects", message: _error!, onRetry: () => _load(fresh: true)),
      );
    }
    if (!_loaded) return _ProjectsSkeleton(slow: _slow);
    if (_projects.isEmpty) return _emptyBoard();

    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 1100;
        // About a third of the window, so wide screens give the notes room instead of stretching the name column.
        final paneWidth = (c.maxWidth * 0.3).clamp(400.0, 580.0).floorToDouble();
        final scoped = _scoped;
        final shown = _shownProjects;
        final items = _items(shown);
        final selected = _byId(_selectedId);
        return CallbackShortcuts(
          bindings: _shortcuts(wide),
          child: Focus(
            focusNode: _listFocus,
            autofocus: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _OverviewBand(scoped: scoped, total: _projects.length, view: _view, onView: _setView, reduceMotion: _reduceMotion),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _toolbar(shown.length, scoped.length),
                            if (_staleError != null) FlatStaleNotice(message: _staleError!, busy: _loading, onRetry: () => _load(fresh: true)),
                            Expanded(
                              child: shown.isEmpty
                                  ? _noMatches()
                                  : _ProjectList(
                                      items: items,
                                      selectedId: wide ? _selectedId : null,
                                      showStatus: _group != _Group.status,
                                      showOwner: _group != _Group.owner,
                                      busy: _busy,
                                      sort: _sort,
                                      ascending: _ascending,
                                      controller: _scroll,
                                      entrance: _entrance,
                                      onSort: _sortBy,
                                      onToggleGroup: _toggleGroup,
                                      onTap: (p) {
                                        _listFocus.requestFocus();
                                        if (wide) {
                                          setState(() => _selectedId = p.id);
                                        } else {
                                          _openDetailDialog(p);
                                        }
                                      },
                                      onDoubleTap: (p) => _canUpdate ? _openEditor(p) : (wide ? null : _openDetailDialog(p)),
                                      onMenu: (p, at) {
                                        // Right-click selects the row too, so the pane shows what the menu acts on.
                                        if (wide) setState(() => _selectedId = p.id);
                                        _showProjectMenu(p, at, wide: wide);
                                      },
                                    ),
                            ),
                          ],
                        ),
                      ),
                      if (wide)
                        SizedBox(
                          width: paneWidth,
                          child: DecoratedBox(
                            decoration: const BoxDecoration(
                              border: Border(left: BorderSide(color: DashUi.line)),
                            ),
                            child: selected == null
                                ? const _DetailPlaceholder()
                                : AnimatedSwitcher(
                                    duration: _reduceMotion ? Duration.zero : const Duration(milliseconds: 200),
                                    switchInCurve: Curves.easeOutCubic,
                                    switchOutCurve: Curves.easeInCubic,
                                    transitionBuilder: (child, a) => FadeTransition(
                                      opacity: a,
                                      child: SlideTransition(
                                        position: a.drive(Tween(begin: const Offset(0.02, 0), end: Offset.zero)),
                                        child: child,
                                      ),
                                    ),
                                    layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
                                    child: KeyedSubtree(key: ValueKey(selected.id), child: _detailFor(selected)),
                                  ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _toolbar(int shown, int scoped) {
    return LayoutBuilder(
      builder: (context, c) {
        final roomy = c.maxWidth >= 760;
        return Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 16, 12),
          child: Row(
            children: [
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 340),
                  child: TextField(
                    controller: _search,
                    focusNode: _searchFocus,
                    style: const TextStyle(fontSize: 14, color: DashUi.ink),
                    decoration: flatSearchDecoration(
                      'Search projects',
                      onClear: _query.isEmpty
                          ? null
                          : () {
                              _search.clear();
                              _setQuery('');
                            },
                    ),
                    onChanged: _setQuery,
                    onSubmitted: (_) => _listFocus.requestFocus(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _PeopleFilter(crew: _crew, me: _session.name.trim(), value: _person, onChanged: _setPerson),
              const SizedBox(width: 10),
              const Text(
                'Group',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.slate),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 210,
                child: AppSegmented<_Group>(
                  value: _group,
                  options: const [(_Group.status, 'Status'), (_Group.owner, 'Owner'), (_Group.none, 'None')],
                  onChanged: _setGroup,
                ),
              ),
              if (roomy) ...[
                const Spacer(),
                Text(
                  '$shown of ${_projects.length} ${_projects.length == 1 ? 'project' : 'projects'}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.slate, fontFeatures: flatFigures),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _noMatches() {
    final q = _query.trim();
    final filtered = q.isNotEmpty || _person != null;
    final scope = switch (_view) {
      _View.all => 'any project',
      _View.open => 'open projects',
      _View.overdue => 'overdue projects',
      _View.dueSoon => 'projects due this week',
      _View.unassigned => 'projects with no owner',
      _ => '${_view.label} projects',
    };
    final who = _person == null ? '' : ' for $_person';
    final (String title, String message) = filtered
        ? ('No projects match', q.isNotEmpty ? 'Nothing in $scope$who mentions "$q".' : 'No $scope$who.')
        : switch (_view) {
            _View.open => ('Everything is finished', 'Every project is marked Complete.'),
            _View.overdue => ('Nothing is overdue', 'No open project is past its deadline.'),
            _View.dueSoon => ('Nothing due this week', 'No open project has a deadline in the next 7 days.'),
            _View.unassigned => ('Every project has an owner', 'No open project is waiting for someone to own it.'),
            _ => ('No projects ${_view.label.toLowerCase()}', 'No project is in ${_view.label} right now.'),
          };
    return Center(
      child: SingleChildScrollView(
        child: FlatEmpty(
          icon: filtered ? Icons.search_off_rounded : Icons.task_alt_rounded,
          title: title,
          message: message,
          action: OutlinedButton.icon(
            onPressed: _clearFilters,
            icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
            label: Text(filtered ? 'Clear search and filters' : 'Show open projects'),
            style: OutlinedButton.styleFrom(
              foregroundColor: DashUi.ink,
              side: const BorderSide(color: DashUi.line),
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyBoard() {
    return Center(
      child: SingleChildScrollView(
        child: FlatEmpty(
          icon: Icons.folder_copy_outlined,
          title: 'No projects yet',
          message: _canCreate
              ? 'Add the first project, or copy everything over from the old project sheet.'
              : 'Projects will show here once someone adds them.',
          action: !_canCreate
              ? null
              : Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    AppButton.ink('New project', () => _openEditor(null), icon: Icons.add_rounded),
                    OutlinedButton.icon(
                      onPressed: _importing ? null : _importSheet,
                      icon: _importing
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.download_rounded, size: 18),
                      label: const Text('Import from the old sheet'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: DashUi.ink,
                        side: const BorderSide(color: DashUi.line),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

// ─── overview band ──────────────────────────────────────────────────────────
// The workflow stages left to right with how many projects sit in each, then what needs attention. Each segment is
// also the filter for the list below; the Open segment carries the pipeline as one stacked bar in the stage colours.

class _OverviewBand extends StatelessWidget {
  final List<_Project> scoped;
  final int total;
  final _View view;
  final ValueChanged<_View> onView;
  final bool reduceMotion;
  const _OverviewBand({required this.scoped, required this.total, required this.view, required this.onView, required this.reduceMotion});

  static const _stages = [_View.open, _View.planning, _View.inProgress, _View.inReview, _View.onHold, _View.complete, _View.all];
  static const _alerts = [_View.overdue, _View.dueSoon, _View.unassigned];

  @override
  Widget build(BuildContext context) {
    final counts = {for (final v in _View.values) v: scoped.where(v.matches).length};
    final open = [
      for (final p in scoped)
        if (!p.isComplete) p,
    ];
    final pipeline = [
      for (final s in const ['Planning', 'In Progress', 'In Review', 'On Hold']) (s, open.where((p) => p.status == s).length),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final n = _stages.length + _alerts.length;
        final narrow = (c.maxWidth - 1) / n < 112; // below this the segments go on two rows
        // Floored, and the divider's pixel kept back, so the segments never add up to more than the band.
        final seg = narrow ? (c.maxWidth / 5).floorToDouble() : ((c.maxWidth - 1) / n).clamp(112.0, 176.0).floorToDouble();
        Widget segment(_View v) => SizedBox(
          width: seg,
          child: _BandSegment(
            view: v,
            count: counts[v]!,
            selected: view == v,
            onTap: () => onView(v),
            reduceMotion: reduceMotion,
            pipeline: v == _View.open ? pipeline : null,
          ),
        );
        return Container(
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: DashUi.line)),
          ),
          child: narrow
              ? Wrap(
                  children: [
                    for (final v in [..._stages, ..._alerts]) segment(v),
                  ],
                )
              : Row(
                  children: [
                    for (final v in _stages) segment(v),
                    const Spacer(),
                    Container(width: 1, height: 44, color: DashUi.line),
                    for (final v in _alerts) segment(v),
                  ],
                ),
        );
      },
    );
  }
}

class _BandSegment extends StatefulWidget {
  final _View view;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final bool reduceMotion;
  final List<(String, int)>? pipeline;
  const _BandSegment({required this.view, required this.count, required this.selected, required this.onTap, required this.reduceMotion, this.pipeline});

  @override
  State<_BandSegment> createState() => _BandSegmentState();
}

class _BandSegmentState extends State<_BandSegment> {
  bool _hover = false;

  Color get _valueColor {
    final v = widget.view;
    if (widget.count == 0 && v.attention) return DashUi.subtle;
    return switch (v) {
      _View.overdue => DashUi.redText,
      _View.dueSoon => DashUi.amberText,
      _ => DashUi.ink,
    };
  }

  /// The stage's colour key, matching the Open bar and the status badges.
  Color? get _key => switch (widget.view.status) {
    final String s => _statusColor(s),
    null => null,
  };

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    final duration = widget.reduceMotion ? Duration.zero : const Duration(milliseconds: 160);
    final label = Row(
      children: [
        if (_key != null) ...[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: _key, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 6),
        ],
        if (v.attention && widget.count > 0) ...[
          Icon(
            v == _View.overdue ? Icons.error_outline_rounded : (v == _View.dueSoon ? Icons.schedule_rounded : Icons.person_off_outlined),
            size: 13,
            color: _valueColor,
          ),
          const SizedBox(width: 5),
        ],
        Flexible(
          child: Text(
            v.label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: widget.selected ? DashUi.ink : DashUi.slate),
          ),
        ),
      ],
    );
    final value = TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: widget.count.toDouble()),
      duration: widget.reduceMotion ? Duration.zero : const Duration(milliseconds: 650),
      curve: Curves.easeOutCubic,
      builder: (_, n, _) => Text(
        '${n.round()}',
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5, color: _valueColor, height: 1.15, fontFeatures: flatFigures),
      ),
    );
    final caption = v.caption;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: '${v.label}, ${widget.count}${caption == null ? '' : ', $caption'}',
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: duration,
            padding: const EdgeInsets.fromLTRB(16, 11, 10, 9),
            decoration: BoxDecoration(
              color: widget.selected ? DashUi.faint : (_hover ? DashUi.faint.withValues(alpha: 0.6) : Colors.white),
              border: Border(bottom: BorderSide(color: widget.selected ? DashUi.ink : Colors.transparent, width: 2.5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                label,
                const SizedBox(height: 3),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    value,
                    const SizedBox(width: 8),
                    if (widget.pipeline != null)
                      Expanded(
                        child: _PipelineBar(parts: widget.pipeline!, reduceMotion: widget.reduceMotion),
                      )
                    else if (caption != null)
                      Flexible(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            caption,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, color: DashUi.slate, height: 1.2),
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
    );
  }
}

/// Open work split by stage, as one rounded bar.
class _PipelineBar extends StatelessWidget {
  final List<(String, int)> parts;
  final bool reduceMotion;
  const _PipelineBar({required this.parts, required this.reduceMotion});

  @override
  Widget build(BuildContext context) {
    final total = parts.fold<int>(0, (s, p) => s + p.$2);
    final tip = total == 0 ? 'No open projects' : parts.where((p) => p.$2 > 0).map((p) => '${p.$1}: ${p.$2}').join('\n');
    return Tooltip(
      message: tip,
      child: Padding(
        padding: const EdgeInsets.only(top: 4, right: 4),
        child: LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth;
            return ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: Container(
                height: 7,
                color: DashUi.line,
                child: Row(
                  children: [
                    for (final p in parts)
                      if (total > 0 && p.$2 > 0)
                        TweenAnimationBuilder<double>(
                          // The share animates, not the pixels: the bar narrows while the count beside it grows, and a
                          // floored share of the current width can never add up to more than the bar.
                          tween: Tween(begin: 0, end: p.$2 / total),
                          duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 700),
                          curve: Curves.easeOutCubic,
                          builder: (_, share, _) => Container(
                            width: (w * share).floorToDouble(),
                            decoration: BoxDecoration(
                              color: _statusColor(p.$1),
                              border: const Border(right: BorderSide(color: Colors.white, width: 1)),
                            ),
                          ),
                        ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ─── toolbar pieces ─────────────────────────────────────────────────────────

/// "Everyone" or one person: owners and support, with their open project counts, and a shortcut to your own.
class _PeopleFilter extends StatelessWidget {
  final List<(String, int)> crew;
  final String me;
  final String? value;
  final ValueChanged<String?> onChanged;
  const _PeopleFilter({required this.crew, required this.me, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final mine = me.isNotEmpty && crew.any((c) => c.$1.toLowerCase() == me.toLowerCase());
    final label = value == null ? 'Everyone' : (value!.toLowerCase() == me.toLowerCase() ? 'My projects' : value!);
    final active = value != null;
    return PopupMenuButton<String>(
      tooltip: 'Show one person\'s projects',
      position: PopupMenuPosition.under,
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      constraints: const BoxConstraints(minWidth: 240, maxHeight: 420),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: DashUi.line),
      ),
      onSelected: (v) => onChanged(v.isEmpty ? null : v),
      itemBuilder: (_) => [
        _item('', 'Everyone', null, value == null),
        if (mine) _item(crew.firstWhere((c) => c.$1.toLowerCase() == me.toLowerCase()).$1, 'My projects', null, label == 'My projects'),
        const PopupMenuDivider(),
        for (final c in crew) _item(c.$1, c.$1, c.$2, value == c.$1, person: true),
      ],
      child: ClickCursor(child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: active ? DashUi.ink : DashUi.faint, borderRadius: BorderRadius.circular(10)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.people_alt_outlined, size: 18, color: active ? Colors.white : DashUi.slate),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: active ? Colors.white : DashUi.ink),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.expand_more_rounded, size: 18, color: active ? Colors.white : DashUi.slate),
          ],
        ),
      )),
    );
  }

  PopupMenuItem<String> _item(String value, String label, int? open, bool selected, {bool person = false}) => PopupMenuItem<String>(
    value: value,
    height: 40,
    child: Row(
      children: [
        if (person) ...[_PersonMark(value, size: 24), const SizedBox(width: 10)],
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, fontWeight: selected ? FontWeight.w800 : FontWeight.w500, color: DashUi.ink),
          ),
        ),
        if (open != null)
          Text(
            '$open open',
            style: const TextStyle(fontSize: 12.5, color: DashUi.slate, fontFeatures: flatFigures),
          ),
        if (selected) ...[const SizedBox(width: 8), const Icon(Icons.check_rounded, size: 18, color: DashUi.ink)],
      ],
    ),
  );
}

// ─── loading ────────────────────────────────────────────────────────────────

/// First load: the band, toolbar, rows and pane drawn in grey, so the page has its shape while the server answers.
class _ProjectsSkeleton extends StatelessWidget {
  final bool slow;
  const _ProjectsSkeleton({required this.slow});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading projects',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (slow)
            Semantics(
              liveRegion: true,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                color: DashUi.faint,
                child: const Text(
                  'Waking up the server, this can take up to a minute.',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.slate),
                ),
              ),
            ),
          Expanded(
            child: SkeletonPulse(
              child: LayoutBuilder(
                builder: (context, c) {
                  final wide = c.maxWidth >= 1100;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        height: 68,
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                        decoration: const BoxDecoration(
                          border: Border(bottom: BorderSide(color: DashUi.line)),
                        ),
                        child: Row(
                          children: [
                            for (var i = 0; i < 7; i++)
                              const Expanded(
                                child: Padding(
                                  padding: EdgeInsets.only(right: 24),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [SkeletonBox(h: 10, w: 64, r: 3), SizedBox(height: 8), SkeletonBox(h: 20, w: 36, r: 4)],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: ClipRect(
                                // Rows for a tall window, cut off at the bottom of a short one.
                                child: OverflowBox(
                                  alignment: Alignment.topCenter,
                                  maxHeight: double.infinity,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      const Padding(
                                        padding: EdgeInsets.fromLTRB(20, 12, 16, 12),
                                        child: Row(children: [SkeletonBox(h: 40, w: 300, r: 10), SizedBox(width: 10), SkeletonBox(h: 40, w: 130, r: 10)]),
                                      ),
                                      Container(height: 38, color: DashUi.faint),
                                      for (var r = 0; r < 12; r++)
                                        Container(
                                          height: 58,
                                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                                          decoration: const BoxDecoration(
                                            border: Border(bottom: BorderSide(color: DashUi.line)),
                                          ),
                                          child: const Row(
                                            children: [
                                              Expanded(
                                                flex: 5,
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    FractionallySizedBox(widthFactor: 0.7, child: SkeletonBox(h: 13, r: 4)),
                                                    SizedBox(height: 7),
                                                    FractionallySizedBox(widthFactor: 0.4, child: SkeletonBox(h: 10, r: 4)),
                                                  ],
                                                ),
                                              ),
                                              SizedBox(width: 24),
                                              Expanded(flex: 2, child: SkeletonBox(h: 13, r: 4)),
                                              SizedBox(width: 24),
                                              Expanded(flex: 2, child: SkeletonBox(h: 22, r: 11)),
                                              SizedBox(width: 24),
                                              Expanded(flex: 2, child: SkeletonBox(h: 13, r: 4)),
                                            ],
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            if (wide)
                              Container(
                                width: (c.maxWidth * 0.3).clamp(400.0, 580.0).floorToDouble(),
                                padding: const EdgeInsets.all(24),
                                decoration: const BoxDecoration(
                                  border: Border(left: BorderSide(color: DashUi.line)),
                                ),
                                child: const Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SkeletonBox(h: 22, w: 110, r: 11),
                                    SizedBox(height: 16),
                                    SkeletonBox(h: 18, r: 4),
                                    SizedBox(height: 8),
                                    SkeletonBox(h: 18, w: 220, r: 4),
                                    SizedBox(height: 28),
                                    SkeletonBox(h: 36, r: 8),
                                    SizedBox(height: 28),
                                    SkeletonBox(h: 80, r: 8),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The pane when the list is empty (nothing matches).
class _DetailPlaceholder extends StatelessWidget {
  const _DetailPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.article_outlined, size: 36, color: DashUi.muted),
            SizedBox(height: 12),
            Text(
              'No project selected',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: DashUi.ink),
            ),
            SizedBox(height: 4),
            Text(
              'Pick a project in the list to see its details here.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: DashUi.slate, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
