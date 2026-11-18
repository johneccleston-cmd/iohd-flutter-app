part of 'projects_screen.dart';

// The register: a pinned header with sortable columns, then group headers and two-line project rows of one fixed
// height (so the keyboard can keep the selected row in view without measuring). Columns come and go with the width:
// a labelled Priority column from 1000 px of list (below that the bars lead the row), Updated from 1240 px.

class _Columns {
  final bool priority; // a labelled Priority column; otherwise the bars lead the row
  final bool updated;
  final bool status; // off when the list is grouped by status: the group header says it
  final bool owner; // off when grouped by owner (support then shows under the name)
  const _Columns({required this.priority, required this.updated, required this.status, required this.owner});

  factory _Columns.forWidth(double w, {required bool status, required bool owner}) =>
      _Columns(priority: w >= 1000, updated: w >= 1240, status: status, owner: owner);

  static const ownerWidth = 176.0;
  static const statusWidth = 136.0;
  static const priorityWidth = 104.0;
  static const deadline = 132.0;
  static const updatedWidth = 112.0;
  static const bars = 28.0;
  static const gap = 14.0;
  static const left = 20.0;
  static const right = 16.0;
}

class _ProjectList extends StatelessWidget {
  final List<_Item> items;
  final int? selectedId;
  final bool showStatus;
  final bool showOwner;
  final Set<int> busy;
  final _Sort sort;
  final bool ascending;
  final ScrollController controller;
  final Animation<double> entrance;
  final ValueChanged<_Sort> onSort;
  final ValueChanged<String> onToggleGroup;
  final ValueChanged<_Project> onTap;
  final ValueChanged<_Project> onDoubleTap;
  final void Function(_Project, Offset) onMenu;

  const _ProjectList({
    required this.items,
    required this.selectedId,
    required this.showStatus,
    required this.showOwner,
    required this.busy,
    required this.sort,
    required this.ascending,
    required this.controller,
    required this.entrance,
    required this.onSort,
    required this.onToggleGroup,
    required this.onTap,
    required this.onDoubleTap,
    required this.onMenu,
  });

  /// Row heights at the current text size: two lines of text and their padding.
  static double rowExtent(TextScaler s) => 22 + s.scale(38);
  static double groupExtent(TextScaler s) => 14 + s.scale(26);

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context);
    final rowH = rowExtent(scale);
    final groupH = groupExtent(scale);
    return LayoutBuilder(
      builder: (context, c) {
        final cols = _Columns.forWidth(c.maxWidth, status: showStatus, owner: showOwner);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ListHeader(cols: cols, sort: sort, ascending: ascending, onSort: onSort),
            Expanded(
              child: Scrollbar(
                controller: controller,
                child: ListView.builder(
                  controller: controller,
                  itemCount: items.length,
                  itemExtentBuilder: (i, _) => i >= items.length ? null : (items[i] is _GroupItem ? groupH : rowH),
                  itemBuilder: (context, i) {
                    final item = items[i];
                    return switch (item) {
                      _GroupItem() => _GroupHeader(item: item, onTap: () => onToggleGroup(item.key)),
                      _ProjectItem(:final project, :final index) => flatRowEntrance(
                        entrance,
                        index,
                        _ProjectRow(
                          key: ValueKey(project.id),
                          project: project,
                          cols: cols,
                          selected: project.id == selectedId,
                          busy: busy.contains(project.id),
                          onTap: () => onTap(project),
                          onDoubleTap: () => onDoubleTap(project),
                          onMenu: (at) => onMenu(project, at),
                        ),
                      ),
                    };
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─── header ─────────────────────────────────────────────────────────────────

class _ListHeader extends StatelessWidget {
  final _Columns cols;
  final _Sort sort;
  final bool ascending;
  final ValueChanged<_Sort> onSort;
  const _ListHeader({required this.cols, required this.sort, required this.ascending, required this.onSort});

  Widget _label(String text, _Sort key, {String? tip}) {
    final active = key == sort;
    final arrow = Icon(ascending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 14, color: DashUi.ink);
    return SelectionContainer.disabled(
      child: Semantics(
        button: true,
        label: 'Sort by ${tip ?? text}',
        value: active ? (ascending ? 'Sorted ascending' : 'Sorted descending') : null,
        excludeSemantics: true,
        child: Tooltip(
          message: active ? 'Sorted by ${tip ?? text.toLowerCase()}. Click to reverse.' : 'Sort by ${tip ?? text.toLowerCase()}',
          waitDuration: const Duration(milliseconds: 500),
          child: InkWell(
            onTap: () => onSort(key),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: active ? DashUi.ink : DashUi.slate),
                    ),
                  ),
                  if (active) ...[const SizedBox(width: 4), arrow],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const g = SizedBox(width: _Columns.gap);
    return Container(
      padding: const EdgeInsets.fromLTRB(_Columns.left, 9, _Columns.right, 9),
      decoration: const BoxDecoration(
        color: DashUi.faint,
        border: Border(
          top: BorderSide(color: DashUi.line),
          bottom: BorderSide(color: DashUi.line),
        ),
      ),
      child: Row(
        children: [
          if (!cols.priority)
            SizedBox(
              width: _Columns.bars,
              child: Align(
                alignment: Alignment.centerLeft,
                child: SelectionContainer.disabled(
                  child: Tooltip(
                    message: sort == _Sort.priority ? 'Sorted by priority. Click to reverse.' : 'Sort by priority',
                    child: Semantics(
                      button: true,
                      label: 'Sort by priority',
                      excludeSemantics: true,
                      child: InkWell(
                        onTap: () => onSort(_Sort.priority),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Icon(
                            sort == _Sort.priority
                                ? (ascending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded)
                                : Icons.signal_cellular_alt_rounded,
                            size: 16,
                            color: sort == _Sort.priority ? DashUi.ink : DashUi.slate,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: _label('Project', _Sort.name, tip: 'name'),
            ),
          ),
          if (cols.owner) ...[
            g,
            SizedBox(
              width: _Columns.ownerWidth,
              child: Align(alignment: Alignment.centerLeft, child: _label('Owner', _Sort.owner)),
            ),
          ],
          if (cols.status) ...[
            g,
            SizedBox(
              width: _Columns.statusWidth,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _label('Status', _Sort.status, tip: 'workflow stage'),
              ),
            ),
          ],
          if (cols.priority) ...[
            g,
            SizedBox(
              width: _Columns.priorityWidth,
              child: Align(alignment: Alignment.centerLeft, child: _label('Priority', _Sort.priority)),
            ),
          ],
          g,
          SizedBox(
            width: _Columns.deadline,
            child: Align(alignment: Alignment.centerLeft, child: _label('Deadline', _Sort.deadline)),
          ),
          if (cols.updated) ...[
            g,
            SizedBox(
              width: _Columns.updatedWidth,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _label('Updated', _Sort.updated, tip: 'last change'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── group header ───────────────────────────────────────────────────────────

class _GroupHeader extends StatelessWidget {
  final _GroupItem item;
  final VoidCallback onTap;
  const _GroupHeader({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final person = item.person;
    return SelectionContainer.disabled(
      child: Semantics(
        button: true,
        expanded: !item.collapsed,
        label: '${item.label}, ${item.count} ${item.count == 1 ? 'project' : 'projects'}',
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          hoverColor: DashUi.faint,
          child: Container(
            padding: const EdgeInsets.fromLTRB(_Columns.left - 4, 0, _Columns.right, 0),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: DashUi.line)),
            ),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: item.collapsed ? -0.25 : 0,
                  duration: reduce ? Duration.zero : const Duration(milliseconds: 180),
                  child: const Icon(Icons.expand_more_rounded, size: 20, color: DashUi.slate),
                ),
                const SizedBox(width: 6),
                if (item.dot != null) ...[
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: item.dot, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 8),
                ],
                if (person != null) ...[_PersonMark(person, size: 22), const SizedBox(width: 8)],
                Flexible(
                  child: Text(
                    item.dot != null ? item.label.toUpperCase() : item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: item.dot != null ? 12.5 : 13.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: item.dot != null ? 0.6 : 0,
                      color: person == '' ? DashUi.amberText : DashUi.ink,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(
                    color: DashUi.faint,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: DashUi.line),
                  ),
                  child: Text(
                    '${item.count}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.slate, fontFeatures: flatFigures),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── row ────────────────────────────────────────────────────────────────────

class _ProjectRow extends StatefulWidget {
  final _Project project;
  final _Columns cols;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final ValueChanged<Offset> onMenu;
  const _ProjectRow({
    super.key,
    required this.project,
    required this.cols,
    required this.selected,
    required this.busy,
    required this.onTap,
    required this.onDoubleTap,
    required this.onMenu,
  });

  @override
  State<_ProjectRow> createState() => _ProjectRowState();
}

class _ProjectRowState extends State<_ProjectRow> {
  bool _hover = false;
  DateTime? _lastTap;

  static const _name = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: DashUi.ink, height: 1.3);
  static const _meta = TextStyle(fontSize: 13, color: DashUi.slate, height: 1.3);

  /// A second click within the double-click time opens the editor. Done by hand so the first click selects at once
  /// (a double-tap recogniser would hold every single click back).
  void _tap() {
    final now = DateTime.now();
    final last = _lastTap;
    _lastTap = now;
    if (last != null && now.difference(last) < const Duration(milliseconds: 350)) {
      _lastTap = null;
      widget.onDoubleTap();
    } else {
      widget.onTap();
    }
  }

  /// Under the name: an Urgent flag when there's no Priority column, who asked for it, files, and the start of the notes.
  /// One line of text, so however long the pieces are it is cut off at the end instead of overflowing.
  Widget _metaLine(_Project p) {
    final spans = <InlineSpan>[];
    void dot() {
      if (spans.isNotEmpty) spans.add(const TextSpan(text: '  ·  '));
    }

    if (!widget.cols.priority && p.priority == 'Urgent') {
      spans.add(
        const TextSpan(
          text: 'Urgent',
          style: TextStyle(fontWeight: FontWeight.w800, color: DashUi.redText),
        ),
      );
    }
    if (!widget.cols.owner && p.support.isNotEmpty && p.support.toLowerCase() != p.owner.toLowerCase()) {
      spans.add(TextSpan(text: 'With ${p.support}'));
    }
    if (p.requestedBy.isNotEmpty && p.requestedBy.toLowerCase() != p.owner.toLowerCase()) {
      dot();
      spans.add(TextSpan(text: 'Requested by ${p.requestedBy}'));
    }
    if (p.files.isNotEmpty) {
      dot();
      spans.add(
        const WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: EdgeInsets.only(right: 2),
            child: Icon(Icons.attach_file_rounded, size: 14, color: DashUi.slate),
          ),
        ),
      );
      spans.add(
        TextSpan(
          text: '${p.files.length}',
          style: const TextStyle(fontFeatures: flatFigures),
        ),
      );
    }
    final note = p.notes.trim().split('\n').map((l) => l.trim().replaceFirst(RegExp(r'^[-*•]\s*'), '')).firstWhere((l) => l.isNotEmpty, orElse: () => '');
    if (note.isNotEmpty) {
      dot();
      spans.add(
        TextSpan(
          text: note,
          style: const TextStyle(color: DashUi.subtle),
        ),
      );
    }
    if (spans.isEmpty) return const SizedBox.shrink();
    return Text.rich(
      TextSpan(style: _meta, children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _projectCell(_Project p) {
    final title = Text(
      p.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: p.isComplete
          ? _name.copyWith(color: DashUi.slate, fontWeight: FontWeight.w500)
          : (p.name.isEmpty ? _name.copyWith(fontStyle: FontStyle.italic, color: DashUi.slate) : _name),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          children: [
            if (p.isComplete) ...[const Icon(Icons.check_circle_rounded, size: 15, color: DashUi.emeraldDeep), const SizedBox(width: 6)],
            Flexible(
              child: p.title.length > 34 ? Tooltip(message: p.title, waitDuration: const Duration(milliseconds: 700), child: title) : title,
            ),
          ],
        ),
        const SizedBox(height: 2),
        _metaLine(p),
      ],
    );
  }

  Widget _ownerCell(_Project p) {
    final none = p.owner.isEmpty;
    return Row(
      children: [
        _PersonMark(p.owner),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                none ? 'No owner' : p.owner,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: none && !p.isComplete ? FontWeight.w700 : FontWeight.w600,
                  color: none ? (p.isComplete ? DashUi.slate : DashUi.amberText) : DashUi.ink,
                  height: 1.3,
                ),
              ),
              if (p.support.isNotEmpty && p.support.toLowerCase() != p.owner.toLowerCase())
                Text('with ${p.support}', maxLines: 1, overflow: TextOverflow.ellipsis, style: _meta),
            ],
          ),
        ),
      ],
    );
  }

  Widget _statusCell(_Project p) {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Row(
      children: [
        Flexible(
          child: AnimatedSwitcher(
            duration: reduce ? Duration.zero : const Duration(milliseconds: 220),
            transitionBuilder: (child, a) => FadeTransition(
              opacity: a,
              child: ScaleTransition(scale: a.drive(Tween(begin: 0.9, end: 1)), child: child),
            ),
            child: _StatusBadge(p.status, key: ValueKey(p.status), dense: true),
          ),
        ),
        if (widget.busy) ...[
          const SizedBox(width: 6),
          const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.8, color: DashUi.slate)),
        ],
      ],
    );
  }

  Widget _deadlineCell(_Project p) {
    final d = p.deadline;
    if (d == null) {
      return Semantics(
        label: 'No deadline',
        excludeSemantics: true,
        child: Text('–', style: _meta.copyWith(color: DashUi.muted)),
      );
    }
    final note = _deadlineNote(p);
    final late = p.overdue;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          _date(d),
          maxLines: 1,
          style: TextStyle(
            fontSize: 14,
            height: 1.3,
            fontFeatures: flatFigures,
            color: p.isComplete ? DashUi.slate : DashUi.ink,
            fontWeight: late ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        if (note != null)
          Text(
            note.$1,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _meta.copyWith(color: note.$2, fontWeight: note.$2 == DashUi.slate ? FontWeight.w400 : FontWeight.w700),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.project;
    final cols = widget.cols;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    const g = SizedBox(width: _Columns.gap);
    final bg = widget.selected
        ? Color.alphaBlend(DashUi.blue.withValues(alpha: 0.06), Colors.white)
        : (_hover ? DashUi.faint.withValues(alpha: 0.75) : Colors.white);
    return Semantics(
      button: true,
      selected: widget.selected,
      label: [
        p.title,
        p.status,
        if (p.priority.isNotEmpty) '${p.priority} priority',
        p.owner.isEmpty ? 'no owner' : 'owner ${p.owner}',
        if (p.deadline != null) 'deadline ${_date(p.deadline)}${p.overdue ? ', overdue' : ''}',
      ].join(', '),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _tap,
          onSecondaryTapUp: (d) => widget.onMenu(d.globalPosition),
          onLongPressStart: (d) => widget.onMenu(d.globalPosition),
          child: AnimatedContainer(
            duration: reduce ? Duration.zero : const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              color: bg,
              border: const Border(bottom: BorderSide(color: DashUi.line)),
            ),
            child: Stack(
              children: [
                // The selected row's edge, in ink.
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: AnimatedContainer(
                    duration: reduce ? Duration.zero : const Duration(milliseconds: 160),
                    width: widget.selected ? 3 : 0,
                    color: DashUi.ink,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(_Columns.left, 0, _Columns.right, 0),
                  child: Row(
                    children: [
                      if (!cols.priority)
                        SizedBox(
                          width: _Columns.bars,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: p.priority.isEmpty
                                ? const SizedBox.shrink()
                                : Tooltip(message: '${p.priority} priority', child: _PriorityMark(p.priority, showLabel: false)),
                          ),
                        ),
                      Expanded(child: _projectCell(p)),
                      if (cols.owner) ...[g, SizedBox(width: _Columns.ownerWidth, child: _ownerCell(p))],
                      if (cols.status) ...[g, SizedBox(width: _Columns.statusWidth, child: _statusCell(p))],
                      if (cols.priority) ...[
                        g,
                        SizedBox(
                          width: _Columns.priorityWidth,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: p.priority.isEmpty ? Text('–', style: _meta.copyWith(color: DashUi.muted)) : _PriorityMark(p.priority),
                          ),
                        ),
                      ],
                      g,
                      SizedBox(
                        width: _Columns.deadline,
                        child: Align(alignment: Alignment.centerLeft, child: _deadlineCell(p)),
                      ),
                      if (cols.updated) ...[
                        g,
                        SizedBox(
                          width: _Columns.updatedWidth,
                          child: Text(
                            p.updatedAt == null ? '–' : _ago(p.updatedAt),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _meta.copyWith(fontSize: 13.5, color: p.updatedAt == null ? DashUi.muted : DashUi.slate),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
