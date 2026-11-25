import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/charge_presets.dart';
import '../utils/line_item_math.dart';
import '../utils/sales_tax_catalog.dart';
import 'catalog_search_field.dart';
import 'dashboard_kit.dart';
import 'line_table_style.dart';
import 'ps_menu.dart';

// The Tax, discounts & fees panel of the Products & Services block (redesign 2026-11-20). It opens from its button under
// the lines, grows out of it the way the block's menus do (ps_menu.dart), and is organised like the Add Line search's
// results: a search box, then sections under headings, each choice on a row with its figures at the right.
//
//   On this record      the record's tax lines, discounts and fees (a tick on each), opened to change or remove
//   State sales tax     Arkansas's own rate
//   County sales tax    every county with a tax, its own rate and what it comes to with the state's
//   City / local tax    every city with a tax, its county (or counties) and its own rate
//   Out-of-state tax    one tax with a rate typed in, never an Arkansas rate
//   Discounts / Fees    the presets from the Tax, Discounts & Fees screen, and a custom one
//
// A pick opens a short form in the same panel: a place's tax shows its parts (state, county, city) with their rates
// and the days they took effect, adding up to what it charges, and a city in two counties asks which; a discount or fee
// takes its name, % or $, and amount. Whatever is done there closes the panel and is handed back to the editor
// ([ChargesResult]), so every change lands in the table and the totals where it can be seen.
//
// USER RULE 2026-11-20: adding a tax taxes nothing. It becomes a choice in each line's Tax dropdown, and only a line set
// to it is taxed. Fees and discounts are never taxed. The forms say so where it matters.

/// A discount or fee on the record, as the panel lists it.
class ChargeEntry {
  final int uid;
  final LineDraft line;
  final int amountCents;
  const ChargeEntry(this.uid, this.line, this.amountCents);
}

/// What the panel shows of the editor's draft when it opens.
class ChargesSnapshot {
  final List<SalesTax> taxes;

  /// How many lines have each tax selected, by name ('' the set's own rate).
  final Map<String, int> taxedLines;

  /// The set's own tax rate (an estimate option, a job's set), or null; [ownRate] is only offered where [canOwnRate].
  final double? ownRate;
  final bool canOwnRate;
  final List<ChargeEntry> charges;

  /// The source's own discounts and charges that aren't lines of the table (Service Fusion figures it keeps only in
  /// its totals): label, cents, whether it is a discount. Shown for reference; they can't be changed here. Service
  /// Fusion's discounts and fees that are lines come in [charges] instead.
  final List<(String, int, bool)> recordCharges;
  final int itemsCents;
  final int discountCents;
  final String today;
  final TaxSettings settings;
  const ChargesSnapshot({
    required this.taxes,
    required this.taxedLines,
    required this.ownRate,
    required this.canOwnRate,
    required this.charges,
    this.recordCharges = const [],
    required this.itemsCents,
    required this.discountCents,
    required this.today,
    this.settings = TaxSettings.builtIn,
  });
}

/// What was done in the panel, for the editor to apply.
sealed class ChargesResult {
  const ChargesResult();
}

class AddTax extends ChargesResult {
  final SalesTax tax;
  const AddTax(this.tax);
}

class UpdateTax extends ChargesResult {
  final SalesTax was, now;
  const UpdateTax(this.was, this.now);
}

class RemoveTax extends ChargesResult {
  final SalesTax tax;
  const RemoveTax(this.tax);
}

/// The set's own rate set to [rate] (null: removed).
class SetOwnRate extends ChargesResult {
  final double? rate;
  const SetOwnRate(this.rate);
}

class AddCharge extends ChargesResult {
  final LineDraft line;
  const AddCharge(this.line);
}

class UpdateCharge extends ChargesResult {
  final int uid;
  final LineDraft line;
  const UpdateCharge(this.uid, this.line);
}

class RemoveCharge extends ChargesResult {
  final int uid;
  const RemoveCharge(this.uid);
}

/// The panel's width, and the rule for the set's own rate (the old inline field's: 0% to 30%).
const kChargesPanelWidth = 560.0;
const kTaxRateRule = 'Tax rate must be between 0% and 30%.';

/// The out-of-state rate's rule: above 0%, so it says so (audit item 72: it showed [kTaxRateRule] while refusing 0).
const kOutOfStateRateRule = 'Enter a rate above 0% and up to 30%.';

/// The record's own rate (an estimate option's or a job's own set of lines), in plain words (audit item 104: "this
/// set's own rate" was the code's word, not the office's).
const _kOwnRateTitle = 'Sales tax (the record\'s own rate)';

/// Opens the panel from the widget whose [context] is given (its button) and gives back what was done, or null.
Future<ChargesResult?> showChargesPanel({required BuildContext context, required ChargesSnapshot snapshot}) {
  final nav = Navigator.of(context);
  final overlay = nav.overlay!.context.findRenderObject()! as RenderBox;
  final box = context.findRenderObject()! as RenderBox;
  final anchor = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  return nav.push(
    _ChargesRoute(
      anchor: anchor,
      snapshot: snapshot,
      still: MediaQuery.disableAnimationsOf(context),
      themes: InheritedTheme.capture(from: context, to: nav.context),
    ),
  );
}

class _ChargesRoute extends PopupRoute<ChargesResult> {
  final Rect anchor;
  final ChargesSnapshot snapshot;
  final bool still;
  final CapturedThemes themes;
  _ChargesRoute({required this.anchor, required this.snapshot, required this.still, required this.themes});

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Close Tax, discounts and fees';

  @override
  Duration get transitionDuration => still ? Duration.zero : kPsPanelOpen;

  @override
  Duration get reverseTransitionDuration => still ? Duration.zero : kPsPanelClose;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) => themes.wrap(_ChargesPage(route: this));
}

// ---- what the panel lists ---------------------------------------------------------------------------------------------

enum _Filter { all, taxes, discounts, fees }

enum _Section { record, state, county, city, outOfState, discounts, fees }

String _sectionTitle(_Section s) => switch (s) {
  _Section.record => 'On this record',
  _Section.state => 'State sales tax',
  _Section.county => 'County sales tax',
  _Section.city => 'City / local sales tax',
  _Section.outOfState => 'Out-of-state tax',
  _Section.discounts => 'Discounts',
  _Section.fees => 'Fees',
};

/// One choice in the list: its title and quiet line, its one figure, whether it is already on the record, and what
/// picking it opens.
class _Choice {
  final String key;
  final String title;
  final String sub;
  final String trailing;
  final bool onRecord;
  final bool enabled;
  final _View Function()? open;
  final String search;
  const _Choice({
    required this.key,
    required this.title,
    required this.sub,
    required this.trailing,
    this.onRecord = false,
    this.enabled = true,
    this.open,
    String? search,
  }) : search = search ?? '';
}

class _Heading {
  final _Section section;
  final int count;

  /// What the figures at the right are: "Rate", "Total rate", "Amount", or "Rate / amount" over the record's taxes and
  /// charges together (audit item 94: "Amount" sat over tax rates).
  final String figures;
  const _Heading(this.section, this.count, this.figures);
}

/// The forms a pick opens.
sealed class _View {
  const _View();
}

class _Browse extends _View {
  const _Browse();
}

/// A place's Arkansas tax: [county] and [city] (a city's county is asked for when it is in two).
class _PlaceView extends _View {
  final TaxJurisdiction? county;
  final TaxJurisdiction? city;
  const _PlaceView({this.county, this.city});
}

class _RecordTaxView extends _View {
  final SalesTax tax;
  const _RecordTaxView(this.tax);
}

class _OutOfStateView extends _View {
  final SalesTax? existing;
  const _OutOfStateView([this.existing]);
}

class _OwnRateView extends _View {
  const _OwnRateView();
}

class _ChargeView extends _View {
  final bool fee;
  final ChargePreset? preset;
  final ChargeEntry? existing;
  const _ChargeView({required this.fee, this.preset, this.existing});
}

/// Heights fixed at the reader's text size, so the arrow keys can keep a choice in view without measuring.
double _headH(TextScaler s) => math.max(32, (s.scale(12) * 1.3).ceilToDouble() + 18);
double _rowH(TextScaler s) => math.max(50, (s.scale(13.5) * 1.3).ceilToDouble() + (s.scale(12) * 1.35).ceilToDouble() + 20);

const _gap = 4.0, _margin = 8.0;

class _ChargesPage extends StatefulWidget {
  final _ChargesRoute route;
  const _ChargesPage({required this.route});

  @override
  State<_ChargesPage> createState() => _ChargesPageState();
}

class _ChargesPageState extends State<_ChargesPage> {
  final _search = TextEditingController();
  // The search's own node takes the arrows, Enter and Esc first: in the browser the field's text handling stopped them
  // before they reached the panel (found in real Chrome 2026-11-20; the widget tests run as Android and didn't show it).
  late final _searchFocus = FocusNode(debugLabel: 'charges search', onKeyEvent: (node, e) => _keys(node, e));
  final _scroll = ScrollController();
  _Filter _filter = _Filter.all;
  _View _view = const _Browse();
  int? _hi; // the highlighted choice, an index into [_rows]
  bool _done = false;

  ChargesSnapshot get _s => widget.route.snapshot;
  String get _day => _s.today;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() => _hi = null));
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _panelFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _finish(ChargesResult? r) {
    if (_done) return;
    _done = true;
    Navigator.of(context).pop(r);
  }

  /// The panel's own focus: when a form with no field to type in opens, focus comes here, so Esc still goes back to
  /// the list (with focus nowhere in the panel, Esc reached the route and closed it).
  final _panelFocus = FocusNode(debugLabel: 'charges panel');

  void _go(_View v) {
    setState(() {
      _view = v;
      _hi = null;
    });
    // Two frames on, once the form's own field (if any) has taken focus: if nothing in the panel has it, the panel does.
    // (Checking the old focus's place in the tree right away was fooled by the list's search field as it went.)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_panelFocus.hasFocus) _panelFocus.requestFocus();
      });
      WidgetsBinding.instance.scheduleFrame();
    });
  }

  void _back() {
    _go(const _Browse());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  // ---- the list -------------------------------------------------------------------------------------------------------

  /// The record's tax by the name a catalog place would have, so a place already on it is ticked and not added twice.
  Set<String> get _taxNames => {for (final t in _s.taxes) t.name};

  List<Object> _rows() {
    final words = _search.text.trim().toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    bool hit(_Choice c) => words.every((w) => '${c.title} ${c.sub} ${c.search}'.toLowerCase().contains(w));
    bool shows(_Section s) => switch (_filter) {
      _Filter.all => true,
      _Filter.taxes => s == _Section.record || s == _Section.state || s == _Section.county || s == _Section.city || s == _Section.outOfState,
      _Filter.discounts => s == _Section.record || s == _Section.discounts,
      _Filter.fees => s == _Section.record || s == _Section.fees,
    };
    final out = <Object>[];
    void section(_Section s, List<_Choice> all) {
      if (!shows(s)) return;
      var list = all.where(hit).toList();
      if (s == _Section.record && _filter != _Filter.all) {
        list = list
            .where(
              (c) => switch (_filter) {
                _Filter.taxes => c.key.startsWith('rt:') || c.key == 'own',
                _Filter.discounts => c.key.startsWith('rd:') || c.key.startsWith('sfd:'),
                _Filter.fees => c.key.startsWith('rf:') || c.key.startsWith('sfc:'),
                _Filter.all => true,
              },
            )
            .toList();
      }
      if (list.isEmpty) return;
      final rates = list.any((c) => c.key.startsWith('rt:') || c.key == 'own');
      final amounts = list.any((c) => !c.key.startsWith('rt:') && c.key != 'own');
      final figures = switch (s) {
        _Section.record => rates && amounts ? 'Rate / amount' : (rates ? 'Rate' : 'Amount'),
        _Section.discounts || _Section.fees => 'Amount',
        _Section.county || _Section.city => 'Total rate',
        _ => 'Rate',
      };
      out.add(_Heading(s, list.length, figures));
      out.addAll(list);
    }

    section(_Section.record, _recordChoices());
    // Discounts and fees, then the taxes with out of state first, before the long Arkansas list (user 2026-11-23).
    section(_Section.discounts, _presetChoices(fee: false));
    section(_Section.fees, _presetChoices(fee: true));
    section(_Section.outOfState, [_outOfStateChoice()]);
    section(_Section.state, [_stateChoice()]);
    section(_Section.county, [for (final c in ArkansasTax.counties(_day)) _countyChoice(c)]);
    section(_Section.city, [for (final c in ArkansasTax.cities(_day)) _cityChoice(c)]);
    return out;
  }

  String _lines(int n) => n == 0 ? 'on no lines yet' : 'on $n line${n == 1 ? '' : 's'}';

  List<_Choice> _recordChoices() => [
    if (_s.canOwnRate && _s.ownRate != null)
      _Choice(
        key: 'own',
        title: _kOwnRateTitle,
        sub: 'Lines set to "Taxable" · ${_lines(_s.taxedLines[''] ?? 0)}',
        trailing: '${SalesTax.rateText(_s.ownRate!)}%',
        onRecord: true,
        open: () => const _OwnRateView(),
      ),
    for (final t in _s.taxes)
      _Choice(
        key: 'rt:${t.name}',
        title: t.short,
        sub: [
          switch (t.kind) {
            SalesTaxKind.record => 'On this record',
            SalesTaxKind.arkansas => 'Added here',
            SalesTaxKind.outOfState => 'Out of state, rate entered',
          },
          _lines(_s.taxedLines[t.name] ?? 0),
        ].join(' · '),
        trailing: '${SalesTax.rateText(t.rate)}%',
        onRecord: true,
        open: () => t.kind == SalesTaxKind.outOfState ? _OutOfStateView(t) : _RecordTaxView(t),
        search: t.name,
      ),
    for (final c in _s.charges)
      _Choice(
        key: '${c.line.isFee ? 'rf' : 'rd'}:${c.uid}',
        title: c.line.name.trim().isEmpty ? (c.line.isFee ? 'Fee' : 'Discount') : c.line.name.trim(),
        sub: [
          c.line.isFee ? 'Fee' : 'Discount',
          if (c.line.percent != null) '${SalesTax.rateText(c.line.percent!)}% of ${c.line.isFee ? 'items less discounts' : 'items'}' else 'dollar amount',
          if (c.line.isFee) 'not taxed',
        ].join(' · '),
        trailing: centsMoney(c.amountCents),
        onRecord: true,
        open: () => _ChargeView(fee: c.line.isFee, existing: c),
      ),
    for (final (i, (label, cents, discount)) in _s.recordCharges.indexed)
      _Choice(
        key: '${discount ? 'sfd' : 'sfc'}:$i',
        title: label,
        sub: 'From Service Fusion · in the totals, not changed here',
        trailing: centsMoney(cents),
        onRecord: true,
        enabled: false,
      ),
  ];

  // One figure per row: the rate a line set to it is charged (state + county + city), never the part rates or the day
  // a rate took effect (user 2026-11-23: "too many different numbers for each line, only need the figures that matter").
  // The breakdown is still on the place's own page.
  _Choice _stateChoice() {
    final r = ArkansasTax.rateOn(ArkansasTax.state, _day)!;
    final name = TaxComposition(day: _day).serviceFusionName;
    return _Choice(
      key: 'state',
      title: 'Arkansas',
      sub: 'State tax only',
      trailing: milliText(r.milli),
      onRecord: _taxNames.contains(name),
      open: () => const _PlaceView(),
      search: 'state',
    );
  }

  _Choice _countyChoice(TaxJurisdiction c) {
    final r = ArkansasTax.rateOn(c, _day)!;
    final comp = TaxComposition(day: _day, county: c);
    return _Choice(
      key: c.id,
      title: c.name,
      sub: 'State + county${r.typed ? ' · rate entered' : ''}',
      trailing: milliText(comp.milli),
      onRecord: _taxNames.contains(comp.serviceFusionName),
      open: () => _PlaceView(county: c),
      search: c.code,
    );
  }

  _Choice _cityChoice(TaxJurisdiction c) {
    final r = ArkansasTax.rateOn(c, _day)!;
    final counties = [for (final n in c.counties) ?ArkansasTax.county(n)];
    final totals = {for (final k in counties) TaxComposition(day: _day, county: k, city: c).milli}.toList()..sort();
    final names = {for (final k in counties) TaxComposition(day: _day, county: k, city: c).serviceFusionName};
    final where = counties.length == 1 ? counties.single.name : '${counties.map((k) => k.name.replaceFirst(RegExp(r'\s+County$'), '')).join(' / ')} counties';
    return _Choice(
      key: c.id,
      title: c.name,
      sub: '$where${r.typed ? ' · rate entered' : ''}',
      trailing: totals.length == 1 ? milliText(totals.single) : '${milliText(totals.first)}–${milliText(totals.last)}',
      onRecord: names.any(_taxNames.contains),
      open: () => _PlaceView(county: counties.first, city: c),
      search: '${c.code} ${counties.map((k) => k.name).join(' ')}',
    );
  }

  _Choice _outOfStateChoice() => _Choice(
    key: 'oos',
    title: _s.settings.outOfStateLabel,
    sub: 'A sale outside Arkansas · you enter the rate (states differ)',
    trailing: _s.settings.outOfStateRate == null ? 'Enter rate' : '${SalesTax.rateText(_s.settings.outOfStateRate!)}%',
    onRecord: _s.taxes.any((t) => t.kind == SalesTaxKind.outOfState),
    open: () => const _OutOfStateView(),
    search: 'out of state other state',
  );

  List<_Choice> _presetChoices({required bool fee}) => [
    for (final p in _s.settings.presets)
      if (p.fee == fee && p.active)
        _Choice(
          key: 'p:${p.id}',
          title: p.name,
          sub: p.mode == ChargeMode.percent ? 'Percentage of ${fee ? 'items less discounts' : 'items'}' : 'Dollar amount',
          // A preset with no value says what it needs, not a bare "%" or "$" (audit item 93).
          trailing: p.value == null ? (p.mode == ChargeMode.percent ? 'Enter %' : 'Enter amount') : _valueText(p.mode, p.value!),
          open: () => _ChargeView(fee: fee, preset: p),
        ),
    _Choice(
      key: fee ? 'custom-fee' : 'custom-discount',
      title: fee ? 'Custom fee' : 'Custom discount',
      sub: 'Any name · percentage or dollar amount',
      trailing: '',
      open: () => _ChargeView(fee: fee),
      search: fee ? 'other fee' : 'other discount',
    ),
  ];

  static String _valueText(ChargeMode m, double v) => m == ChargeMode.percent ? '${SalesTax.rateText(v)}%' : centsMoney((v * 100).round());

  // ---- keyboard -------------------------------------------------------------------------------------------------------

  List<int> _choices(List<Object> rows) => [
    for (var i = 0; i < rows.length; i++)
      if (rows[i] case _Choice(enabled: true)) i,
  ];

  void _step(int by) {
    final rows = _rows();
    final c = _choices(rows);
    if (c.isEmpty) return;
    final at = _hi == null ? -1 : c.indexOf(_hi!);
    final next = at < 0 ? (by > 0 ? c.first : c.last) : c[(at + by) % c.length];
    setState(() => _hi = next);
    _reveal(rows, next);
  }

  void _reveal(List<Object> rows, int index) {
    if (!_scroll.hasClients) return;
    final s = MediaQuery.textScalerOf(context);
    var top = 6.0;
    for (var i = 0; i < index; i++) {
      top += rows[i] is _Heading ? _headH(s) : _rowH(s);
    }
    final h = _rowH(s);
    final view = _scroll.position.viewportDimension;
    final off = _scroll.offset;
    // The first choice of a section shows its heading too.
    final withHead = index > 0 && rows[index - 1] is _Heading ? _headH(s) : 0.0;
    if (top - withHead < off) _scroll.jumpTo(math.max(0, top - withHead));
    if (top + h > off + view) _scroll.jumpTo(top + h - view + 6);
  }

  void _pick(_Choice c) {
    final open = c.open;
    if (!c.enabled || open == null) return;
    _go(open());
  }

  KeyEventResult _keys(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    // Esc is left to the app's dismiss (the DismissIntent action in [_panel]): handled here as well, one press went back
    // to the list and then closed the panel (found in real Chrome 2026-11-20).
    if (_view is! _Browse) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      _step(1);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      _step(-1);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final rows = _rows();
      final c = _choices(rows);
      final i = _hi ?? (c.isEmpty ? null : c.first);
      if (i != null) _pick(rows[i] as _Choice);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---- layout ---------------------------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final size = c.biggest;
        final a = widget.route.anchor;
        final below = size.height - a.bottom - _gap - _margin;
        final above = a.top - _gap - _margin;
        const want = 560.0, least = 420.0;
        // Under its button, or over it when there is more room there (near the window's bottom edge). When neither side
        // has room for a usable list (a short window: 1280 x 600 left about 270 px over the button), it takes the
        // window's height and covers its own button, as a tall select does.
        final room = math.max(below, above);
        final fits = room >= math.min(want, least);
        final down = fits ? (below >= math.min(want, least) || below >= above) : true;
        final h = fits ? math.max(0.0, math.min(want, down ? below : above)) : math.max(0.0, math.min(want, size.height - 2 * _margin));
        final w = math.min(kChargesPanelWidth, size.width - 2 * _margin);
        final left = a.left.clamp(_margin, math.max(_margin, size.width - _margin - w)).toDouble();
        final top = fits
            ? (down ? a.bottom + _gap : a.top - _gap - h)
            : (a.bottom + _gap).clamp(_margin, math.max(_margin, size.height - _margin - h)).toDouble();
        final origin = Alignment(-1, down ? -1 : 1);
        return Stack(
          children: [
            Positioned(
              left: left,
              top: top,
              width: w,
              height: h,
              child: PsPopMotion(animation: widget.route.animation!, down: down, origin: origin, child: _panel()),
            ),
          ],
        );
      },
    );
  }

  Widget _panel() {
    final still = MediaQuery.disableAnimationsOf(context);
    final body = switch (_view) {
      _Browse() => _browse(),
      final _PlaceView v => _PlaceForm(key: ValueKey('place-${v.county?.id}-${v.city?.id}'), view: v, page: this),
      final _RecordTaxView v => _RecordTaxForm(key: ValueKey('rt-${v.tax.name}'), tax: v.tax, page: this),
      final _OutOfStateView v => _OutOfStateForm(key: ValueKey('oos-${v.existing?.name}'), existing: v.existing, page: this),
      _OwnRateView() => _OwnRateForm(key: const ValueKey('own'), page: this),
      final _ChargeView v => _ChargeForm(key: ValueKey('charge-${v.fee}-${v.preset?.id}-${v.existing?.uid}'), view: v, page: this),
    };
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: 'Tax, discounts and fees',
      // Esc is the app's dismiss (DismissIntent), taken here first: from a form, even from inside one of its fields, it
      // goes back to the list; from the list it closes the panel. (In Chrome a field's Esc went straight to the route
      // and closed everything, found 2026-11-20.)
      child: Actions(
        actions: {
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              if (_view is _Browse) {
                _finish(null);
              } else {
                _back();
              }
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _panelFocus,
          onKeyEvent: _keys,
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              decoration: psMenuPanelDecoration(),
              // A menu, not a page: its text is never selected, so the pointer stays the arrow/hand over every label
              // (the page-wide selection showed an I-beam and a highlight over its rows; user 2026-11-23). Its own
              // fields keep their editing cursor.
              child: SelectionContainer.disabled(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: AnimatedSwitcher(
                    duration: still ? Duration.zero : const Duration(milliseconds: 160),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween(begin: const Offset(0.03, 0), end: Offset.zero).animate(anim),
                        child: child,
                      ),
                    ),
                    layoutBuilder: (current, previous) => Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
                    child: KeyedSubtree(key: ValueKey(_view.runtimeType.toString() + body.key.toString()), child: body),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _browse() {
    final rows = _rows();
    final s = MediaQuery.textScalerOf(context);
    return Column(
      key: const ValueKey('browse'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 10, 0),
          child: Row(
            children: [
              const Expanded(
                // The forms' title style (audit item 105: 14 px here, 15 px there).
                child: Text('Tax, discounts & fees', maxLines: 1, overflow: TextOverflow.ellipsis, style: _titleStyle),
              ),
              // Tabs flush right, the selected one in ink (user rule).
              for (final (f, label) in const [(_Filter.all, 'All'), (_Filter.taxes, 'Taxes'), (_Filter.discounts, 'Discounts'), (_Filter.fees, 'Fees')])
                _Tab(
                  label: label,
                  selected: _filter == f,
                  onTap: () => setState(() {
                    _filter = f;
                    _hi = null;
                    if (_scroll.hasClients) _scroll.jumpTo(0);
                  }),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: _SearchBox(controller: _search, focusNode: _searchFocus),
        ),
        const Divider(height: 1, thickness: 1, color: DashUi.line),
        Expanded(
          child: rows.isEmpty
              ? _NothingFound(query: _search.text.trim(), filter: _filter)
              : Scrollbar(
                  controller: _scroll,
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final r = rows[i];
                      if (r is _Heading) {
                        return SizedBox(
                          height: _headH(s),
                          child: _SectionHead(section: r.section, count: r.count, figures: r.figures, first: i == 0),
                        );
                      }
                      final c = r as _Choice;
                      return SizedBox(
                        height: _rowH(s),
                        child: _ChoiceRow(
                          choice: c,
                          highlighted: _hi == i,
                          onHover: (on) => setState(() => _hi = on ? i : (_hi == i ? null : _hi)),
                          onTap: () => _pick(c),
                        ),
                      );
                    },
                  ),
                ),
        ),
        const Divider(height: 1, thickness: 1, color: DashUi.line),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 9),
          // "DFA" said in full once (audit item 104): the Arkansas Department of Finance and Administration publishes the
          // rates.
          child: Text(
            'Arkansas rates: Dept. of Finance & Administration (DFA) table ${ArkansasTax.source.lastQuarter} · '
            'checked ${dayText(ArkansasTax.source.verified)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, color: DashUi.slate, height: 1.3),
          ),
        ),
      ],
    );
  }
}

// ---- the list's parts -------------------------------------------------------------------------------------------------

class _Tab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Tab({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    inMutuallyExclusiveGroup: true,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      mouseCursor: SystemMouseCursors.click,
      // No hover shading, as on the rest of the job page (user 2026-11-25, audit item 88); focus and a press still show.
      overlayColor: dashNoHoverOverlay,
      splashFactory: NoSplash.splashFactory,
      child: Container(
        padding: const EdgeInsets.fromLTRB(9, 6, 9, 4),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: selected ? DashUi.ink : Colors.transparent, width: 2)),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 12.5, fontWeight: selected ? FontWeight.w700 : FontWeight.w600, color: selected ? DashUi.ink : DashUi.slate, height: 1.3),
        ),
      ),
    ),
  );
}

/// The search box, in the Add Line search's look (40 px, hairline, ink while focused).
class _SearchBox extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  const _SearchBox({required this.controller, required this.focusNode});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: CatalogSearchField.height,
    child: TextField(
      key: const ValueKey('charges-search'),
      controller: controller,
      focusNode: focusNode,
      autofocus: true,
      cursorColor: DashUi.ink,
      style: const TextStyle(fontSize: 13.5, color: DashUi.ink),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: Colors.white,
        hoverColor: Colors.white,
        visualDensity: VisualDensity.standard,
        hintText: 'Search a city, county, discount or fee',
        hintStyle: const TextStyle(fontSize: 13.5, color: DashUi.slate),
        prefixIcon: const Icon(Icons.search_rounded, size: 18, color: DashUi.slate),
        prefixIconConstraints: const BoxConstraints(minWidth: 38, minHeight: 38),
        suffixIcon: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => controller.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  tooltip: 'Clear the search',
                  onPressed: controller.clear,
                  icon: const Icon(Icons.close_rounded, size: 16, color: DashUi.slate),
                  style: ButtonStyle(overlayColor: dashNoHoverOverlay),
                ),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: DashUi.fieldEdge),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: DashUi.fieldEdge),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: DashUi.ink, width: 1.5),
        ),
      ),
    ),
  );
}

class _SectionHead extends StatelessWidget {
  final _Section section;
  final int count;
  final String figures;
  final bool first;
  const _SectionHead({required this.section, required this.count, required this.figures, required this.first});

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.ink, letterSpacing: 0.6, height: 1.3);
    return Semantics(
      header: true,
      child: Container(
        alignment: Alignment.bottomLeft,
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
        decoration: first
            ? null
            : const BoxDecoration(
                border: Border(top: BorderSide(color: DashUi.line)),
              ),
        child: Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: _sectionTitle(section).toUpperCase()),
                    TextSpan(
                      text: '  $count',
                      style: const TextStyle(fontWeight: FontWeight.w600, color: DashUi.subtle, letterSpacing: 0),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
            Text(figures, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: DashUi.subtle, height: 1.3)),
          ],
        ),
      ),
    );
  }
}

/// One choice: its tick slot (always there, so every title starts in the same place), title over a quiet line, and its
/// figures at the right. Under the pointer or the arrow keys the Add Line search's highlight.
class _ChoiceRow extends StatelessWidget {
  final _Choice choice;
  final bool highlighted;
  final ValueChanged<bool> onHover;
  final VoidCallback onTap;
  const _ChoiceRow({required this.choice, required this.highlighted, required this.onHover, required this.onTap});

  static const _figures = [FontFeature.tabularFigures()];

  @override
  Widget build(BuildContext context) {
    final c = choice;
    final on = c.enabled;
    final still = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: on,
      enabled: on,
      selected: c.onRecord,
      label: [c.title, c.sub, if (c.trailing.isNotEmpty) c.trailing, if (c.onRecord) 'on this record'].join(', '),
      excludeSemantics: true,
      onTap: on ? onTap : null,
      child: MouseRegion(
        cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: on ? (_) => onHover(true) : null,
        onExit: on ? (_) => onHover(false) : null,
        child: GestureDetector(
          key: ValueKey('charge-choice-${c.key}'),
          behavior: HitTestBehavior.opaque,
          onTap: on ? onTap : null,
          child: AnimatedContainer(
            duration: still ? Duration.zero : const Duration(milliseconds: 90),
            curve: Curves.easeOut,
            padding: const EdgeInsets.fromLTRB(6, 0, 10, 0),
            decoration: BoxDecoration(color: highlighted && on ? DashUi.faint : Colors.white.withValues(alpha: 0), borderRadius: BorderRadius.circular(6)),
            child: Row(
              children: [
                SizedBox(width: 24, child: c.onRecord ? const Icon(Icons.check_rounded, size: 16, color: DashUi.ink) : null),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        c.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: on ? DashUi.ink : DashUi.slate, height: 1.3),
                      ),
                      Text.rich(
                        TextSpan(text: c.sub),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: DashUi.slate, height: 1.35, fontFeatures: _figures),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  c.trailing,
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: on ? DashUi.ink : DashUi.slate, height: 1.3, fontFeatures: _figures),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NothingFound extends StatelessWidget {
  final String query;
  final _Filter filter;
  const _NothingFound({required this.query, required this.filter});

  @override
  Widget build(BuildContext context) {
    // What to try next, for the list being searched (audit item 107: it always talked about Arkansas places).
    final hint = switch (filter) {
      _Filter.discounts => 'No discount on this record or in the presets has that name. Clear the search for Custom discount.',
      _Filter.fees => 'No fee on this record or in the presets has that name. Clear the search for Custom fee.',
      _Filter.taxes => 'Only Arkansas places with a local sales tax are listed. For a sale outside Arkansas use Out-of-state tax.',
      _Filter.all =>
        'Only Arkansas places with a local sales tax are listed, with the discount and fee presets. For a sale outside '
            'Arkansas use Out-of-state tax.',
    };
    return _nothing(hint);
  }

  Widget _nothing(String hint) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.search_off_rounded, size: 28, color: DashUi.muted),
          const SizedBox(height: 10),
          Text(
            'Nothing matches "$query"',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.ink),
          ),
          const SizedBox(height: 4),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12.5, color: DashUi.slate, height: 1.4),
          ),
        ],
      ),
    ),
  );
}

// ---- the forms --------------------------------------------------------------------------------------------------------

/// Every form's frame: a back arrow and title over a hairline, the form, and its buttons at the foot.
class _Form extends StatelessWidget {
  final String title;
  final String? sub;
  final VoidCallback onBack;
  final Widget body;
  final List<Widget> start; // at the foot's left (Remove)
  final List<Widget> end; // at the foot's right (Back, the main action)
  const _Form({required this.title, this.sub, required this.onBack, required this.body, this.start = const [], required this.end});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(6, 6, 16, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconButton(
              key: const ValueKey('charges-back'),
              tooltip: 'Back to the list',
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_rounded, size: 18, color: DashUi.ink),
              // No hover shading (audit item 88).
              style: ButtonStyle(overlayColor: dashNoHoverOverlay),
            ),
            const SizedBox(width: 2),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: _titleStyle),
                    ),
                    if (sub != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(sub!, style: const TextStyle(fontSize: 12.5, color: DashUi.slate, height: 1.35)),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      const Divider(height: 1, thickness: 1, color: DashUi.line),
      // Scrolls, with its bar showing, when the panel is shorter than the form (a short window, large text).
      Expanded(child: _FormBody(body: body)),
      const Divider(height: 1, thickness: 1, color: DashUi.line),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        // The buttons wrap onto a second row rather than run off the panel (large text, a long place name).
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            ...start,
            const SizedBox(width: 8),
            Expanded(
              child: Wrap(alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, runSpacing: 6, children: end),
            ),
          ],
        ),
      ),
    ],
  );
}

/// A form's body: it scrolls, with its bar showing, when the panel is shorter than the form.
class _FormBody extends StatefulWidget {
  final Widget body;
  const _FormBody({required this.body});

  @override
  State<_FormBody> createState() => _FormBodyState();
}

class _FormBodyState extends State<_FormBody> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scrollbar(
    controller: _scroll,
    child: SingleChildScrollView(controller: _scroll, padding: const EdgeInsets.fromLTRB(16, 12, 16, 12), child: widget.body),
  );
}

/// The panel's titles, the list's and every form's: one size and weight (audit item 105).
const _titleStyle = TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: DashUi.ink, height: 1.3);

/// The panel's buttons: 36 px, the block's quiet text button and its ink one. No hover shading, as on the rest of the
/// job page (user 2026-11-25, audit item 88); keyboard focus and a press still show.
Widget _ghost(String label, VoidCallback? onPressed, {Key? key, bool danger = false}) => TextButton(
  key: key,
  onPressed: onPressed,
  style: TextButton.styleFrom(
    foregroundColor: danger ? DashUi.redText : DashUi.ink,
    minimumSize: const Size(0, 36),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  ).copyWith(overlayColor: dashNoHoverOverlay),
  child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
);

Widget _primary(String label, VoidCallback? onPressed, {Key? key}) => FilledButton(
  key: key,
  onPressed: onPressed,
  style: FilledButton.styleFrom(
    backgroundColor: DashUi.ink,
    disabledBackgroundColor: DashUi.line,
    foregroundColor: Colors.white,
    disabledForegroundColor: DashUi.slate,
    minimumSize: const Size(0, 36),
    padding: const EdgeInsets.symmetric(horizontal: 16),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  ).copyWith(overlayColor: dashNoHoverOverlay),
  child: Text(
    label,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
  ),
);

/// A one-line note under a form: what adding does (or doesn't do).
class _Note extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color tone;
  const _Note(this.text, {this.icon = Icons.info_outline_rounded, this.tone = DashUi.slate});

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 1),
        child: Icon(icon, size: 15, color: tone),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(text, style: TextStyle(fontSize: 12.5, color: tone == DashUi.slate ? DashUi.ink : tone, height: 1.45)),
      ),
    ],
  );
}

/// A tax's parts, one per row (rate and since-when at the right), and the total under a rule.
class _Parts extends StatelessWidget {
  final List<SalesTaxPart> parts;
  final String totalLabel;
  final String total;

  /// Toggles beside the county and city rows (a place's form): null rows have none. A part that is off is still listed
  /// (greyed, its rate struck through) and left out of [total].
  final Map<String, ({bool on, bool locked, ValueChanged<bool>? onChanged})> toggles;
  const _Parts({required this.parts, required this.totalLabel, required this.total, this.toggles = const {}});

  static const _figures = [FontFeature.tabularFigures()];

  @override
  Widget build(BuildContext context) {
    Widget row(String id, String name, String sub, String rate, {bool strong = false}) {
      final t = toggles[id];
      // A part turned off stays listed, greyed, so it can be turned back on (audit item 74: it used to vanish).
      final off = t != null && !t.on;
      final change = t == null || t.locked || t.onChanged == null ? null : t.onChanged!;
      final line = Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            if (toggles.isNotEmpty)
              SizedBox(
                width: 38,
                child: t == null
                    ? null
                    // A 32 px target (audit item 75: it was 18 px), and the part's name turns it on and off too (below).
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: Checkbox(
                          key: ValueKey('part-$id'),
                          value: t.on,
                          onChanged: change == null ? null : (v) => change(v == true),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          activeColor: DashUi.ink,
                          overlayColor: dashNoHoverOverlay,
                          side: const BorderSide(color: LineTable.edgeHover, width: 1.2),
                          semanticLabel: '$name${t.locked ? ', always included' : ''}',
                        ),
                      ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: strong ? FontWeight.w700 : FontWeight.w600,
                      color: off ? DashUi.slate : DashUi.ink,
                      height: 1.3,
                    ),
                  ),
                  if (sub.isNotEmpty)
                    Text(
                      sub,
                      style: const TextStyle(fontSize: 12, color: DashUi.slate, height: 1.35, fontFeatures: _figures),
                    ),
                ],
              ),
            ),
            Text(
              rate,
              style: TextStyle(
                fontSize: strong ? 15 : 13.5,
                fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
                color: off ? DashUi.slate : DashUi.ink,
                decoration: off ? TextDecoration.lineThrough : null,
                fontFeatures: _figures,
              ),
            ),
          ],
        ),
      );
      if (change == null) return line;
      // The whole row is the checkbox's label: a click on the name or the rate turns the part on or off.
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => change(!t!.on), child: line),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final p in parts)
          row(
            p.id,
            p.name,
            [
              'since ${dayText(p.from)}',
              if (p.next != null) (p.next!.$1 == 0 ? 'ends ${dayText(p.next!.$2)}' : 'changes to ${milliText(p.next!.$1)} on ${dayText(p.next!.$2)}'),
            ].join(' · '),
            milliText(p.milli),
          ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 4),
          child: Divider(height: 1, thickness: 1, color: DashUi.line),
        ),
        row('total', totalLabel, '', total, strong: true),
      ],
    );
  }
}

/// A place's Arkansas sales tax: its parts, which county for a city in two, and Add.
class _PlaceForm extends StatefulWidget {
  final _PlaceView view;
  final _ChargesPageState page;
  const _PlaceForm({super.key, required this.view, required this.page});

  @override
  State<_PlaceForm> createState() => _PlaceFormState();
}

class _PlaceFormState extends State<_PlaceForm> {
  /// The county the place is in (for a city in two, the one picked), and whether its and the city's parts are in.
  TaxJurisdiction? _place;
  bool _countyOn = true;
  bool _cityOn = true;

  /// What is added: the county and city only while their parts are in.
  TaxJurisdiction? get _county => _countyOn ? _place : null;
  TaxJurisdiction? get _city => _cityOn ? widget.view.city : null;

  @override
  void initState() {
    super.initState();
    _place = widget.view.county;
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.page;
    final day = p._day;
    final comp = TaxComposition(day: day, county: _county, city: _city);
    // Every part the place has, those turned off too, so one turned off can be turned back on (audit item 74).
    final parts = TaxComposition(day: day, county: _place, city: widget.view.city).parts;
    final already = p._taxNames.contains(comp.serviceFusionName);
    final cityCounties = widget.view.city == null ? const <TaxJurisdiction>[] : [for (final n in widget.view.city!.counties) ?ArkansasTax.county(n)];
    final title = _city != null ? '${_city!.name} sales tax' : (_county != null ? '${_county!.name} sales tax' : 'Arkansas state sales tax');
    // A county with no tax that day (Saline, Monroe) is still the county a city is in; it adds nothing.
    final countyRate = _place == null ? null : ArkansasTax.milliOn(_place!, day);
    final toggles = <String, ({bool on, bool locked, ValueChanged<bool>? onChanged})>{
      ArkansasTax.state.id: (on: true, locked: true, onChanged: null),
      // The county's part is always in while the city's is: a city's tax comes with its county's.
      if (_place != null && countyRate != null)
        _place!.id: (on: _countyOn || _cityOn, locked: _cityOn && widget.view.city != null, onChanged: (v) => setState(() => _countyOn = v)),
      if (widget.view.city != null)
        widget.view.city!.id: (
          on: _cityOn,
          locked: false,
          onChanged: (v) => setState(() {
            _cityOn = v;
            if (v) _countyOn = true;
          }),
        ),
    };
    final dropped = [
      if (widget.view.city != null && _city == null) widget.view.city!,
      if (_place != null && countyRate != null && _county == null) _place!,
    ];
    return _Form(
      title: title,
      sub: [
        if (_city != null) _county!.name else if (_county != null) 'Unincorporated ${_county!.name}' else 'The state\'s rate only',
        'rates on ${dayText(day)}',
      ].join(' · '),
      onBack: p._back,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (cityCounties.length > 1 && _city != null) ...[
            // The form's one label style (audit item 105).
            _label('Which county is the job in?'),
            const SizedBox(height: 2),
            _CountyChoice(counties: cityCounties, city: _city!, day: day, value: _place!, onChanged: (c) => setState(() => _place = c)),
            const SizedBox(height: 12),
          ],
          _label('Parts'),
          _Parts(parts: parts, totalLabel: 'Sales tax charged', total: milliText(comp.milli), toggles: toggles),
          for (final d in dropped)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: _Note('${d.name}\'s tax is left out: this is ${comp.place}\'s tax without it.', icon: Icons.remove_circle_outline_rounded),
            ),
          if (countyRate == null && _county != null && _city != null)
            Padding(padding: const EdgeInsets.only(top: 4), child: _Note('${_county!.name} has no county sales tax on ${dayText(day)}.')),
          const SizedBox(height: 10),
          if (already)
            const _Note('Already on this record: choose it in a line\'s Tax column.', icon: Icons.check_circle_outline_rounded, tone: DashUi.emeraldText)
          else
            const _Note('Adding it taxes nothing yet: choose it in a line\'s Tax column to tax that line.'),
        ],
      ),
      end: [
        _ghost('Back', p._back),
        _primary(
          already ? 'Already on this record' : 'Add ${_city?.name ?? _county?.name ?? 'Arkansas state'} ${milliText(comp.milli)}',
          already ? null : () => p._finish(AddTax(comp.toSalesTax())),
          key: const ValueKey('add-tax'),
        ),
      ],
    );
  }
}

/// Which of a city's counties the job is in: one even-width choice per county, with what the tax comes to there (state,
/// county and city together; audit item 106: it showed the county's own part rate).
class _CountyChoice extends StatelessWidget {
  final List<TaxJurisdiction> counties;
  final TaxJurisdiction city;
  final String day;
  final TaxJurisdiction value;
  final ValueChanged<TaxJurisdiction> onChanged;
  const _CountyChoice({required this.counties, required this.city, required this.day, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (final (i, c) in counties.indexed) ...[
        if (i > 0) const SizedBox(width: 8),
        Expanded(
          child: Semantics(
            button: true,
            selected: c.id == value.id,
            inMutuallyExclusiveGroup: true,
            child: InkWell(
              key: ValueKey('county-${c.id}'),
              onTap: () => onChanged(c),
              borderRadius: BorderRadius.circular(LineTable.radius),
              mouseCursor: SystemMouseCursors.click,
              overlayColor: dashNoHoverOverlay,
              child: AnimatedContainer(
                duration: LineTable.motion(context, 120),
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(LineTable.radius),
                  border: Border.all(color: c.id == value.id ? DashUi.ink : LineTable.edge, width: c.id == value.id ? 1.5 : 1),
                ),
                child: Row(
                  children: [
                    Icon(
                      c.id == value.id ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                      size: 16,
                      color: c.id == value.id ? DashUi.ink : DashUi.subtle,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.ink),
                      ),
                    ),
                    Text(
                      milliText(TaxComposition(day: day, county: c, city: city).milli),
                      style: const TextStyle(fontSize: 12.5, color: DashUi.slate, fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ],
  );
}

/// A tax already on the record: what it is made of, how many lines use it, and whether DFA's rate today differs from
/// the one it charges (the record keeps its own: what was charged is never changed).
class _RecordTaxForm extends StatelessWidget {
  final SalesTax tax;
  final _ChargesPageState page;
  const _RecordTaxForm({super.key, required this.tax, required this.page});

  @override
  Widget build(BuildContext context) {
    final p = page;
    final lines = p._s.taxedLines[tax.name] ?? 0;
    final now = ArkansasTax.fromServiceFusionName(tax.name, p._day);
    final charged = (tax.rate * 1000).round();
    final parts = tax.parts.isNotEmpty ? tax.parts : (now?.parts ?? const <SalesTaxPart>[]);
    final differs = now != null && now.milli != charged;
    return _Form(
      title: tax.short,
      sub: switch (tax.kind) {
        SalesTaxKind.record => 'On this record at ${SalesTax.rateText(tax.rate)}%',
        _ => 'Added here at ${SalesTax.rateText(tax.rate)}%${tax.asOf == null ? '' : ', rates on ${dayText(tax.asOf!)}'}',
      },
      onBack: p._back,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (parts.isNotEmpty) ...[
            // Plain words for "DFA" (audit item 104) and the form's one label style (item 105).
            _label(tax.parts.isNotEmpty ? 'Parts' : 'Parts at today\'s Arkansas rates'),
            _Parts(
              parts: parts,
              totalLabel: tax.parts.isNotEmpty ? 'Sales tax charged' : 'Arkansas rate on ${dayText(p._day)}',
              total: milliText(tax.parts.isNotEmpty ? charged : now!.milli),
            ),
            const SizedBox(height: 12),
          ],
          if (differs)
            // The way to act on it is the button at the foot (audit item 84: it said to add the place again from the
            // list, where its button reads "Already on this record").
            _Note(
              'This record charges ${SalesTax.rateText(tax.rate)}%. Arkansas\'s published rate for ${now.place} on ${dayText(p._day)} is '
              '${milliText(now.milli)}. The record keeps its own rate unless you update it; lines set to this tax follow.',
              icon: Icons.warning_amber_rounded,
              tone: DashUi.amberText,
            )
          else if (now == null && tax.kind == SalesTaxKind.record)
            const _Note('Not an Arkansas place in the catalog (or not named the way Service Fusion names one), so its rate can\'t be checked here.'),
          const SizedBox(height: 8),
          _Note(
            lines == 0
                ? 'No line is set to this tax.'
                : '$lines line${lines == 1 ? ' is' : 's are'} set to this tax. Removing it sets ${lines == 1 ? 'that line' : 'them'} to No tax.',
          ),
        ],
      ),
      start: [_ghost('Remove tax', () => p._finish(RemoveTax(tax)), key: const ValueKey('remove-tax'), danger: true)],
      // Back, not a "Done" that only went back like the arrow (audit item 108); when today's Arkansas rate differs, the
      // one thing to do here is take it (item 84).
      end: [
        _ghost('Back', p._back),
        // The same tax line (its name, so its lines keep it, and whether it is the record's own) at today's rate and parts.
        if (differs)
          _primary(
            'Use ${milliText(now.milli)}',
            () => p._finish(
              UpdateTax(
                tax,
                SalesTax(tax.name, now.milli / 1000, onRecord: tax.onRecord, kind: tax.kind, parts: now.parts, asOf: p._day, display: tax.display),
              ),
            ),
            key: const ValueKey('update-tax'),
          ),
      ],
    );
  }
}

/// A rate box: the figure at the left, right after its "$" (the table's value boxes since 2026-11-23; user 2026-11-25,
/// audit item 109), or with its "%" at the box's right. Both marks are always laid out (one shown), so switching between
/// them moves nothing (one width, one height: [LineTable.boxHeight]). [label] is its name for screen readers.
class _ValueBox extends StatelessWidget {
  final TextEditingController controller;
  final bool percent;
  final bool error;
  final String? hint;
  final Key? fieldKey;
  final String label;
  final ValueChanged<String> onChanged;
  final VoidCallback? onSubmitted;
  final bool autofocus;
  const _ValueBox({
    required this.controller,
    required this.percent,
    required this.error,
    required this.label,
    required this.onChanged,
    this.hint,
    this.fieldKey,
    this.onSubmitted,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 14, color: DashUi.ink, height: 1.35, fontFeatures: [FontFeature.tabularFigures()]);
    OutlineInputBorder b(Color c, double w) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(LineTable.radius),
      borderSide: BorderSide(color: c, width: w),
    );
    return SizedBox(
      width: 140,
      height: CatalogSearchField.height,
      child: _OwnFocus(
        autofocus: autofocus,
        // A labelled node around the field (audit item 85: screen readers heard only "0"). Not MergeSemantics: merging a TextField trips a semantics assertion.
        builder: (node) => Semantics(container: true,
          child: Semantics(
            label: label,
            child: TextField(
          key: fieldKey,
          controller: controller,
          focusNode: node,
          textAlign: TextAlign.left,
          style: style,
          cursorColor: DashUi.ink,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,%$]'))],
          onChanged: onChanged,
          onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: Colors.white,
            hoverColor: Colors.white,
            visualDensity: VisualDensity.standard,
            hintText: hint,
            hintStyle: LineTable.hint.copyWith(fontSize: 14),
            // Both are always laid out (one shown), so the figure never moves when % and $ are swapped. The "$" sits at
            // the prefix's right edge, a space before the figure, as the table's "$ " does.
            prefixIcon: SizedBox(
              width: 28,
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(percent ? '' : r'$ ', style: LineTable.currency.copyWith(fontSize: 14)),
              ),
            ),
            prefixIconConstraints: const BoxConstraints(minWidth: 28, maxWidth: 28),
            suffixIcon: SizedBox(
              width: 28,
              child: Center(child: Text(percent ? '%' : '', style: LineTable.currency.copyWith(fontSize: 14))),
            ),
            suffixIconConstraints: const BoxConstraints(minWidth: 28, maxWidth: 28),
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
            border: b(LineTable.edge, 1),
            enabledBorder: b(error ? DashUi.red : LineTable.edge, error ? 1.5 : 1),
            focusedBorder: b(error ? DashUi.red : DashUi.ink, 1.5),
          ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A text box in the same look (the name of a discount, fee or out-of-state tax). [label] is its name for screen readers.
class _TextBox extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final String label;
  final Key? fieldKey;
  final bool error;
  final ValueChanged<String> onChanged;
  final bool autofocus;
  const _TextBox({
    required this.controller,
    required this.hint,
    required this.onChanged,
    this.label = 'Name on the record',
    this.fieldKey,
    this.error = false,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    OutlineInputBorder b(Color c, double w) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(LineTable.radius),
      borderSide: BorderSide(color: c, width: w),
    );
    return SizedBox(
      height: CatalogSearchField.height,
      child: _OwnFocus(
        autofocus: autofocus,
        // A labelled node around the field (audit item 85).
        builder: (node) => Semantics(container: true,
          child: Semantics(
            label: label,
            child: TextField(
          key: fieldKey,
          controller: controller,
          focusNode: node,
          style: const TextStyle(fontSize: 14, color: DashUi.ink, height: 1.35),
          cursorColor: DashUi.ink,
          onChanged: onChanged,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: Colors.white,
            hoverColor: Colors.white,
            visualDensity: VisualDensity.standard,
            hintText: hint,
            hintStyle: LineTable.hint.copyWith(fontSize: 14),
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            border: b(LineTable.edge, 1),
            enabledBorder: b(error ? DashUi.red : LineTable.edge, error ? 1.5 : 1),
            focusedBorder: b(error ? DashUi.red : DashUi.ink, 1.5),
          ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A form field's own focus: it takes focus once its form has been built when [autofocus] (a field's autofocus was
/// skipped in Chrome after the list's search went away, so focus ended up nowhere), and Esc in it goes back to the list
/// through the panel's dismiss action (the field sees the key first).
class _OwnFocus extends StatefulWidget {
  final bool autofocus;
  final Widget Function(FocusNode node) builder;
  const _OwnFocus({required this.autofocus, required this.builder});

  @override
  State<_OwnFocus> createState() => _OwnFocusState();
}

class _OwnFocusState extends State<_OwnFocus> {
  late final FocusNode _node = FocusNode(
    debugLabel: 'charges form field',
    onKeyEvent: (node, e) {
      if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
        Actions.maybeInvoke(context, const DismissIntent());
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
  );

  @override
  void initState() {
    super.initState();
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _node.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_node);
}

Widget _label(String text) => Padding(
  padding: const EdgeInsets.only(bottom: 6),
  child: Text(
    text,
    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: DashUi.ink),
  ),
);

/// An out-of-state sales tax: a name and a rate someone types (states' rates differ; an Arkansas rate is never used).
class _OutOfStateForm extends StatefulWidget {
  final SalesTax? existing;
  final _ChargesPageState page;
  const _OutOfStateForm({super.key, this.existing, required this.page});

  @override
  State<_OutOfStateForm> createState() => _OutOfStateFormState();
}

class _OutOfStateFormState extends State<_OutOfStateForm> {
  late final TextEditingController _name;
  late final TextEditingController _rate;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    final s = widget.page._s.settings;
    _name = TextEditingController(text: e?.short ?? s.outOfStateLabel);
    final r = e?.rate ?? s.outOfStateRate;
    _rate = TextEditingController(text: r == null ? '' : SalesTax.rateText(r));
  }

  @override
  void dispose() {
    _name.dispose();
    _rate.dispose();
    super.dispose();
  }

  double? get _r => parsePercent(_rate.text);
  bool get _rateOk => _r != null && _r! > 0 && _r! <= 30;
  String get _n => _name.text.trim();

  /// Another tax line already has this name (each tax is one choice in the lines' Tax column).
  bool get _clash => _n.isNotEmpty && widget.page._s.taxes.any((t) => t.name == _n && t.name != widget.existing?.name);

  void _submit() {
    if (!_rateOk || _n.isEmpty || _clash) return;
    final t = SalesTax(_n, _r!, kind: SalesTaxKind.outOfState, display: _n, asOf: widget.page._day);
    widget.page._finish(widget.existing == null ? AddTax(t) : UpdateTax(widget.existing!, t));
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.page;
    final typed = _rate.text.trim().isNotEmpty;
    final lines = widget.existing == null ? 0 : (p._s.taxedLines[widget.existing!.name] ?? 0);
    return _Form(
      // Its own name as the title (audit item 92: "Out-of-state: Out-of-state sales tax"); the line under it says what it is.
      title: widget.existing == null ? 'Out-of-state sales tax' : widget.existing!.short,
      sub: 'For a sale outside Arkansas. Enter that place\'s rate.',
      onBack: p._back,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('Name on the record'),
          _TextBox(
            controller: _name,
            hint: 'Out-of-state sales tax (Missouri)',
            fieldKey: const ValueKey('oos-name'),
            error: _n.isEmpty || _clash,
            onChanged: (_) => setState(() {}),
          ),
          // The red border always says why (audit item 83: an empty name had a red border and no text).
          if (_clash || _n.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _Note(
                _clash ? 'Another tax on this record has that name.' : 'Enter a name for this tax.',
                icon: Icons.error_outline_rounded,
                tone: DashUi.redText,
              ),
            ),
          const SizedBox(height: 14),
          _label('Rate'),
          _ValueBox(
            controller: _rate,
            percent: true,
            error: typed && !_rateOk,
            hint: '0',
            fieldKey: const ValueKey('oos-rate'),
            label: 'Out-of-state rate, percent',
            autofocus: true,
            onChanged: (_) => setState(() {}),
            onSubmitted: _submit,
          ),
          SizedBox(
            height: 26,
            child: typed && !_rateOk
                ? const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(kOutOfStateRateRule, style: TextStyle(fontSize: 12, color: DashUi.redText)),
                  )
                : null,
          ),
          const SizedBox(height: 6),
          _Note(
            widget.existing == null
                ? 'Adding it taxes nothing yet. It becomes a choice in each line\'s Tax column, and only lines set to it are taxed.'
                : (lines == 0
                      ? 'No line is set to this tax.'
                      : '$lines line${lines == 1 ? ' is' : 's are'} set to this tax; a new rate applies to ${lines == 1 ? 'it' : 'them'}.'),
          ),
        ],
      ),
      start: [if (widget.existing != null) _ghost('Remove tax', () => p._finish(RemoveTax(widget.existing!)), key: const ValueKey('remove-tax'), danger: true)],
      end: [
        _ghost('Back', p._back),
        _primary(widget.existing == null ? 'Add tax' : 'Save', _rateOk && _n.isNotEmpty && !_clash ? _submit : null, key: const ValueKey('save-oos')),
      ],
    );
  }
}

/// The set's own rate (an estimate option or a job's set carries one, seeded from Service Fusion's tax): 0% to 30%.
class _OwnRateForm extends StatefulWidget {
  final _ChargesPageState page;
  const _OwnRateForm({super.key, required this.page});

  @override
  State<_OwnRateForm> createState() => _OwnRateFormState();
}

class _OwnRateFormState extends State<_OwnRateForm> {
  late final TextEditingController _rate;

  @override
  void initState() {
    super.initState();
    final r = widget.page._s.ownRate;
    _rate = TextEditingController(text: r == null ? '' : SalesTax.rateText(r));
  }

  @override
  void dispose() {
    _rate.dispose();
    super.dispose();
  }

  double? get _r => parsePercent(_rate.text);
  bool get _empty => _rate.text.trim().isEmpty;
  bool get _ok => _empty || (_r != null && _r! >= 0 && _r! <= 30);

  void _submit() {
    if (!_ok) return;
    widget.page._finish(SetOwnRate(_empty || _r == 0 ? null : _r));
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.page;
    final lines = p._s.taxedLines[''] ?? 0;
    return _Form(
      title: _kOwnRateTitle,
      sub: 'The rate these products and services were given (from Service Fusion\'s tax line). Lines set to "Taxable" pay it.',
      onBack: p._back,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('Rate'),
          Row(
            children: [
              _ValueBox(
                controller: _rate,
                percent: true,
                error: !_ok,
                hint: '0',
                fieldKey: const ValueKey('tax-rate'),
                label: 'Tax rate, percent',
                autofocus: true,
                onChanged: (_) => setState(() {}),
                onSubmitted: _submit,
              ),
              if (!_ok)
                const Padding(
                  key: ValueKey('tax-rate-invalid'),
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(Icons.error_outline_rounded, size: 16, color: DashUi.redText, semanticLabel: kTaxRateRule),
                ),
            ],
          ),
          SizedBox(
            height: 26,
            child: !_ok
                ? const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(kTaxRateRule, style: TextStyle(fontSize: 12, color: DashUi.redText)),
                  )
                : null,
          ),
          const SizedBox(height: 6),
          _Note(
            lines == 0
                ? 'No line is set to "Taxable".'
                : '$lines line${lines == 1 ? ' is' : 's are'} set to "Taxable". Removing the rate sets ${lines == 1 ? 'it' : 'them'} to No tax.',
          ),
        ],
      ),
      start: [_ghost('Remove tax', () => p._finish(const SetOwnRate(null)), key: const ValueKey('remove-tax'), danger: true)],
      end: [
        _ghost('Back', p._back),
        _primary('Save', _ok ? _submit : null, key: const ValueKey('save-own-rate')),
      ],
    );
  }
}

/// A discount or fee: its name, % or $ (one box either way, so nothing moves when it is switched), its amount, and what
/// it comes to on this record.
class _ChargeForm extends StatefulWidget {
  final _ChargeView view;
  final _ChargesPageState page;
  const _ChargeForm({super.key, required this.view, required this.page});

  @override
  State<_ChargeForm> createState() => _ChargeFormState();
}

class _ChargeFormState extends State<_ChargeForm> {
  late final TextEditingController _name;
  late final TextEditingController _value;
  late ChargeMode _mode;

  bool get _fee => widget.view.fee;

  @override
  void initState() {
    super.initState();
    final e = widget.view.existing?.line;
    final p = widget.view.preset;
    _name = TextEditingController(text: e?.name ?? p?.name ?? '');
    _mode = e != null ? (e.percent != null ? ChargeMode.percent : ChargeMode.amount) : (p?.mode ?? ChargeMode.percent);
    final v = e != null ? (e.percent ?? e.rate) : p?.value;
    _value = TextEditingController(text: v == null ? '' : (_mode == ChargeMode.percent ? SalesTax.rateText(v) : _money(v)));
  }

  static String _money(double v) => centsMoney((v * 100).round()).replaceFirst(r'$', '');

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  double? get _v => _mode == ChargeMode.percent ? parsePercent(_value.text) : parseMoney(_value.text);
  bool get _valueOk {
    final v = _v;
    if (v == null || v <= 0) return false;
    return _mode == ChargeMode.percent ? v <= 100 : v <= kMaxLineRate;
  }

  String get _n => _name.text.trim();

  /// What it comes to on this record now.
  int? get _cents {
    final v = _v;
    if (v == null || !_valueOk) return null;
    final s = widget.page._s;
    if (_mode == ChargeMode.amount) return (v * 100).round();
    final others = s.discountCents - (widget.view.existing != null && !_fee ? widget.view.existing!.amountCents.abs() : 0);
    return percentOf(_fee ? s.itemsCents - others : s.itemsCents, v);
  }

  void _submit() {
    if (!_valueOk || _n.isEmpty) return;
    final v = _v!;
    final e = widget.view.existing;
    final kind = _fee ? LineKind.fee : LineKind.discount;
    final pct = _mode == ChargeMode.percent ? v : null;
    final rate = _mode == ChargeMode.amount ? v : null;
    if (e == null) {
      widget.page._finish(AddCharge(LineDraft(kind: kind, name: _n, quantity: 1, rate: rate, percent: pct, source: 'manual')));
    } else {
      widget.page._finish(UpdateCharge(e.uid, e.line.copyWith(name: _n, rate: rate, percent: pct)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.page;
    final s = p._s;
    final what = _fee ? 'fee' : 'discount';
    final typed = _value.text.trim().isNotEmpty;
    final cents = _cents;
    final base = _fee ? s.itemsCents - s.discountCents : s.itemsCents;
    // The percent as the panel writes rates, not as typed (audit item 73: "10%%", "1,5%").
    final pct = cents == null || _mode != ChargeMode.percent ? '' : SalesTax.rateText(_v!);
    final preview = cents == null
        ? null
        : _fee
        ? 'Adds ${centsMoney(cents)}${_mode == ChargeMode.percent ? ' ($pct% of ${centsMoney(base)}, the items less discounts)' : ''}.'
        : 'Takes ${centsMoney(cents)} off${_mode == ChargeMode.percent ? ' ($pct% of ${centsMoney(base)} in items)' : ' the items'}.';
    // An empty name says so once something has been typed (audit item 83: Add was greyed out with no reason given).
    final nameMissing = _n.isEmpty && (_name.text.isNotEmpty || typed);
    final v = _v;
    return _Form(
      title: widget.view.existing != null ? 'Change $what' : (widget.view.preset?.name ?? 'Custom $what'),
      sub: _fee ? 'Added to the total. Fees are never taxed.' : 'Taken off the total. It doesn\'t change the sales tax.',
      onBack: p._back,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('Name on the record'),
          _TextBox(
            controller: _name,
            hint: _fee ? 'What the fee is for' : 'What the discount is for',
            fieldKey: const ValueKey('charge-name'),
            label: 'Name of the $what',
            error: nameMissing,
            autofocus: widget.view.preset == null && widget.view.existing == null,
            onChanged: (_) => setState(() {}),
          ),
          if (nameMissing)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _Note('Enter a name for the $what.', icon: Icons.error_outline_rounded, tone: DashUi.redText),
            ),
          const SizedBox(height: 14),
          _label('Amount'),
          // Wraps the box under the choice in a narrow panel rather than overflowing (audit item 80: 360 px fixed).
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              SizedBox(
                width: 210,
                child: AppSegmentedLite(
                  value: _mode,
                  options: [(ChargeMode.percent, 'Percentage'), (ChargeMode.amount, 'Dollar amount')],
                  onChanged: (m) => setState(() {
                    if (m == _mode) return;
                    _mode = m;
                    _value.clear();
                  }),
                ),
              ),
              _ValueBox(
                controller: _value,
                percent: _mode == ChargeMode.percent,
                error: typed && !_valueOk,
                hint: _mode == ChargeMode.percent ? '0' : '0.00',
                fieldKey: const ValueKey('charge-value'),
                label: _mode == ChargeMode.percent ? 'Percentage of the $what' : 'Dollar amount of the $what',
                autofocus: widget.view.preset != null || widget.view.existing != null,
                onChanged: (_) => setState(() {}),
                onSubmitted: _submit,
              ),
            ],
          ),
          // One line kept for what it comes to (or what is wrong), so nothing below moves as it is typed.
          SizedBox(
            height: 28,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: typed && !_valueOk
                  ? Text(
                      _mode == ChargeMode.percent
                          ? 'Enter a percentage above 0% and up to 100%.'
                          // Too big says so (audit item 95: over $999,999.99 it said "above $0").
                          : (v != null && v > kMaxLineRate ? 'Enter an amount up to ${centsMoney((kMaxLineRate * 100).round())}.' : 'Enter an amount above \$0.'),
                      style: const TextStyle(fontSize: 12.5, color: DashUi.redText),
                    )
                  : Text(
                      preview ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: DashUi.ink, fontFeatures: [FontFeature.tabularFigures()]),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          _Note(
            _fee
                ? 'A percentage fee is worked out on the items less discounts, before tax. It is never taxed.'
                : 'A percentage discount is a percentage of the items. It comes off the total and never lowers the sales tax: tax is worked out line by line.',
          ),
        ],
      ),
      start: [
        if (widget.view.existing != null)
          _ghost('Remove $what', () => p._finish(RemoveCharge(widget.view.existing!.uid)), key: const ValueKey('remove-charge'), danger: true),
      ],
      end: [
        _ghost('Back', p._back),
        _primary(widget.view.existing != null ? 'Save' : 'Add $what', _valueOk && _n.isNotEmpty ? _submit : null, key: const ValueKey('save-charge')),
      ],
    );
  }
}

/// A small two-way choice in the panel's box look (40 px, one hairline, the chosen side ink on white): the same height
/// as the value box beside it.
class AppSegmentedLite<V> extends StatelessWidget {
  final V value;
  final List<(V, String)> options;
  final ValueChanged<V> onChanged;
  const AppSegmentedLite({super.key, required this.value, required this.options, required this.onChanged});

  @override
  Widget build(BuildContext context) => Container(
    height: CatalogSearchField.height,
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(8)),
    child: Row(
      children: [
        for (final o in options)
          Expanded(
            child: Semantics(
              button: true,
              selected: o.$1 == value,
              inMutuallyExclusiveGroup: true,
              child: InkWell(
                key: ValueKey('mode-${o.$2}'),
                onTap: () => onChanged(o.$1),
                borderRadius: BorderRadius.circular(6),
                mouseCursor: SystemMouseCursors.click,
                overlayColor: dashNoHoverOverlay, // no hover shading (audit item 88)
                splashFactory: NoSplash.splashFactory,
                child: AnimatedContainer(
                  duration: LineTable.motion(context, 140),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: o.$1 == value ? Colors.white : Colors.white.withValues(alpha: 0),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: o.$1 == value ? DashUi.line : DashUi.line.withValues(alpha: 0)),
                  ),
                  child: Text(
                    o.$2,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: o.$1 == value ? FontWeight.w700 : FontWeight.w600,
                      color: o.$1 == value ? DashUi.ink : DashUi.slate,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
