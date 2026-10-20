import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';

const _statusOrder = ['In Progress', 'In Review', 'Planning', 'Complete'];
const _priorityOrder = ['Urgent', 'High', 'Medium', 'Low'];

Color _statusColor(String s) => switch (s) {
  'In Progress' => DashUi.emeraldDeep,
  'In Review' => DashUi.indigo,
  'Planning' => DashUi.sky,
  'Complete' => DashUi.slate,
  _ => DashUi.amber,
};

class _Project {
  final String name, owner, support, requestedBy, priority, status, files, notes;
  final DateTime? deadline;

  _Project(Map<String, dynamic> j)
    : name = '${j['name'] ?? ''}'.trim(),
      owner = '${j['owner'] ?? ''}',
      support = '${j['support'] ?? ''}',
      requestedBy = '${j['requestedBy'] ?? ''}',
      priority = '${j['priority'] ?? ''}',
      status = '${j['status'] ?? ''}',
      files = '${j['files'] ?? ''}',
      notes = '${j['notes'] ?? ''}',
      deadline = DateTime.tryParse('${j['deadline'] ?? ''}');

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

int _rank(List<String> order, String v) {
  final i = order.indexOf(v);
  return i < 0 ? order.length : i;
}

class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key});

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  List<_Project> _projects = [];
  bool _loading = true;
  String? _error;
  int _requestId = 0;

  String _query = '';
  String? _status; // null = all

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool fresh = false}) async {
    final id = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final uri = Uri.parse('$kApiBaseUrl/api/projects${fresh ? '?fresh=1' : ''}');
      final res = await http.get(uri, headers: AuthSession.instance.headers(json: false)).timeout(const Duration(seconds: 30));
      if (!mounted || id != _requestId) return;
      if (res.statusCode == 401) {
        AuthSession.instance.logout();
        return;
      }
      final data = json.decode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200) throw Exception(data['error'] ?? 'Server error (${res.statusCode})');
      final list = [for (final j in (data['projects'] as List? ?? const [])) _Project(j as Map<String, dynamic>)];
      setState(() {
        _projects = list;
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
      final byPriority = _rank(_priorityOrder, a.priority).compareTo(_rank(_priorityOrder, b.priority));
      if (byPriority != 0) return byPriority;
      if (a.deadline == null || b.deadline == null) return a.deadline == null ? (b.deadline == null ? 0 : 1) : -1;
      return a.deadline!.compareTo(b.deadline!);
    });
    return list;
  }

  void _open(_Project p) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(p.name),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                FlatStatus(p.status, _statusColor(p.status)),
                const SizedBox(height: 12),
                _detail('Owner', p.owner),
                _detail('Support', p.support),
                _detail('Requested by', p.requestedBy),
                _detail('Priority', p.priority),
                _detail('Deadline', _date(p.deadline)),
                _detail('Files', p.files),
                _detail('Notes', p.notes),
              ],
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Close'))],
      ),
    );
  }

  Widget _detail(String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.slate)),
          const SizedBox(height: 2),
          SelectableText(value, style: flatCellStyle),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageBanner(title: 'Project Tracker', actions: [PageBanner.refresh(onPressed: _loading ? null : () => _load(fresh: true))]),
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
      return const Center(
        child: FlatEmpty(
          icon: Icons.folder_copy_outlined,
          title: 'No projects yet',
          message: 'Add rows to the Projects tab of the project sheet and they will show up here.',
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
              for (final s in [null, ..._statusOrder])
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
              : _ProjectGrid(projects: shown, onTap: _open),
        ),
      ],
    );
  }
}

// Spreadsheet-style grid: dark header, a tinted cell per person / priority / status, wrapped notes.
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

  Widget _person(int col, String name) =>
      _cell(col, Text(name, style: const TextStyle(fontSize: 15, color: DashUi.ink), textAlign: TextAlign.center), tint: name.isEmpty ? null : _personTint(name));

  Widget _row(_Project p) {
    return InkWell(
      onTap: () => onTap(p),
      child: Container(
        decoration: const BoxDecoration(border: Border(bottom: _border)),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _cell(0, Text(p.name.trim(), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: DashUi.ink)), align: Alignment.centerLeft),
              _person(1, p.owner),
              _person(2, p.support),
              _person(3, p.requestedBy),
              _cell(4, Text(p.priority, style: const TextStyle(fontSize: 15, color: DashUi.ink)), tint: _priorityTint(p.priority)),
              _cell(5, Text(p.status, style: const TextStyle(fontSize: 15, color: DashUi.ink)), tint: _statusTint(p.status)),
              _cell(
                6,
                Text(
                  _date(p.deadline),
                  style: TextStyle(fontSize: 15, color: p.overdue ? DashUi.red : DashUi.ink, fontWeight: p.overdue ? FontWeight.w700 : null),
                ),
              ),
              _cell(
                7,
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final f in p.files.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty))
                      Container(
                        margin: const EdgeInsets.symmetric(vertical: 2),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(6)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.description_rounded, size: 14, color: DashUi.blue),
                            const SizedBox(width: 6),
                            Flexible(child: Text(f, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, color: DashUi.ink))),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              _cell(8, Text(p.notes.trim(), maxLines: 5, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, color: DashUi.ink)), align: Alignment.centerLeft),
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
                  color: DashUi.ink,
                  child: Row(
                    children: [
                      for (final col in _gridCols)
                        col.width == null
                            ? Expanded(child: _headerCell(col.label))
                            : SizedBox(width: col.width, child: _headerCell(col.label)),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(itemCount: projects.length, itemBuilder: (_, i) => _row(projects[i])),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _headerCell(String label) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
    child: Text(label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white)),
  );
}
