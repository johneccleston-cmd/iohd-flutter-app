part of 'projects_screen.dart';

// The selected project in full: status and priority, the whole name, who asked and when it last changed, the workflow
// track (click a stage to move the project there), owner, support, deadline and priority, then the notes and files.
// The header stays put while the body scrolls, so Edit is always in reach.

class _ProjectDetail extends StatelessWidget {
  final _Project project;
  final bool busy;
  final bool canUpdate;
  final bool canDelete;
  final bool inDialog;
  final bool reduceMotion;
  final VoidCallback? onClose;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<String> onStatus;

  const _ProjectDetail({
    required this.project,
    required this.busy,
    required this.canUpdate,
    required this.canDelete,
    required this.inDialog,
    required this.reduceMotion,
    required this.onClose,
    required this.onEdit,
    required this.onDelete,
    required this.onStatus,
  });

  static const _sectionStyle = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.7, color: DashUi.slate);

  Widget _section(String label, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        Text(label.toUpperCase(), style: _sectionStyle),
        const SizedBox(width: 10),
        const Expanded(child: Divider(height: 1, thickness: 1, color: DashUi.line)),
        if (trailing != null) ...[const SizedBox(width: 8), trailing],
      ],
    ),
  );

  Widget _header(BuildContext context) {
    final p = project;
    final meta = [if (p.requestedBy.isNotEmpty) 'Requested by ${p.requestedBy}', if (p.updatedAt != null) 'Updated ${_agoPhrase(p.updatedAt)}'];
    return Padding(
      padding: EdgeInsets.fromLTRB(24, inDialog ? 18 : 16, inDialog ? 12 : 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Wraps (priority under status) when large text leaves no room beside the buttons.
              Expanded(
                child: Wrap(
                  spacing: 14,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    AnimatedSwitcher(
                      duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 220),
                      child: _StatusBadge(p.status, key: ValueKey(p.status)),
                    ),
                    if (p.priority.isNotEmpty) _PriorityMark(p.priority),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (canUpdate)
                OutlinedButton.icon(
                  onPressed: busy ? null : onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Edit', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: DashUi.ink,
                    side: const BorderSide(color: DashUi.line),
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                  ),
                ),
              if (canDelete)
                PopupMenuButton<String>(
                  tooltip: 'More actions',
                  enabled: !busy,
                  icon: const Icon(Icons.more_horiz_rounded, color: DashUi.slate),
                  color: Colors.white,
                  surfaceTintColor: Colors.transparent,
                  position: PopupMenuPosition.under,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: const BorderSide(color: DashUi.line),
                  ),
                  onSelected: (v) => v == 'delete' ? onDelete() : null,
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete_outline_rounded, size: 18, color: DashUi.redText),
                          SizedBox(width: 12),
                          Text(
                            'Delete project',
                            style: TextStyle(fontWeight: FontWeight.w600, color: DashUi.redText),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              if (inDialog)
                IconButton(
                  tooltip: 'Close',
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded, size: 20, color: DashUi.slate),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            p.title,
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.2,
              height: 1.28,
              color: p.name.isEmpty ? DashUi.slate : DashUi.ink,
              fontStyle: p.name.isEmpty ? FontStyle.italic : null,
            ),
          ),
          if (meta.isNotEmpty) ...[const SizedBox(height: 6), Text(meta.join('  ·  '), style: const TextStyle(fontSize: 13, color: DashUi.slate, height: 1.4))],
        ],
      ),
    );
  }

  /// "Updated 3 days ago", "Updated today", "Updated on Nov 3".
  static String _agoPhrase(DateTime? t) {
    final a = _ago(t);
    if (a == 'Today' || a == 'Yesterday') return a.toLowerCase();
    if (a.endsWith('ago')) return a;
    return 'on $a';
  }

  Widget _fact(String label, Widget value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label.toUpperCase(), style: _sectionStyle.copyWith(fontSize: 11.5)),
      const SizedBox(height: 6),
      value,
    ],
  );

  Widget _personValue(String name, {required String empty, Color emptyColor = DashUi.slate}) {
    return Row(
      children: [
        _PersonMark(name, size: 26),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            name.isEmpty ? empty : name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: name.isEmpty ? FontWeight.w600 : FontWeight.w700,
              color: name.isEmpty ? emptyColor : DashUi.ink,
              height: 1.25,
            ),
          ),
        ),
      ],
    );
  }

  Widget _facts() {
    final p = project;
    final note = _deadlineNote(p);
    final deadline = p.deadline == null
        ? const Text(
            'No deadline',
            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: DashUi.slate),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _date(p.deadline),
                style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: DashUi.ink, fontFeatures: flatFigures),
              ),
              if (note != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    note.$1,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: note.$2),
                  ),
                ),
            ],
          );
    final priority = p.priority.isEmpty
        ? const Text(
            'Not set',
            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: DashUi.slate),
          )
        : _PriorityMark(p.priority);
    return LayoutBuilder(
      builder: (context, c) {
        final half = (c.maxWidth - 20) / 2;
        return Wrap(
          spacing: 20,
          runSpacing: 18,
          children: [
            SizedBox(
              width: half,
              child: _fact('Owner', _personValue(p.owner, empty: 'Not assigned', emptyColor: p.isComplete ? DashUi.slate : DashUi.amberText)),
            ),
            SizedBox(
              width: half,
              child: _fact('Support', _personValue(p.support, empty: 'Nobody')),
            ),
            SizedBox(width: half, child: _fact('Deadline', deadline)),
            SizedBox(width: half, child: _fact('Priority', priority)),
          ],
        );
      },
    );
  }

  Widget _empty(String text, {String? action}) => Row(
    children: [
      Text(text, style: const TextStyle(fontSize: 14, color: DashUi.slate)),
      if (action != null && canUpdate) ...[
        const SizedBox(width: 4),
        TextButton(
          onPressed: busy ? null : onEdit,
          style: TextButton.styleFrom(foregroundColor: DashUi.ink, padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(0, 32)),
          child: Text(
            action,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, decoration: TextDecoration.underline),
          ),
        ),
      ],
    ],
  );

  Widget _files(BuildContext context) {
    final files = project.files;
    if (files.isEmpty) return _empty('No files linked.', action: 'Add a file');
    return Column(
      children: [for (final f in files) _FileLink(file: f, onOpen: f.linked ? () => _openLink(context, f.url) : null)],
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = project;
    return ColoredBox(
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context),
          const Divider(height: 1, thickness: 1, color: DashUi.line),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _section(
                    'Workflow',
                    trailing: busy
                        ? const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.8, color: DashUi.slate)),
                              SizedBox(width: 6),
                              Text(
                                'Saving',
                                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: DashUi.slate),
                              ),
                            ],
                          )
                        : null,
                  ),
                  _WorkflowTrack(status: p.status, enabled: canUpdate && !busy, onStatus: onStatus, reduceMotion: reduceMotion),
                  const SizedBox(height: 22),
                  _section('People and dates'),
                  _facts(),
                  const SizedBox(height: 24),
                  _section('Notes'),
                  if (p.notes.trim().isEmpty) _empty('No notes yet.', action: 'Add notes') else _NotesBody(p.notes),
                  const SizedBox(height: 24),
                  _section(p.files.isEmpty ? 'Files' : 'Files  ${p.files.length}'),
                  _files(context),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── workflow track ─────────────────────────────────────────────────────────

/// Planning → In Progress → In Review → Complete as joined steps, with On Hold beside them as a pause. A step that
/// isn't the current one is a button that moves the project there (when the person may change projects).
class _WorkflowTrack extends StatelessWidget {
  final String status;
  final bool enabled;
  final ValueChanged<String> onStatus;
  final bool reduceMotion;
  const _WorkflowTrack({required this.status, required this.enabled, required this.onStatus, required this.reduceMotion});

  @override
  Widget build(BuildContext context) {
    final current = _workflow.indexOf(status); // -1 = On Hold (or a status the server added later)
    final held = status == 'On Hold';
    final color = _statusColor(status);
    final duration = reduceMotion ? Duration.zero : const Duration(milliseconds: 260);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < _workflow.length; i++)
              Expanded(
                child: _Step(
                  label: _workflow[i],
                  done: current >= 0 && i < current || status == 'Complete',
                  current: i == current,
                  color: current < 0 ? DashUi.muted : color,
                  leftLine: i == 0 ? null : (current >= 0 && i <= current ? color : DashUi.line),
                  rightLine: i == _workflow.length - 1 ? null : (current >= 0 && i < current ? color : DashUi.line),
                  onTap: enabled && i != current ? () => onStatus(_workflow[i]) : null,
                  duration: duration,
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            if (held) ...[
              const Icon(Icons.pause_circle_filled_rounded, size: 18, color: DashUi.amber),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  enabled ? 'On hold. Pick a stage above to start it again.' : 'On hold.',
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.amberText),
                ),
              ),
            ] else if (enabled && status != 'Complete')
              TextButton.icon(
                onPressed: () => onStatus('On Hold'),
                icon: const Icon(Icons.pause_circle_outline_rounded, size: 18),
                label: const Text('Put on hold', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                style: TextButton.styleFrom(foregroundColor: DashUi.slate, padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(0, 32)),
              )
            else if (status == 'Complete')
              const Expanded(
                child: Text(
                  'Finished.',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.emeraldText),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _Step extends StatefulWidget {
  final String label;
  final bool done;
  final bool current;
  final Color color;
  final Color? leftLine;
  final Color? rightLine;
  final VoidCallback? onTap;
  final Duration duration;
  const _Step({
    required this.label,
    required this.done,
    required this.current,
    required this.color,
    required this.leftLine,
    required this.rightLine,
    required this.onTap,
    required this.duration,
  });

  @override
  State<_Step> createState() => _StepState();
}

class _StepState extends State<_Step> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final filled = widget.done || widget.current;
    final can = widget.onTap != null;
    Widget line(Color? c) => Expanded(
      child: c == null ? const SizedBox(height: 2) : AnimatedContainer(duration: widget.duration, height: 2, color: c),
    );
    final circle = AnimatedContainer(
      duration: widget.duration,
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? widget.color : Colors.white,
        border: Border.all(color: filled ? widget.color : (_hover && can ? DashUi.ink : DashUi.line), width: filled ? 0 : 1.6),
        boxShadow: widget.current ? [BoxShadow(color: widget.color.withValues(alpha: 0.25), blurRadius: 0, spreadRadius: 4)] : null,
      ),
      child: Center(
        child: widget.done
            ? const Icon(Icons.check_rounded, size: 15, color: Colors.white)
            : widget.current
            ? Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              )
            : null,
      ),
    );
    final body = Column(
      children: [
        Row(children: [line(widget.leftLine), circle, line(widget.rightLine)]),
        const SizedBox(height: 7),
        Text(
          widget.label,
          textAlign: TextAlign.center,
          maxLines: 2,
          style: TextStyle(
            fontSize: 12.5,
            height: 1.2,
            fontWeight: widget.current ? FontWeight.w800 : FontWeight.w600,
            color: widget.current ? DashUi.ink : (_hover && can ? DashUi.ink : DashUi.slate),
          ),
        ),
      ],
    );
    final semantics = '${widget.label}${widget.current ? ', current stage' : (widget.done ? ', done' : '')}';
    if (!can) return Semantics(label: semantics, excludeSemantics: true, child: body);
    return Semantics(
      button: true,
      label: '$semantics. Move the project to ${widget.label}',
      excludeSemantics: true,
      child: Tooltip(
        message: 'Move to ${widget.label}',
        waitDuration: const Duration(milliseconds: 400),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: widget.onTap, child: body),
        ),
      ),
    );
  }
}

// ─── notes and files ────────────────────────────────────────────────────────

/// Notes as written, with "- " lines drawn as bullets and runs of blank lines folded to one gap.
class _NotesBody extends StatelessWidget {
  final String notes;
  const _NotesBody(this.notes);

  static const _style = TextStyle(fontSize: 14, color: DashUi.ink, height: 1.5);

  @override
  Widget build(BuildContext context) {
    final lines = notes.trim().split('\n');
    final out = <Widget>[];
    var gap = false;
    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        gap = true;
        continue;
      }
      if (gap && out.isNotEmpty) out.add(const SizedBox(height: 8));
      gap = false;
      final bullet = RegExp(r'^\s*[-*•]\s+').firstMatch(line);
      if (bullet != null) {
        out.add(
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 8.5, right: 10),
                  child: SizedBox(
                    width: 5,
                    height: 5,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: DashUi.slate, shape: BoxShape.circle),
                    ),
                  ),
                ),
                Expanded(child: Text(line.substring(bullet.end), style: _style)),
              ],
            ),
          ),
        );
      } else {
        out.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(line.trim(), style: _style),
          ),
        );
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: out);
  }
}

class _FileLink extends StatefulWidget {
  final _ProjectFile file;
  final VoidCallback? onOpen;
  const _FileLink({required this.file, required this.onOpen});

  @override
  State<_FileLink> createState() => _FileLinkState();
}

class _FileLinkState extends State<_FileLink> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final f = widget.file;
    final linked = widget.onOpen != null;
    final row = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: _hover && linked ? DashUi.faint : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DashUi.line),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(color: (linked ? DashUi.blue : DashUi.slate).withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
            child: Icon(linked ? Icons.description_outlined : Icons.link_off_rounded, size: 18, color: linked ? DashUi.blue : DashUi.slate),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  f.label.isEmpty ? 'Untitled file' : f.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: linked ? DashUi.ink : DashUi.slate, height: 1.3),
                ),
                Text(
                  linked ? (f.host.isEmpty ? 'Link' : f.host) : 'No link yet',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: linked ? DashUi.slate : DashUi.amberText, height: 1.3),
                ),
              ],
            ),
          ),
          if (linked) Icon(Icons.open_in_new_rounded, size: 17, color: _hover ? DashUi.ink : DashUi.slate),
        ],
      ),
    );
    if (!linked) return row;
    return Semantics(
      link: true,
      label: 'Open ${f.label}',
      child: Tooltip(
        message: 'Open in a new tab',
        waitDuration: const Duration(milliseconds: 500),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(onTap: widget.onOpen, child: row),
        ),
      ),
    );
  }
}
