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
const _statusFilters = ['In Progress', 'In Review', 'Planning', 'On Hold', 'Complete'];
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
      files = [
        for (final f in (j['files'] as List? ?? const []))
          _ProjectFile('${(f as Map)['name'] ?? ''}', '${f['url'] ?? ''}'),
      ];

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

String _isoDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

int _rank(List<String> order, String v) {
  final i = order.indexOf(v);
  return i < 0 ? order.length : i;
}

Future<void> _openLink(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
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

  String _query = '';
  String? _status; // null = all

  final _session = AuthSession.instance;
  bool get _canCreate => _session.can('projects', AccessAction.create);
  bool get _canUpdate => _session.can('projects', AccessAction.update);
  bool get _canDelete => _session.can('projects', AccessAction.delete);

  @override
  void initState() {
    super.initState();
    _load();
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
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  List<_Project> get _shown {
    final q = _query.trim().toLowerCase();
    final list = [
      for (final p in _projects)
        if ((_status == null || p.status == _status) &&
            (q.isEmpty || '${p.name} ${p.owner} ${p.support} ${p.requestedBy}'.toLowerCase().contains(q)))
          p,
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
            actions: [
              if (_canCreate) PageBanner.button(icon: Icons.add_rounded, label: 'New Project', onPressed: _loading ? null : () => _edit(null)),
              PageBanner.refresh(onPressed: _loading ? null : () => _load(fresh: true)),
            ],
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && _projects.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_error != null && _projects.isEmpty) {
      return Center(child: DashErrorPanel(title: "Couldn't load projects", message: _error!, onRetry: () => _load(fresh: true)));
    }
    if (_projects.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const FlatEmpty(
              icon: Icons.folder_copy_outlined,
              title: 'No projects yet',
              message: 'Add the first project, or copy everything over from the old project sheet.',
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
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 12),
          child: Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 320,
                child: TextField(
                  decoration: flatSearchDecoration('Search projects or people'),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              for (final s in [null, ..._statusFilters])
                ChoiceChip(label: Text(s ?? 'All'), selected: _status == s, onSelected: (_) => setState(() => _status = s)),
            ],
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? const Center(
                  child: FlatEmpty(
                    icon: Icons.search_off_rounded,
                    title: 'No projects found',
                    message: 'Try a different search or status filter.',
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
      'name': _name.text,
      'owner': _owner.text,
      'support': _support.text,
      'requestedBy': _requestedBy.text,
      'priority': _priority,
      'status': _status,
      'deadline': _deadline == null ? '' : _isoDate(_deadline!),
      'notes': _notes.text,
      'files': [
        for (final f in _files)
          if (f.name.text.trim().isNotEmpty || f.url.text.trim().isNotEmpty) {'name': f.name.text, 'url': f.url.text},
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
    final d = await showDatePicker(
      context: context,
      initialDate: _deadline ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 10),
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
              Row(children: [Expanded(child: _personField('Owner', _owner)), const SizedBox(width: 12), Expanded(child: _personField('Support', _support))]),
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
                              ? IconButton(tooltip: 'Clear deadline', icon: const Icon(Icons.close_rounded, size: 18), onPressed: () => setState(() => _deadline = null))
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
              const Text('Files', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: DashUi.ink)),
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
                  child: Text(_error!, style: const TextStyle(color: DashUi.red, fontSize: 14, fontWeight: FontWeight.w600)),
                ),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        if (widget.canDelete)
          TextButton(onPressed: _busy ? null : _delete, style: TextButton.styleFrom(foregroundColor: DashUi.red), child: const Text('Delete'))
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
                child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Save'),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

// ─── grid ───────────────────────────────────────────────────────────────────
// Spreadsheet-style grid: a tinted cell per person / priority / status, clickable file chips, wrapped notes.
const _personTints = [
  Color(0xFFE1CCF0), Color(0xFFF8C9AB), Color(0xFFC5DAE0), Color(0xFFD3E8C4),
  Color(0xFFF4D0DA), Color(0xFFCFD8F5), Color(0xFFF1E3B5), Color(0xFFC9EBE3),
];

Color _personTint(String name) {
  var h = 0;
  for (final c in name.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return _personTints[h % _personTints.length];
}

Color? _priorityTint(String p) => switch (p) {
  'Urgent' => const Color(0xFFF2A9A0),
  'High' => const Color(0xFFF7BC78),
  'Medium' => const Color(0xFFEDD97E),
  'Low' => const Color(0xFFCDE6B8),
  _ => null,
};

Color? _statusTint(String s) => switch (s) {
  'In Progress' => const Color(0xFFEFEAA6),
  'In Review' => const Color(0xFFC9DAF5),
  'Planning' => const Color(0xFFE4E4E4),
  'On Hold' => const Color(0xFFF7D9B0),
  'Complete' => const Color(0xFFCDE6B8),
  _ => null,
};

class _GridCol {
  final String label;
  final double? width; // null = takes the remaining width
  const _GridCol(this.label, this.width);
}

const _gridCols = [
  _GridCol('Project Name', 200),
  _GridCol('Owner', 125),
  _GridCol('Support', 125),
  _GridCol('Requested By', 140),
  _GridCol('Priority', 95),
  _GridCol('Status', 110),
  _GridCol('Deadline', 115),
  _GridCol('Files', 160),
  _GridCol('Notes', null),
];
const _notesMinWidth = 300.0;

class _ProjectGrid extends StatelessWidget {
  final List<_Project> projects;
  final void Function(_Project) onTap;
  const _ProjectGrid({required this.projects, required this.onTap});

  static const _border = BorderSide(color: Color(0x33000000));

  Widget _cell(int col, Widget child, {Color? tint, Alignment align = Alignment.center}) {
    final w = _gridCols[col].width;
    final box = Container(
      alignment: align,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(color: tint, border: const Border(right: _border)),
      child: child,
    );
    return w == null ? Expanded(child: box) : SizedBox(width: w, child: box);
  }

  Widget _person(int col, String name) => _cell(
    col,
    Text(name, style: const TextStyle(fontSize: 15, color: DashUi.ink), textAlign: TextAlign.center),
    tint: name.isEmpty ? null : _personTint(name),
  );

  Widget _fileChip(BuildContext context, _ProjectFile f) {
    final linked = f.url.trim().isNotEmpty;
    final chip = Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(linked ? Icons.description_rounded : Icons.link_off_rounded, size: 14, color: linked ? DashUi.blue : DashUi.muted),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              f.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: linked ? DashUi.blue : DashUi.slate, decoration: linked ? TextDecoration.underline : null),
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
    const base = TextStyle(fontSize: 15, color: DashUi.ink);
    return InkWell(
      onTap: () => onTap(p),
      child: Container(
        decoration: const BoxDecoration(border: Border(bottom: _border)),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _cell(0, Text(p.name, style: base.copyWith(fontWeight: FontWeight.w700)), align: Alignment.centerLeft),
              _person(1, p.owner),
              _person(2, p.support),
              _person(3, p.requestedBy),
              _cell(4, Text(p.priority, style: base), tint: _priorityTint(p.priority)),
              _cell(5, Text(p.status, style: base), tint: _statusTint(p.status)),
              _cell(6, Text(_date(p.deadline), style: base.copyWith(color: p.overdue ? DashUi.red : DashUi.ink, fontWeight: p.overdue ? FontWeight.w700 : null))),
              _cell(
                7,
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [for (final f in p.files) _fileChip(context, f)],
                ),
              ),
              _cell(8, Text(p.notes.trim(), maxLines: 5, overflow: TextOverflow.ellipsis, style: base.copyWith(fontSize: 14)), align: Alignment.centerLeft),
            ],
          ),
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
                  decoration: const BoxDecoration(
                    color: DashUi.faint,
                    border: Border(top: BorderSide(color: DashUi.line), bottom: BorderSide(color: DashUi.muted)),
                  ),
                  child: Row(
                    children: [
                      for (final col in _gridCols)
                        col.width == null ? Expanded(child: _headerCell(col.label)) : SizedBox(width: col.width, child: _headerCell(col.label)),
                    ],
                  ),
                ),
                Expanded(child: ListView.builder(itemCount: projects.length, itemBuilder: (_, i) => _row(context, projects[i]))),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _headerCell(String label) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
    child: Text(label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: DashUi.ink)),
  );
}
