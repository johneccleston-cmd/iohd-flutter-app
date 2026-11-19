part of 'job_detail_screen.dart';

// The job's line items and the estimate's options, in the Products & Services block at the bottom of the job page.
//
// A record shows Service Fusion's own items, or the set kept in our tables when it has one (an estimate's options, a
// job's items sent from an accepted option). Service Fusion's copy stays one click away for reference. Estimate
// options are alternatives for the same job: each has its own lines, totals and notes for the customer, one can be
// marked recommended, one accepted (which locks it), and the accepted one is sent to the job once.
//
// The block, top to bottom: its title with the record's controls at the right; while editing, the preview strip; for an
// estimate with options, a row of tabs on white (one per option: name, total, lines and margin, its marks; the open one
// underlined in ink) and the open option's header (its name, where it stands, Accept or Send to job, and one menu for the
// rest); then the lines and, under them, the notes for the customer beside the summary.
//
// The lines are read-only until the ribbon's Edit Job / Edit Estimate. That opens a preview: the lines on show can be
// changed and the totals follow, but nothing is saved, to our database or to Service Fusion. So the strip has no Save
// (it only ever said saving isn't available, user 2026-11-13): it says what the preview is, and Exit preview (or leaving
// the page) puts back what was there. Ctrl+S, from habit, gets the same answer in the strip. The option actions (new,
// rename, recommend, notes, accept, send to job, delete) still save to our own database, never to Service Fusion.

const _figures = [FontFeature.tabularFigures()];

/// What Service Fusion calls an estimate's own option (its first option tab). Service Fusion doesn't send the name (0
/// of 2,182 synced estimates carry it, checked 2026-11-13), so the app gives its lines the name Service Fusion shows.
const kEstimateOptionName = 'Estimate Option';

/// Behind a neutral banner: the app's lightest fill.
const _tileTint = AppTheme.subtleFillLight;

/// How a sales tax reads in the totals: "Sales tax Rogers 10%", or "Sales tax 10.5%" when its name says nothing more.
String _taxRowLabel(SalesTax t) => t.short.trim().toLowerCase() == 'sales tax' ? 'Sales tax ${SalesTax.rateText(t.rate)}%' : 'Sales tax ${t.label}';

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
  /// A cost of $0 is Service Fusion's "no cost entered" (most services): unknown, not free, so the line has no cost and
  /// no profit is worked out over it (Services Catalog Phase 2; the server copies these lines the same way).
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
          // A return's cost comes as -$7 on -1: $7 a unit (it was shown as -$7 a unit, so +$7 extended, before).
          // Same rule as seedFromServiceFusion in line_items.js, where a cost of 0 is unknown too.
          cost: ext == null || ext == 0 ? null : (q != 0 ? (ext / q * 100).round() / 100 : null),
          taxable: (it['tax'] ?? '').toString().trim().isNotEmpty,
          source: 'service_fusion',
          customerVisible: it['is_show_rate_items'] == true,
          taxName: (it['tax'] ?? '').toString().trim().isEmpty ? null : (it['tax'] as Object).toString().trim(),
        );
      }(),
  ];

  /// Each Service Fusion line's own total, in cents, lined up with [_sfLines].
  List<int> get _sfAmounts => [for (final it in _sfItems) (_JobDetailScreenState._n(it['total']) * 100).round()];

  /// For a record Service Fusion sent without its charges (estimates come that way), the sales tax its total implies:
  /// what the total holds beyond the items, as a rate on the taxed lines. It is kept only when that rate gives back
  /// Service Fusion's total to the cent, the same rule the server uses when it copies Service Fusion's items into an
  /// option (seedFromServiceFusion in line_items.js), and only when the taxed lines all name the same tax. Null otherwise.
  SalesTax? get _impliedTax {
    if (_sfCharges.isNotEmpty || _job?['total_revenue'] == null) return null;
    int cents(dynamic v) => (_JobDetailScreenState._n(v) * 100).round();
    final items = _sfItems;
    final taxed = items.where((it) => (it['tax'] ?? '').toString().trim().isNotEmpty).toList();
    final names = {for (final it in taxed) it['tax'].toString().trim()};
    if (names.length != 1) return null;
    final itemsC = items.fold<int>(0, (s, it) => s + cents(it['total']));
    final taxableC = taxed.fold<int>(0, (s, it) => s + cents(it['total']));
    final left = cents(_job!['total_revenue']) - itemsC;
    if (left <= 0 || taxableC <= 0) return null;
    final rate = (left / taxableC * 10000).round() / 100;
    if (rate <= 0 || rate > 30) return null;
    return mulDivRound(taxableC, (rate * 10000).round(), 1000000) == left ? SalesTax(names.single, rate, onRecord: true) : null;
  }

  /// Service Fusion's figures as it has them: its items, each charge it lists (tax, discounts), anything its total
  /// holds that it doesn't itemize, and its total. (Its cost shows per line, in the table's cost columns.)
  ///
  /// With [lines] and [figures] (a preview of changed lines) the same figures are reworked for them: each sales tax is
  /// its rate on the lines that carry it (see SalesTax.resolve), a percentage charge follows the items in the proportion
  /// Service Fusion had, and fixed charges and anything it doesn't itemize stay as they are.
  ///
  /// Each figure says what it is ([SummaryKind]), so the editor can work out profit on the money before tax: items,
  /// discounts (Service Fusion keeps its discounts as charges) and other charges, never tax or the unexplained rest.
  List<LineSummaryRow> _sfSummaryRows([List<LineDraft>? lines, List<LineFigures>? figures]) {
    int cents(dynamic v) => (_JobDetailScreenState._n(v) * 100).round();
    final sfItems = _sfItems;
    final wasItems = sfItems.fold<int>(0, (s, it) => s + cents(it['total']));
    final wasTaxable = sfItems.where((it) => (it['tax'] ?? '').toString().trim().isNotEmpty).fold<int>(0, (s, it) => s + cents(it['total']));
    final implied = _impliedTax;
    // The implied tax on Service Fusion's own lines: exactly what its total holds beyond the items (see _impliedTax).
    final impliedWas = implied == null ? 0 : mulDivRound(wasTaxable, (implied.rate * 10000).round(), 1000000);
    const impliedTip = 'Worked out from Service Fusion\'s total: it doesn\'t send the tax line for estimates.';
    var items = wasItems, discounts = 0, taxable = wasTaxable;
    final preview = lines != null && figures != null;
    if (preview) {
      items = discounts = taxable = 0;
      for (var i = 0; i < lines.length; i++) {
        final amount = figures[i].amountCents;
        if (lines[i].isDiscount) {
          discounts -= amount; // a discount's amount is negative
        } else {
          items += amount;
        }
        if (lines[i].taxable) taxable += amount;
      }
      if (taxable < 0) taxable = 0;
    }
    final net = items - discounts;
    int scaled(int was, int base, int wasBase) => wasBase <= 0 || base == wasBase ? was : (was * base / wasBase).round();

    final rows = <LineSummaryRow>[
      LineSummaryRow('Items', items, kind: SummaryKind.items),
      if (discounts != 0) LineSummaryRow('Discounts', -discounts, kind: SummaryKind.discount),
    ];
    var wasCharges = 0, charges = 0;
    if (preview) {
      // Taxable cents per sales tax, in the order the lines name them.
      final choices = _taxChoices;
      final bases = <String, int>{};
      final byName = <String, SalesTax>{};
      var discountBase = 0;
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].taxable) continue;
        if (lines[i].isDiscount) {
          discountBase += figures[i].amountCents; // negative
          continue;
        }
        final t = SalesTax.resolve(lines[i].taxName, choices);
        final key = t?.name ?? lines[i].taxName ?? '';
        if (t != null) byName[key] = t;
        bases[key] = (bases[key] ?? 0) + figures[i].amountCents;
      }
      // A taxable discount comes off the first tax's lines.
      if (discountBase != 0 && bases.isNotEmpty) bases[bases.keys.first] = bases[bases.keys.first]! + discountBase;
      for (final e in bases.entries) {
        final t = byName[e.key];
        final rate = t?.rate ?? 0;
        final amount = e.value <= 0 ? 0 : mulDivRound(e.value, (rate * 10000).round(), 1000000);
        charges += amount;
        rows.add(
          LineSummaryRow(
            t == null ? 'Sales tax (rate not known)' : _taxRowLabel(t),
            amount,
            kind: SummaryKind.tax,
            tip: t == implied ? impliedTip : null,
          ),
        );
      }
    } else if (implied != null) {
      charges += impliedWas;
      rows.add(LineSummaryRow(_taxRowLabel(implied), impliedWas, kind: SummaryKind.tax, tip: impliedTip));
    }
    for (final c in _sfCharges) {
      final amount = cents(c['total']).abs();
      final discount = c['is_discount'] == true;
      final was = discount ? -amount : amount;
      wasCharges += was;
      final name = (c['name'] ?? c['other_charge'] ?? 'Charge').toString().trim();
      // A percentage, not a quantity: "10%", "9.75%" (quantities always show two decimals; rates don't).
      final pct = c['is_percentage'] == true && c['rate'] != null ? ' ${SalesTax.rateText(_JobDetailScreenState._n(c['rate']))}%' : '';
      // Service Fusion names its tax charges in full ("Sales Tax (State, County, & Local Use Tax, Prairie Grove)").
      final isTax = _isTaxCharge(c);
      if (isTax && preview) continue; // worked out above, per tax
      final now = isTax
          ? (wasTaxable > 0 ? scaled(was, taxable, wasTaxable) : scaled(was, net, wasItems))
          : (c['is_percentage'] == true ? scaled(was, net, wasItems) : was);
      charges += now;
      rows.add(
        LineSummaryRow(
          isTax ? 'Sales tax$pct' : '$name$pct',
          now,
          kind: isTax ? SummaryKind.tax : (discount ? SummaryKind.discount : SummaryKind.charge),
          tip: isTax ? name : null,
        ),
      );
    }
    if (_job?['total_revenue'] != null) {
      final left = cents(_job!['total_revenue']) - wasItems - wasCharges - impliedWas;
      if (left.abs() >= 1) {
        rows.add(
          LineSummaryRow(
            _sfCharges.isEmpty && left > 0 ? 'Tax and other charges' : 'Not itemized in Service Fusion',
            left,
            kind: SummaryKind.unitemized,
            tip: 'In Service Fusion\'s total, but not listed as an item or a charge. Left out of profit.',
          ),
        );
      }
      rows.add(LineSummaryRow('Total', net + charges + left, kind: SummaryKind.total));
    }
    return rows;
  }

  /// A Service Fusion charge that is a sales tax (it names its tax charges in full: "Sales Tax (State, County, ...)").
  static bool _isTaxCharge(Map<String, dynamic> c) =>
      c['is_discount'] != true && (c['name'] ?? c['other_charge'] ?? '').toString().toLowerCase().contains('tax');

  /// The sales taxes a line can be given: the tax charge(s) on this record (its Rogers tax line, say), so each line is
  /// either taxed at that tax or not taxed at all. A record sent without its charges offers the tax its total implies.
  List<SalesTax> get _taxChoices {
    final mine = <String, SalesTax>{};
    for (final c in _sfCharges.where(_isTaxCharge)) {
      final name = (c['name'] ?? c['other_charge'] ?? '').toString().trim();
      if (name.isNotEmpty) mine[name] = SalesTax(name, _JobDetailScreenState._n(c['rate']), onRecord: true);
    }
    if (mine.isEmpty) {
      final implied = _impliedTax;
      if (implied != null) return [implied];
    }
    return mine.values.toList();
  }

  /// The estimate's own option (Service Fusion's lines) as a rail tab: its total as Service Fusion has it, its lines,
  /// and its margin on the money before tax (as the editor's profit panel works it out). No margin while a line's cost
  /// is unknown (a Service Fusion cost of 0 is, see [_sfLines]): it would read as if that line cost nothing.
  _TabFacts get _sfTab {
    final rows = _sfSummaryRows();
    final total = rows.where((r) => r.kind == SummaryKind.total).firstOrNull?.cents ?? rows.fold<int>(0, (s, r) => s + r.cents);
    final net = rows.where((r) => r.beforeTax).fold<int>(0, (s, r) => s + r.cents);
    final figures = computeLineTotals(_sfLines, null);
    final cost = figures.costCents;
    return _TabFacts(
      name: kEstimateOptionName,
      totalCents: total,
      lines: _sfLines.where((l) => !l.isDiscount).length,
      marginPct: net > 0 && figures.missingCostLines == 0 ? ((net - cost) / net * 1000).round() / 10 : null,
      current: _lines?.accepted == null,
    );
  }

  /// Service Fusion's items with its own figures: read-only, or the preview's draft while editing.
  LineItemsEditor _sfEditor({Key key = const ValueKey('sf-items'), required String emptyTitle, required String emptyMessage, Widget? banner}) =>
      LineItemsEditor(
        key: key,
        lines: _editSfLines ?? _sfLines,
        taxRate: null,
        editable: _editing && _canEditLines,
        showCost: _canSeeCost,
        summary: _sfSummaryRows(),
        summaryBuilder: _sfSummaryRows,
        fixedAmounts: _editSfAmounts ?? _sfAmounts,
        taxOptions: _taxChoices,
        totalLabel: _isEstimate ? 'Estimate total' : 'Job total',
        onPreviewSave: _previewSave,
        // The estimate's own option's tab follows a changed draft's figures (see _OptionTabs).
        onFigures: _isEstimate ? (total, margin) => _set(() => _liveFigures['sf'] = (total, margin)) : null,
        onDirtyChanged: (d) => _set(() {
          if (d) {
            _dirty.add('sf');
            return;
          }
          _dirty.remove('sf');
          // Back to no changes in the preview: the lines on show follow what was last loaded (a Refresh may have come
          // in while there were changes, and kept them; found by the 2026-11-13 review).
          if (_editing) {
            _editSfLines = _sfLines;
            _editSfAmounts = _sfAmounts;
          }
        }),
        emptyTitle: emptyTitle,
        emptyMessage: _editing ? 'Search the catalog below to try a line.' : emptyMessage,
        banner: banner,
      );

  // ---- editing: a preview that is never saved ---------------------------------------------------------------------

  /// The ribbon's Edit Job / Edit Estimate. Nothing is sent anywhere by this, or by anything done while it is on.
  void _startEditing() {
    if (_editing || !_canEditLines) return;
    _set(() {
      _editing = true;
      _saveAsked = false;
      _editSfLines = _sfLines;
      _editSfAmounts = _sfAmounts;
    });
    // The line items are at the bottom of the page: bring them up.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _itemsKey.currentContext;
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(
        ctx,
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    });
  }

  /// Cancel: every editor drops its draft as it turns read-only again, so what shows is what was loaded. A "Removed ...
  /// Undo" still on screen goes too: there is no draft left to put the line back into.
  void _stopEditing() {
    if (!_editing) return;
    final changed = _dirty.isNotEmpty;
    _set(() {
      _editing = false;
      _saveAsked = false;
      _editSfLines = null;
      _editSfAmounts = null;
      _dirty.clear();
    });
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    if (changed) _say('Preview closed. The original products and services are back; nothing was changed.');
  }

  /// Ctrl+S in the table: there is nothing to save to yet, and the strip says so.
  void _previewSave() => _set(() => _saveAsked = true);

  // ---- job: line items --------------------------------------------------------------------------------------------

  /// While our line items load, a spinner. If they can't be loaded (the server is down, or older than this app),
  /// Service Fusion's own items still show, read-only, with what went wrong and a Retry: the page never loses them.
  Widget _linesLoadingOrError() {
    if (_linesError != null) {
      return _sfEditor(
        key: const ValueKey('sf-items-fallback'),
        emptyTitle: 'No products or services',
        emptyMessage: 'Service Fusion has no items on this record.',
        banner: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: _ItemsBanner(
            icon: Icons.cloud_off_rounded,
            tone: DashUi.amberText,
            text:
                'Showing Service Fusion\'s items. The products and services kept in this app couldn\'t be loaded ($_linesError), so editing is unavailable for now.',
            actions: [TextButton.icon(onPressed: _loadLines, icon: const Icon(Icons.refresh_rounded, size: 16), label: const Text('Retry'))],
          ),
        ),
      );
    }
    return const _LinesSkeleton();
  }

  Widget _jobItemsPanel() {
    final set = _jobSet;
    final loaded = _lines != null;
    final actions = <Widget>[
      if (loaded && set != null && set.source == 'estimate' && set.sourceEstimateId != null)
        _QuietLink(
          icon: Icons.request_quote_outlined,
          text: 'From estimate #${set.sourceEstimateId}',
          tip: 'These items came from the accepted option of estimate #${set.sourceEstimateId}',
          onTap: () => _openRecord(set.sourceEstimateId!, estimate: true),
        ),
      if (loaded && set != null)
        DashSegmented<bool>(
          value: _showSfItems,
          options: const [(false, 'This job'), (true, 'Service Fusion')],
          label: 'Products and services from',
          onChanged: (v) => _set(() => _showSfItems = v),
        ),
    ];
    final Widget body;
    if (!loaded) {
      body = _linesLoadingOrError();
    } else if (set == null) {
      body = _sfEditor(emptyTitle: 'No products or services', emptyMessage: 'Service Fusion has no items on this job.');
    } else {
      // Both stay alive (one hidden), so a preview draft survives a look at Service Fusion's copy and back.
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Offstage(
            offstage: _showSfItems,
            child: TickerMode(
              enabled: !_showSfItems,
              child: LineItemsEditor(
                key: ValueKey('job-set-${set.id}'),
                lines: set.items,
                taxRate: set.taxRate,
                editable: _editing && _canEditLines,
                showCost: _canSeeCost,
                totalLabel: 'Job total',
                // No taxOptions: this set has its own tax rate (its tax line), so a line is taxed at that or not at all.
                onPreviewSave: _previewSave,
                onDirtyChanged: (d) => _set(() => d ? _dirty.add(set.id) : _dirty.remove(set.id)),
                onConfirmZero: _canEditLines && !set.locked ? (line) => _confirmZero(set, line) : null,
              ),
            ),
          ),
          Offstage(
            offstage: !_showSfItems,
            child: TickerMode(
              enabled: _showSfItems,
              child: _sfEditor(emptyTitle: 'No products or services', emptyMessage: 'Service Fusion has no items on this job.'),
            ),
          ),
        ],
      );
    }
    return _itemsPanel(actions: _linesError != null ? const [] : actions, body: body);
  }

  /// The Products & Services block (Service Fusion's own name for these lines), a square white block headed exactly
  /// like Details and Job Info above it (the page's standard block heading, see _tabbedBlock): the title alone (no
  /// helper line under it, user 2026-11-12) with the record's controls flush right (under it on a narrow block), and a
  /// hairline under the heading; the preview strip while editing; then the body.
  Widget _itemsPanel({List<Widget> actions = const [], required Widget body}) {
    final still = MediaQuery.disableAnimationsOf(context);
    const title = Text(
      'Products & Services',
      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: DashUi.ink, letterSpacing: -0.2),
    );
    final buttons = actions.isEmpty ? null : Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: actions);
    // No hover helper text anywhere on the block (user 2026-11-13): every tooltip under it stays hidden.
    return TooltipVisibility(
      visible: false,
      child: Container(
        key: _itemsKey,
        decoration: _JobDetailScreenState._blockFill, // a square full-width block, like the rest of the page
        clipBehavior: Clip.hardEdge,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, c) {
                final inline = c.maxWidth >= 640 || buttons == null;
                return Padding(
                  padding: EdgeInsets.fromLTRB(20, 14, inline ? 14 : 20, 14),
                  child: inline
                      ? ConstrainedBox(
                          // As tall as the Details block's heading with its tabs, so the blocks' titles match.
                          constraints: const BoxConstraints(minHeight: 34),
                          child: Row(
                            children: [
                              const Expanded(child: title),
                              if (buttons != null) ...[const SizedBox(width: 16), buttons],
                            ],
                          ),
                        )
                      : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [title, const SizedBox(height: 10), buttons]),
                );
              },
            ),
            const Divider(height: 1, color: DashUi.line),
            // The preview strip opens and closes with the editing state.
            AnimatedSize(
              duration: still ? Duration.zero : const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _editing
                  ? _EditPreviewBar(what: _isEstimate ? 'estimate' : 'job', changed: _dirty.isNotEmpty, saveAsked: _saveAsked, onExit: _stopEditing)
                  : const SizedBox(width: double.infinity),
            ),
            Padding(padding: const EdgeInsets.only(bottom: 16), child: body),
          ],
        ),
      ),
    );
  }

  // ---- estimate: the proposal and its options ---------------------------------------------------------------------

  Widget _proposalPanel() {
    final opts = _lines?.options ?? const <LineOption>[];
    final Widget body;
    var actions = const <Widget>[];
    if (_lines == null) {
      body = _linesLoadingOrError();
    } else {
      // Service Fusion's own lines are the estimate's own option, "Estimate Option" (Service Fusion's name for it), with
      // the first tab; which option opens first is _keepOptionInView's. With no option of ours it is the only tab, so
      // the table always says which option it is (round 4).
      final selected = _option ?? (opts.isEmpty ? 'sf' : opts.first.id);
      final current = _lines!.byId(selected);
      // New option sits at the right of the block's heading, where the page keeps its other adds (Add Task, Add Notes).
      if (_canEditLines) actions = [_NewOptionButton(state: this, current: current)];
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // The tabs stand on the table: its column headings start right under them.
          _OptionTabs(state: this, selected: selected),
          _SwitchFade(value: selected, child: _optionEditors(opts, selected)),
        ],
      );
    }
    return _itemsPanel(actions: actions, body: body);
  }

  /// Every option's table. Each keeps its own editor alive (hidden, not thrown away), so a draft survives switching to
  /// another option and back. Hidden ones take no room, so a short option isn't padded out to a long one's height.
  Widget _optionEditors(List<LineOption> opts, String selected) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final o in opts)
            Offstage(
              offstage: o.id != selected,
              child: TickerMode(
                enabled: o.id == selected,
                child: LineItemsEditor(
                  key: ValueKey('option-${o.id}'),
                  lines: o.items,
                  taxRate: o.taxRate,
                  editable: _editing && _canEditLines && !o.locked,
                  showCost: _canSeeCost,
                  totalLabel: 'Estimate total',
                  // No taxOptions: the option has its own tax rate (its tax line); a line is taxed at that or not at all.
                  onPreviewSave: _previewSave,
                  onDirtyChanged: (d) => _set(() => d ? _dirty.add(o.id) : _dirty.remove(o.id)),
                  onFigures: (total, margin) => _set(() => _liveFigures[o.id] = (total, margin)),
                  onConfirmZero: _canEditLines && !o.locked ? (line) => _confirmZero(o, line) : null,
                  emptyTitle: 'No lines in ${o.name} yet',
                  emptyMessage: _editing && !o.locked
                      ? 'Search the catalog below to try a line. Lines tried here are a preview and aren\'t kept.'
                      : 'Nothing has been added to this option. Line items can\'t be saved from this page yet, so a blank option stays empty.',
                  aside: _ProposalNotes(state: this, option: o),
                ),
              ),
            ),
          Offstage(
            offstage: selected != 'sf',
            child: _sfEditor(
              emptyTitle: 'No products or services in Service Fusion',
              emptyMessage: _canEditLines ? 'Start an option with "New option" above.' : 'Service Fusion has no items on this estimate.',
            ),
          ),
        ],
      );

  /// Why [o] can't be accepted yet, or null when it can: the server's own rules (a line to sell, every line priced,
  /// every $0.00 line confirmed as no charge), checked here first so the button can say so instead of failing.
  String? _cantAccept(LineOption o) {
    if (_editing) return 'Exit the preview first: changes in it aren\'t part of ${o.name}.';
    final items = o.items.where((l) => !l.isDiscount).toList();
    if (items.isEmpty) return 'Add line items before accepting this option.';
    final unpriced = items.where((l) => l.rate == null).length;
    if (unpriced > 0) return '${unpriced == 1 ? 'One line has' : '$unpriced lines have'} no price yet. Price every line before accepting.';
    // As the server words it (ZERO_PRICE_UNCONFIRMED), the line numbered as the option lists it.
    final zero = o.items.indexWhere((l) => l.zeroUnconfirmed);
    if (zero >= 0) {
      final more = o.items.where((l) => l.zeroUnconfirmed).length - 1;
      final line = 'Line ${zero + 1} ("${o.items[zero].name.trim()}")';
      return more == 0
          ? '$line is \$0.00 and not confirmed as no charge. Confirm it or enter a price before accepting.'
          : '$line and $more other line${more == 1 ? '' : 's'} are \$0.00 and not confirmed as no charge. Confirm them or enter prices before accepting.';
    }
    return null;
  }

  /// A saved $0.00 line confirmed as no charge, outside the preview: the server records who and when, and the option
  /// comes back with it (a stale version or an accepted option is refused, and the page reloads).
  Future<void> _confirmZero(LineOption o, LineDraft line) async {
    final id = line.id;
    if (id == null) return;
    final current = _lines?.byId(o.id) ?? o;
    await _run('confirm-zero', () => _api.confirmZero(o.id, id, current.version), done: '"${line.name.trim()}" is confirmed as no charge.');
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
    done: o.isRecommended ? '${o.name} is no longer recommended.' : '${o.name} is marked recommended.',
  );

  /// The option's notes for the customer.
  Future<void> _editOptionNotes(LineOption o) async {
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TextDialog(
        title: o.notes.trim().isEmpty ? 'Add notes for the customer' : 'Notes for the customer',
        hint: 'For ${o.name}: what is included, lead time, warranty...',
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
    final why = _cantAccept(o);
    if (why != null) {
      _say(why);
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
    final ok = await _confirm('Undo the acceptance of ${o.name}?', 'It is unlocked, and no option is accepted.', 'Undo acceptance');
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
}

/// ---- the option tabs ----------------------------------------------------------------------------------------------

// The estimate's options are tabs on the table itself (user 2026-11-13 round 4: "native table tabs", Service Fusion's
// own layout): folder tabs standing on the table's top rule. The open one is white and open at its foot, so it runs
// straight into the column headings under it; the others sit behind the rule in a faint fill. Each tab says what the
// option is (its name and marks) and what it comes to (its total and, for people who see costs, its margin), in the
// same two lines on every tab, so switching moves nothing. At the strip's right end is what can be done with the option
// on show (Accept, Send to job, its menu). The estimate's own option (Service Fusion's lines) comes first, a little
// apart. Tabs that don't fit go into "+N more" at the end; the open one is always among those shown.

/// The table's top rule, under the tabs (the open tab breaks it), and the tabs' own outline: a step darker than the
/// rules inside the table, so the open tab's edge reads against the white it stands on.
final Color _tabRule = Color.lerp(DashUi.line, DashUi.fieldEdge, 0.35)!;

/// How much higher the open tab stands than the others (its text stays on their baseline).
const _tabRise = 3.0;

/// A tab behind the rule: the faint fill. Under the pointer it goes a step DARKER, with a firmer edge (final polish
/// 2026-11-13: it used to go lighter, toward the open tab's white, so in Chrome a hovered tab read as the open one).
const _tabFill = DashUi.faint;
final Color _tabHover = Color.lerp(DashUi.faint, DashUi.line, 0.75)!;
final Color _tabHoverEdge = Color.lerp(_tabRule, DashUi.fieldEdge, 0.8)!;
const _tabRadius = 7.0;

/// The open tab's ink cap along its top edge: what marks it as the open one at a glance, with or without others
/// beside it (a lone tab used to read as a loose label).
const _tabCapH = 2.0;

const _tabName = TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.3, letterSpacing: -0.05);
const _tabTotal = TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.3, fontFeatures: _figures);
const _tabMeta = TextStyle(fontSize: 12, height: 1.3, fontFeatures: _figures);
const _tabMarkText = TextStyle(fontSize: 12, fontWeight: FontWeight.w600, height: 1.25);

/// A text's width as the tabs draw it (the page's font, the reader's text size).
double _textWidth(BuildContext context, String text, TextStyle style) {
  final p = TextPainter(
    text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.merge(style)),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final w = p.width;
  p.dispose();
  return w;
}

/// What a tab shows: an option of ours, or the estimate's own option (Service Fusion's lines).
class _TabFacts {
  final String name;
  final int totalCents;
  final int lines;
  final double? marginPct;
  final bool recommended;
  final bool accepted;

  /// The estimate's own option while no alternative is accepted.
  final bool current;
  const _TabFacts({
    required this.name,
    required this.totalCents,
    required this.lines,
    required this.marginPct,
    this.recommended = false,
    this.accepted = false,
    this.current = false,
  });

  factory _TabFacts.of(LineOption o) => _TabFacts(
    name: o.name,
    totalCents: o.totals.totalCents,
    lines: o.items.where((l) => !l.isDiscount).length,
    marginPct: o.totals.marginPct,
    recommended: o.isRecommended,
    accepted: o.accepted,
  );

  /// The mark after the name, which says which option is the current one: "Current" on the estimate's own option,
  /// "Accepted" on an alternative the customer chose (accepting it takes "Current" off the estimate's own).
  String? get mark => accepted ? 'Accepted' : (current ? 'Current' : null);

  /// The same tab with a changed draft's figures (what its table's totals show while the preview changes it).
  _TabFacts withFigures((int, double?) f) => _TabFacts(
    name: name,
    totalCents: f.$1,
    lines: lines,
    marginPct: f.$2,
    recommended: recommended,
    accepted: accepted,
    current: current,
  );
}

/// "Current" or "Accepted" after a tab's name: a small pill, white so it reads on either tab fill.
class _TabMark extends StatelessWidget {
  final String text;
  const _TabMark(this.text);

  static const _padL = 5.0, _padR = 7.0, _icon = 13.0, _iconGap = 3.0;

  static double widthOf(BuildContext context, String text) => _padL + _icon + _iconGap + _textWidth(context, text, _tabMarkText) + _padR + 2;

  @override
  Widget build(BuildContext context) {
    final accepted = text == 'Accepted';
    final tone = accepted ? DashUi.emeraldText : DashUi.ink;
    return Container(
      padding: const EdgeInsets.fromLTRB(_padL, 1, _padR, 1),
      decoration: BoxDecoration(
        color: accepted ? Color.lerp(Colors.white, DashUi.emerald, 0.08) : Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accepted ? DashUi.emerald.withValues(alpha: 0.3) : DashUi.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(accepted ? Icons.verified_rounded : Icons.check_circle_rounded, size: _icon, color: tone),
          const SizedBox(width: _iconGap),
          Text(text, maxLines: 1, style: _tabMarkText.copyWith(color: tone)),
        ],
      ),
    );
  }
}

/// A tab's outline: a box with rounded top corners and no foot, filled. The open tab's foot covers the rule under the
/// tabs, which is what joins it to the table; its [cap] (0 to 1, eased in as it opens) is the ink line along its top.
class _TabPainter extends CustomPainter {
  final Color fill;
  final Color edge;
  final double cap;
  const _TabPainter({required this.fill, required this.edge, this.cap = 0});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    const r = _tabRadius, i = 0.5;
    final shape = Path()
      ..moveTo(0, h)
      ..lineTo(0, r)
      ..arcToPoint(const Offset(r, 0), radius: const Radius.circular(r))
      ..lineTo(w - r, 0)
      ..arcToPoint(Offset(w, r), radius: const Radius.circular(r))
      ..lineTo(w, h)
      ..close();
    canvas.drawPath(shape, Paint()..color = fill);
    final outline = Path()
      ..moveTo(i, h)
      ..lineTo(i, r)
      ..arcToPoint(const Offset(r, i), radius: const Radius.circular(r - i))
      ..lineTo(w - r, i)
      ..arcToPoint(Offset(w - i, r), radius: const Radius.circular(r - i))
      ..lineTo(w - i, h);
    canvas.drawPath(
      outline,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = edge,
    );
    if (cap > 0) {
      // Clipped to the tab's shape, so the cap follows the rounded corners and thins out into them.
      canvas
        ..save()
        ..clipPath(shape)
        ..drawRect(Rect.fromLTWH(0, 0, w, _tabCapH), Paint()..color = DashUi.ink.withValues(alpha: cap))
        ..restore();
    }
  }

  @override
  bool shouldRepaint(_TabPainter old) => old.fill != fill || old.edge != edge || old.cap != cap;
}

/// A tab's surface: white and standing on the rule while [open], the faint fill a little lower behind the rule
/// otherwise. Changing between the two eases (still with reduce motion).
class _TabSurface extends StatelessWidget {
  final bool open;
  final bool hover;
  final Widget child;
  const _TabSurface({required this.open, required this.hover, required this.child});

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    // The others stand [_tabRise] lower, and stop at the rule rather than covering it; the open one's text is padded
    // down by as much, so every tab's text sits on one line.
    return TweenAnimationBuilder<double>(
      tween: Tween(end: open ? 1 : 0),
      duration: still ? Duration.zero : const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      builder: (context, v, child) => Padding(
        padding: EdgeInsets.only(top: _tabRise * (1 - v), bottom: 1 - v),
        child: CustomPaint(
          painter: _TabPainter(
            fill: Color.lerp(hover ? _tabHover : _tabFill, Colors.white, v)!,
            edge: Color.lerp(hover ? _tabHoverEdge : _tabRule, _tabRule, v)!,
            cap: v,
          ),
          child: Padding(padding: EdgeInsets.only(top: _tabRise * v), child: child),
        ),
      ),
      child: child,
    );
  }
}

class _OptionTab extends StatelessWidget {
  final _TabFacts tab;
  final bool selected;
  final bool dirty;
  final bool showMargin;
  final VoidCallback onTap;
  const _OptionTab({super.key, required this.tab, required this.selected, required this.dirty, required this.showMargin, required this.onTap});

  static const padX = 14.0, minW = 112.0, maxW = 248.0;

  static String _marginText(double m) => '${m.toStringAsFixed(1)}% margin';

  /// The width the tab needs for its name and marks and for its figures, within [minW] and [maxW] (a longer name is cut
  /// short; the tab's screen-reader label has it whole).
  static double widthOf(BuildContext context, _TabFacts f, {required bool showMargin, required bool dirty}) {
    final mark = f.mark;
    var top = _textWidth(context, f.name, _tabName);
    if (mark != null) top += 6 + _TabMark.widthOf(context, mark);
    if (f.recommended) top += 5 + 15;
    if (dirty) top += 6 + 7;
    final bottom = _figuresWidth(context, f, showMargin: showMargin);
    return ((top > bottom ? top : bottom) + 2 * padX + 2).clamp(minW, maxW).toDouble();
  }

  static double _figuresWidth(BuildContext context, _TabFacts f, {required bool showMargin}) {
    final margin = showMargin ? f.marginPct : null;
    var w = _textWidth(context, centsMoney(f.totalCents), _tabTotal);
    if (margin != null) w += _textWidth(context, '  ·  ${_marginText(margin)}', _tabMeta);
    return w;
  }

  /// The least a tab may be cut to so one more fits beside it: its figures and its marks stay whole, only a long name is
  /// shortened. (Its marks used to be left out: once a tab's figures got short, the estimate's own tab with no margin
  /// to show while a cost is unknown, it could be cut narrower than its "Current" mark, which overflowed.)
  static double floorOf(BuildContext context, _TabFacts f, {required bool showMargin, bool dirty = false}) {
    var marks = 0.0;
    if (f.mark case final mark?) marks += 6 + _TabMark.widthOf(context, mark);
    if (f.recommended) marks += 5 + 15;
    if (dirty) marks += 6 + 7;
    final figures = _figuresWidth(context, f, showMargin: showMargin);
    return ((figures > marks ? figures : marks) + 2 * padX + 2).clamp(minW, maxW).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final o = tab;
    final margin = showMargin ? o.marginPct : null;
    return DashPressable(
      onTap: onTap,
      label:
          '${o.name}, ${centsMoney(o.totalCents)}${o.current ? ', the current option' : ''}${o.accepted ? ', accepted' : ''}${o.recommended ? ', recommended' : ''}${dirty ? ', changed in the preview' : ''}',
      selected: selected,
      radius: const BorderRadius.vertical(top: Radius.circular(_tabRadius)),
      builder: (hover) {
        // The open tab in ink; the others slate, ink under the pointer. One weight for both, so a tab's width never
        // changes as it opens.
        final tone = selected || hover ? DashUi.ink : DashUi.slate;
        return _TabSurface(
          open: selected,
          hover: hover,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(padX, 9, padX, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: MediaQuery.textScalerOf(context).scale(13) * 1.3 + 2,
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(o.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: _tabName.copyWith(color: tone)),
                      ),
                      if (o.mark case final mark?) Padding(padding: const EdgeInsets.only(left: 6), child: _TabMark(mark)),
                      if (o.recommended)
                        const Padding(
                          padding: EdgeInsets.only(left: 5),
                          child: Icon(Icons.star_rounded, size: 15, color: DashUi.amber, semanticLabel: 'Recommended'),
                        ),
                      if (dirty)
                        const Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: SizedBox(
                            width: 7,
                            height: 7,
                            child: DecoratedBox(
                              decoration: BoxDecoration(color: DashUi.amber, shape: BoxShape.circle),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 1),
                Row(
                  children: [
                    Text(centsMoney(o.totalCents), maxLines: 1, style: _tabTotal.copyWith(color: tone)),
                    if (margin != null)
                      Flexible(
                        child: Text(
                          '  ·  ${_marginText(margin)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _tabMeta.copyWith(
                            color: margin < 0 ? DashUi.redText : tone,
                            fontWeight: margin < 0 ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The options that don't fit beside the others, in a tab at the end: "+3 more", opening a menu of them.
class _MoreTab extends StatelessWidget {
  final _JobDetailScreenState state;
  final List<(String, _TabFacts)> hidden;
  const _MoreTab({required this.state, required this.hidden});

  static String _label(int n) => '+$n more';

  static double widthOf(BuildContext context, int n) => _textWidth(context, _label(n), _tabName) + 4 + 16 + 2 * 12 + 2;

  @override
  Widget build(BuildContext context) => PsMenuButton<String>(
    entries: () => [
      for (final (id, f) in hidden)
        PsMenuItem(id, f.name, icon: f.recommended ? Icons.star_rounded : (f.mark != null ? Icons.check_circle_rounded : null), trailing: centsMoney(f.totalCents)),
    ],
    onSelected: (id) => state._set(() => state._option = id),
    width: 320,
    align: PsMenuAlign.end,
    label: 'More options',
    builder: (context, open, show) => DashPressable(
      key: const ValueKey('option-tab-more'),
      onTap: show,
      label: '${hidden.length} more option${hidden.length == 1 ? '' : 's'}',
      radius: const BorderRadius.vertical(top: Radius.circular(_tabRadius)),
      builder: (hover) => _TabSurface(
        open: false,
        hover: hover || open,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_label(hidden.length), maxLines: 1, style: _tabName.copyWith(color: hover || open ? DashUi.ink : DashUi.slate)),
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: open ? 0.5 : 0,
                duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : (open ? kPsMenuOpen : kPsMenuClose),
                curve: Curves.easeOutCubic,
                child: const Icon(Icons.expand_more_rounded, size: 16, color: DashUi.slate),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The tab strip: the tabs standing on the table's top rule, and at its right end what can be done with the option on
/// show. On a narrow block those actions go into the option's menu.
class _OptionTabs extends StatelessWidget {
  final _JobDetailScreenState state;
  final String selected;
  const _OptionTabs({required this.state, required this.selected});

  /// Between tabs; between the estimate's own tab and the alternatives (with a short hairline in it).
  static const _gap = 4.0, _split = 17.0;

  @override
  Widget build(BuildContext context) {
    final s = state;
    // An option changed in the preview shows its draft's total and margin, as its table does (they used to stay at the
    // saved figures beside a changed total).
    _TabFacts live(String id, _TabFacts f) => switch (s._liveFigures[id]) {
      final figures? when s._dirty.contains(id) => f.withFigures(figures),
      _ => f,
    };
    final entries = <(String, _TabFacts)>[
      ('sf', live('sf', s._sfTab)),
      for (final o in s._lines!.options) (o.id, live(o.id, _TabFacts.of(o))),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final compact = c.maxWidth < 640;
        final actions = _actions(compact: compact, roomy: c.maxWidth >= 1100);
        return Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SizedBox(height: 1, child: ColoredBox(color: _tabRule)),
            ),
            Padding(
              // The first tab's left edge on the table's own edge, where the eye column starts.
              padding: const EdgeInsets.fromLTRB(20, 12, 14, 0),
              child: Row(
                children: [
                  Expanded(child: LayoutBuilder(builder: (context, t) => _tabs(context, entries, t.maxWidth))),
                  if (actions.isNotEmpty) ...[
                    const SizedBox(width: 12),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Row(mainAxisSize: MainAxisSize.min, children: actions),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _tabs(BuildContext context, List<(String, _TabFacts)> entries, double room) {
    final s = state;
    final showMargin = s._canSeeCost;
    final w = [for (final (id, f) in entries) _OptionTab.widthOf(context, f, showMargin: showMargin, dirty: s._dirty.contains(id))];
    final n = entries.length;
    final sel = entries.indexWhere((e) => e.$1 == selected).clamp(0, n - 1);
    double need(List<int> ids, {int more = 0}) {
      var total = 0.0;
      for (var k = 0; k < ids.length; k++) {
        if (k > 0) total += ids[k - 1] == 0 ? _split : _gap;
        total += w[ids[k]];
      }
      return more > 0 ? total + _gap + _MoreTab.widthOf(context, more) : total;
    }

    final all = [for (var i = 0; i < n; i++) i];
    var shown = all;
    if (need(all) > room + 0.5) {
      // As many as fit in order beside a "+N more" that says how many are left; then the open one, in place of the
      // last few if it isn't among them.
      shown = <int>[];
      for (final i in all) {
        if (need([...shown, i], more: n - shown.length - 1) > room) break;
        shown.add(i);
      }
      if (!shown.contains(sel)) {
        while (shown.isNotEmpty && need([...shown, sel], more: n - shown.length - 1) > room) {
          shown.removeLast();
        }
        shown.add(sel);
      }
      // Room left over, but not quite enough for the next one: long names give up a little width (their figures stay
      // whole, the open one is never cut) so it fits too, rather than leaving a gap before Accept (final polish
      // 2026-11-13: up to ~190 px stood empty at 1280). Widths depend only on the room and the open option, so
      // nothing moves on hover.
      while (shown.length < n) {
        final trial = [...shown, all.firstWhere((i) => !shown.contains(i))]..sort();
        final short = need(trial, more: n - trial.length) - room;
        if (short > 0) {
          final floor = {
            for (final i in shown)
              if (i != sel) i: _OptionTab.floorOf(context, entries[i].$2, showMargin: showMargin, dirty: s._dirty.contains(entries[i].$1)),
          };
          double cut(double level) => floor.entries.fold(0.0, (a, e) => a + (w[e.key] - math.max(level, e.value)).clamp(0, double.infinity));
          if (cut(0) < short) break;
          // The widest come down first, to one level: the lowest it needs (found by halving).
          var lo = 0.0, hi = _OptionTab.maxW;
          for (var k = 0; k < 24; k++) {
            final mid = (lo + hi) / 2;
            if (cut(mid) >= short) {
              lo = mid;
            } else {
              hi = mid;
            }
          }
          for (final e in floor.entries) {
            w[e.key] = math.min(w[e.key], math.max(lo, e.value));
          }
        }
        shown = trial;
      }
    }
    final hidden = [for (final i in all) if (!shown.contains(i)) entries[i]];
    // Too narrow even for the open tab and "+N more": the open tab gives up width (its name is cut short).
    final over = need(shown, more: hidden.length) - room;
    if (over > 0) w[sel] = (w[sel] - over).clamp(64.0, w[sel]).toDouble();
    final kids = <Widget>[];
    for (var k = 0; k < shown.length; k++) {
      final i = shown[k];
      if (k > 0) {
        kids.add(
          shown[k - 1] == 0
              ? SizedBox(
                  width: _split,
                  child: Center(
                    child: SizedBox(width: 1, height: 22, child: ColoredBox(color: _tabRule)),
                  ),
                )
              : const SizedBox(width: _gap),
        );
      }
      final (id, f) = entries[i];
      kids.add(
        SizedBox(
          width: w[i],
          child: _OptionTab(
            key: ValueKey('option-tab-$id'),
            tab: f,
            selected: i == sel,
            dirty: s._dirty.contains(id),
            showMargin: showMargin,
            onTap: () => s._set(() => s._option = id),
          ),
        ),
      );
    }
    if (hidden.isNotEmpty) kids.addAll([const SizedBox(width: _gap), _MoreTab(state: s, hidden: hidden)]);
    return Align(
      alignment: Alignment.bottomLeft,
      child: IntrinsicHeight(
        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: kids),
      ),
    );
  }

  /// What can be done with the option on show, at the strip's right end: Accept; once accepted, Undo acceptance and
  /// Send to job; once sent, Open job; and its menu for the rest. A narrow strip keeps only the menu, with those in it.
  /// An accepted option says when and by whom beside them when there is room; the estimate's own option, once an
  /// alternative is accepted, says which.
  List<Widget> _actions({required bool compact, required bool roomy}) {
    final s = state;
    final o = s._lines!.byId(selected);
    if (o == null) {
      final accepted = s._lines!.accepted;
      return [if (accepted != null && !compact) _StripNote('${accepted.name} was accepted instead', key: const ValueKey('option-note'))];
    }
    final canEdit = s._canEditLines;
    final busy = s._busy != null;
    final menu = canEdit ? _OptionMenu(state: s, option: o, canAddOption: s._lines!.options.length < 10, withActions: compact) : null;
    if (compact) return [?menu];
    final cantAccept = s._cantAccept(o);
    return [
      if (o.accepted && roomy) _StripNote(_acceptedNote(o), tone: DashUi.emeraldText, key: const ValueKey('option-note')),
      if (o.converted)
        TextButton.icon(
          onPressed: () => s._openRecord(o.convertedJobId!, estimate: false),
          icon: const Icon(Icons.open_in_new_rounded, size: 16),
          label: Text('Open job #${o.convertedJobId}', style: const TextStyle(fontWeight: FontWeight.w600)),
          style: TextButton.styleFrom(foregroundColor: _JobDetailScreenState._link, minimumSize: const Size(0, 34)),
        )
      else if (o.accepted && canEdit) ...[
        TextButton(
          onPressed: busy ? null : () => s._unaccept(o),
          style: TextButton.styleFrom(foregroundColor: DashUi.ink, minimumSize: const Size(0, 34)),
          child: const Text('Undo acceptance', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: 6),
        FilledButton.icon(
          onPressed: busy ? null : () => s._convert(o),
          icon: s._busy == 'convert'
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.send_rounded, size: 16),
          label: const Text('Send to job'),
          style: FilledButton.styleFrom(
            backgroundColor: DashUi.ink,
            minimumSize: const Size(0, 34),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ] else if (canEdit && s._lines!.accepted == null)
        Tooltip(
          message: cantAccept ?? 'The customer chose this one: lock its price and get it ready to send to the job',
          child: OutlinedButton.icon(
            // Still clickable when it can't accept yet: with no hover text on the block, the click says why (_accept).
            onPressed: busy ? null : () => s._accept(o),
            icon: s._busy == 'accept'
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.verified_outlined, size: 17),
            label: const Text('Accept'),
            style: OutlinedButton.styleFrom(
              foregroundColor: DashUi.emeraldText,
              side: BorderSide(color: cantAccept == null ? DashUi.emerald.withValues(alpha: 0.45) : DashUi.line),
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
      if (menu != null) ...[const SizedBox(width: 6), menu],
    ];
  }
}

/// "Accepted Nov 2 by Dana Whitfield": when and by whom an option was accepted, and that its price is locked.
String _acceptedNote(LineOption o) {
  final when = o.acceptedAt == null ? '' : ' ${DateFormat('MMM d').format(o.acceptedAt!.toLocal())}';
  final by = o.acceptedBy.isEmpty ? '' : ' by ${o.acceptedBy}';
  return 'Accepted$when$by · price locked';
}

/// Where an option stands, for the head of its menu: who accepted it, or where it came from and when it was saved.
String _optionAbout(LineOption o) {
  if (o.accepted) {
    final note = _acceptedNote(o);
    return o.converted ? '$note · sent to job #${o.convertedJobId}' : note;
  }
  final parts = [
    if (o.source == 'service_fusion') 'Started from Service Fusion\'s items',
    if (o.source == 'copy' && o.sourceOptionName != null) 'Copied from ${o.sourceOptionName}',
    if (o.updatedAt != null) 'saved ${DateFormat('MMM d').format(o.updatedAt!.toLocal())}${o.updatedBy.isEmpty ? '' : ' by ${o.updatedBy}'}',
  ].join(', ');
  return parts.isEmpty ? '' : parts[0].toUpperCase() + parts.substring(1);
}

/// A quiet line of text at the strip's right end (where an accepted option stands).
class _StripNote extends StatelessWidget {
  final String text;
  final Color tone;
  const _StripNote(this.text, {super.key, this.tone = DashUi.ink});

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 300),
    child: Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: tone),
      ),
    ),
  );
}

/// The table under the tabs: it fades in as one option replaces another, so the switch reads as the same table
/// changing, not a jump (still with reduce motion). Every option's editor stays alive underneath, so this never
/// rebuilds them.
class _SwitchFade extends StatefulWidget {
  final Object value;
  final Widget child;
  const _SwitchFade({required this.value, required this.child});

  @override
  State<_SwitchFade> createState() => _SwitchFadeState();
}

class _SwitchFadeState extends State<_SwitchFade> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 170), value: 1);

  @override
  void didUpdateWidget(_SwitchFade old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && !MediaQuery.disableAnimationsOf(context)) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    // The same widgets at every frame (only the opacity changes), so the editors under it keep their state.
    builder: (context, child) => Opacity(opacity: 0.35 + 0.65 * Curves.easeOutCubic.transform(_c.value), child: child),
    child: widget.child,
  );
}

/// "Option actions": where the option stands, then rename, recommend, duplicate, notes for the customer, delete; on a
/// narrow strip its next step too (Accept, Send to job...). What a locked (accepted) option can't have done to it isn't
/// offered.
class _OptionMenu extends StatelessWidget {
  final _JobDetailScreenState state;
  final LineOption option;
  final bool canAddOption;

  /// A narrow strip, with no room for the option's buttons beside its tabs: they are in here instead.
  final bool withActions;
  const _OptionMenu({required this.state, required this.option, required this.canAddOption, this.withActions = false});

  @override
  Widget build(BuildContext context) {
    final s = state;
    final o = option;
    final busy = s._busy != null;
    final dirty = s._dirty.contains(o.id);
    final actions = <String, VoidCallback>{
      'accept': () => s._accept(o),
      'unaccept': () => s._unaccept(o),
      'convert': () => s._convert(o),
      'open': () => s._openRecord(o.convertedJobId!, estimate: false),
      'rename': () => s._renameOption(o),
      'recommend': () => s._toggleRecommended(o),
      'duplicate': () => s._newOption('copy', copyOf: o.id),
      'notes': () => s._editOptionNotes(o),
      'delete': () => s._deleteOption(o),
    };
    return PsMenuButton<String>(
      entries: () {
        final about = _optionAbout(o);
        final steps = <PsMenuEntry<String>>[
          if (o.converted)
            PsMenuItem('open', 'Open job #${o.convertedJobId}', icon: Icons.open_in_new_rounded)
          else if (o.accepted) ...[
            PsMenuItem('convert', 'Send to job', icon: Icons.send_rounded, enabled: !busy),
            PsMenuItem('unaccept', 'Undo acceptance', icon: Icons.undo_rounded, enabled: !busy),
          ] else if (s._lines?.accepted == null)
            PsMenuItem('accept', 'Accept', icon: Icons.verified_outlined, enabled: !busy),
        ];
        return [
          if (about.isNotEmpty) PsMenuHeading(about),
          if (withActions && steps.isNotEmpty) ...[...steps, const PsMenuDivider()],
          if (!o.accepted) ...[
            PsMenuItem('rename', 'Rename', icon: Icons.drive_file_rename_outline_rounded, enabled: !busy),
            PsMenuItem(
              'recommend',
              o.isRecommended ? 'Remove the recommendation' : 'Mark as recommended',
              icon: o.isRecommended ? Icons.star_outline_rounded : Icons.star_rounded,
              enabled: !busy,
            ),
          ],
          PsMenuItem('duplicate', dirty ? 'Duplicate (as saved)' : 'Duplicate as a new option', icon: Icons.copy_all_rounded, enabled: !busy && canAddOption),
          if (!o.locked)
            PsMenuItem(
              'notes',
              o.notes.trim().isEmpty ? 'Add notes for the customer' : 'Edit notes for the customer',
              icon: Icons.description_outlined,
              enabled: !busy,
            ),
          if (!o.accepted && !o.converted) ...[
            const PsMenuDivider(),
            PsMenuItem('delete', 'Delete option', icon: Icons.delete_outline_rounded, danger: true, enabled: !busy),
          ],
        ];
      },
      onSelected: (v) => actions[v]?.call(),
      width: 300,
      align: PsMenuAlign.end,
      label: 'Option actions',
      // No hover text on the block (user 2026-11-13): the label is for screen readers, the key for tests.
      builder: (context, open, show) => Semantics(
        label: 'Option actions',
        button: true,
        expanded: open,
        child: IconButton(
          key: const ValueKey('option-actions'),
          tooltip: 'Option actions',
          onPressed: show,
          icon: const Icon(Icons.more_horiz_rounded, size: 20),
          style: IconButton.styleFrom(
            foregroundColor: DashUi.ink,
            hoverColor: DashUi.faint,
            backgroundColor: open ? DashUi.faint : null,
            minimumSize: const Size(34, 34),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
    );
  }
}

// "New option": with options to copy, a menu (blank, or a copy of the one on show); with none, a blank option at once.
class _NewOptionButton extends StatelessWidget {
  final _JobDetailScreenState state;
  final LineOption? current;
  const _NewOptionButton({required this.state, required this.current});

  @override
  Widget build(BuildContext context) {
    final s = state;
    final count = s._lines?.options.length ?? 0;
    final busy = s._busy != null;
    final full = count >= 10;
    final cur = current;
    final tip = full ? 'An estimate can have at most 10 options' : (cur == null ? 'Start a blank option' : 'A blank option, or a copy of ${cur.name}');
    Widget button(VoidCallback? onTap, {bool open = false}) => Tooltip(
      message: tip,
      child: TextButton.icon(
        onPressed: busy || full ? null : onTap,
        icon: s._busy == 'new'
            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.add_rounded, size: 18),
        // Weight on the label, not the button's textStyle, which would replace the app font.
        label: const Text('New option', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        // Lit while its menu is open, so the menu reads as coming from it.
        style: open ? _addStyle.copyWith(backgroundColor: WidgetStatePropertyAll(DashUi.blue.withValues(alpha: 0.08))) : _addStyle,
      ),
    );
    if (cur == null) return button(() => s._newOption('blank'));
    return PsMenuButton<String>(
      entries: () => [
        const PsMenuItem('blank', 'Blank option', icon: Icons.note_add_outlined),
        PsMenuItem('copy', s._dirty.contains(cur.id) ? 'Copy of ${cur.name} (as saved)' : 'Copy of ${cur.name}', icon: Icons.copy_all_rounded),
      ],
      onSelected: (v) => v == 'blank' ? s._newOption('blank') : s._newOption('copy', copyOf: cur.id),
      width: 280,
      align: PsMenuAlign.end,
      label: 'New option',
      builder: (context, open, show) => button(show, open: open),
    );
  }
}

/// New option, drawn like the page's other adds at the right of a heading (Add Task, Add Notes: _addButton).
final ButtonStyle _addStyle = TextButton.styleFrom(
  foregroundColor: DashUi.blue,
  visualDensity: VisualDensity.compact,
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
);

/// A small text link with an icon, for the block's title row ("From estimate #123").
class _QuietLink extends StatelessWidget {
  final IconData icon;
  final String text;
  final String tip;
  final VoidCallback onTap;
  const _QuietLink({required this.icon, required this.text, required this.tip, required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tip,
    child: TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
      style: TextButton.styleFrom(foregroundColor: DashUi.ink, minimumSize: const Size(0, 34), padding: const EdgeInsets.symmetric(horizontal: 10)),
    ),
  );
}

// ---- beside the totals ---------------------------------------------------------------------------------------------

/// Beside an option's summary: its notes for the customer (what is included, lead times, warranty). They read as the
/// customer will read them, as a passage beside a hairline rather than another box, under a small heading.
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Icon(Icons.description_outlined, size: 16, color: DashUi.ink),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Notes for the customer',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink),
              ),
            ),
            if (canEdit)
              TextButton.icon(
                onPressed: () => state._editOptionNotes(o),
                icon: Icon(text.isEmpty ? Icons.add_rounded : Icons.edit_rounded, size: text.isEmpty ? 18 : 16),
                label: Text(text.isEmpty ? 'Add notes' : 'Edit notes', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                style: _addStyle,
              )
            else
              const SizedBox(height: 32),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          margin: const EdgeInsets.only(left: 7),
          padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: DashUi.line, width: 2)),
          ),
          child: text.isEmpty
              ? const Text(
                  'None yet. Use them for what is included, lead times or warranty terms.',
                  style: TextStyle(fontSize: 13, color: DashUi.ink, height: 1.45),
                )
              : SelectableText(text, style: const TextStyle(fontSize: 13.5, color: DashUi.ink, height: 1.55)),
        ),
      ],
    );
  }
}

/// While the lines load: placeholder rows shaped like the table (an item with its code under it, then qty, rate and
/// amount at the right) and the total under them, pulsing (still with reduce motion).
class _LinesSkeleton extends StatelessWidget {
  const _LinesSkeleton();

  static Widget _bar(double w, double h) => Container(
    width: w,
    height: h,
    decoration: BoxDecoration(color: DashUi.line, borderRadius: BorderRadius.circular(6)),
  );

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading products and services',
    child: SkeletonPulse(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final w in const [0.46, 0.34, 0.4]) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _bar(16, 14),
                  const SizedBox(width: 20),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, c) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [_bar(c.maxWidth * w + 80, 14), const SizedBox(height: 8), _bar(84, 10)],
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  _bar(24, 14),
                  const SizedBox(width: 48),
                  _bar(72, 14),
                  const SizedBox(width: 40),
                  _bar(80, 14),
                ],
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Divider(height: 1, color: DashUi.faint),
              ),
            ],
            Align(alignment: Alignment.centerRight, child: _bar(220, 24)),
          ],
        ),
      ),
    ),
  );
}

/// A note above the lines with its actions (the line items couldn't be loaded, and a Retry), tinted when it matters.
class _ItemsBanner extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color tone;
  final List<Widget> actions;
  const _ItemsBanner({required this.icon, required this.text, this.tone = DashUi.slate, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    final (bg, edge) = switch (tone) {
      DashUi.emeraldText => (DashUi.emerald.withValues(alpha: 0.07), DashUi.emerald.withValues(alpha: 0.35)),
      DashUi.amberText => (AppTheme.notesBg, AppTheme.notesStroke),
      _ => (_tileTint, DashUi.line),
    };
    final message = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 17, color: tone),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: tone, height: 1.4),
          ),
        ),
      ],
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: edge),
      ),
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

/// Across the block under its title while editing: what this is, a preview that is never saved, and its one way out.
/// There is no Save: nothing here can be kept yet, so offering one only to say so was confusing (user 2026-11-13).
/// Exit preview puts back what was there. Ctrl+S, pressed from habit, says here that nothing was saved.
class _EditPreviewBar extends StatelessWidget {
  final String what; // job | estimate
  final bool changed;
  final bool saveAsked; // Ctrl+S was pressed
  final VoidCallback onExit;
  const _EditPreviewBar({required this.what, required this.changed, required this.saveAsked, required this.onExit});

  static const _ink = AppTheme.notesText; // the strip's body text: dark amber on the light amber
  static const _edge = AppTheme.notesStroke;

  @override
  Widget build(BuildContext context) {
    final title = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.visibility_outlined, size: 17, color: DashUi.amberText),
        const SizedBox(width: 8),
        const Text(
          'Editing preview only',
          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.amberText),
        ),
        if (changed) ...[
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: _edge),
            ),
            child: const Text(
              'Changed, not saved',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.amberText),
            ),
          ),
        ],
      ],
    );
    final body = Text(
      'Changes made here will NOT overwrite or update Service Fusion, and they can\'t be saved yet. The original $what stays exactly as it is.',
      style: const TextStyle(fontSize: 12.5, color: _ink, height: 1.4),
    );
    final exit = Tooltip(
      message: 'Close the preview and put back the original products and services',
      child: FilledButton.icon(
        onPressed: onExit,
        icon: const Icon(Icons.close_rounded, size: 16),
        label: const Text('Exit preview', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        style: FilledButton.styleFrom(
          backgroundColor: DashUi.ink,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
    final asked = saveAsked
        ? Semantics(
            liveRegion: true,
            child: const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Icon(Icons.info_outline_rounded, size: 15, color: DashUi.amberText),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Not saved: saving isn\'t available yet. Nothing was sent to Service Fusion or to our database. '
                      'Your changes stay on this screen until you exit the preview or leave the page.',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: _ink, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          )
        : null;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 9, 14, 9),
      decoration: const BoxDecoration(
        color: AppTheme.notesBg,
        border: Border(bottom: BorderSide(color: _edge)),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          if (c.maxWidth >= 980) {
            // One line: what it is, what it means, the way out.
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    title,
                    const SizedBox(width: 16),
                    Expanded(child: body),
                    const SizedBox(width: 16),
                    exit,
                  ],
                ),
                ?asked,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: title),
                    ),
                  ),
                  const SizedBox(width: 12),
                  exit,
                ],
              ),
              const SizedBox(height: 4),
              Padding(padding: const EdgeInsets.only(left: 25), child: body),
              ?asked,
            ],
          );
        },
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
            'The job\'s products and services become this option\'s ${o.items.length} line${o.items.length == 1 ? '' : 's'} (${centsMoney(t.totalCents)}). '
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
