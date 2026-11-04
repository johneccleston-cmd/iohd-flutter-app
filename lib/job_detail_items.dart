part of 'job_detail_screen.dart';

// The job's line items and the estimate's options, in the Line Items panel at the bottom of the job page.
//
// A record starts with Service Fusion's own items, read-only. "Edit line items here" (a job) or "New option" (an
// estimate) copies them into our tables (the server turns its cost into a unit cost, adds the tax rate, and makes the
// copy total what Service Fusion says), and from then on the lines are edited here. Service Fusion's copy stays one
// click away for reference. Estimate options are alternatives for the same job: each has its own lines, totals and
// notes for the customer, one can be marked recommended, one accepted (which locks it), and the accepted one is sent
// to the job once. Picking an option only changes which one is being edited; the rest of the page stays put.

const _figures = [FontFeature.tabularFigures()];

/// The option tiles' and banners' light fill.
const _tileTint = Color(0xFFFBFCFE);

extension _JobItems on _JobDetailScreenState {
  /// The job's own set of items edited here, if it has one.
  LineOption? get _jobSet => _isEstimate ? null : _lines?.options.firstOrNull;

  List<Map<String, dynamic>> get _sfItems {
    final raw = _job?['raw_items'];
    final list = raw is List ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : <Map<String, dynamic>>[];
    list.sort((a, b) => _JobDetailScreenState._n(a['item_index']).compareTo(_JobDetailScreenState._n(b['item_index'])));
    return list;
  }

  List<Map<String, dynamic>> get _sfCharges {
    final raw = _job?['other_charges'];
    return raw is List ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : const [];
  }

  /// Service Fusion's items as lines to show (never saved from here). Its cost is the extended cost; shown per unit.
  List<LineDraft> get _sfLines => [
    for (final it in _sfItems)
      () {
        final q = it['multiplier'] == null ? 1.0 : _JobDetailScreenState._n(it['multiplier']);
        final ext = it['cost'] == null ? null : _JobDetailScreenState._n(it['cost']);
        return LineDraft(
          name: (it['name'] ?? it['product'] ?? it['service'] ?? 'Item').toString().trim(),
          description: (it['description'] ?? '').toString().trim(),
          quantity: q,
          rate: it['rate'] == null ? null : _JobDetailScreenState._n(it['rate']),
          cost: ext == null ? null : (q > 0 ? (ext / q * 100).round() / 100 : ext),
          taxable: (it['tax'] ?? '').toString().trim().isNotEmpty,
          source: 'service_fusion',
        );
      }(),
  ];

  /// Each Service Fusion line's own total, in cents, lined up with [_sfLines].
  List<int> get _sfAmounts => [for (final it in _sfItems) (_JobDetailScreenState._n(it['total']) * 100).round()];

  /// Service Fusion's figures as it has them: its items, each charge it lists (tax, discounts), anything its total
  /// holds that it doesn't itemize, and its total. Its cost goes on the internal panel.
  List<LineSummaryRow> get _sfSummary {
    final itemsC = _sfItems.fold<int>(0, (s, it) => s + (_JobDetailScreenState._n(it['total']) * 100).round());
    final rows = <LineSummaryRow>[LineSummaryRow('Items', itemsC)];
    var chargesC = 0;
    for (final c in _sfCharges) {
      final amount = (_JobDetailScreenState._n(c['total']).abs() * 100).round();
      final signed = c['is_discount'] == true ? -amount : amount;
      chargesC += signed;
      final name = (c['name'] ?? c['other_charge'] ?? 'Charge').toString().trim();
      final pct = c['is_percentage'] == true && c['rate'] != null ? ' ${qtyText(_JobDetailScreenState._n(c['rate']))}%' : '';
      // Service Fusion names its tax charges in full ("Sales Tax (State, County, & Local Use Tax, Prairie Grove)").
      final isTax = c['is_discount'] != true && name.toLowerCase().contains('tax');
      rows.add(LineSummaryRow(isTax ? 'Sales tax$pct' : '$name$pct', signed));
    }
    if (_job?['total_revenue'] != null) {
      final totalC = (_JobDetailScreenState._n(_job!['total_revenue']) * 100).round();
      final left = totalC - itemsC - chargesC;
      if (left.abs() >= 1) rows.add(LineSummaryRow(_sfCharges.isEmpty && left > 0 ? 'Tax and other charges' : 'Not itemized in Service Fusion', left));
      rows.add(LineSummaryRow('Total', totalC, strong: true));
    }
    if (_canSeeCost) {
      final cost = _sfItems.fold<int>(0, (s, it) => s + (_JobDetailScreenState._n(it['cost']) * 100).round());
      rows.insert(0, LineSummaryRow('Cost', cost, internal: true));
    }
    return rows;
  }

  /// Service Fusion's items, read-only, with its own figures.
  LineItemsEditor _sfEditor({Key key = const ValueKey('sf-items'), required String emptyTitle, required String emptyMessage, Widget? banner}) => LineItemsEditor(
    key: key,
    lines: _sfLines,
    taxRate: null,
    editable: false,
    showCost: _canSeeCost,
    summary: _sfSummary,
    fixedAmounts: _sfAmounts,
    emptyTitle: emptyTitle,
    emptyMessage: emptyMessage,
    banner: banner,
  );

  // ---- job: line items --------------------------------------------------------------------------------------------

  /// While our line items load, a spinner. If they can't be loaded (the server is down, or older than this app),
  /// Service Fusion's own items still show, read-only, with what went wrong and a Retry: the page never loses them.
  Widget _linesLoadingOrError() {
    if (_linesError != null) {
      return _sfEditor(
        key: const ValueKey('sf-items-fallback'),
        emptyTitle: 'No line items',
        emptyMessage: 'Service Fusion has no items on this record.',
        banner: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: _ItemsBanner(
            icon: Icons.cloud_off_rounded,
            tone: DashUi.amberText,
            text: 'Service Fusion\'s items, read-only. Line items edited here couldn\'t be loaded ($_linesError), so editing is unavailable for now.',
            actions: [TextButton.icon(onPressed: _loadLines, icon: const Icon(Icons.refresh_rounded, size: 16), label: const Text('Retry'))],
          ),
        ),
      );
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 48),
      child: Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5))),
    );
  }

  Widget _jobItemsPanel() {
    final set = _jobSet;
    final loaded = _lines != null;
    final showingSf = loaded && (set == null || _showSfItems);
    final String caption;
    if (!loaded) {
      caption = 'Service Fusion\'s line items, and any edited here.';
    } else if (set == null) {
      caption = 'Service Fusion\'s line items, read-only. Edit them here to change quantities, prices and costs or add from the catalog; Service Fusion keeps its own copy.';
    } else if (_showSfItems) {
      caption = 'Service Fusion\'s copy, for reference. The job\'s items are edited here.';
    } else if (set.source == 'estimate') {
      caption =
          'From estimate #${set.sourceEstimateId}${set.sourceOptionName == null ? '' : ', option "${set.sourceOptionName}"'}. Changes here are change orders; the estimate keeps the agreed price.';
    } else {
      caption =
          'Edited here${set.updatedBy.isEmpty ? '' : ', last by ${set.updatedBy}'}${set.updatedAt == null ? '' : ' on ${DateFormat('MMM d').format(set.updatedAt!.toLocal())}'}. Service Fusion still bills and reports its own items until the switch-over.';
    }
    final actions = <Widget>[
      if (loaded && set != null && set.source == 'estimate' && set.sourceEstimateId != null && !_showSfItems)
        TextButton(onPressed: () => _openRecord(set.sourceEstimateId!, estimate: true), child: Text('Open estimate #${set.sourceEstimateId}')),
      if (loaded && set != null)
        _showSfItems
            ? TextButton.icon(
                onPressed: () => _set(() => _showSfItems = false),
                icon: const Icon(Icons.arrow_back_rounded, size: 16),
                label: const Text('Back to the items edited here'),
              )
            : TextButton.icon(
                onPressed: () => _set(() => _showSfItems = true),
                icon: const Icon(Icons.visibility_outlined, size: 16),
                label: const Text('Service Fusion\'s copy'),
              ),
      if (loaded && set == null && _canEditLines)
        FilledButton.icon(
          onPressed: _busy != null ? null : _startJobItems,
          icon: _busy == 'start'
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.edit_rounded, size: 16),
          label: const Text('Edit line items here'),
        ),
    ];
    final Widget body;
    if (!loaded) {
      body = _linesLoadingOrError();
    } else if (showingSf) {
      body = _sfEditor(
        emptyTitle: 'No line items',
        emptyMessage: set == null && _canEditLines ? 'Use "Edit line items here" to add the first one.' : 'Service Fusion has no items on this job.',
      );
    } else {
      body = LineItemsEditor(
        key: ValueKey('job-set-${set!.id}'),
        lines: set.items,
        taxRate: set.taxRate,
        editable: _canEditLines,
        showCost: _canSeeCost,
        onSave: (lines, tax) => _saveLines(set, lines, tax),
        onDirtyChanged: (d) => _set(() => d ? _dirty.add(set.id) : _dirty.remove(set.id)),
      );
    }
    return _itemsPanel(caption: _linesError != null ? null : caption, actions: _linesError != null ? const [] : actions, body: body);
  }

  /// The original Line Items panel (grey title bar, hairline rows): what these lines are and the actions on them in a
  /// row of their own, then the lines.
  Widget _itemsPanel({String? caption, List<Widget> actions = const [], required Widget body}) => _panel('Line Items', [
    if ((caption != null && caption.isNotEmpty) || actions.isNotEmpty)
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 12, 10),
        child: Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          children: [
            if (caption != null && caption.isNotEmpty) ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: _text(caption, muted: true)),
            if (actions.isNotEmpty) Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
          ],
        ),
      ),
    Padding(padding: const EdgeInsets.only(top: 12, bottom: 4), child: body),
  ]);

  Future<void> _startJobItems() async {
    _set(() => _busy = 'start');
    try {
      final (s, _) = await _api.create(from: 'service_fusion');
      _set(() {
        _lines = s;
        _showSfItems = false;
      });
      _say('Service Fusion\'s items are copied here. Click a line to change it, or search below the lines to add one.');
    } on LineItemsException catch (e) {
      _say(e.message);
      if (e.isConflict) unawaited(_loadLines());
    } finally {
      _set(() => _busy = null);
    }
  }

  Future<String?> _saveLines(LineOption o, List<LineDraft> lines, double? tax) async {
    final current = _lines?.byId(o.id) ?? o;
    try {
      final s = await _api.saveItems(o.id, current.version, lines, tax);
      _set(() {
        _lines = s;
        _dirty.remove(o.id);
        _keepOptionInView();
      });
      return null;
    } on LineItemsException catch (e) {
      if (e.isConflict) {
        // Their version comes in underneath the draft: Discard shows it, Save again replaces it with this one.
        unawaited(_loadLines());
        return 'Someone else changed these lines while you were editing. Save again to replace their changes with yours, or Discard to see theirs.';
      }
      return e.message;
    }
  }

  // ---- estimate: the proposal and its options ---------------------------------------------------------------------

  Widget _proposalPanel() {
    final opts = _lines?.options ?? const <LineOption>[];
    final Widget body;
    if (_lines == null) {
      body = _linesLoadingOrError();
    } else {
      final selected = _option ?? (opts.isEmpty ? 'sf' : opts.first.id);
      final current = _lines!.byId(selected);
      final banner = current == null ? null : _optionBanner(current);
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _OptionPicker(state: this, selected: selected),
          ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: current == null ? _sfOptionNote(opts) : _OptionBar(state: this, option: current),
          ),
          if (banner != null) Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 0), child: banner),
          const SizedBox(height: 14),
          // Every option keeps its own editor alive (hidden, not thrown away), so a draft survives switching to another
          // option and back. Hidden ones take no room, so a short option isn't padded out to a long one's height.
          for (final o in opts)
            Offstage(
              offstage: o.id != selected,
              child: TickerMode(
                enabled: o.id == selected,
                child: LineItemsEditor(
                  key: ValueKey('option-${o.id}'),
                  lines: o.items,
                  taxRate: o.taxRate,
                  editable: _canEditLines && !o.locked,
                  showCost: _canSeeCost,
                  onSave: (lines, tax) => _saveLines(o, lines, tax),
                  onDirtyChanged: (d) => _set(() => d ? _dirty.add(o.id) : _dirty.remove(o.id)),
                  emptyTitle: 'No lines in ${o.name} yet',
                  emptyMessage: _canEditLines ? 'Search the catalog below to add the first one.' : 'Nothing has been added to this option.',
                  footer: _ProposalNotes(state: this, option: o),
                ),
              ),
            ),
          Offstage(
            offstage: selected != 'sf',
            child: _sfEditor(
              emptyTitle: 'No line items in Service Fusion',
              emptyMessage: _canEditLines ? 'Start a blank option with "New option" above.' : 'Service Fusion has no items on this estimate.',
            ),
          ),
        ],
      );
    }
    return _itemsPanel(
      caption: opts.length > 1
          ? 'Alternatives for the same work. Each option has its own lines, prices and totals; the customer PDF shows them all.'
          : 'What the customer is offered. Add options to give them a choice.',
      actions: [
        OutlinedButton.icon(
          onPressed: _lines == null || _busy != null ? null : _openProposalPdf,
          icon: const Icon(Icons.picture_as_pdf_outlined, size: 16),
          label: const Text('Customer PDF'),
        ),
      ],
      body: body,
    );
  }

  /// Above Service Fusion's own items in the proposal: what they are, and copying them into an option.
  Widget _sfOptionNote(List<LineOption> opts) => _ItemsBanner(
    icon: Icons.lock_outline_rounded,
    text: opts.isEmpty
        ? 'Service Fusion\'s items, read-only. Copy them into an option to edit prices, add from the catalog and offer alternatives.'
        : 'Service Fusion\'s copy, for reference. The options above are what the customer sees.',
    actions: [
      if (_canEditLines)
        FilledButton.icon(
          onPressed: _busy != null ? null : () => _newOption('service_fusion'),
          icon: const Icon(Icons.content_copy_rounded, size: 16),
          label: Text(opts.isEmpty ? 'Copy into Option 1' : 'Copy into a new option'),
        ),
    ],
  );

  Widget? _optionBanner(LineOption o) {
    if (o.converted) {
      return _ItemsBanner(
        icon: Icons.check_circle_rounded,
        tone: DashUi.emeraldText,
        text:
            'Accepted${o.acceptedBy.isEmpty ? '' : ' by ${o.acceptedBy}'}${o.acceptedAt == null ? '' : ' on ${DateFormat('MMM d, y').format(o.acceptedAt!.toLocal())}'} and sent to job #${o.convertedJobId}. Locked: this is the agreed price.',
        actions: [TextButton(onPressed: () => _openRecord(o.convertedJobId!, estimate: false), child: Text('Open job #${o.convertedJobId}'))],
      );
    }
    if (o.accepted) {
      return _ItemsBanner(
        icon: Icons.verified_rounded,
        tone: DashUi.emeraldText,
        text:
            'Accepted${o.acceptedBy.isEmpty ? '' : ' by ${o.acceptedBy}'}${o.acceptedAt == null ? '' : ' on ${DateFormat('MMM d, y').format(o.acceptedAt!.toLocal())}'}. Locked so the agreed price stays as it was; the other options stay as alternatives.',
        actions: [
          if (_canEditLines) TextButton(onPressed: _busy != null ? null : () => _unaccept(o), child: const Text('Undo acceptance')),
          if (_canEditLines)
            FilledButton.icon(
              onPressed: _busy != null ? null : () => _convert(o),
              icon: const Icon(Icons.send_rounded, size: 16),
              label: const Text('Send to job'),
            ),
        ],
      );
    }
    return null;
  }

  Future<void> _run(String what, Future<LineItemsState> Function() call, {String? done}) async {
    _set(() => _busy = what);
    try {
      final s = await call();
      _set(() {
        _lines = s;
        _keepOptionInView();
      });
      if (done != null) _say(done);
    } on LineItemsException catch (e) {
      _say(e.message);
      if (e.isConflict) unawaited(_loadLines());
    } finally {
      _set(() => _busy = null);
    }
  }

  Future<void> _newOption(String from, {String? copyOf}) async {
    _set(() => _busy = 'new');
    try {
      final (s, id) = await _api.create(from: from, copyOf: copyOf);
      _set(() {
        _lines = s;
        _option = id ?? _option;
        _keepOptionInView();
      });
    } on LineItemsException catch (e) {
      _say(e.message);
    } finally {
      _set(() => _busy = null);
    }
  }

  Future<void> _renameOption(LineOption o) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(initial: o.name),
    );
    if (name == null || name.trim() == o.name) return;
    await _run('rename', () => _api.update(o.id, o.version, {'name': name.trim()}));
  }

  Future<void> _toggleRecommended(LineOption o) => _run(
    'recommend',
    () => _api.update(o.id, o.version, {'isRecommended': !o.isRecommended}),
    done: o.isRecommended ? null : '${o.name} is marked recommended.',
  );

  /// The option's notes for the customer (printed under it on the PDF).
  Future<void> _editOptionNotes(LineOption o) async {
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TextDialog(
        title: o.notes.trim().isEmpty ? 'Add notes for the customer' : 'Notes for the customer',
        hint: 'Printed under ${o.name} on the customer PDF: what is included, lead time, warranty...',
        initial: o.notes,
        allowEmpty: true,
        maxLength: 4000,
        maxLines: 10,
        onSave: (text) async {
          final current = _lines?.byId(o.id) ?? o;
          try {
            final s = await _api.update(o.id, current.version, {'notes': text});
            _set(() {
              _lines = s;
              _keepOptionInView();
            });
            return null;
          } on LineItemsException catch (e) {
            if (e.isConflict) unawaited(_loadLines());
            return e.message;
          }
        },
      ),
    );
  }

  Future<void> _deleteOption(LineOption o) async {
    final ok = await _confirm(
      'Delete ${o.name}?',
      '${o.items.length} line${o.items.length == 1 ? '' : 's'}, ${centsMoney(o.totals.totalCents)}. The other options are not touched. Its history is kept.',
      'Delete option',
      danger: true,
    );
    if (!ok) return;
    _set(() => _dirty.remove(o.id));
    await _run('delete', () => _api.delete(o.id), done: '${o.name} deleted.');
  }

  Future<void> _accept(LineOption o) async {
    if (_dirty.contains(o.id)) {
      _say('Save or discard the changes to ${o.name} first.');
      return;
    }
    final t = o.totals;
    final others = (_lines?.options.length ?? 1) - 1;
    final ok = await _confirm(
      'Accept ${o.name} for ${centsMoney(t.totalCents)}?',
      'Use this when the customer has chosen it. Its lines and prices are locked so the agreed price stays as it was'
          '${others > 0 ? ', and the other $others option${others == 1 ? '' : 's'} stay as alternatives' : ''}. Next, send it to the job.',
      'Accept option',
    );
    if (!ok) return;
    await _run('accept', () => _api.accept(o.id, o.version), done: '${o.name} accepted.');
  }

  Future<void> _unaccept(LineOption o) async {
    final ok = await _confirm('Undo the acceptance of ${o.name}?', 'It unlocks for editing, and no option is accepted.', 'Undo acceptance');
    if (!ok) return;
    await _run('unaccept', () => _api.unaccept(o.id), done: '${o.name} is no longer accepted.');
  }

  Future<void> _convert(LineOption o) async {
    final target = await showDialog<String>(
      context: context,
      builder: (_) => _SendToJobDialog(option: o, suggested: _linkConfirmed ? null : _becameJob),
    );
    if (target == null) return;
    _set(() => _busy = 'convert');
    try {
      final (s, r) = await _api.convert(o.id, target);
      _set(() {
        _lines = s;
        _keepOptionInView();
      });
      _say(
        r.alreadyDone
            ? '${o.name} was already sent to job #${r.jobId}; nothing new was made.'
            : '${o.name} sent to job #${r.jobId}.${r.customerDiffers ? ' Note: that job is for a different customer.' : ''}',
        action: SnackBarAction(label: 'Open job', onPressed: () => _openRecord(r.jobId, estimate: false)),
      );
      unawaited(_load()); // the estimate now links to the job for certain
    } on LineItemsException catch (e) {
      _say(e.message);
    } finally {
      _set(() => _busy = null);
    }
  }

  Future<bool> _confirm(String title, String body, String action, {bool danger = false}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        title: title,
        icon: danger ? Icons.delete_outline_rounded : Icons.help_outline_rounded,
        iconColor: danger ? DashUi.redText : DashUi.ink,
        body: Text(body, style: const TextStyle(fontSize: 14, color: DashUi.slate, height: 1.45)),
        actions: [
          AppButton.ghost('Cancel', () => Navigator.pop(ctx, false)),
          AppButton.ink(action, () => Navigator.pop(ctx, true), danger: danger),
        ],
      ),
    );
    return ok == true;
  }

  /// The customer's PDF: every option with lines. An estimate with no proposal yet can make one from Service Fusion's
  /// items first (the server's copy totals what Service Fusion says).
  Future<void> _openProposalPdf() async {
    final opts = (_lines?.options ?? const <LineOption>[]).where((o) => o.items.isNotEmpty).toList();
    if (opts.isEmpty) {
      if (!_canEditLines || _sfItems.isEmpty) {
        _say('There are no line items to put on a proposal yet.');
        return;
      }
      final ok = await _confirm(
        'Make the proposal first?',
        'The customer PDF is made from the estimate\'s options. Copy Service Fusion\'s ${_sfItems.length} items into Option 1 and open the PDF?',
        'Copy and open PDF',
      );
      if (!ok) return;
      await _newOption('service_fusion');
      if (!mounted || (_lines?.options.isEmpty ?? true)) return;
      return _openProposalPdf();
    }
    if (_dirty.isNotEmpty) _say('Unsaved changes are not on the PDF. Save them first to include them.');
    final cust = _customer;
    await showProposalPdf(
      context,
      ProposalInput(
        estimateId: widget.jobId,
        customer: _s('customer_name'),
        contact: _s('contact_name').isEmpty ? (cust?['primary_contact'] ?? '').toString() : _s('contact_name'),
        location: _s('location'),
        description: _s('description'),
        preparedBy: _s('opportunity_owner'),
        date: DateTime.now(),
        options: [
          for (final o in opts)
            ProposalOption(name: o.name, lines: o.items, taxRate: o.taxRate, recommended: o.isRecommended, accepted: o.accepted, notes: o.notes),
        ],
      ),
    );
  }
}

/// The option selector: one tile per option (name, total, what sets it apart), "New option", and Service Fusion's own
/// items for reference. Picking one changes which option is edited below; nothing else on the page moves.
class _OptionPicker extends StatelessWidget {
  final _JobDetailScreenState state;
  final String selected;
  const _OptionPicker({required this.state, required this.selected});

  @override
  Widget build(BuildContext context) {
    final s = state;
    final opts = s._lines!.options;
    final current = s._lines!.byId(selected);
    final canEdit = s._canEditLines;
    final busy = s._busy != null;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final o in opts)
          _OptionTile(
            option: o,
            selected: o.id == selected,
            dirty: s._dirty.contains(o.id),
            showMargin: s._canSeeCost,
            onTap: () => s._set(() => s._option = o.id),
          ),
        if (canEdit)
          MenuAnchor(
            menuChildren: [
              MenuItemButton(
                leadingIcon: const Icon(Icons.note_add_outlined, size: 18),
                onPressed: () => s._newOption('blank'),
                child: const Text('Blank option'),
              ),
              if (current != null)
                MenuItemButton(
                  leadingIcon: const Icon(Icons.copy_all_rounded, size: 18),
                  onPressed: () => s._newOption('copy', copyOf: current.id),
                  child: Text('Copy of ${current.name}'),
                ),
              MenuItemButton(
                leadingIcon: const Icon(Icons.content_copy_rounded, size: 18),
                onPressed: () => s._newOption('service_fusion'),
                child: const Text('From Service Fusion\'s items'),
              ),
            ],
            builder: (context, ctl, _) => _GhostTile(
              icon: s._busy == 'new' ? null : Icons.add_rounded,
              title: 'New option',
              caption: opts.isEmpty ? 'Blank, or from Service Fusion' : 'Blank, a copy, or from Service Fusion',
              onTap: busy || opts.length >= 10 ? null : () => ctl.isOpen ? ctl.close() : ctl.open(),
            ),
          ),
        _GhostTile(
          icon: Icons.lock_outline_rounded,
          title: 'Service Fusion',
          caption: 'Read-only copy',
          selected: selected == 'sf',
          onTap: () => s._set(() => s._option = 'sf'),
        ),
      ],
    );
  }
}

class _OptionTile extends StatelessWidget {
  final LineOption option;
  final bool selected;
  final bool dirty;
  final bool showMargin;
  final VoidCallback onTap;
  const _OptionTile({required this.option, required this.selected, required this.dirty, required this.showMargin, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final o = option;
    final t = o.totals;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final lines = o.items.where((l) => !l.isDiscount).length;
    final meta = [
      '$lines line${lines == 1 ? '' : 's'}',
      if (showMargin && t.marginPct != null) '${t.marginPct!.toStringAsFixed(1)}% margin',
    ].join('  ·  ');
    final (String, Color, IconData)? mark = o.accepted
        ? ('Accepted', DashUi.emeraldText, Icons.verified_rounded)
        : o.isRecommended
        ? ('Recommended', DashUi.amberText, Icons.star_rounded)
        : null;
    return DashPressable(
      onTap: onTap,
      label:
          '${o.name}, ${centsMoney(t.totalCents)}${o.accepted ? ', accepted' : ''}${o.isRecommended ? ', recommended' : ''}${dirty ? ', unsaved changes' : ''}',
      selected: selected,
      radius: BorderRadius.circular(8),
      builder: (hover) => AnimatedContainer(
        duration: reduce ? Duration.zero : const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        constraints: const BoxConstraints(minWidth: 168, maxWidth: 240),
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
        decoration: BoxDecoration(
          color: selected || hover ? Colors.white : _tileTint,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? DashUi.ink : (o.accepted ? const Color(0xFFA7F3D0) : DashUi.line), width: selected ? 1.6 : 1),
          boxShadow: selected ? [BoxShadow(color: DashUi.ink.withValues(alpha: 0.08), blurRadius: 14, offset: const Offset(0, 4))] : const [],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    o.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: selected ? DashUi.ink : DashUi.slate),
                  ),
                ),
                if (dirty)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Tooltip(
                      message: 'Unsaved changes',
                      child: CircleAvatar(radius: 4, backgroundColor: DashUi.amber),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              centsMoney(t.totalCents),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: DashUi.ink, letterSpacing: -0.4, fontFeatures: _figures),
            ),
            const SizedBox(height: 2),
            Text(meta, style: const TextStyle(fontSize: 12, color: DashUi.subtle, fontFeatures: _figures)),
            // Every tile keeps a line for its mark, so the row of tiles lines up.
            const SizedBox(height: 6),
            SizedBox(
              height: 17,
              child: mark == null
                  ? null
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(mark.$3, size: 14, color: mark.$1 == 'Recommended' ? DashUi.amber : mark.$2),
                        const SizedBox(width: 4),
                        Text(
                          mark.$1,
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: mark.$2),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A quieter tile beside the options: "New option", or Service Fusion's read-only items.
class _GhostTile extends StatelessWidget {
  final IconData? icon; // null: working
  final String title;
  final String caption;
  final bool selected;
  final VoidCallback? onTap;
  const _GhostTile({required this.icon, required this.title, required this.caption, this.selected = false, required this.onTap});

  @override
  Widget build(BuildContext context) => DashPressable(
    onTap: onTap,
    label: '$title. $caption',
    selected: selected,
    radius: BorderRadius.circular(8),
    builder: (hover) => AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.fromLTRB(12, 11, 14, 11),
      decoration: BoxDecoration(
        color: selected ? Colors.white : (hover && onTap != null ? _tileTint : Colors.white.withValues(alpha: 0)),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: selected ? DashUi.ink : DashUi.line, width: selected ? 1.6 : 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon == null
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(icon, size: 18, color: onTap == null ? DashUi.muted : DashUi.slate),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: onTap == null ? DashUi.subtle : DashUi.ink),
              ),
              Text(caption, style: const TextStyle(fontSize: 12, color: DashUi.subtle)),
            ],
          ),
        ],
      ),
    ),
  );
}

/// The option being edited: its name and where it stands on the left, what can be done to it on the right.
class _OptionBar extends StatelessWidget {
  final _JobDetailScreenState state;
  final LineOption option;
  const _OptionBar({required this.state, required this.option});

  @override
  Widget build(BuildContext context) {
    final s = state;
    final o = option;
    final canEdit = s._canEditLines;
    final busy = s._busy != null;
    final opts = s._lines!.options;
    final about = [
      if (o.source == 'service_fusion') 'Started from Service Fusion\'s items',
      if (o.source == 'copy' && o.sourceOptionName != null) 'Copied from ${o.sourceOptionName}',
      if (o.updatedAt != null) 'saved${o.updatedBy.isEmpty ? '' : ' by ${o.updatedBy}'} ${DateFormat('MMM d').format(o.updatedAt!.toLocal())}',
    ].join(', ');
    final icon = IconButton.styleFrom(foregroundColor: DashUi.slate, minimumSize: const Size(36, 36));
    final actions = <Widget>[
      if (canEdit && !o.accepted) ...[
        IconButton(tooltip: 'Rename', style: icon, onPressed: busy ? null : () => s._renameOption(o), icon: const Icon(Icons.drive_file_rename_outline_rounded, size: 19)),
        IconButton(
          tooltip: o.isRecommended ? 'Recommended (click to unmark)' : 'Mark as recommended',
          style: icon,
          onPressed: busy ? null : () => s._toggleRecommended(o),
          icon: Icon(o.isRecommended ? Icons.star_rounded : Icons.star_outline_rounded, size: 20, color: o.isRecommended ? DashUi.amber : null),
        ),
      ],
      if (canEdit)
        IconButton(
          tooltip: 'Duplicate as a new option',
          style: icon,
          onPressed: busy || opts.length >= 10 ? null : () => s._newOption('copy', copyOf: o.id),
          icon: const Icon(Icons.copy_all_rounded, size: 19),
        ),
      if (canEdit && !o.accepted)
        IconButton(tooltip: 'Delete option', style: icon, onPressed: busy ? null : () => s._deleteOption(o), icon: const Icon(Icons.delete_outline_rounded, size: 19)),
      if (canEdit && !o.accepted && s._lines!.accepted == null) ...[
        const SizedBox(width: 6),
        OutlinedButton.icon(
          onPressed: busy ? null : () => s._accept(o),
          icon: s._busy == 'accept'
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.verified_outlined, size: 17),
          label: const Text('Accept'),
          style: OutlinedButton.styleFrom(
            foregroundColor: DashUi.emeraldText,
            side: const BorderSide(color: Color(0xFFA7F3D0)),
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
          ),
        ),
      ],
    ];
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          o.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: DashUi.ink, letterSpacing: -0.2),
        ),
        if (about.isNotEmpty)
          Text(
            about[0].toUpperCase() + about.substring(1),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5, color: DashUi.subtle),
          ),
      ],
    );
    return LayoutBuilder(
      builder: (context, c) => c.maxWidth >= 560
          ? Row(
              children: [
                Expanded(child: title),
                const SizedBox(width: 12),
                Row(mainAxisSize: MainAxisSize.min, children: actions),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                if (actions.isNotEmpty) Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: actions),
              ],
            ),
    );
  }
}

/// Under an option's totals: its notes for the customer, printed under it on the PDF.
class _ProposalNotes extends StatelessWidget {
  final _JobDetailScreenState state;
  final LineOption option;
  const _ProposalNotes({required this.state, required this.option});

  @override
  Widget build(BuildContext context) {
    final o = option;
    final text = o.notes.trim();
    final canEdit = state._canEditLines && !o.locked;
    if (text.isEmpty && !canEdit) return const SizedBox();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: DashUi.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.description_outlined, size: 16, color: DashUi.slate),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: 'Notes for the customer',
                          style: TextStyle(fontWeight: FontWeight.w800, color: DashUi.ink),
                        ),
                        TextSpan(text: '   printed under this option on the PDF'),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: DashUi.subtle),
                  ),
                ),
                if (canEdit)
                  TextButton.icon(
                    onPressed: () => state._editOptionNotes(o),
                    icon: Icon(text.isEmpty ? Icons.add_rounded : Icons.edit_outlined, size: 16),
                    label: Text(text.isEmpty ? 'Add notes' : 'Edit notes'),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 2, right: 6),
              child: text.isEmpty
                  ? const Text(
                      'None yet. Use them for what is included, lead times or warranty terms.',
                      style: TextStyle(fontSize: 13, color: DashUi.subtle, height: 1.4),
                    )
                  : SelectableText(text, style: const TextStyle(fontSize: 13.5, color: DashUi.ink, height: 1.5)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Where the lines come from or why they are locked, with its actions: a rounded note, tinted when it matters
/// (accepted, couldn't load).
class _ItemsBanner extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color tone;
  final List<Widget> actions;
  const _ItemsBanner({required this.icon, required this.text, this.tone = DashUi.slate, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    final (bg, edge) = switch (tone) {
      DashUi.emeraldText => (const Color(0xFFF0FDF4), const Color(0xFFBBF7D0)),
      DashUi.amberText => (const Color(0xFFFFFBEB), const Color(0xFFFDE68A)),
      _ => (_tileTint, DashUi.line),
    };
    final message = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 17, color: tone)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: tone, height: 1.4)),
        ),
      ],
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10), border: Border.all(color: edge)),
      child: LayoutBuilder(
        builder: (context, c) => actions.isEmpty
            ? message
            : c.maxWidth >= 620
            ? Row(
                children: [
                  Expanded(child: message),
                  for (final a in actions) Padding(padding: const EdgeInsets.only(left: 8), child: a),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  message,
                  const SizedBox(height: 6),
                  Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 6, children: actions),
                ],
              ),
      ),
    );
  }
}

class _NameDialog extends StatefulWidget {
  final String initial;
  const _NameDialog({required this.initial});

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _c = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _ok() {
    final v = _c.text.trim();
    if (v.isEmpty) {
      setState(() => _error = 'Give the option a name.');
      return;
    }
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: 'Rename option',
    icon: Icons.drive_file_rename_outline_rounded,
    body: TextField(
      controller: _c,
      autofocus: true,
      maxLength: 80,
      onSubmitted: (_) => _ok(),
      decoration: appFieldDecoration(hint: 'Standard, Upgraded, Premium...', error: _error),
    ),
    actions: [AppButton.ghost('Cancel', () => Navigator.pop(context)), AppButton.ink('Rename', _ok)],
  );
}

/// Which job the accepted option goes to. Jobs are made in Service Fusion; this fills the job's items once.
class _SendToJobDialog extends StatefulWidget {
  final LineOption option;
  final String? suggested;
  const _SendToJobDialog({required this.option, this.suggested});

  @override
  State<_SendToJobDialog> createState() => _SendToJobDialogState();
}

class _SendToJobDialogState extends State<_SendToJobDialog> {
  late final _c = TextEditingController(text: widget.suggested ?? '');
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _ok() {
    final v = _c.text.trim();
    if (!RegExp(r'^\d{1,20}$').hasMatch(v)) {
      setState(() => _error = 'Enter the job number (digits only).');
      return;
    }
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.option;
    final t = o.totals;
    return AppDialog(
      title: 'Send ${o.name} to a job',
      icon: Icons.send_rounded,
      width: 500,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'The job\'s line items become this option\'s ${o.items.length} line${o.items.length == 1 ? '' : 's'} (${centsMoney(t.totalCents)}). '
            'Service Fusion still creates the job itself; this can be done once per option.',
            style: const TextStyle(fontSize: 14, color: DashUi.slate, height: 1.45),
          ),
          const SizedBox(height: 14),
          const AppFieldLabel('Job number', help: 'The job Service Fusion made for this estimate.'),
          TextField(
            controller: _c,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onSubmitted: (_) => _ok(),
            decoration: appFieldDecoration(
              hint: 'e.g. 1096183137',
              error: _error,
              helper: widget.suggested == null ? null : 'Suggested: the likely match (same customer and address).',
            ),
          ),
        ],
      ),
      actions: [
        AppButton.ghost('Cancel', () => Navigator.pop(context)),
        AppButton.ink('Send to job', _ok, icon: Icons.send_rounded),
      ],
    );
  }
}
