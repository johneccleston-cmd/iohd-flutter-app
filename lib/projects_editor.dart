part of 'projects_screen.dart';

// New project / edit project. Status and priority are pill selectors; people fields suggest everyone already named on a
// project; the deadline is a date picker. Limits match the server so nothing is cut off silently. Closing with unsaved
// changes asks first. A save that collides with someone else's (409 CHANGED) keeps the dialog open and offers
// "Save anyway".

class _ProjectEditor extends StatefulWidget {
  final _Project? project; // null = new
  final List<String> people;
  final bool canDelete;
  final Future<_SaveOutcome> Function(Map<String, dynamic> body, {required bool force}) onSave;

  const _ProjectEditor({required this.project, required this.people, required this.canDelete, required this.onSave});

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
  late String _status = widget.project?.status ?? 'Planning';
  late DateTime? _deadline = widget.project?.deadline;
  late final List<_FileRow> _files = [for (final f in widget.project?.files ?? const <_ProjectFile>[]) _FileRow(f.name, f.url)];
  late final String _initial; // the form as it opened, to tell whether anything changed

  bool _busy = false;
  String? _error;
  String? _nameError;
  bool _conflict = false; // someone else saved in between: the next save goes through anyway

  bool get _isNew => widget.project == null;

  @override
  void initState() {
    super.initState();
    _initial = json.encode(_body());
  }

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

  Map<String, dynamic> _body() => {
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
  };

  bool get _dirty => json.encode(_body()) != _initial;

  Future<void> _save() async {
    if (_busy) return;
    if (_name.text.trim().isEmpty) {
      setState(() => _nameError = 'A project needs a name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _nameError = null;
    });
    final r = await widget.onSave(_body(), force: _conflict);
    if (!mounted) return;
    if (r.error == null) {
      Navigator.of(context).pop(_isNew ? _EditorExit.added : _EditorExit.saved);
    } else {
      setState(() {
        _busy = false;
        _error = r.error;
        _conflict = r.conflict;
      });
    }
  }

  Future<bool> _confirmDiscard() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AppDialog(
        title: 'Discard your changes?',
        icon: Icons.edit_off_outlined,
        body: Text(
          _isNew ? 'This project hasn\'t been added yet.' : 'What you changed in "${widget.project!.title}" hasn\'t been saved.',
          style: const TextStyle(fontSize: 14, color: DashUi.slate, height: 1.45),
        ),
        actions: [AppButton.ghost('Keep editing', () => Navigator.of(c).pop(false)), AppButton.ink('Discard', () => Navigator.of(c).pop(true), danger: true)],
      ),
    );
    return sure == true;
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
      helpText: 'Deadline',
    );
    if (d != null) setState(() => _deadline = d);
  }

  /// The counter only shows once the text gets near the server's limit.
  static Widget? _nearLimit(BuildContext context, {required int currentLength, required int? maxLength, required bool isFocused}) {
    if (maxLength == null || currentLength < maxLength * 0.85) return null;
    return Text('$currentLength / $maxLength', style: const TextStyle(fontSize: 12, color: DashUi.slate));
  }

  Widget _labelled(String label, Widget field, {String? help}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      AppFieldLabel(label, help: help),
      field,
    ],
  );

  Widget _deadlineField() {
    final note = _deadline == null ? null : _deadlineNote(_Project.fromJson({'status': _status, 'deadline': _isoDate(_deadline!)}));
    return InkWell(
      mouseCursor: WidgetStateMouseCursor.clickable,
      onTap: _busy ? null : _pickDeadline,
      borderRadius: BorderRadius.circular(10),
      child: InputDecorator(
        isEmpty: _deadline == null,
        decoration: appFieldDecoration(hint: 'No deadline').copyWith(
          prefixIcon: const Icon(Icons.event_outlined, size: 18, color: DashUi.slate),
          suffixIcon: _deadline == null
              ? null
              : IconButton(
                  tooltip: 'Clear deadline',
                  icon: const Icon(Icons.close_rounded, size: 18, color: DashUi.slate),
                  onPressed: _busy ? null : () => setState(() => _deadline = null),
                ),
        ),
        child: _deadline == null
            ? null
            : Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: _date(_deadline),
                      style: const TextStyle(fontSize: 14, color: DashUi.ink, fontWeight: FontWeight.w600),
                    ),
                    if (note != null)
                      TextSpan(
                        text: '   ${note.$1}',
                        style: TextStyle(fontSize: 12.5, color: note.$2, fontWeight: FontWeight.w600),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
      ),
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
              enabled: !_busy,
              maxLength: _maxName,
              buildCounter: _nearLimit,
              style: const TextStyle(fontSize: 14),
              decoration: appFieldDecoration(hint: 'File name'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: TextField(
              controller: f.url,
              enabled: !_busy,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 14),
              decoration: appFieldDecoration(hint: 'Paste a Drive or web link'),
            ),
          ),
          IconButton(
            tooltip: 'Open file',
            icon: const Icon(Icons.open_in_new_rounded, size: 19, color: DashUi.slate),
            onPressed: f.url.text.trim().isEmpty ? null : () => _openLink(context, f.url.text.trim()),
          ),
          IconButton(
            tooltip: 'Remove file',
            icon: const Icon(Icons.close_rounded, size: 19, color: DashUi.slate),
            onPressed: _busy ? null : () => setState(() => _files.removeAt(i).dispose()),
          ),
        ],
      ),
    );
  }

  Widget _form() {
    const gap = SizedBox(height: 18);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _labelled(
          'Project name',
          TextField(
            controller: _name,
            autofocus: _isNew,
            enabled: !_busy,
            maxLength: _maxName,
            buildCounter: _nearLimit,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: DashUi.ink),
            decoration: appFieldDecoration(hint: 'What is the project?', error: _nameError),
            onChanged: (_) {
              if (_nameError != null) setState(() => _nameError = null);
            },
            onSubmitted: (_) => _save(),
          ),
        ),
        gap,
        _labelled(
          'Status',
          AppSegmented<String>(
            value: _status,
            options: [for (final s in _statuses) (s, s), if (!_statuses.contains(_status)) (_status, _status)],
            onChanged: (v) => _busy ? null : setState(() => _status = v),
          ),
        ),
        gap,
        _labelled(
          'Priority',
          AppSegmented<String>(
            value: _priority,
            options: [
              for (final p in _priorities) (p, p),
              ('', 'Not set'),
              if (_priority.isNotEmpty && !_priorities.contains(_priority)) (_priority, _priority),
            ],
            onChanged: (v) => _busy ? null : setState(() => _priority = v),
          ),
        ),
        gap,
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _labelled('Owner', _PersonField(controller: _owner, people: widget.people, hint: 'Who runs it', enabled: !_busy)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: _labelled('Support', _PersonField(controller: _support, people: widget.people, hint: 'Who helps (optional)', enabled: !_busy)),
            ),
          ],
        ),
        gap,
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _labelled('Requested by', _PersonField(controller: _requestedBy, people: widget.people, hint: 'Who asked for it', enabled: !_busy)),
            ),
            const SizedBox(width: 14),
            Expanded(child: _labelled('Deadline', _deadlineField())),
          ],
        ),
        gap,
        _labelled(
          'Notes',
          TextField(
            controller: _notes,
            enabled: !_busy,
            minLines: 4,
            maxLines: 10,
            maxLength: _maxNotes,
            buildCounter: _nearLimit,
            style: const TextStyle(fontSize: 14, height: 1.45, color: DashUi.ink),
            decoration: appFieldDecoration(hint: 'Plan, progress, decisions. Start a line with "- " for a bullet.'),
          ),
        ),
        gap,
        Row(
          children: [
            const Expanded(child: AppFieldLabel('Files', help: 'Links to Drive documents or web pages.')),
            TextButton.icon(
              onPressed: _busy || _files.length >= _maxFiles ? null : () => setState(() => _files.add(_FileRow('', ''))),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add file', style: TextStyle(fontWeight: FontWeight.w700)),
              style: TextButton.styleFrom(foregroundColor: DashUi.ink),
            ),
          ],
        ),
        for (var i = 0; i < _files.length; i++) _fileRow(i),
        if (_files.length >= _maxFiles)
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text('A project can hold $_maxFiles files.', style: TextStyle(fontSize: 12.5, color: DashUi.slate)),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final saveLabel = _busy ? 'Saving...' : (_conflict ? 'Save anyway' : (_isNew ? 'Add project' : 'Save changes'));
    // Every close (Cancel, the X, Escape) comes through here and checks for unsaved changes at that moment, so it never
    // depends on the dialog having rebuilt since the last keystroke. A save closes with Navigator.pop, which skips it.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _busy) return;
        if (_dirty && !await _confirmDiscard()) return;
        if (context.mounted) Navigator.of(context).pop();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
          // The barrier doesn't close this dialog (a stray click would lose the form), so Escape is handled here; it
          // asks about unsaved changes like Cancel does.
          const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop(),
        },
        child: AppDialog(
          title: _isNew ? 'New project' : 'Edit project',
          subtitle: _isNew ? 'Everyone with Projects access will see it.' : 'Changes show for everyone as soon as you save.',
          icon: _isNew ? Icons.create_new_folder_outlined : Icons.edit_outlined,
          width: 660,
          body: _form(),
          footer: _error == null ? null : AppNotice(_error!, kind: _conflict ? AppNoticeKind.warning : AppNoticeKind.error),
          actions: [
            if (widget.canDelete && !_isNew)
              TextButton.icon(
                onPressed: _busy ? null : () => Navigator.of(context).pop(_EditorExit.deleteRequested),
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: const Text('Delete', style: TextStyle(fontWeight: FontWeight.w700)),
                style: TextButton.styleFrom(foregroundColor: DashUi.redText, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15)),
              ),
            AppButton.ghost('Cancel', _busy ? null : () => Navigator.of(context).maybePop()),
            AppButton.ink(saveLabel, _busy ? null : _save, icon: _busy ? null : Icons.check_rounded),
          ],
        ),
      ),
    );
  }
}

/// A name field that suggests the people already named on projects (and you), filtered as you type.
class _PersonField extends StatefulWidget {
  final TextEditingController controller;
  final List<String> people;
  final String hint;
  final bool enabled;
  const _PersonField({required this.controller, required this.people, required this.hint, required this.enabled});

  @override
  State<_PersonField> createState() => _PersonFieldState();
}

class _PersonFieldState extends State<_PersonField> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<String>(
      textEditingController: widget.controller,
      focusNode: _focus,
      optionsBuilder: (v) {
        final q = v.text.trim().toLowerCase();
        return widget.people.where((p) => p.toLowerCase() != q && (q.isEmpty || p.toLowerCase().contains(q))).take(8);
      },
      fieldViewBuilder: (context, controller, focus, onSubmit) => TextField(
        controller: controller,
        focusNode: focus,
        enabled: widget.enabled,
        maxLength: _maxPerson,
        buildCounter: (_, {required currentLength, required maxLength, required isFocused}) => null,
        style: const TextStyle(fontSize: 14, color: DashUi.ink),
        decoration: appFieldDecoration(hint: widget.hint).copyWith(
          prefixIcon: Padding(
            padding: const EdgeInsets.all(9),
            child: ListenableBuilder(listenable: controller, builder: (_, _) => _PersonMark(controller.text.trim(), size: 22)),
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        ),
        onSubmitted: (_) => onSubmit(),
      ),
      optionsViewBuilder: (context, onSelected, options) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          color: Colors.white,
          elevation: 6,
          shadowColor: Colors.black.withValues(alpha: 0.12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: DashUi.line),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260, maxWidth: 290),
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 4),
              shrinkWrap: true,
              children: [
                for (final o in options)
                  InkWell(
                    mouseCursor: WidgetStateMouseCursor.clickable,
                    onTap: () => onSelected(o),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                      child: Row(
                        children: [
                          _PersonMark(o, size: 24),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              o,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14, color: DashUi.ink),
                            ),
                          ),
                        ],
                      ),
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
