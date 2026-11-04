import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'config/access.dart';
import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';

const _statuses = ['Planning', 'In Progress', 'In Review', 'On Hold', 'Complete'];
const _openFilter = 'Open'; // every project that isn't Complete; the default view
const _overdueFilter = 'Overdue'; // open projects past their deadline
const _statusFilters = [_openFilter, 'In Progress', 'In Review', 'Planning', 'On Hold', 'Complete'];
const _priorities = ['Urgent', 'High', 'Medium', 'Low'];

class _ProjectFile {
  String name;
  String url;
  _ProjectFile(this.name, this.url);
}

class _Project {
  final int id;
  final String name, owner, support, requestedBy, priority, status, notes;
  final DateTime? deadline;
  final List<_ProjectFile> files;

  _Project(Map<String, dynamic> j)
    : id = (j['id'] as num).toInt(),
      name = '${j['name'] ?? ''}'.trim(),
      owner = '${j['owner'] ?? ''}',
      support = '${j['support'] ?? ''}',
      requestedBy = '${j['requestedBy'] ?? ''}',
      priority = '${j['priority'] ?? ''}',
      status = '${j['status'] ?? ''}',
      notes = '${j['notes'] ?? ''}',
      deadline = DateTime.tryParse('${j['deadline'] ?? ''}'),
      files = [for (final f in (j['files'] as List? ?? const [])) _ProjectFile('${(f as Map)['name'] ?? ''}', '${f['url'] ?? ''}')];

  bool get isComplete => status == 'Complete';

  bool get overdue {
    final d = deadline;
    if (isComplete || d == null) return false;
    final now = DateTime.now();
    return d.isBefore(DateTime(now.year, now.month, now.day));
  }
}

String _date(DateTime? d) {
  if (d == null) return '';
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${m[d.month - 1]} ${d.day}, ${d.year}';
}

/// The server only takes http(s) links, and people paste "drive.google.com/..." without the scheme.
String _withScheme(String url) {
  final u = url.trim();
  if (u.isEmpty || RegExp(r'^https?://', caseSensitive: false).hasMatch(u)) return u;
  return 'https://${u.replaceFirst(RegExp(r'^/+'), '')}';
}

String _isoDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

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

class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key});

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  List<_Project> _projects = [];
  bool _loading = true;
  bool _importing = false;
  String? _error;
  int _requestId = 0;

  final _search = TextEditingController();
  String _query = '';
  String? _status = _openFilter; // null = all

  final _session = AuthSession.instance;
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
    _search.dispose();
    super.dispose();
  }

  /// One API call. Returns the decoded body; throws an Exception with a message fit to show the person.
  Future<Map<String, dynamic>> _send(String method, String path, [Map<String, dynamic>? body]) async {
    final req = http.Request(method, Uri.parse('$kApiBaseUrl/api$path'))..headers.addAll(_session.headers());
    if (body != null) req.body = json.encode(body);
    final res = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 30)));
    if (res.statusCode == 401) {
      _session.logout();
      throw Exception('Your session expired. Sign in again.');
    }
    Map<String, dynamic> data = {};
    try {
      data = json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {}
    if (res.statusCode >= 400) throw Exception(data['error'] ?? 'Server error (${res.statusCode})');
    return data;
  }

  Future<void> _load({bool fresh = false}) async {
    final id = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await _send('GET', '/projects${fresh ? '?fresh=1' : ''}');
      if (!mounted || id != _requestId) return;
      setState(() {
        _projects = [for (final j in (data['projects'] as List? ?? const [])) _Project(j as Map<String, dynamic>)];
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      final msg = e.toString().replaceFirst('Exception: ', '');
      setState(() {
        _error = msg;
        _loading = false;
      });
      // With projects already on screen the error panel isn't shown, so say the refresh failed.
      if (_projects.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Couldn't refresh projects: $msg"),
            action: SnackBarAction(label: 'Try again', onPressed: () => _load(fresh: true)),
          ),
        );
      }
    }
  }

  bool _matchesStatus(_Project p, String? filter) => switch (filter) {
    null => true,
    _openFilter => !p.isComplete,
    _overdueFilter => p.overdue,
    _ => p.status == filter,
  };

  Widget _filterChip(String? filter) {
    final selected = _status == filter;
    final count = _count(filter);
    final alert = filter == _overdueFilter;
    final tone = alert ? DashUi.redText : DashUi.ink;
    return ChoiceChip(
      label: Text('${filter ?? 'All'}  $count'),
      selected: selected,
      showCheckmark: false,
      labelStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: selected ? Colors.white : tone),
      backgroundColor: Colors.white,
      selectedColor: tone,
      side: BorderSide(color: selected ? tone : (alert ? DashUi.redText.withValues(alpha: 0.4) : DashUi.line)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      onSelected: (_) => setState(() => _status = filter),
    );
  }

  int _count(String? filter) => _projects.where((p) => _matchesStatus(p, filter)).length;

  List<_Project> get _shown {
    final q = _query.trim().toLowerCase();
    final list = [
      for (final p in _projects)
        if (_matchesStatus(p, _status) && (q.isEmpty || '${p.name} ${p.owner} ${p.support} ${p.requestedBy}'.toLowerCase().contains(q))) p,
    ];
    // Open work first (by priority, then deadline); finished projects sink to the bottom.
    list.sort((a, b) {
      if (a.isComplete != b.isComplete) return a.isComplete ? 1 : -1;
      final byPriority = _rank(_priorities, a.priority).compareTo(_rank(_priorities, b.priority));
      if (byPriority != 0) return byPriority;
      if (a.deadline == null || b.deadline == null) return a.deadline == null ? (b.deadline == null ? 0 : 1) : -1;
      return a.deadline!.compareTo(b.deadline!);
    });
    return list;
  }

  List<String> get _people {
    final names = <String>{
      for (final p in _projects) ...[p.owner, p.support, p.requestedBy],
    }..remove('');
    return names.toList()..sort();
  }

  Future<void> _edit(_Project? existing) async {
    final changed = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _ProjectEditor(
        project: existing,
        people: _people,
        canSave: existing == null ? _canCreate : _canUpdate,
        canDelete: existing != null && _canDelete,
        onSave: (body) async {
          try {
            if (existing == null) {
              await _send('POST', '/projects', body);
            } else {
              await _send('PUT', '/projects/${existing.id}', body);
            }
            return null;
          } catch (e) {
            return e.toString().replaceFirst('Exception: ', '');
          }
        },
        onDelete: () async {
          try {
            await _send('DELETE', '/projects/${existing!.id}');
            return null;
          } catch (e) {
            return e.toString().replaceFirst('Exception: ', '');
          }
        },
      ),
    );
    if (changed == null || !mounted) return;
    await _load(fresh: true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(changed)));
  }

  Future<void> _importSheet() async {
    setState(() => _importing = true);
    try {
      final data = await _send('POST', '/projects/import-sheet');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Imported ${data['imported']} projects from the sheet.')));
      await _load(fresh: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageBanner(
            title: 'Project Tracker',
            icon: accessIcon('projects'),
            actions: [
              if (_canCreate) PageBanner.button(icon: Icons.add_rounded, label: 'New Project', onPressed: _loading ? null : () => _edit(null)),
              PageBanner.refresh(onPressed: _loading ? null : () => _load(fresh: true)),
            ],
          ),
          SizedBox(height: 3, child: _loading ? const LinearProgressIndicator(minHeight: 3) : null),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && _projects.isEmpty) return const SizedBox.shrink(); // the progress strip above shows it's loading
    if (_error != null && _projects.isEmpty) {
      return Center(
        child: DashErrorPanel(title: "Couldn't load projects", message: _error!, onRetry: () => _load(fresh: true)),
      );
    }
    if (_projects.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FlatEmpty(
              icon: Icons.folder_copy_outlined,
              title: 'No projects yet',
              message: _canCreate
                  ? 'Add the first project, or copy everything over from the old project sheet.'
                  : 'Projects will show here once someone adds them.',
            ),
            if (_session.isAdmin)
              OutlinedButton.icon(
                onPressed: _importing ? null : _importSheet,
                icon: _importing
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.download_rounded, size: 18),
                label: const Text('Import from the old sheet'),
              ),
          ],
        ),
      );
    }

    final shown = _shown;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 320,
                child: TextField(
                  controller: _search,
                  decoration: flatSearchDecoration('Search projects or people').copyWith(
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: () => setState(() {
                              _search.clear();
                              _query = '';
                            }),
                          ),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              for (final s in [..._statusFilters.take(1), null, ..._statusFilters.skip(1)]) _filterChip(s),
              // Only offered when something is late, so it reads as a warning rather than another empty tab.
              if (_count(_overdueFilter) > 0 || _status == _overdueFilter) _filterChip(_overdueFilter),
            ],
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? const Center(
                  child: FlatEmpty(
                    icon: Icons.search_off_rounded,
                    title: 'No projects found',
                    message: 'Try a different search, or pick All to include every status.',
                  ),
                )
              : _ProjectGrid(projects: shown, onTap: _edit),
        ),
      ],
    );
  }
}

// ─── editor dialog ──────────────────────────────────────────────────────────

class _ProjectEditor extends StatefulWidget {
  final _Project? project; // null = new
  final List<String> people;
  final bool canSave;
  final bool canDelete;

  /// Each returns an error message, or null when it worked.
  final Future<String?> Function(Map<String, dynamic> body) onSave;
  final Future<String?> Function() onDelete;

  const _ProjectEditor({
    required this.project,
    required this.people,
    required this.canSave,
    required this.canDelete,
    required this.onSave,
    required this.onDelete,
  });

  @override
  State<_ProjectEditor> createState() => _ProjectEditorState();
}

class _FileRow {
  final TextEditingController name;
  final TextEditingController url;
  _FileRow(String n, String u) : name = TextEditingController(text: n), url = TextEditingController(text: u);
  void dispose() {
    name.dispose();
    url.dispose();
  }
}

class _ProjectEditorState extends State<_ProjectEditor> {
  late final _name = TextEditingController(text: widget.project?.name ?? '');
  late final _owner = TextEditingController(text: widget.project?.owner ?? '');
  late final _support = TextEditingController(text: widget.project?.support ?? '');
  late final _requestedBy = TextEditingController(text: widget.project?.requestedBy ?? '');
  late final _notes = TextEditingController(text: widget.project?.notes ?? '');
  late String _priority = widget.project?.priority ?? '';
  late String _status = widget.project?.status.isNotEmpty == true ? widget.project!.status : 'Planning';
  late DateTime? _deadline = widget.project?.deadline;
  late final List<_FileRow> _files = [for (final f in widget.project?.files ?? const <_ProjectFile>[]) _FileRow(f.name, f.url)];

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _owner, _support, _requestedBy, _notes]) {
      c.dispose();
    }
    for (final f in _files) {
      f.dispose();
    }
    super.dispose();
  }

  bool get _readOnly => !widget.canSave;

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'A project needs a name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.onSave({
      'name': _name.text.trim(),
      'owner': _owner.text.trim(),
      'support': _support.text.trim(),
      'requestedBy': _requestedBy.text.trim(),
      'priority': _priority,
      'status': _status,
      'deadline': _deadline == null ? '' : _isoDate(_deadline!),
      'notes': _notes.text,
      'files': [
        for (final f in _files)
          if (f.name.text.trim().isNotEmpty || f.url.text.trim().isNotEmpty) {'name': f.name.text.trim(), 'url': _withScheme(f.url.text)},
      ],
    });
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop(widget.project == null ? 'Project added.' : 'Project saved.');
    } else {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  Future<void> _delete() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this project?'),
        content: Text('"${widget.project!.name}" will be removed from the tracker. This can\'t be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: DashUi.red),
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.onDelete();
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop('Project deleted.');
    } else {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  Future<void> _pickDeadline() async {
    final now = DateTime.now();
    final initial = _deadline ?? now;
    // The picker asserts if the current deadline falls outside its range, so widen the range to include it.
    final first = DateTime(now.year - 5);
    final last = DateTime(now.year + 10);
    final d = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: initial.isBefore(first) ? initial : first,
      lastDate: initial.isAfter(last) ? initial : last,
    );
    if (d != null) setState(() => _deadline = d);
  }

  Widget _personField(String label, TextEditingController c) {
    return TextField(
      controller: c,
      readOnly: _readOnly,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
        suffixIcon: _readOnly || widget.people.isEmpty
            ? null
            : PopupMenuButton<String>(
                tooltip: 'Pick someone',
                icon: const Icon(Icons.arrow_drop_down_rounded),
                onSelected: (v) => setState(() => c.text = v),
                itemBuilder: (_) => [for (final p in widget.people) PopupMenuItem(value: p, child: Text(p))],
              ),
      ),
    );
  }

  Widget _dropdown(String label, String value, List<String> options, ValueChanged<String> onChanged, {bool allowBlank = false}) {
    final items = [if (allowBlank) '', ...options, if (value.isNotEmpty && !options.contains(value)) value];
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
      items: [for (final o in items) DropdownMenuItem(value: o, child: Text(o.isEmpty ? 'None' : o))],
      onChanged: _readOnly ? null : (v) => onChanged(v ?? ''),
    );
  }

  Widget _fileRow(int i) {
    final f = _files[i];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: TextField(
              controller: f.name,
              readOnly: _readOnly,
              decoration: const InputDecoration(labelText: 'File name', border: OutlineInputBorder(), isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: TextField(
              controller: f.url,
              readOnly: _readOnly,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Link (paste a Drive or web link)', border: OutlineInputBorder(), isDense: true),
            ),
          ),
          IconButton(
            tooltip: 'Open file',
            icon: const Icon(Icons.open_in_new_rounded, size: 20),
            onPressed: f.url.text.trim().isEmpty ? null : () => _openLink(context, f.url.text.trim()),
          ),
          if (!_readOnly)
            IconButton(
              tooltip: 'Remove file',
              icon: const Icon(Icons.close_rounded, size: 20),
              onPressed: () => setState(() => _files.removeAt(i).dispose()),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 14);
    return AlertDialog(
      title: Text(widget.project == null ? 'New project' : (_readOnly ? 'Project' : 'Edit project')),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 4),
              TextField(
                controller: _name,
                readOnly: _readOnly,
                autofocus: widget.project == null,
                decoration: const InputDecoration(labelText: 'Project name', border: OutlineInputBorder(), isDense: true),
              ),
              gap,
              Row(
                children: [
                  Expanded(child: _personField('Owner', _owner)),
                  const SizedBox(width: 12),
                  Expanded(child: _personField('Support', _support)),
                ],
              ),
              gap,
              Row(
                children: [
                  Expanded(child: _personField('Requested by', _requestedBy)),
                  const SizedBox(width: 12),
                  Expanded(child: _dropdown('Priority', _priority, _priorities, (v) => setState(() => _priority = v), allowBlank: true)),
                ],
              ),
              gap,
              Row(
                children: [
                  Expanded(child: _dropdown('Status', _status, _statuses, (v) => setState(() => _status = v))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: InkWell(
                      onTap: _readOnly ? null : _pickDeadline,
                      child: InputDecorator(
                        decoration: InputDecoration(
                          labelText: 'Deadline',
                          border: const OutlineInputBorder(),
                          isDense: true,
                          suffixIcon: _deadline != null && !_readOnly
                              ? IconButton(
                                  tooltip: 'Clear deadline',
                                  icon: const Icon(Icons.close_rounded, size: 18),
                                  onPressed: () => setState(() => _deadline = null),
                                )
                              : const Icon(Icons.calendar_today_rounded, size: 18),
                        ),
                        child: Text(_deadline == null ? 'None' : _date(_deadline)),
                      ),
                    ),
                  ),
                ],
              ),
              gap,
              TextField(
                controller: _notes,
                readOnly: _readOnly,
                minLines: 4,
                maxLines: 10,
                decoration: const InputDecoration(labelText: 'Notes', border: OutlineInputBorder(), alignLabelWithHint: true),
              ),
              gap,
              const Text(
                'Files',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: DashUi.ink),
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < _files.length; i++) _fileRow(i),
              if (!_readOnly)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _files.add(_FileRow('', ''))),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Add file'),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: DashUi.red, fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        if (widget.canDelete)
          TextButton(
            onPressed: _busy ? null : _delete,
            style: TextButton.styleFrom(foregroundColor: DashUi.red),
            child: const Text('Delete'),
          )
        else
          const SizedBox.shrink(),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: Text(_readOnly ? 'Close' : 'Cancel')),
            if (!_readOnly) ...[
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Save'),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

// ─── grid ───────────────────────────────────────────────────────────────────
// A flat register like Payroll and Inventory: hairline rows, people as initials, status and priority as small marks
// instead of filled cells, so the eye lands on what's urgent or late.

/// Avatar colours, picked by name so a person keeps the same one everywhere on the page.
const _personColors = [DashUi.blue, DashUi.emeraldDeep, DashUi.amberText, DashUi.indigo, DashUi.sky, DashUi.redText, DashUi.slate];

Color _personColor(String name) {
  var h = 0;
  for (final c in name.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return _personColors[h % _personColors.length];
}

String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '';
  return (parts.first[0] + (parts.length > 1 ? parts.last[0] : '')).toUpperCase();
}

Color _statusColor(String s) => switch (s) {
  'In Progress' => DashUi.blue,
  'In Review' => DashUi.indigo,
  'On Hold' => DashUi.amber,
  'Complete' => DashUi.emerald,
  _ => DashUi.muted, // Planning
};

/// Filled bars out of three, and the colour they're drawn in.
(int, Color) _priorityLevel(String p) => switch (p) {
  'Urgent' => (3, DashUi.red),
  'High' => (3, DashUi.amber),
  'Medium' => (2, DashUi.slate),
  'Low' => (1, DashUi.slate),
  _ => (0, DashUi.slate),
};

/// "6 days overdue" / "Due tomorrow" for open work that's late or due within a week; null otherwise.
(String, Color)? _deadlineNote(_Project p) {
  final d = p.deadline;
  if (d == null || p.isComplete) return null;
  final now = DateTime.now();
  final days = DateTime(d.year, d.month, d.day).difference(DateTime(now.year, now.month, now.day)).inDays;
  if (days < 0) return ('${-days} ${days == -1 ? 'day' : 'days'} overdue', DashUi.redText);
  if (days == 0) return ('Due today', DashUi.amberText);
  if (days == 1) return ('Due tomorrow', DashUi.amberText);
  if (days <= 7) return ('Due in $days days', DashUi.amberText);
  return null;
}

class _GridCol {
  final String label;
  final double? width; // null = takes the remaining width
  const _GridCol(this.label, this.width);
}

const _gutter = 24.0;
const _gridCols = [
  _GridCol('Project', 280),
  _GridCol('Owner', 200),
  _GridCol('Priority', 110),
  _GridCol('Status', 140),
  _GridCol('Deadline', 150),
  _GridCol('Files', 180),
  _GridCol('Notes', null),
];
const _notesMinWidth = 260.0;

class _ProjectGrid extends StatelessWidget {
  final List<_Project> projects;
  final void Function(_Project) onTap;
  const _ProjectGrid({required this.projects, required this.onTap});

  static const _base = TextStyle(fontSize: 14.5, color: DashUi.ink, height: 1.3);
  static const _meta = TextStyle(fontSize: 13, color: DashUi.slate, height: 1.3);

  /// First column gets the page gutter on the left, last one on the right.
  Widget _cell(int col, Widget child) {
    final w = _gridCols[col].width;
    final box = Padding(
      padding: EdgeInsets.fromLTRB(col == 0 ? _gutter : 0, 0, col == _gridCols.length - 1 ? _gutter : 16, 0),
      child: Align(alignment: Alignment.centerLeft, child: child),
    );
    return w == null ? Expanded(child: box) : SizedBox(width: w, child: box);
  }

  Widget _project(_Project p) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        p.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: _base.copyWith(fontWeight: FontWeight.w700, color: p.isComplete ? DashUi.slate : DashUi.ink),
      ),
      if (p.requestedBy.isNotEmpty && p.requestedBy != p.owner)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text('Requested by ${p.requestedBy}', maxLines: 1, overflow: TextOverflow.ellipsis, style: _meta),
        ),
    ],
  );

  Widget _avatar(String name) {
    final c = _personColor(name);
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.withValues(alpha: 0.13), shape: BoxShape.circle),
      child: Text(
        _initials(name),
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: c),
      ),
    );
  }

  Widget _people(_Project p) {
    if (p.owner.isEmpty) return const Text('No owner', style: _meta);
    return Row(
      children: [
        _avatar(p.owner),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                p.owner,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _base.copyWith(fontWeight: FontWeight.w600),
              ),
              if (p.support.isNotEmpty && p.support != p.owner) Text('with ${p.support}', maxLines: 1, overflow: TextOverflow.ellipsis, style: _meta),
            ],
          ),
        ),
      ],
    );
  }

  Widget _priority(String p) {
    if (p.isEmpty) return const SizedBox.shrink();
    final (level, color) = _priorityLevel(p);
    final urgent = p == 'Urgent';
    return Row(
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
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            p,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _base.copyWith(fontWeight: urgent ? FontWeight.w800 : FontWeight.w500, color: urgent ? DashUi.redText : DashUi.ink),
          ),
        ),
      ],
    );
  }

  Widget _status(String s) {
    if (s.isEmpty) return const SizedBox.shrink();
    final c = _statusColor(s);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 5, 12, 5),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              s,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.ink),
            ),
          ),
        ],
      ),
    );
  }

  Widget _deadline(_Project p) {
    if (p.deadline == null) return const SizedBox.shrink();
    final note = _deadlineNote(p);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _date(p.deadline),
          style: _base.copyWith(
            fontFeatures: flatFigures,
            color: p.isComplete ? DashUi.slate : DashUi.ink,
            fontWeight: p.overdue ? FontWeight.w700 : null,
          ),
        ),
        if (note != null)
          Text(
            note.$1,
            style: _meta.copyWith(color: note.$2, fontWeight: FontWeight.w700),
          ),
      ],
    );
  }

  Widget _fileChip(BuildContext context, _ProjectFile f) {
    final linked = f.url.trim().isNotEmpty;
    final chip = Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(linked ? Icons.description_rounded : Icons.link_off_rounded, size: 16, color: linked ? DashUi.blue : DashUi.muted),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              f.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: linked ? DashUi.blue : DashUi.slate),
            ),
          ),
        ],
      ),
    );
    if (!linked) return Tooltip(message: 'No link yet. Open the project to add one.', child: chip);
    return Tooltip(
      message: 'Open ${f.name}',
      child: InkWell(borderRadius: BorderRadius.circular(6), onTap: () => _openLink(context, f.url.trim()), child: chip),
    );
  }

  Widget _row(BuildContext context, _Project p) {
    return InkWell(
      onTap: () => onTap(p),
      hoverColor: DashUi.faint,
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: DashUi.line)),
        ),
        child: Row(
          children: [
            _cell(0, _project(p)),
            _cell(1, _people(p)),
            _cell(2, _priority(p.priority)),
            _cell(3, _status(p.status)),
            _cell(4, _deadline(p)),
            _cell(
              5,
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [for (final f in p.files) _fileChip(context, f)],
              ),
            ),
            // Blank lines would spend one of the three preview lines on nothing.
            _cell(
              6,
              Text(
                p.notes.trim().replaceAll(RegExp(r'\n\s*\n'), '\n'),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: _meta.copyWith(fontSize: 13.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fixed = _gridCols.fold<double>(0, (s, c) => s + (c.width ?? 0));
    return LayoutBuilder(
      builder: (context, c) {
        final width = c.maxWidth < fixed + _notesMinWidth ? fixed + _notesMinWidth : c.maxWidth;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  decoration: const BoxDecoration(
                    color: DashUi.faint,
                    border: Border(
                      top: BorderSide(color: DashUi.line),
                      bottom: BorderSide(color: DashUi.line),
                    ),
                  ),
                  child: Row(
                    children: [
                      for (var i = 0; i < _gridCols.length; i++)
                        _cell(
                          i,
                          Text(
                            _gridCols[i].label,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: DashUi.ink),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(itemCount: projects.length, itemBuilder: (_, i) => _row(context, projects[i])),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
