import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'config/access.dart';
import 'config/auth_session.dart';
import 'services/tax_settings_api.dart';
import 'utils/charge_presets.dart';
import 'utils/line_item_math.dart';
import 'utils/sales_tax_catalog.dart';
import 'widgets/app_dialog.dart';
import 'widgets/app_ribbon.dart' show RibbonRefreshButton;
import 'widgets/dashboard_data.dart' show DashClock;
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';
import 'widgets/leave_guard.dart';
import 'widgets/line_table_style.dart';

// Inventory > Tax, Discounts & Fees (2026-11-20, kept simple for now at the user's request): what the Products &
// Services panel ("Tax, discounts & fees" under a job's or estimate's lines) offers.
//
//   Discounts / Fees     the presets: name, % or $, a starting amount (or none), offered or not; add and remove
//   Out-of-state tax     its starting name and rate (or none: typed each time, states' rates differ)
//   Arkansas sales tax   where the catalog's rates come from and when they were checked; rate changes typed in ahead of
//                        the next catalog update (each from its day); a look-up of any place's rate
//
// Saved to our own database (src/taxSettings.js); never to Service Fusion. A record that already has a tax, discount or
// fee keeps what it was given: these settings only change what the panel offers next.

class TaxSettingsScreen extends StatefulWidget {
  const TaxSettingsScreen({super.key});

  @override
  State<TaxSettingsScreen> createState() => _TaxSettingsScreenState();
}

class _TaxSettingsScreenState extends State<TaxSettingsScreen> {
  TaxSettings? _saved; // what the server has (the built-in list while nothing was saved)
  TaxSettings? _draft;
  bool _loading = true;
  bool _saving = false;
  String? _error; // the load failed
  bool _notOnServer = false; // the server is older than this screen: shown, not saved
  String? _saveError;
  late final VoidCallback _unguard;
  final _lookup = TextEditingController();
  int _nextId = 0;

  bool get _canEdit => AuthSession.instance.can('tax_settings', AccessAction.update) && !_notOnServer;
  bool get _dirty => _saved != null && _draft != null && !_same(_saved!, _draft!);
  String get _today => isoDay(DashClock.now());

  @override
  void initState() {
    super.initState();
    _unguard = LeaveGuard.register(canLeave: _confirmLeave, holdsWork: () => mounted && _dirty);
    _lookup.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _unguard();
    _lookup.dispose();
    super.dispose();
  }

  Future<bool> _confirmLeave() async {
    if (!mounted || !_dirty) return true;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        title: 'Leave without saving?',
        icon: Icons.edit_note_rounded,
        body: const Text('Your changes to the discounts, fees and rates aren\'t saved yet.', style: TextStyle(fontSize: 14, color: DashUi.slate, height: 1.45)),
        actions: [AppButton.ghost('Keep editing', () => Navigator.pop(ctx, false)), AppButton.ink('Discard and leave', () => Navigator.pop(ctx, true))],
      ),
    );
    return go == true;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await TaxSettingsApi.load();
      TaxSettingsStore.instance.set(s);
      if (!mounted) return;
      setState(() {
        _saved = s;
        _draft = s;
        _notOnServer = false;
        _loading = false;
      });
    } on TaxSettingsException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (e.notOnServer) {
          // An older server: show what the panel offers (the built-in list), read-only.
          _notOnServer = true;
          _saved = _draft = TaxSettingsStore.instance.value;
        } else {
          _error = e.message;
        }
      });
    }
  }

  Future<void> _save() async {
    final d = _draft;
    if (d == null || !_dirty || _saving) return;
    final problem = _problem(d);
    if (problem != null) {
      setState(() => _saveError = problem);
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final saved = await TaxSettingsApi.save(d);
      TaxSettingsStore.instance.set(saved);
      if (!mounted) return;
      setState(() {
        _saved = saved;
        _draft = saved;
        _saving = false;
      });
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Saved. The Tax, discounts & fees panel offers these from now on.')));
    } on TaxSettingsException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = e.isConflict ? '${e.message} Your changes are still here; Refresh loads theirs (and drops yours).' : e.message;
      });
    }
  }

  void _discard() => setState(() {
    _draft = _saved;
    _saveError = null;
  });

  void _edit(TaxSettings Function(TaxSettings d) f) => setState(() {
    _draft = f(_draft!);
    _saveError = null;
  });

  static bool _same(TaxSettings a, TaxSettings b) {
    if (a.presets.length != b.presets.length || a.rateChanges.length != b.rateChanges.length) return false;
    for (var i = 0; i < a.presets.length; i++) {
      if (!a.presets[i].sameAs(b.presets[i])) return false;
    }
    for (var i = 0; i < a.rateChanges.length; i++) {
      final x = a.rateChanges[i], y = b.rateChanges[i];
      if (x.jurisdictionId != y.jurisdictionId || x.milli != y.milli || x.from != y.from || x.note != y.note) return false;
    }
    return a.outOfStateLabel == b.outOfStateLabel && a.outOfStateRate == b.outOfStateRate;
  }

  /// What is wrong with the draft, or null (the server checks the same).
  static String? _problem(TaxSettings d) {
    for (final p in d.presets) {
      if (p.name.trim().isEmpty) return 'Every ${p.fee ? 'fee' : 'discount'} needs a name.';
      final v = p.value;
      if (v != null && (v <= 0 || (p.mode == ChargeMode.percent ? v > 100 : v > kMaxLineRate))) {
        return '"${p.name}": ${p.mode == ChargeMode.percent ? 'a percentage above 0% and up to 100%' : 'an amount above \$0'}, or leave it empty.';
      }
    }
    if (d.outOfStateLabel.trim().isEmpty) return 'The out-of-state tax needs a name.';
    final r = d.outOfStateRate;
    if (r != null && (r <= 0 || r > 30)) return 'The out-of-state rate must be above 0% and up to 30%, or empty.';
    for (final c in d.rateChanges) {
      if (ArkansasTax.byId(c.jurisdictionId) == null) return 'A rate change needs an Arkansas place.';
      if (DateTime.tryParse(c.from) == null) return 'A rate change needs the day it starts.';
    }
    return null;
  }

  // ---- layout -----------------------------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageBanner(
          title: 'Tax, Discounts & Fees',
          icon: accessIcon('tax_settings'),
          actions: [
            if (_dirty && !_notOnServer) ...[
              TextButton(
                onPressed: _saving ? null : _discard,
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                child: const Text('Discard', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              PageBanner.button(icon: Icons.check_rounded, label: _saving ? 'Saving…' : 'Save', onPressed: _saving ? null : _save),
            ],
            RibbonRefreshButton(onPressed: _loading || _saving ? null : _load),
          ],
        ),
        Expanded(child: PageSheet(child: _body())),
      ],
    );
  }

  Widget _body() {
    if (_loading && _draft == null) {
      return Center(
        child: Semantics(
          label: 'Loading the tax, discount and fee settings',
          child: SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.5, color: DashUi.ink)),
        ),
      );
    }
    if (_error != null && _draft == null) {
      return FlatEmpty(
        icon: Icons.cloud_off_rounded,
        title: 'Couldn\'t load the settings',
        message: _error!,
        action: FilledButton.icon(onPressed: _load, icon: const Icon(Icons.refresh_rounded, size: 18), label: const Text('Try again')),
      );
    }
    final d = _draft!;
    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 48),
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_notOnServer)
                  const _Notice(
                    'Showing the built-in list. The server doesn\'t have these settings yet (its update isn\'t deployed), so nothing here can be saved. '
                    'The Tax, discounts & fees panel offers the built-in list meanwhile.',
                    tone: DashUi.amberText,
                  )
                else if (!AuthSession.instance.can('tax_settings', AccessAction.update))
                  const _Notice('You can look but not change these. Changing them needs the Tax, Discounts & Fees > Update switch on the Team screen.'),
                if (_saveError != null) _Notice(_saveError!, tone: DashUi.redText, icon: Icons.error_outline_rounded),
                if (d.updatedAt != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      'Last saved ${dayText(isoDay(d.updatedAt!.toLocal()))}${d.updatedBy == null ? '' : ' by ${d.updatedBy}'}',
                      style: const TextStyle(fontSize: 12.5, color: DashUi.slate),
                    ),
                  ),
                _presetSection(fee: false),
                const SizedBox(height: 32),
                _presetSection(fee: true),
                const SizedBox(height: 32),
                _outOfState(d),
                const SizedBox(height: 32),
                _arkansas(d),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- discounts and fees --------------------------------------------------------------------------------------------

  Widget _presetSection({required bool fee}) {
    final d = _draft!;
    final list = fee ? d.fees : d.discounts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(
          fee ? 'Fees' : 'Discounts',
          count: list.length,
          caption: fee
              ? 'Added on the items less discounts, before tax. Fees are never taxed.'
              : 'Taken off the total. A discount never lowers the sales tax: tax is worked out line by line.',
        ),
        const _Head(['NAME', 'KIND', 'STARTS AT', 'OFFERED', '']),
        for (final p in list)
          _PresetRow(
            key: ValueKey('preset-${p.id}'),
            preset: p,
            enabled: _canEdit,
            onChanged: (n) => _edit((d) => d.copyWith(presets: [for (final x in d.presets) x.id == p.id ? n : x])),
            onRemove: () => _edit((d) => d.copyWith(presets: [for (final x in d.presets) if (x.id != p.id) x])),
          ),
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text('No ${fee ? 'fees' : 'discounts'} yet. The panel still offers a custom one.', style: const TextStyle(fontSize: 13, color: DashUi.slate)),
          ),
        if (_canEdit)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextButton.icon(
                key: ValueKey(fee ? 'add-fee' : 'add-discount'),
                onPressed: () => _edit(
                  (d) => d.copyWith(
                    presets: [
                      ...d.presets,
                      ChargePreset(id: '${fee ? 'f' : 'd'}-${DateTime.now().millisecondsSinceEpoch}-${_nextId++}', fee: fee, name: '', mode: fee ? ChargeMode.amount : ChargeMode.percent),
                    ],
                  ),
                ),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(fee ? 'Add fee' : 'Add discount', style: const TextStyle(fontWeight: FontWeight.w700)),
                style: TextButton.styleFrom(foregroundColor: DashUi.ink),
              ),
            ),
          ),
      ],
    );
  }

  // ---- out of state ----------------------------------------------------------------------------------------------------

  Widget _outOfState(TaxSettings d) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _SectionTitle(
        'Out-of-state tax',
        caption: 'One tax for a sale outside Arkansas. Its rate is typed on each record (states differ); an Arkansas rate is never used.',
      ),
      Wrap(
        spacing: 16,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: [
          _Labelled(
            'Name it starts with',
            SizedBox(
              width: 360,
              child: _Box(
                key: const ValueKey('oos-label'),
                initial: d.outOfStateLabel,
                enabled: _canEdit,
                onChanged: (v) => _edit((d) => d.copyWith(outOfStateLabel: v.trim())),
              ),
            ),
          ),
          _Labelled(
            'Rate it starts with (optional)',
            SizedBox(
              width: 140,
              child: _Box(
                key: const ValueKey('oos-rate'),
                initial: d.outOfStateRate == null ? '' : SalesTax.rateText(d.outOfStateRate!),
                enabled: _canEdit,
                numeric: true,
                suffix: '%',
                hint: 'none',
                onChanged: (v) => _edit((d) => d.copyWith(outOfStateRate: v.trim().isEmpty ? null : (parsePercent(v) ?? -1))),
              ),
            ),
          ),
        ],
      ),
    ],
  );

  // ---- Arkansas --------------------------------------------------------------------------------------------------------

  Widget _arkansas(TaxSettings d) {
    final src = ArkansasTax.source;
    final counties = ArkansasTax.counties(_today).length, cities = ArkansasTax.cities(_today).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('Arkansas sales tax', caption: 'The state, every county and every city with a local sales and use tax, at the rates DFA publishes.'),
        _Facts([
          ('Source', '${src.publisher}, ${src.table}'),
          ('Quarters', '${src.firstQuarter} to ${src.lastQuarter} (rates and the days they took effect)'),
          ('Places', 'Arkansas state 6.5%, $counties counties and $cities cities with a tax today'),
          ('Last checked', dayText(src.verified)),
          ('Updating', 'Each quarter: download DFA\'s new table and run tool/tax/ar_tax_import.dart (docs/arkansas-sales-tax-catalog.md)'),
        ]),
        const SizedBox(height: 20),
        Text('RATE CHANGES ENTERED HERE  ${d.rateChanges.length}', style: LineTable.head),
        const SizedBox(height: 4),
        const Text(
          'A change DFA has announced that the catalog doesn\'t have yet. It holds from its day on, for new taxes picked in the panel. '
          'A record that already has a tax keeps its own rate.',
          style: TextStyle(fontSize: 12.5, color: DashUi.slate, height: 1.4),
        ),
        const SizedBox(height: 8),
        if (d.rateChanges.isNotEmpty) const _Head(['PLACE', 'NEW RATE', 'FROM', 'NOTE', '']),
        for (final (i, c) in d.rateChanges.indexed)
          _RateChangeRow(
            key: ValueKey('change-$i-${c.jurisdictionId}-${c.from}'),
            change: c,
            enabled: _canEdit,
            onChanged: (n) => _edit((d) => d.copyWith(rateChanges: [for (final (j, x) in d.rateChanges.indexed) j == i ? n : x])),
            onRemove: () => _edit((d) => d.copyWith(rateChanges: [for (final (j, x) in d.rateChanges.indexed) if (j != i) x])),
          ),
        if (_canEdit)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextButton.icon(
                key: const ValueKey('add-rate-change'),
                onPressed: () => _edit(
                  (d) => d.copyWith(rateChanges: [...d.rateChanges, TaxRateChange(jurisdictionId: '', milli: 0, from: _today)]),
                ),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Add a rate change', style: TextStyle(fontWeight: FontWeight.w700)),
                style: TextButton.styleFrom(foregroundColor: DashUi.ink),
              ),
            ),
          ),
        const SizedBox(height: 24),
        Text('LOOK UP A RATE', style: LineTable.head),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 420,
            child: _Box(key: const ValueKey('tax-lookup'), controller: _lookup, hint: 'A city or county', enabled: true, icon: Icons.search_rounded),
          ),
        ),
        const SizedBox(height: 8),
        _LookupResults(query: _lookup.text, day: _today),
      ],
    );
  }
}

// ---- parts ------------------------------------------------------------------------------------------------------------

class _Notice extends StatelessWidget {
  final String text;
  final Color tone;
  final IconData icon;
  const _Notice(this.text, {this.tone = DashUi.slate, this.icon = Icons.info_outline_rounded});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
      decoration: BoxDecoration(border: Border(left: BorderSide(color: tone, width: 3))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: tone),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: TextStyle(fontSize: 13, color: tone == DashUi.slate ? DashUi.ink : tone, height: 1.45))),
        ],
      ),
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final int? count;
  final String caption;
  const _SectionTitle(this.title, {this.count, required this.caption});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: title),
                if (count != null) TextSpan(text: '  $count', style: const TextStyle(color: DashUi.subtle, fontWeight: FontWeight.w600)),
              ],
            ),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: DashUi.ink, letterSpacing: -0.2),
          ),
        ),
        const SizedBox(height: 3),
        Text(caption, style: const TextStyle(fontSize: 13, color: DashUi.slate, height: 1.4)),
      ],
    ),
  );
}

/// The column widths shared by a section's headings and rows.
const _wide = [5, 3, 2, 1, 0];

class _Head extends StatelessWidget {
  final List<String> labels;
  const _Head(this.labels);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.only(bottom: 8, top: 4),
    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: DashUi.line))),
    child: Row(
      children: [
        for (var i = 0; i < labels.length; i++)
          if (_wide[i] == 0)
            const SizedBox(width: 40)
          else
            Expanded(flex: _wide[i], child: Padding(padding: const EdgeInsets.only(right: 12), child: Text(labels[i], style: LineTable.head))),
      ],
    ),
  );
}

/// A box in the line tables' look: 40 px, one hairline, ink while focused.
class _Box extends StatefulWidget {
  final String? initial;
  final TextEditingController? controller;
  final bool enabled;
  final bool numeric;
  final String? suffix;
  final String? prefix;
  final String? hint;
  final IconData? icon;
  final bool error;
  final ValueChanged<String>? onChanged;
  const _Box({super.key, this.initial, this.controller, required this.enabled, this.numeric = false, this.suffix, this.prefix, this.hint, this.icon, this.error = false, this.onChanged});

  @override
  State<_Box> createState() => _BoxState();
}

class _BoxState extends State<_Box> {
  late final TextEditingController _c = widget.controller ?? TextEditingController(text: widget.initial ?? '');

  @override
  void dispose() {
    if (widget.controller == null) _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    OutlineInputBorder b(Color c, double w) => OutlineInputBorder(borderRadius: BorderRadius.circular(LineTable.radius), borderSide: BorderSide(color: c, width: w));
    return SizedBox(
      height: 40,
      child: TextField(
        controller: _c,
        enabled: widget.enabled,
        onChanged: widget.onChanged,
        textAlign: widget.numeric ? TextAlign.right : TextAlign.left,
        keyboardType: widget.numeric ? const TextInputType.numberWithOptions(decimal: true) : null,
        inputFormatters: widget.numeric ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))] : null,
        style: const TextStyle(fontSize: 13.5, color: DashUi.ink, fontFeatures: [FontFeature.tabularFigures()]),
        cursorColor: DashUi.ink,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: widget.enabled ? Colors.white : DashUi.faint,
          hoverColor: Colors.white,
          visualDensity: VisualDensity.standard,
          hintText: widget.hint,
          hintStyle: LineTable.hint,
          prefixIcon: widget.icon == null ? null : Icon(widget.icon, size: 18, color: DashUi.slate),
          prefixText: widget.prefix,
          suffixText: widget.suffix,
          prefixStyle: LineTable.currency,
          suffixStyle: LineTable.currency,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          border: b(LineTable.edge, 1),
          enabledBorder: b(widget.error ? DashUi.red : LineTable.edge, widget.error ? 1.5 : 1),
          disabledBorder: b(DashUi.line, 1),
          focusedBorder: b(widget.error ? DashUi.red : DashUi.ink, 1.5),
        ),
      ),
    );
  }
}

class _Labelled extends StatelessWidget {
  final String label;
  final Widget child;
  const _Labelled(this.label, this.child);

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: DashUi.ink))),
      child,
    ],
  );
}

class _PresetRow extends StatelessWidget {
  final ChargePreset preset;
  final bool enabled;
  final ValueChanged<ChargePreset> onChanged;
  final VoidCallback onRemove;
  const _PresetRow({super.key, required this.preset, required this.enabled, required this.onChanged, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final p = preset;
    final v = p.value;
    final bad = v != null && (v <= 0 || (p.mode == ChargeMode.percent ? v > 100 : v > kMaxLineRate));
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: LineTable.rowRule))),
      child: Row(
        children: [
          Expanded(
            flex: _wide[0],
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: _Box(
                initial: p.name,
                enabled: enabled,
                hint: p.fee ? 'What the fee is for' : 'What the discount is for',
                error: p.name.trim().isEmpty,
                onChanged: (t) => onChanged(p.copyWith(name: t)),
              ),
            ),
          ),
          Expanded(
            flex: _wide[1],
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: AppSegmented<ChargeMode>(
                dense: true,
                value: p.mode,
                options: const [(ChargeMode.percent, '% of items'), (ChargeMode.amount, r'$ amount')],
                onChanged: (m) {
                  if (enabled && m != p.mode) onChanged(p.copyWith(mode: m, value: null));
                },
              ),
            ),
          ),
          Expanded(
            flex: _wide[2],
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: _Box(
                // A new box when the kind changes, so a percentage never shows as dollars.
                key: ValueKey('${p.id}-${p.mode.name}'),
                initial: v == null ? '' : (p.mode == ChargeMode.percent ? SalesTax.rateText(v) : v.toStringAsFixed(2)),
                enabled: enabled,
                numeric: true,
                hint: 'typed each time',
                prefix: p.mode == ChargeMode.amount ? r'$ ' : null,
                suffix: p.mode == ChargeMode.percent ? '%' : null,
                error: bad,
                onChanged: (t) {
                  final n = p.mode == ChargeMode.percent ? parsePercent(t) : parseMoney(t);
                  onChanged(p.copyWith(value: t.trim().isEmpty ? null : (n ?? -1)));
                },
              ),
            ),
          ),
          Expanded(
            flex: _wide[3],
            child: Align(
              alignment: Alignment.centerLeft,
              child: Switch(
                value: p.active,
                activeThumbColor: Colors.white,
                activeTrackColor: DashUi.ink,
                onChanged: enabled ? (a) => onChanged(p.copyWith(active: a)) : null,
              ),
            ),
          ),
          SizedBox(
            width: 40,
            child: enabled
                ? IconButton(
                    tooltip: 'Remove ${p.name.isEmpty ? 'this one' : p.name}',
                    onPressed: onRemove,
                    icon: const Icon(Icons.delete_outline_rounded, size: 19, color: DashUi.slate),
                  )
                : null,
          ),
        ],
      ),
    );
  }
}

class _RateChangeRow extends StatelessWidget {
  final TaxRateChange change;
  final bool enabled;
  final ValueChanged<TaxRateChange> onChanged;
  final VoidCallback onRemove;
  const _RateChangeRow({super.key, required this.change, required this.enabled, required this.onChanged, required this.onRemove});

  static String _label(TaxJurisdiction j) => switch (j.level) {
    TaxLevel.state => 'Arkansas (state)',
    TaxLevel.county => j.name,
    TaxLevel.city => '${j.name} (${[for (final c in j.counties) ?ArkansasTax.county(c)].map((c) => c.name.replaceFirst(' County', '')).join(' / ')})',
  };

  @override
  Widget build(BuildContext context) {
    final c = change;
    final place = ArkansasTax.byId(c.jurisdictionId);
    TaxRateChange next({String? id, int? milli, String? from, String? note}) =>
        TaxRateChange(jurisdictionId: id ?? c.jurisdictionId, milli: milli ?? c.milli, from: from ?? c.from, note: note ?? c.note);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: LineTable.rowRule))),
      child: Row(
        children: [
          Expanded(
            flex: _wide[0],
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Autocomplete<TaxJurisdiction>(
                initialValue: TextEditingValue(text: place == null ? '' : _label(place)),
                displayStringForOption: _label,
                optionsBuilder: (v) {
                  final q = v.text.trim().toLowerCase();
                  if (q.isEmpty) return const [];
                  return ArkansasTax.all.where((j) => _label(j).toLowerCase().contains(q)).take(12);
                },
                onSelected: (j) => onChanged(next(id: j.id)),
                fieldViewBuilder: (context, controller, focus, submit) => SizedBox(
                  height: 40,
                  child: TextField(
                    controller: controller,
                    focusNode: focus,
                    enabled: enabled,
                    style: const TextStyle(fontSize: 13.5, color: DashUi.ink),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'A city or county',
                      hintStyle: LineTable.hint,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(LineTable.radius),
                        borderSide: BorderSide(color: place == null ? DashUi.red : LineTable.edge, width: place == null ? 1.5 : 1),
                      ),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(LineTable.radius), borderSide: const BorderSide(color: DashUi.ink, width: 1.5)),
                      disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(LineTable.radius), borderSide: const BorderSide(color: DashUi.line)),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            flex: _wide[1],
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: _Box(
                initial: c.milli == 0 && place == null ? '' : SalesTax.rateText(c.milli / 1000),
                enabled: enabled,
                numeric: true,
                suffix: '%',
                hint: '0',
                onChanged: (t) => onChanged(next(milli: ((parsePercent(t) ?? 0) * 1000).round())),
              ),
            ),
          ),
          Expanded(
            flex: _wide[2],
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: _Box(
                initial: c.from,
                enabled: enabled,
                hint: 'YYYY-MM-DD',
                error: DateTime.tryParse(c.from) == null,
                onChanged: (t) => onChanged(next(from: t.trim())),
              ),
            ),
          ),
          Expanded(
            flex: _wide[3],
            child: _Box(initial: c.note, enabled: enabled, hint: 'Note', onChanged: (t) => onChanged(next(note: t))),
          ),
          SizedBox(
            width: 40,
            child: enabled
                ? IconButton(tooltip: 'Remove this rate change', onPressed: onRemove, icon: const Icon(Icons.delete_outline_rounded, size: 19, color: DashUi.slate))
                : null,
          ),
        ],
      ),
    );
  }
}

class _Facts extends StatelessWidget {
  final List<(String, String)> rows;
  const _Facts(this.rows);

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final (k, v) in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 130, child: Text(k, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.ink))),
              Expanded(child: Text(v, style: const TextStyle(fontSize: 13, color: DashUi.ink, height: 1.4))),
            ],
          ),
        ),
    ],
  );
}

/// Places matching [query] with their rate today, since when, and any change ahead.
class _LookupResults extends StatelessWidget {
  final String query;
  final String day;
  const _LookupResults({required this.query, required this.day});

  @override
  Widget build(BuildContext context) {
    final q = query.trim().toLowerCase();
    if (q.length < 2) return const SizedBox.shrink();
    final hits = ArkansasTax.all.where((j) => j.name.toLowerCase().contains(q)).take(30).toList();
    if (hits.isEmpty) {
      return Text('No Arkansas place with a local sales tax matches "$query".', style: const TextStyle(fontSize: 13, color: DashUi.slate));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final j in hits)
          () {
            final r = ArkansasTax.rateOn(j, day);
            final next = ArkansasTax.nextAfter(j, day);
            final counties = [for (final c in j.counties) ?ArkansasTax.county(c)];
            final totals = j.level == TaxLevel.city
                ? {for (final c in counties) TaxComposition(day: day, county: c, city: j).milli}
                : {if (j.level == TaxLevel.county) TaxComposition(day: day, county: j).milli else ArkansasTax.milliOn(j, day) ?? 0};
            final total = totals.isEmpty ? '' : (totals.length == 1 ? milliText(totals.single) : '${milliText(totals.reduce((a, b) => a < b ? a : b))}–${milliText(totals.reduce((a, b) => a > b ? a : b))}');
            return Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: LineTable.rowRule))),
              child: Row(
                children: [
                  Expanded(
                    flex: 4,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(j.level == TaxLevel.city ? '${j.name} (city)' : j.name, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.ink)),
                        Text(
                          [
                            if (j.level == TaxLevel.city) counties.map((c) => c.name).join(' / '),
                            if (j.code.isNotEmpty) 'DFA code ${j.code}',
                          ].join(' · '),
                          style: const TextStyle(fontSize: 12, color: DashUi.slate),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      r == null || r.milli == 0 ? 'No tax today' : '${milliText(r.milli)} own · since ${dayText(r.from)}${r.typed ? ' (entered)' : ''}',
                      style: const TextStyle(fontSize: 13, color: DashUi.ink, fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(total.isEmpty ? '' : '$total total', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.ink, fontFeatures: [FontFeature.tabularFigures()])),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      next == null ? '' : '${next.$1 == 0 ? 'Ends' : 'To ${milliText(next.$1)}'} on ${dayText(next.$2)}',
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: DashUi.amberText),
                    ),
                  ),
                ],
              ),
            );
          }(),
      ],
    );
  }
}
