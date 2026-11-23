import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'config/access.dart';
import 'config/auth_session.dart';
import 'services/line_items_api.dart';
import 'widgets/app_dialog.dart';
import 'widgets/app_menu.dart';
import 'widgets/app_ribbon.dart';
import 'widgets/catalog_kit.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';
import 'widgets/focus_ring.dart';
import 'widgets/leave_guard.dart';
import 'widgets/line_table_style.dart';

/// Whether the signed-in person may change services: Team screen > Services Catalog > Update, plus Line Items & Costs >
/// View (rate lines keep hidden costs by position, so the server refuses edits from someone who can't see them).
bool canEditServices() => AuthSession.instance.can('services_catalog', AccessAction.update) && AuthSession.instance.can('line_items', AccessAction.view);

/// A service's own page (`/inventory/services/item?key=...`, the catalog key), built like the product page. Two parts:
///   SERVICE INFO  its name, category, status (Active / Inactive), sales tax and an optional description;
///   RATES         its own rate lines, like Service Fusion's rate editor: each with a name, optional description,
///                 quantity, regular rate and total, internal cost and total cost, and its own commission (USER RULE
///                 2026-11-19 late, reversing the service-level one: each rate line may pay differently): none, a
///                 percentage of the line's total, or a fixed amount for each one sold, always shown with what it pays.
///                 In edit mode the + button adds one. A package's rates are separate lines, none of them the "main"
///                 one (USER RULE 2026-11-20): on a job or estimate the package's name heads them and each rate is its
///                 own line under it, at its own quantity (usually 0, raised when the job needs it; the dispatch line
///                 1), with its own rate and commission.
///
/// A service has no record of its own in Service Fusion's sync (the catalog is rebuilt from the synced job lines), so
/// everything saved here goes to our own database (backend serviceOverrides.js). Service Fusion is never changed.
List<RouteBase> serviceDetailRoutes() => [
  GoRoute(
    path: 'item',
    // Leaving with typed-in changes asks first (the page registers with LeaveGuard).
    onExit: (context, state) => LeaveGuard.confirm(),
    builder: (context, state) {
      final key = state.uri.queryParameters['key'] ?? '';
      return ServiceDetailScreen(key: ValueKey('service-$key'), serviceKey: key, initial: state.extra is CatalogEntry ? state.extra as CatalogEntry : null);
    },
  ),
];

/// The service categories (USER RULE 2026-11-19): the only ones a service can be put in.
const kServiceCategories = [
  'High Volume Builders',
  'Commercial Installations',
  'Commercial Services',
  'Operator Services',
  'Operator Installations',
  'Residential Installations',
  'Service Packages',
];

/// Where a service's page lives.
String serviceLocation(String key) => Uri(path: '/inventory/services/item', queryParameters: {'key': key}).toString();

/// The service a page just saved or reset, so the Services Catalog list shows it without reloading.
final serviceChanged = ValueNotifier<CatalogEntry?>(null);

class ServiceDetailScreen extends StatefulWidget {
  final String serviceKey;

  /// The row that was clicked, so the page shows at once (it is then read fresh from the server).
  final CatalogEntry? initial;

  /// Tests pass fakes; the app talks to the backend.
  final Future<({List<CatalogEntry> entries, bool canSeeCost, int historyDays})> Function()? loader;
  final Future<CatalogEntry> Function(String key, Map<String, dynamic> fields)? saver;
  final Future<CatalogEntry> Function(String key, List<ServiceRate> rates)? ratesSaver;

  const ServiceDetailScreen({super.key, required this.serviceKey, this.initial, this.loader, this.saver, this.ratesSaver});

  @override
  State<ServiceDetailScreen> createState() => _ServiceDetailScreenState();
}

/// One rate line being edited: its boxes and switches.
class _RateDraft {
  final TextEditingController name, description, qty, rate, cost, commission;
  String commissionType; // fixed | percent

  /// A rate pays commission when its box holds an amount (the % / $ toggle says what the amount is; empty is none).
  bool get paysCommission => commission.text.trim().isNotEmpty;
  final Key key = UniqueKey();

  /// The commission's amount box, so choosing a kind can put the keyboard straight in it.
  final FocusNode commissionFocus = FocusNode(debugLabel: 'rate commission');

  /// The line's description box is open under its name (the Products & Services table's "Description" toggle).
  bool descOpen = false;

  /// The name box, so Add rate can put the keyboard in the new line (UX audit 2026-11-20: it stayed on the page).
  final FocusNode nameFocus = FocusNode(debugLabel: 'rate name');

  /// The other boxes' focus: each box draws its own focused edge from it, and the figures are tidied as it leaves.
  final FocusNode descFocus = FocusNode(debugLabel: 'rate description');
  final FocusNode qtyFocus = FocusNode(debugLabel: 'rate quantity');
  final FocusNode rateFocus = FocusNode(debugLabel: 'rate regular rate');
  final FocusNode costFocus = FocusNode(debugLabel: 'rate internal cost');

  _RateDraft(ServiceRate r)
    : name = TextEditingController(text: r.name),
      description = TextEditingController(text: r.description),
      // A whole quantity reads "2", as it does on the page, not "2.00" (UX audit 2026-11-19).
      qty = TextEditingController(text: r.qty == r.qty.roundToDouble() ? r.qty.toStringAsFixed(0) : _num(r.qty)),
      rate = TextEditingController(text: _num(r.rate)),
      cost = TextEditingController(text: _num(r.cost)),
      // A whole percentage reads "20", not "20.00"; a fixed amount keeps its cents.
      commission = TextEditingController(
        text: !r.paysCommission
            ? ''
            : r.commissionType == 'percent' && r.commissionValue != null && r.commissionValue == r.commissionValue!.roundToDouble()
            ? r.commissionValue!.toStringAsFixed(0)
            : _num(r.commissionValue),
      ),
      commissionType = r.commissionType ?? 'percent';

  static String _num(double? v) => v == null ? '' : v.toStringAsFixed(2);

  List<TextEditingController> get boxes => [name, description, qty, rate, cost, commission];

  void dispose() {
    for (final c in boxes) {
      c.dispose();
    }
    for (final f in [commissionFocus, nameFocus, descFocus, qtyFocus, rateFocus, costFocus]) {
      f.dispose();
    }
  }

  /// A figure as the page writes it, once its box is left: "395" becomes "395.00", "2.0" becomes "2", a whole
  /// percentage stays whole. Left alone when it isn't a number (its box says so).
  void tidy(TextEditingController c) {
    final v = parse(c.text);
    if (v == null || v.isNaN) return;
    final whole = c == qty || (c == commission && commissionType == 'percent');
    final t = whole ? (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2)) : v.toStringAsFixed(2);
    if (t != c.text) c.text = t;
  }

  /// null = the box is empty; double.nan = not an amount.
  static double? parse(String text) {
    final t = text.replaceAll(RegExp(r'[\$,%\s]'), '');
    if (t.isEmpty) return null;
    final v = double.tryParse(t);
    return v == null || v < 0 || v > 10000000 ? double.nan : (v * 100).round() / 100;
  }

  ServiceRate toRate() => ServiceRate(
    name: name.text.trim().replaceAll(RegExp(r'\s+'), ' '),
    description: description.text.trim(),
    qty: parse(qty.text) ?? 1,
    rate: parse(rate.text),
    cost: parse(cost.text),
    paysCommission: paysCommission,
    commissionType: paysCommission ? commissionType : null,
    commissionValue: paysCommission ? parse(commission.text) : null,
  );
}

class _ServiceDetailScreenState extends State<ServiceDetailScreen> {
  CatalogEntry? _s;
  bool _canSeeCost = false;
  bool _loading = true;
  String? _error;
  int? _errorStatus;

  bool _editing = false;
  bool _saving = false;
  String? _saveError;
  Map<String, String> _errors = const {};

  /// The other services' names (folded), so a rename can't take a name another service already has.
  Map<String, String> _otherNames = const {};

  /// Someone saved this service while it was being edited here: their version (nothing is saved until the person
  /// decides, see [_conflictNotice]).
  CatalogEntry? _conflict;

  final _name = TextEditingController();
  final _description = TextEditingController();
  String _category = '';
  bool _taxable = false;
  bool _active = true;
  List<_RateDraft> _rates = [];
  VoidCallback? _unguard;

  /// The page's own focus, so Esc and Ctrl+S still reach it when the button just pressed (Edit, Save) is gone.
  final _pageFocus = FocusNode(debugLabel: 'service page');

  /// + Add rate, where the keyboard goes when the rate it was on is removed.
  final _addRateFocus = FocusNode(debugLabel: 'add rate');

  bool get _canEdit => canEditServices();

  @override
  void initState() {
    super.initState();
    for (final c in [_name, _description]) {
      c.addListener(_typed);
    }
    final first = widget.initial;
    if (first != null && first.key == widget.serviceKey) {
      _s = first;
      _canSeeCost = AuthSession.instance.can('line_items', AccessAction.view);
      _loading = false;
      _fill(first);
    }
    _unguard = LeaveGuard.register(canLeave: _confirmLeave, holdsWork: () => mounted && _editing && _changed);
    _load();
  }

  @override
  void dispose() {
    _unguard?.call();
    _pageFocus.dispose();
    _addRateFocus.dispose();
    _name.dispose();
    _description.dispose();
    for (final r in [..._rates, ..._retired]) {
      r.dispose();
    }
    super.dispose();
  }

  void _typed() {
    if (!mounted || !_editing) return;
    setState(() {
      // After a Save found problems, each one clears as soon as it is put right (no new ones are raised while typing).
      if (_errors.isNotEmpty) {
        final now = _check();
        _errors = {
          for (final e in _errors.entries) e.key: ?now[e.key],
        };
      }
    });
  }

  static String _groupOf(CatalogEntry s) => (s.group.isEmpty ? s.category : s.group).trim();

  void _fill(CatalogEntry s) {
    _name.text = s.name;
    _category = _groupOf(s);
    _description.text = s.description;
    _taxable = s.taxable;
    _active = s.active;
    _setRates(s.rates);
  }

  /// Drafts just replaced or removed. Their boxes can still be on screen for a moment (the read/edit cross-fade keeps the
  /// outgoing boxes while it fades), so they are disposed at the next replacement or with the page, never at once:
  /// disposing them at once let a box that rebuilt during the fade use a disposed controller (found 2026-11-19).
  List<_RateDraft> _retired = [];

  void _retire(Iterable<_RateDraft> drafts) {
    for (final r in _retired) {
      r.dispose();
    }
    _retired = drafts.toList();
  }

  void _setRates(List<ServiceRate> rates) {
    _retire(_rates);
    _rates = [for (final r in rates) _newDraft(r)];
  }

  _RateDraft _newDraft(ServiceRate r) {
    final d = _RateDraft(r);
    for (final c in d.boxes) {
      c.addListener(_typed);
    }
    for (final (node, ctl) in [(d.qtyFocus, d.qty), (d.rateFocus, d.rate), (d.costFocus, d.cost), (d.commissionFocus, d.commission)]) {
      node.addListener(() {
        if (!node.hasFocus && mounted && _editing && _rates.contains(d)) d.tidy(ctl);
      });
    }
    return d;
  }

  Future<void> _load() async {
    setState(() {
      _loading = _s == null;
      _error = null;
    });
    try {
      final r = await (widget.loader ?? () => LineItemsApi.listCatalog(kind: 'service', includeInactive: true))();
      if (!mounted) return;
      final found = r.entries.where((e) => e.key == widget.serviceKey).firstOrNull;
      if (found == null) throw const LineItemsException('It may have been renamed, or not used in the last 18 months.', status: 404);
      setState(() {
        _s = found;
        _canSeeCost = r.canSeeCost;
        _loading = false;
        _error = null;
        _otherNames = _namesBesides(r.entries);
        if (!_editing) _fill(found);
      });
    } on LineItemsException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
        _errorStatus = e.status;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load the service.';
        _errorStatus = null;
      });
    }
  }

  // ---- what changed -------------------------------------------------------------

  /// What to send for [field]: nothing when unchanged, null when it is back to what the job lines say (the edit is
  /// dropped), the new value otherwise.
  void _diff(Map<String, dynamic> out, String field, Object? now, Object? shown) {
    if (now == shown) return;
    final s = _s!;
    final original = s.computed != null ? s.computed![field] : shown;
    out[field] = now == original ? null : now;
  }

  Map<String, dynamic> _infoChanges() {
    final s = _s!;
    final out = <String, dynamic>{};
    _diff(out, 'name', _name.text.trim().replaceAll(RegExp(r'\s+'), ' '), s.name);
    _diff(out, 'category', _category, _groupOf(s));
    _diff(out, 'description', _description.text.trim(), s.description.trim());
    _diff(out, 'taxable', _taxable, s.taxable);
    _diff(out, 'active', _active, s.active);
    // No service-level commission any more: it is on each rate (USER RULE 2026-11-19 late). The service's own
    // commission field is left as it is (prod had none set when it moved).
    return out;
  }

  List<ServiceRate> get _draftRates => [for (final d in _rates) d.toRate()];

  bool get _ratesChanged {
    final now = _draftRates, was = _s!.rates;
    if (now.length != was.length) return true;
    for (var i = 0; i < now.length; i++) {
      if (now[i] != was[i]) return true;
    }
    return false;
  }

  bool get _changed => _s != null && _editing && (_infoChanges().isNotEmpty || _ratesChanged);

  /// A name as the catalog matches it: case, spaces and the "|" separators' spacing don't make two names different.
  static String _foldName(String s) => s.toLowerCase().replaceAll(RegExp(r'\s*\|\s*'), '|').replaceAll(RegExp(r'\s+'), ' ').trim();

  Map<String, String> _namesBesides(List<CatalogEntry> entries) => {
    for (final e in entries)
      if (e.key != widget.serviceKey) _foldName(e.name): e.name,
  };

  Map<String, String> _check() {
    final errors = <String, String>{};
    final name = _name.text.trim();
    if (name.isEmpty) {
      errors['name'] = 'The name cannot be empty.';
    } else if (_foldName(name) != _foldName(_s!.name)) {
      // Two services with one name could not be told apart in the add-line picker.
      final taken = _otherNames[_foldName(name)];
      if (taken != null) errors['name'] = 'Another service is already called "$taken".';
    }
    for (var i = 0; i < _rates.length; i++) {
      final d = _rates[i];
      bool bad(TextEditingController c) => _RateDraft.parse(c.text)?.isNaN ?? false;
      if (d.name.text.trim().isEmpty) errors['rate$i.name'] = 'Give the rate a name.';
      // The server's limits (src/serviceOverrides.js), checked here so a long name can't save the info and then fail
      // the rates (the save is two requests; audit round 2, 2026-11-20).
      if (d.name.text.trim().length > 200) errors['rate$i.name'] = 'Keep the name to 200 characters.';
      if (d.description.text.trim().length > 2000) errors['rate$i.description'] = 'Keep the description to 2,000 characters.';
      // An empty quantity used to save as 1, so the line then went onto every job at 1 (only the dispatch line starts
      // there: USER RULE 2026-11-20). It has to be typed: 0 for a line a job adds when it needs it.
      if (d.qty.text.trim().isEmpty) {
        errors['rate$i.qty'] = 'Enter a quantity (0 if a job adds it when needed).';
      } else if (bad(d.qty)) {
        errors['rate$i.qty'] = 'Enter a number.';
      }
      if (bad(d.rate)) errors['rate$i.rate'] = 'Enter an amount.';
      if (_canSeeCost && bad(d.cost)) errors['rate$i.cost'] = 'Enter an amount.';
      // A rate that pays commission says how much (the same rules as the server: 0 or more, a percentage 100 at most).
      if (_canSeeCost && d.paysCommission) {
        final v = _RateDraft.parse(d.commission.text);
        final percent = d.commissionType == 'percent';
        if (v == null || v.isNaN) {
          errors['rate$i.commission'] = 'Enter a number, like 5 or 2.50.';
        } else if (percent && v > 100) {
          errors['rate$i.commission'] = 'A percentage is 100 at most.';
        }
      }
    }
    return errors;
  }

  // ---- saving -------------------------------------------------------------------

  void _done(CatalogEntry saved, String message) {
    setState(() {
      _s = saved;
      _saving = false;
      _editing = false;
      _errors = const {};
      _conflict = null;
      _fill(saved);
    });
    serviceChanged.value = saved;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2), behavior: SnackBarBehavior.floating, width: 300));
  }

  String _failText(Object e, String fallback) {
    if (e is LineItemsException) {
      return e.status == 404 || e.status == 405 ? 'The server does not have this yet. Try again in a few minutes.' : e.message;
    }
    return fallback;
  }

  /// What a person saved about a service, as one string: two reads that differ here were saved in between. Only what a
  /// person set counts (and when, and the rates): a field nobody edited follows the synced job lines, which move on their
  /// own as the catalog is rebuilt (the newest line's description, a vote on taxable), and raised "someone else saved
  /// this" when nobody had (audit round 2, 2026-11-20).
  static String _fingerprint(CatalogEntry e) {
    final edited = e.editedFields.toSet();
    String mine(String field, Object? value) => edited.contains(field) ? '$field=$value' : '';
    return [
      mine('name', e.name),
      mine('category', _groupOf(e)),
      mine('description', e.description.trim()),
      mine('taxable', e.taxable),
      mine('active', e.active),
      e.commission?.type ?? '',
      e.commission?.value ?? '',
      e.editedAt ?? '',
      for (final r in e.rates) r.toJson(withCost: true).toString(),
    ].join('\u0001');
  }

  /// The service as the server has it now, or null when that can't be read (the save then goes ahead as before).
  Future<CatalogEntry?> _freshCopy() async {
    try {
      final r = await (widget.loader ?? () => LineItemsApi.listCatalog(kind: 'service', includeInactive: true))();
      _otherNames = _namesBesides(r.entries);
      return r.entries.where((e) => e.key == widget.serviceKey).firstOrNull;
    } catch (_) {
      return null;
    }
  }

  /// Saves the changes. First it reads the service again: when someone else saved it meanwhile, nothing is sent and
  /// the page says so ([_conflict]), unless [overTheirs] (the person chose to save theirs over it).
  Future<void> _save({bool overTheirs = false}) async {
    if (_saving || _s == null) return;
    final errors = _check();
    setState(() => _errors = errors);
    if (errors.isNotEmpty) return;
    if (_infoChanges().isEmpty && !_ratesChanged) {
      setState(() => _editing = false);
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
      _conflict = null;
    });
    if (!overTheirs) {
      final fresh = await _freshCopy();
      if (!mounted) return;
      if (fresh != null && _fingerprint(fresh) != _fingerprint(_s!)) {
        setState(() {
          _saving = false;
          _conflict = fresh;
        });
        return;
      }
      // A name taken meanwhile is caught too (the list was read again).
      final again = _check();
      if (again.isNotEmpty) {
        setState(() {
          _saving = false;
          _errors = again;
        });
        return;
      }
    }
    final info = _infoChanges();
    final rates = _ratesChanged ? _draftRates : null;
    final key = _s!.key;
    CatalogEntry? saved;
    try {
      if (info.isNotEmpty) saved = await (widget.saver ?? LineItemsApi.saveService)(key, info);
      if (rates != null) {
        saved = await (widget.ratesSaver ?? (k, r) => LineItemsApi.saveServiceRates(k, r, withCost: _canSeeCost))(key, rates);
      }
      if (!mounted) return;
      _done(saved!, 'Saved');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        // The info may have saved before the rates failed: keep what was saved, and the typed rates to try again.
        if (saved != null) _s = saved;
        _saveError = _failText(e, 'Could not save the service. Try again.');
      });
    }
  }

  /// Leaving the page with changes asks first. Discard also drops the changes: the page stays alive behind the other
  /// tabs (the shell's indexed stack), so a kept draft would ask again on every later page change (bug 2026-11-20).
  Future<bool> _confirmLeave() async {
    if (!mounted || !_editing || !_changed) return true;
    if (!await _askDiscard()) return false;
    if (mounted) setState(_dropEdits);
    return true;
  }

  Future<bool> _askDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        title: 'Discard your changes?',
        subtitle: 'This service has changes that are not saved.',
        icon: Icons.edit_off_rounded,
        width: 460,
        body: const Text('If you leave now they are lost.', style: TextStyle(fontSize: 14, color: DashUi.slate)),
        actions: [
          // Opens on the safe answer: Enter keeps the work (UX audit 2026-11-20: nothing had the keyboard).
          AppButton.ghost('Keep editing', () => Navigator.pop(ctx, false), autofocus: true),
          AppButton.ink('Discard changes', () => Navigator.pop(ctx, true), danger: true),
        ],
      ),
    );
    return discard == true;
  }

  Future<void> _cancelEdit() async {
    if (_changed && !await _askDiscard()) return;
    if (!mounted) return;
    setState(_dropEdits);
  }

  /// Back to reading the service as saved (call inside setState).
  void _dropEdits() {
    _editing = false;
    _saveError = null;
    _errors = const {};
    _conflict = null;
    if (_s != null) _fill(_s!);
  }

  /// Someone else's save landed while this page was editing: take theirs (dropping what was typed here), or save these
  /// changes over it. Either way the page now builds on their version.
  void _useTheirs() {
    final theirs = _conflict;
    if (theirs == null) return;
    setState(() {
      _s = theirs;
      _conflict = null;
      _editing = false;
      _errors = const {};
      _fill(theirs);
    });
    serviceChanged.value = theirs;
  }

  /// Only what was changed here goes over their version: a field this page did not touch keeps their value.
  void _saveOverTheirs() {
    final theirs = _conflict;
    if (theirs == null) return;
    final mine = _infoChanges(); // against the version this page started from
    final myRates = _ratesChanged ? _draftRates : null;
    final now = (name: _name.text, category: _category, description: _description.text, taxable: _taxable, active: _active);
    setState(() {
      _s = theirs;
      _conflict = null;
      _fill(theirs);
      if (mine.containsKey('name')) _name.text = now.name;
      if (mine.containsKey('category')) _category = now.category;
      if (mine.containsKey('description')) _description.text = now.description;
      if (mine.containsKey('taxable')) _taxable = now.taxable;
      if (mine.containsKey('active')) _active = now.active;
      if (myRates != null) _setRates(myRates); // the rates (with their commissions) go as a whole set
    });
    _save(overTheirs: true);
  }

  /// The + button: a new rate line. The first one starts from the service itself (its name, description, price, cost).
  void _addRate() {
    final s = _s!;
    if (!_editing) return;
    setState(() {
      _rates = [
        ..._rates,
        _newDraft(
          // The first starts from the service itself, at 1; each later one blank, at 0 (a package's other lines go on a
          // job at 0 and are raised when the job needs them: USER RULE 2026-11-20).
          _rates.isEmpty ? ServiceRate(name: s.name, description: s.description, rate: s.rate, cost: _canSeeCost ? s.cost : null) : const ServiceRate(name: '', qty: 0),
        ),
      ];
    });
    // The keyboard goes into the new line's name box, as a spreadsheet's new row would take it.
    final added = _rates.last;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _rates.contains(added)) added.nameFocus.requestFocus();
    });
  }

  void _removeRate(int i) {
    // Was the keyboard in the line going away (its remove button, or one of its boxes)? Then it moves to + Add rate
    // rather than falling back to the page.
    final focus = FocusManager.instance.primaryFocus;
    final hadFocus = focus != null && (focus.context?.findAncestorWidgetOfExactType<_RateLine>()?.index == i);
    setState(() {
      _retire([_rates.removeAt(i)]);
      _rates = [..._rates];
      _errors = {
        for (final e in _errors.entries)
          if (!e.key.startsWith('rate')) e.key: e.value,
      };
    });
    if (hadFocus) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _addRateFocus.requestFocus() : null);
  }

  void _toList() {
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      router.go('/inventory/services');
    } else {
      Navigator.maybePop(context);
    }
  }

  void _shortcutSave() {
    if (_editing && !_saving && _changed) _save();
  }

  // ---- build --------------------------------------------------------------------
  //
  // The page (redesign 2026-11-19 evening): one header for both modes (the name, its status and category, who changed
  // it last; editing adds an ink rule, an "Editing" chip and whether anything is unsaved), then two sections on white:
  //   Service information  a property sheet (label column, values two to a row, hairlines between rows). Edit turns
  //                        each value into its box in the same place, so nothing moves when editing starts.
  //   Rates                a table with the same columns read and edited; edited, every cell is a compact box and the
  //                        commission a small No / % / $ switch with its amount. Too narrow for the table (a small
  //                        window, large text), each rate stacks instead.

  static const _maxContent = 1440.0;

  /// The text size the person has set (1 = 100%), for widths that must grow with the text.
  double get _scale => MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.4);

  bool _wasEditing = false;

  /// The service's category when it is in one of [kServiceCategories], else ''.
  static String _categoryOf(CatalogEntry s) {
    final g = _groupOf(s);
    return kServiceCategories.contains(g) ? g : '';
  }

  @override
  Widget build(BuildContext context) {
    final category = _s == null ? '' : _categoryOf(_s!);
    if (_editing != _wasEditing) {
      _wasEditing = _editing;
      // The Edit / Save / Cancel button just pressed is gone: keep the keys on the page.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final focused = FocusManager.instance.primaryFocus;
        if (mounted && (focused == null || !_ownsFocus(focused))) _pageFocus.requestFocus();
      });
    }
    return Scaffold(
      backgroundColor: Colors.white,
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): _shortcutSave,
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _shortcutSave,
          const SingleActivator(LogicalKeyboardKey.escape): _shortcutCancel,
        },
        child: Focus(
          focusNode: _pageFocus,
          autofocus: true,
          // A click on the page's background (not a box or button) keeps the keyboard on the page, so Ctrl+S and Esc
          // still work (found in the real browser 2026-11-19: the click took focus off the page and the keys died).
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => WidgetsBinding.instance.addPostFrameCallback((_) {
              final f = FocusManager.instance.primaryFocus;
              if (mounted && (f == null || !_ownsFocus(f))) _pageFocus.requestFocus();
            }),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppRibbon(
                  // "SERVICE PACKAGE", not "SERVICE  SERVICE PACKAGES" (title then category): the category says the
                  // kind already (audit round 2, 2026-11-20). Other categories read "SERVICE  OPERATOR INSTALLATIONS".
                  title: category.toLowerCase() == 'service packages' ? 'SERVICE PACKAGE' : 'SERVICE',
                  kind: category.isEmpty || category.toLowerCase() == 'service packages' ? null : category.toUpperCase(),
                  icon: accessIcon('services_catalog'),
                  compactSide: 16,
                  controls: _controls(),
                ),
                Expanded(child: PageSheet(child: _body())),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Whether [node] is this page's focus or inside it (a box being typed in).
  bool _ownsFocus(FocusNode node) => node == _pageFocus || node.ancestors.contains(_pageFocus);

  void _shortcutCancel() {
    if (_editing && !_saving) _cancelEdit();
  }

  List<Widget> _controls() {
    const gap = SizedBox(width: 8);
    // On a phone-narrow window the three ribbon buttons only fit with the short label.
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final back = RibbonGhostButton(icon: Icons.arrow_back_rounded, label: narrow ? 'Back' : 'All services', onPressed: () => LeaveGuard.leave(_toList));
    if (_s == null) return [back];
    if (_editing) {
      return [
        RibbonGhostButton(icon: Icons.close_rounded, label: 'Cancel', onPressed: _saving ? null : _cancelEdit),
        gap,
        PageBanner.button(icon: Icons.check_rounded, label: _saving ? 'Saving...' : 'Save', onPressed: _saving || !_changed ? null : _save),
      ];
    }
    return [
      back,
      if (_canEdit) ...[gap, PageBanner.button(icon: Icons.edit_rounded, label: 'Edit', onPressed: _saving ? null : () => setState(() => _editing = true))],
    ];
  }

  Widget _body() {
    if (_loading) return const _ServiceSkeleton();
    if (_error != null && _s == null) {
      final gone = _errorStatus == 404;
      final denied = _errorStatus == 403;
      return Center(
        child: FlatEmpty(
          icon: gone ? Icons.search_off_rounded : (denied ? Icons.lock_outline_rounded : Icons.cloud_off_rounded),
          title: gone ? 'That service is not in the catalog' : (denied ? "You don't have access to the Services Catalog" : 'Could not load the service'),
          message: denied ? 'Ask an admin to turn it on in Team.' : _error!,
          action: gone || denied ? AppButton.ink('Back to the catalog', _toList) : AppButton.ink('Try again', _load),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        final width = c.maxWidth.clamp(0.0, _maxContent);
        final side = width < 600 ? 16.0 : 28.0;
        final inner = width - side * 2;
        // The product page's layout (redesign 2026-11-20, the user: "not up to par with other screens"): the service on
        // the left, its status and tax in a rail on the right, the rates across the whole width under both.
        final two = inner >= 900;
        final rail = (inner * 0.32).clamp(320.0, 420.0);
        Widget band(Widget child) => Center(
          child: SizedBox(width: width, child: child),
        );
        // One traversal group each, so Tab finishes the form before the rail's switches (by height alone it went from
        // Category to Active and from Description straight to Add rate).
        final main = FocusTraversalGroup(child: _editing ? _editMain() : _readMain());
        final railBody = FocusTraversalGroup(child: _editing ? _editRail() : _readRail());
        final columns = two
            ? Stack(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(right: _columnGap),
                          child: main,
                        ),
                      ),
                      SizedBox(
                        width: rail,
                        child: Padding(
                          padding: const EdgeInsets.only(left: _columnGap),
                          child: railBody,
                        ),
                      ),
                    ],
                  ),
                  // The rail's edge runs the full height of the two columns, however long either one is.
                  Positioned(
                    top: 22,
                    bottom: 0,
                    right: rail,
                    child: const SizedBox(width: 1, child: ColoredBox(color: DashUi.line)),
                  ),
                ],
              )
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [main, railBody]);
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // A refresh that failed while the service was already on show: say the page may be out of date.
              if (_error != null && !_editing) FlatStaleNotice(message: 'Could not refresh. This may be out of date.', busy: _loading, onRetry: _load),
              if (_conflict != null) band(_conflictNotice(side)),
              if (_saveError != null || _errors.isNotEmpty) band(_notice(side)),
              _header(band, side),
              band(
                Padding(
                  padding: EdgeInsets.fromLTRB(side, 0, side, 32),
                  // Read and edit cross-fade (instantly with reduced motion); both share one layout.
                  child: AnimatedSwitcher(
                    duration: CatalogUi.motion(context, 160),
                    switchInCurve: Curves.easeOutCubic,
                    layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
                    child: KeyedSubtree(
                      key: ValueKey(_editing),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          columns,
                          _section('RATES', _editing ? _ratesEdit(inner) : _ratesRead(inner), note: _rateNote(), top: 34),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static const double _columnGap = 28;

  /// The quiet words beside RATES: how many, and what a rate is (USER RULE 2026-11-20: no rate is the main one; each
  /// is its own line under the package, starting at its own quantity).
  String? _rateNote() {
    final n = _editing ? _rates.length : _s!.rates.length;
    if (n == 0) return null;
    return '${n == 1 ? '1 rate' : '$n rates'}. Each is its own line under the package on a job, starting at its qty.';
  }

  // ---- the product page's pieces: a section, a labelled field, a switch row (redesign 2026-11-20) ----

  /// A block: its small-caps label (with a quiet note), then its content.
  Widget _section(String label, Widget child, {String? note, double top = 20, Widget? trailing}) {
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CatalogLabel(label, note: note, trailing: trailing),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  /// A thin rule between the rail's blocks.
  Widget _rule() => const Padding(
    padding: EdgeInsets.only(top: 18),
    child: Divider(height: 1, color: DashUi.line),
  );

  /// A field with its label over it (every box on the page has one: the user, "no label for package name").
  Widget _labelled(String label, Widget field, {bool optional = false, String? help}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppFieldLabel(optional ? '$label (optional)' : label, help: help),
        field,
      ],
    );
  }

  /// A yes/no setting: its name and what it means, and a switch; the whole row is one control (click, or Tab to it
  /// and press Space or Enter). This replaced the two-button toggles ("tacky and bulky", the user 2026-11-20).
  ///
  /// [helpOn] and [helpOff] are what it means each way. Both are laid out, one shown: the row is as tall as the longer,
  /// so switching never moves what is under it (found in Chrome 2026-11-20: turning Active off wrapped its caption to a
  /// second line and pushed Sales tax down).
  Widget _switchRow({
    required String id,
    required String label,
    required String helpOn,
    required String helpOff,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final motion = CatalogUi.motion(context, 140);
    const helpStyle = TextStyle(fontSize: 13, height: 1.4, color: DashUi.slate);
    return Semantics(
      container: true,
      toggled: value,
      label: label,
      hint: value ? helpOn : helpOff,
      excludeSemantics: true,
      child: FocusRing(
        borderRadius: BorderRadius.circular(10),
        outset: const EdgeInsets.symmetric(horizontal: 6),
        child: InkWell(
          key: ValueKey('switch:$id'),
          borderRadius: BorderRadius.circular(10),
          onTap: _saving ? null : () => onChanged(!value),
          hoverColor: Colors.transparent,
          focusColor: Colors.transparent,
          splashFactory: NoSplash.splashFactory,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: DashUi.ink, height: 1.3),
                      ),
                      const SizedBox(height: 2),
                      Stack(
                        children: [
                          for (final on in const [true, false])
                            AnimatedOpacity(
                              opacity: on == value ? 1 : 0,
                              duration: motion,
                              child: Text(on ? helpOn : helpOff, style: helpStyle),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 20),
                // The row is the control: the switch itself takes no Tab stop of its own.
                ExcludeFocus(
                  child: CatalogSwitch(value: value, onChanged: _saving ? null : onChanged, compact: true),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- shared pieces ------------------------------------------------------------

  Widget _notice(double side) {
    final text = _saveError ?? (_errors.length == 1 ? 'One field needs a look before saving.' : '${_errors.length} fields need a look before saving.');
    return Padding(
      padding: EdgeInsets.fromLTRB(side, 14, side, 0),
      child: Semantics(
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: DashUi.red.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: DashUi.red.withValues(alpha: 0.25)),
          ),
          child: Row(
            children: [
              const Icon(Icons.error_outline_rounded, size: 18, color: DashUi.red),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: DashUi.ink),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _conflictNotice(double side) {
    final theirs = _conflict!;
    final at = DateTime.tryParse(theirs.editedAt ?? '')?.toLocal();
    final who = [if (theirs.editedBy != null) 'by ${theirs.editedBy}', if (at != null) 'at ${DateFormat('h:mm a').format(at)}'].join(' ');
    return Padding(
      padding: EdgeInsets.fromLTRB(side, 14, side, 0),
      child: Semantics(
        liveRegion: true,
        child: Container(
          key: const ValueKey('conflict-notice'),
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          decoration: BoxDecoration(
            color: DashUi.amber.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: DashUi.amber.withValues(alpha: 0.35)),
          ),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 8,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.group_outlined, size: 18, color: DashUi.amberText),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        'Someone else saved this service while you were editing${who.isEmpty ? '' : ' ($who)'}. Nothing of yours is saved yet.',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: DashUi.ink),
                      ),
                    ),
                  ],
                ),
              ),
              CatalogOutlineButton(label: 'Use their version', dense: true, onPressed: _useTheirs),
              CatalogOutlineButton(label: 'Save mine over it', dense: true, onPressed: _saveOverTheirs),
            ],
          ),
        ),
      ),
    );
  }

  /// Children [columns] to a row, [gap] apart, wrapping into further rows (the stacked rates).
  Widget _grid(List<Widget> children, {int columns = 2, double gap = 16, double runGap = 16}) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += columns) {
      final slice = children.sublist(i, (i + columns).clamp(0, children.length));
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var j = 0; j < columns; j++) ...[if (j > 0) SizedBox(width: gap), Expanded(child: j < slice.length ? slice[j] : const SizedBox())],
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++) ...[if (i > 0) SizedBox(height: runGap), rows[i]],
      ],
    );
  }

  /// A figure to read: its label, then the value (the stacked rates).
  Widget _value(String label, String value, {bool quiet = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: _smallLabel),
        const SizedBox(height: 3),
        Text(value, style: quiet ? CatalogUi.cellQuiet : CatalogUi.cellStrong),
      ],
    );
  }

  static const _smallLabel = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: DashUi.slate, height: 1.3);

  static String _money(double? v, [String none = '—']) => v == null ? none : dashMoney(v);

  static String _qty(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  // ---- boxes ---------------------------------------------------------------------

  /// What is typed in a box: the theme's font (so it matches the app), 14.5, ink.
  TextStyle _boxText({bool figures = false}) =>
      (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).merge(CatalogUi.fieldText).copyWith(fontFeatures: figures ? CatalogUi.figures : null);

  /// The service's own boxes (name, description) are the catalog's form box (catalogFieldDecoration, UX audit
  /// 2026-11-19; the product page's look, 2026-11-20): 40 px at any platform density, one edge, hover, focus and error
  /// look, a readable placeholder. The rates table draws its own boxes (see [_RateBox]).
  InputDecoration _box({String? hint, String? error}) => catalogFieldDecoration(
    hint: hint,
    error: error,
    enabled: !_saving,
    filled: true,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
  );

  /// A box for [ctl] in the service's own part of the page (its name, its description). [grow] lets it take up to that
  /// many lines as the text needs; [lines] makes it that tall from the start. [label] names it for screen readers.
  Widget _input(String key, TextEditingController ctl, {int lines = 1, int grow = 1, String? hint, String? label}) {
    final multi = lines > 1 || grow > 1;
    Widget field = TextField(
      key: ValueKey('field:$key'),
      controller: ctl,
      minLines: lines,
      maxLines: multi ? (lines > grow ? lines : grow) : 1,
      enabled: !_saving,
      textAlignVertical: multi ? TextAlignVertical.top : TextAlignVertical.center,
      cursorWidth: CatalogUi.cursorWidth,
      cursorRadius: CatalogUi.cursorRadius,
      style: _boxText(),
      keyboardType: multi ? TextInputType.multiline : TextInputType.text,
      decoration: _box(error: _errors[key], hint: hint),
    );
    if (label != null) field = Semantics(label: label, child: field);
    return field;
  }

  // ---- header (redesign 2026-11-20) ----------------------------------------------------
  //
  // Read: the name as the page's title, and under it its status, its category and who changed it last. Editing (as the
  // product page does): a pencil, "Editing <name>", what saving changes, and "Unsaved changes" once something is. The
  // name itself is edited in the form below, under its own label (it was an unlabelled box up here).

  static const _titleStyle = TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: DashUi.ink, letterSpacing: -0.3, height: 1.3);

  Widget _header(Widget Function(Widget) band, double side) {
    final s = _s!;
    final motion = CatalogUi.motion(context, 200);
    final Widget content;
    if (_editing) {
      final name = _name.text.trim().isEmpty ? s.name : _name.text.trim();
      content = Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: CatalogUi.picked, borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.edit_rounded, size: 18, color: DashUi.ink),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(text: 'Editing '),
                      catalogNameSpan(name, const TextStyle()),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: DashUi.ink, height: 1.3),
                ),
                const SizedBox(height: 2),
                const Text('Changes apply to new lines. Jobs and estimates already written keep theirs.', style: CatalogUi.meta),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Semantics(
            liveRegion: true,
            child: AnimatedOpacity(
              opacity: _changed ? 1 : 0,
              duration: motion,
              child: const CatalogTag('Unsaved changes', key: ValueKey('unsaved'), tone: CatalogTone.warn, icon: Icons.circle),
            ),
          ),
        ],
      );
    } else {
      final at = DateTime.tryParse(s.editedAt ?? '')?.toLocal();
      // A service with only its own rates has no who/when of its fields' edit: it still says it was changed.
      final String? changed = !s.isEdited
          ? null
          : (s.editedBy == null && at == null
                ? 'Changed by the office'
                : 'Last changed${s.editedBy == null ? '' : ' by ${s.editedBy}'}${at == null ? '' : ' on ${DateFormat('MMM d, yyyy').format(at)}'}');
      final category = _categoryOf(s);
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(catalogNameSpan(s.name, _titleStyle), maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              s.active ? const CatalogTag('Active', tone: CatalogTone.good) : const CatalogTag('Inactive'),
              if (!s.active) const Text(_inactiveNote, style: CatalogUi.meta),
              Text(
                category.isEmpty ? 'No category' : category,
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: category.isEmpty ? DashUi.slate : DashUi.ink),
              ),
              if (changed != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.history_rounded, size: 15, color: DashUi.subtle),
                    const SizedBox(width: 5),
                    Text(changed, style: CatalogUi.meta),
                  ],
                ),
            ],
          ),
        ],
      );
    }
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: DashUi.line)),
      ),
      child: band(
        Padding(
          padding: EdgeInsets.fromLTRB(side, 18, side, 16),
          child: AnimatedSwitcher(
            duration: CatalogUi.motion(context, 160),
            layoutBuilder: (current, previous) => Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
            child: KeyedSubtree(key: ValueKey(_editing), child: content),
          ),
        ),
      ),
    );
  }

  // ---- service information (redesign 2026-11-20) -------------------------------------
  //
  // As the product page lays a record out: on the left the service itself (its name, category and description, each
  // with its label over its box); in the rail on the right its status and sales tax, each a switch with its name and
  // what it means. Read, the same places hold the same things as text.

  static const _inactiveNote = 'Not offered on new lines. Jobs and estimates that have it keep it.';
  static const _activeNote = 'Offered when adding lines to jobs and estimates.';

  Widget _readText(String text, {bool quiet = false}) => Text(text, style: (quiet ? CatalogUi.cellQuiet : CatalogUi.cell).copyWith(height: 1.5));

  Widget _readMain() {
    final s = _s!;
    final description = s.description.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section('DESCRIPTION', _readText(description.isEmpty ? 'No description' : description, quiet: description.isEmpty)),
        if (s.supersededBy case final by?) _section('REPLACED BY', _readText(by.name)),
        if (s.replaces.isNotEmpty) _section('REPLACES', _readText(s.replaces.map((r) => r.name).join('\n'))),
      ],
    );
  }

  /// Read, the rail holds what the product page's does: the price (and cost, for those who may see it), then sales
  /// tax. The status is in the header, once.
  Widget _readRail() {
    final s = _s!;
    // A package (a service with rates) has no one price: what it comes to at its rates' starting quantities (the lines
    // at 0 add nothing until a job needs them). A service without rates keeps its own price.
    final package = s.rates.isNotEmpty;
    final priced = s.rates.where((r) => r.rate != null).toList();
    final double? price = !package ? s.rate : (priced.isEmpty ? null : priced.fold<double>(0, (sum, r) => sum + (r.total ?? 0)));
    final costed = s.rates.where((r) => r.cost != null).toList();
    final double? cost = !package ? s.cost : (costed.isEmpty ? null : costed.fold<double>(0, (sum, r) => sum + (r.totalCost ?? 0)));
    Widget figure(String label, String value, {bool big = false, bool quiet = false}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.ink, height: 1.3),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: big ? 26 : 16,
            fontWeight: big ? FontWeight.w700 : FontWeight.w600,
            color: quiet ? DashUi.slate : DashUi.ink,
            letterSpacing: big ? -0.4 : 0,
            height: 1.2,
            fontFeatures: CatalogUi.figures,
          ),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(
          'PRICE',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: figure(package ? 'Starts at' : 'Price', price == null ? 'No price' : dashMoney(price), big: price != null, quiet: price == null),
                  ),
                  if (_canSeeCost) Expanded(child: figure('Cost', cost == null ? 'Not entered' : dashMoney(cost), quiet: cost == null)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                package
                    ? 'Its lines at their starting quantities. A line at 0 adds to it when a job needs it.'
                    : (price == null ? 'New lines start without a price.' : 'What new lines start at.'),
                style: CatalogUi.meta,
              ),
            ],
          ),
        ),
        _rule(),
        _section('SALES TAX', _readText(s.taxWarning ?? (s.taxable ? 'Taxable' : 'No sales tax'))),
      ],
    );
  }

  /// Editing, the service itself: its name and category side by side (the name the wider: catalog names run long),
  /// its description under them across both. Too narrow for two, they stack.
  Widget _editMain() {
    final name = _labelled('Service name', _input('name', _name, hint: 'What the office and the techs call it', label: 'Service name'));
    final category = _labelled('Category', _categoryField());
    return _section(
      'SERVICE',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, c) => c.maxWidth >= 600
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 3, child: name),
                      const SizedBox(width: 16),
                      Expanded(flex: 2, child: category),
                    ],
                  )
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [name, const SizedBox(height: _fieldGap), category]),
          ),
          const SizedBox(height: _fieldGap),
          // Room to write (the user: "description box too slim"): three lines to start, growing to ten as it is typed.
          _labelled(
            'Description',
            _input('description', _description, lines: 3, grow: 10, hint: 'What the service includes', label: 'Description'),
            optional: true,
          ),
        ],
      ),
    );
  }

  /// Between one labelled field and the next.
  static const double _fieldGap = 14;

  Widget _editRail() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(
          'STATUS',
          _switchRow(id: 'active', label: 'Active', helpOn: _activeNote, helpOff: _inactiveNote, value: _active, onChanged: (v) => setState(() => _active = v)),
        ),
        _rule(),
        _section(
          'SALES TAX',
          _switchRow(
            id: 'taxable',
            label: 'Taxable',
            helpOn: 'Sales tax is added to this service on jobs and estimates.',
            helpOff: 'No sales tax is added to this service.',
            value: _taxable,
            onChanged: (v) => setState(() => _taxable = v),
          ),
        ),
      ],
    );
  }

  /// Category: one of the service categories (kServiceCategories), or No category. Picking No category drops the
  /// category edit, so the service is back to having none. Opening the page never changes it by itself.
  Widget _categoryField() {
    final s = _s!;
    final original = (s.computed != null ? (s.computed!['category'] ?? '') : _groupOf(s)).toString().trim();
    final options = <(String, String)>[
      for (final c in kServiceCategories) (c, c),
      if (!kServiceCategories.contains(original)) (original, 'No category'),
      if (_category != original && !kServiceCategories.contains(_category)) (_category, _category.isEmpty ? 'No category' : _category),
    ];
    // The shared select field (app_menu.dart, UX audit 2026-11-19): the old DropdownButtonFormField opened its list over
    // the field itself, cut it off at the top of the page and showed two grey rows at once.
    return AppSelectField<String>(
      key: const ValueKey('field:category'),
      value: _category,
      options: options,
      semanticLabel: 'Category',
      errorText: _errors['category'],
      quiet: (v) => !kServiceCategories.contains(v),
      filled: true,
      onChanged: _saving ? null : (v) => setState(() => _category = v),
    );
  }

  // ---- rates --------------------------------------------------------------------

  // ---- a rate's commission (USER RULE 2026-11-19 late: each rate line may pay differently) ----
  //
  // A commission never stands alone as a number (the user: "nobody would have any idea what this means"): it always
  // says what kind it is and what it pays on that line. A percentage is of the line's total (qty x regular rate); a
  // fixed amount is for each one sold, so a line of 2 pays it twice.

  /// What a commission pays on its line, or null while that can't be worked out.
  static double? _commissionPays(String type, double? value, {required double qty, required double? total}) {
    if (value == null || value.isNaN || qty.isNaN) return null;
    if (type == 'percent') return total == null || total.isNaN ? null : (total * value).round() / 100;
    return (value * qty * 100).round() / 100;
  }

  /// How the pay is worked out, in words: "5% of $395.00", "2 × $25.00", "for each one sold".
  static String _commissionBasis(String type, double value, {required double qty, required double? total}) {
    if (type == 'percent') return '${_qty(value)}% of ${total == null ? 'the total' : dashMoney(total)}';
    return qty == 1 ? 'for each one sold' : '${_qty(qty)} × ${dashMoney(value)}';
  }

  // ---- the rates table (redesign 2026-11-20 evening) ---------------------------------------------------------------
  //
  // The Products & Services table on the job and estimate pages (line_items_editor.dart) is the reference, and both
  // tables take their values from line_table_style.dart, so they can't drift: 12 px caps headings, 31 px white boxes
  // drawn by the table (one hairline, darker under the pointer, ink with a soft ring while typing in it), "$" inside the
  // money boxes, x and = between the quantity, the rate and the total, "Description" inside the name box, ⋮ at the end.
  // Read and edit share one column layout ([_RateCols]) and a value's text sits 8 px in from its column's edge either
  // way, so nothing moves when Edit is pressed.
  //
  // Every row is one line tall in both modes. A rate's commission is the % / $ switch and its amount box; PAYS, worked
  // out like TOTAL, is what it comes to on that line. Each part has a fixed width and the amount box keeps a fixed slot
  // at each end for its unit, so switching % and $ moves nothing. (It used to: the box's unit was Material's prefix /
  // suffix text, which keeps its room while hidden, so the box's "None" slid sideways on every switch; and the
  // "Pays ..." note under the box could wrap to a second line and make that row taller than the rest.)
  //
  // While editing, the row under the pointer is lit across its whole width, and the row being typed in keeps a tint
  // and an ink edge down its left side (the Products & Services table's open line).

  _RateCols get _cols => _RateCols(costs: _canSeeCost, k: _scale);

  /// The box fields of a rate, in the order they run, with the words a problem with each is said with.
  static const _rateFieldNames = {'name': '', 'description': 'Description', 'qty': 'Qty', 'rate': 'Regular rate', 'cost': 'Internal cost', 'commission': 'Commission'};

  /// Where the quantity's figure ends: in from its box's right edge past the arrows (read, the same place).
  static const double _qtyInset = _StepArrows.width + LineTable.cellX;

  /// A figure or a read value in a cell: as tall as a box, its text level with the boxes' and [inset] in from its side.
  Widget _cellText(String text, {bool right = true, TextStyle? style, double inset = LineTable.cellX, Key? key}) => SizedBox(
    height: LineTable.boxHeight(context),
    child: Align(
      alignment: right ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.only(left: right ? 0 : inset, right: right ? inset : 0),
        child: Text(
          text,
          key: key,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: style ?? (text == '—' ? LineTable.quiet : LineTable.cell),
        ),
      ),
    ),
  );

  /// The headings, each over where its column's text sits.
  Widget _tHeader(_RateCols cols) {
    Widget h(String s, {bool right = true, double inset = LineTable.cellX}) => Padding(
      padding: EdgeInsets.only(left: right ? 0 : inset, right: right ? inset : 0),
      child: Text(s, maxLines: 1, softWrap: false, overflow: TextOverflow.fade, textAlign: right ? TextAlign.right : TextAlign.left, style: LineTable.head),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(_RateCols.side, 10, _RateCols.side, 9),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: DashUi.line)),
      ),
      child: cols.line(
        cross: CrossAxisAlignment.center,
        item: h('RATE', right: false),
        qty: h('QTY', inset: _qtyInset),
        rate: h('REGULAR RATE'),
        total: h('TOTAL'),
        cost: h('INTERNAL COST'),
        totalCost: h('TOTAL COST'),
        commission: h('COMMISSION', right: false, inset: 0),
        pays: h('PAYS'),
      ),
    );
  }

  /// "Description" and its chevron: at the end of a rate's name box while editing, under its name when read. Bold when
  /// the rate has a description (so it can be told from one without, closed), quieter when it has none.
  Widget _descToggle({required bool open, required bool has, required VoidCallback onTap, required String id}) {
    return Semantics(
      button: true,
      expanded: open,
      label: open ? 'Hide the description' : (has ? 'Show the description' : 'Add a description'),
      excludeSemantics: true,
      child: FocusRing(
        borderRadius: BorderRadius.circular(5),
        child: InkWell(
          key: ValueKey(id),
          onTap: onTap,
          borderRadius: BorderRadius.circular(5),
          hoverColor: Colors.transparent,
          focusColor: Colors.transparent,
          highlightColor: Colors.transparent,
          splashFactory: NoSplash.splashFactory,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 2, 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Description',
                  style: TextStyle(fontSize: 12, fontWeight: has || open ? FontWeight.w600 : FontWeight.w500, color: has || open ? DashUi.ink : DashUi.slate, height: 1.2),
                ),
                AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: LineTable.motion(context, 160),
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

  /// x and = between the quantity, the rate and the total.
  Widget _sym(String s) => SizedBox(
    height: LineTable.boxHeight(context),
    child: Center(
      child: Text(s, style: const TextStyle(fontSize: 13, color: DashUi.subtle, height: 1.35)),
    ),
  );

  /// No rates: what the service is usually billed at, and how to add one. Editing, the Add rate box follows it.
  Widget _noRates({required bool edit}) {
    final usual = _s!.rate;
    final String? sub = edit
        ? (usual == null ? null : 'The first rate starts at its usual price, ${dashMoney(usual)}.')
        : [if (usual != null) 'Usually billed at ${dashMoney(usual)}.', if (_canEdit) 'Add one with Edit.'].join(' ');
    final box = Container(
      key: const ValueKey('no-rates'),
      padding: const EdgeInsets.symmetric(horizontal: _RateCols.side, vertical: 13),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: DashUi.line),
          bottom: BorderSide(color: DashUi.line),
        ),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            const TextSpan(
              text: 'No rates yet',
              style: TextStyle(fontWeight: FontWeight.w600, color: DashUi.ink),
            ),
            if (sub != null && sub.isNotEmpty)
              TextSpan(
                text: '   $sub',
                style: const TextStyle(color: DashUi.slate),
              ),
          ],
        ),
        style: LineTable.cell,
      ),
    );
    if (!edit) return box;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [box, _addRow()]);
  }

  /// Add rate under the table: an outlined box with a +, the Products & Services table's "Add a line" box, as tall as
  /// the boxes above it.
  Widget _addRow() => Padding(
    padding: const EdgeInsets.fromLTRB(_RateCols.side, 12, 0, 0),
    child: Align(
      alignment: Alignment.centerLeft,
      child: _AddRateButton(key: const ValueKey('add-rate'), focusNode: _addRateFocus, onPressed: _saving ? null : _addRate),
    ),
  );

  /// The read table's rates whose description is open (the "Description" toggle under the name).
  final Set<int> _readDescOpen = {};

  /// A saved rate's commission, read: what it is ("20%", "$10.00 each", "None") and what it pays on its line.
  static (String, String) _rateCommissionRead(ServiceRate r) {
    final type = r.commissionType;
    if (!r.paysCommission || type == null) return ('None', '—');
    final v = r.commissionValue;
    if (v == null) return (type == 'percent' ? 'Percent, not set' : 'Fixed, not set', '—');
    final pays = _commissionPays(type, v, qty: r.qty, total: r.total);
    return (type == 'percent' ? '${_qty(v)}%' : '${dashMoney(v)} each', pays == null ? '—' : dashMoney(pays));
  }

  Widget _ratesRead(double width) {
    final rates = _s!.rates;
    if (rates.isEmpty) return _noRates(edit: false);
    final cols = _cols;
    if (!cols.fits(width)) {
      // Stacked (a narrow window or large text): one block per rate, hairlines between.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rates.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                border: Border(
                  top: const BorderSide(color: DashUi.line),
                  bottom: i == rates.length - 1 ? const BorderSide(color: DashUi.line) : BorderSide.none,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Flexible(child: Text.rich(catalogNameSpan(rates[i].name, LineTable.name))),
                    ],
                  ),
                  if (rates[i].description.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(rates[i].description, style: LineTable.description.copyWith(color: DashUi.slate)),
                  ],
                  const SizedBox(height: 10),
                  _grid(
                    [
                      _value('Qty', _qty(rates[i].qty)),
                      _value('Regular rate', _money(rates[i].rate), quiet: rates[i].rate == null),
                      _value('Total', _money(rates[i].total), quiet: rates[i].total == null),
                      if (_canSeeCost) ...[
                        _value('Internal cost', _money(rates[i].cost), quiet: rates[i].cost == null),
                        _value('Total cost', _money(rates[i].totalCost), quiet: rates[i].cost == null),
                        _value('Commission', _rateCommissionRead(rates[i]).$1, quiet: !rates[i].paysCommission),
                        _value('Pays', _rateCommissionRead(rates[i]).$2, quiet: !rates[i].paysCommission),
                      ],
                    ],
                    columns: 3,
                    runGap: 10,
                  ),
                ],
              ),
            ),
        ],
      );
    }
    final boxH = LineTable.boxHeight(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _tHeader(cols),
        for (var i = 0; i < rates.length; i++)
          _RateRowShell(
            edit: false,
            stripe: i.isOdd,
            child: cols.line(
              item: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: boxH,
                    child: Padding(
                      padding: const EdgeInsets.only(left: LineTable.cellX),
                      child: Row(
                        children: [
                          Flexible(
                            child: Text.rich(
                              catalogNameSpan(rates[i].name, rates[i].qty == 0 ? LineTable.name.copyWith(fontWeight: FontWeight.w500, color: DashUi.slate) : LineTable.name),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (rates[i].description.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.only(left: LineTable.cellX - 6),
                      child: _descToggle(
                        id: 'rate-desc-read:$i',
                        open: _readDescOpen.contains(i),
                        has: true,
                        onTap: () => setState(() => _readDescOpen.contains(i) ? _readDescOpen.remove(i) : _readDescOpen.add(i)),
                      ),
                    ),
                    AnimatedSize(
                      duration: LineTable.motion(context, 180),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.topLeft,
                      child: _readDescOpen.contains(i)
                          ? Padding(
                              padding: const EdgeInsets.fromLTRB(LineTable.cellX, 4, 12, 4),
                              child: Text(rates[i].description, style: LineTable.description),
                            )
                          : const SizedBox(width: double.infinity),
                    ),
                  ],
                ],
              ),
              // A line at 0 reads quieter, as the Products & Services table draws its 0 lines.
              qty: _cellText(_qty(rates[i].qty), inset: _qtyInset, style: _quietly(LineTable.cell, rates[i].qty == 0)),
              rate: _cellText(_money(rates[i].rate), style: rates[i].rate == null ? null : _quietly(LineTable.cell, rates[i].qty == 0)),
              total: _cellText(_money(rates[i].total), style: rates[i].total == null ? LineTable.quiet : _quietly(LineTable.amount, rates[i].qty == 0)),
              cost: _cellText(_money(rates[i].cost), style: rates[i].cost == null ? null : _quietly(LineTable.cell, rates[i].qty == 0)),
              totalCost: _cellText(
                _money(rates[i].cost == null ? null : rates[i].totalCost),
                style: rates[i].cost == null ? null : _quietly(LineTable.cell, rates[i].qty == 0),
              ),
              commission: _cellText(
                _rateCommissionRead(rates[i]).$1,
                right: false,
                style: rates[i].paysCommission ? _quietly(LineTable.cell, rates[i].qty == 0) : LineTable.quiet,
              ),
              pays: _cellText(_rateCommissionRead(rates[i]).$2, style: rates[i].paysCommission ? _quietly(LineTable.cell, rates[i].qty == 0) : null),
            ),
          ),
        const Divider(height: 1, thickness: 1, color: DashUi.line),
      ],
    );
  }

  /// A rate's figures as it is typed: its total and total cost (null while a box holds something that isn't a number).
  ({double? total, double? totalCost}) _figures(_RateDraft d) {
    final r = d.toRate();
    return (
      total: r.rate == null || r.rate!.isNaN || r.qty.isNaN ? null : r.total,
      totalCost: r.cost == null || r.cost!.isNaN || r.qty.isNaN ? null : r.totalCost,
    );
  }

  String _readMoney(double? v) => v == null || v.isNaN ? '—' : dashMoney(v);

  // ---- a rate's boxes ----

  /// The field inside a rate box: no edge or fill of its own (the box draws those), its text where a read value's sits.
  Widget _rateField(
    String key,
    TextEditingController ctl,
    FocusNode node, {
    required String label,
    String? hint,
    bool right = false,
    bool numeric = false,
    bool multiline = false,
    TextStyle? style,
  }) {
    // The page's text style (what the read cells inherit: the theme's body text, under this page's Scaffold) and then
    // the table's, resolved in full: a TextField starts from the theme's field style (Material 3 bodyLarge, wider letter
    // spacing), so a figure would be wider in its box than read (the Products & Services table found the same,
    // 2026-11-13). Not DefaultTextStyle.of(context): this state's context is above its own Scaffold.
    final s = (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).merge(style ?? (multiline ? LineTable.description : LineTable.cell));
    const none = InputBorder.none;
    return Semantics(
      label: label,
      child: TextField(
        key: ValueKey('field:$key'),
        controller: ctl,
        focusNode: node,
        enabled: !_saving,
        minLines: multiline ? 2 : 1,
        maxLines: multiline ? 8 : 1,
        textAlign: right ? TextAlign.right : TextAlign.left,
        textAlignVertical: multiline ? TextAlignVertical.top : TextAlignVertical.center,
        cursorWidth: CatalogUi.cursorWidth,
        cursorRadius: CatalogUi.cursorRadius,
        style: s,
        keyboardType: numeric ? const TextInputType.numberWithOptions(decimal: true) : (multiline ? TextInputType.multiline : TextInputType.text),
        inputFormatters: numeric ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,$%]'))] : null,
        decoration: InputDecoration(
          isDense: true,
          filled: false,
          visualDensity: VisualDensity.standard,
          border: none,
          enabledBorder: none,
          focusedBorder: none,
          errorBorder: none,
          focusedErrorBorder: none,
          disabledBorder: none,
          hoverColor: Colors.transparent,
          hintText: hint,
          hintMaxLines: 1,
          hintStyle: s.copyWith(color: DashUi.slate, fontWeight: FontWeight.w400),
          // A right-aligned field keeps room after its text for the caret: given back, so a typed figure ends where
          // the read one does, 8 px in from the box's edge.
          contentPadding: multiline
              ? const EdgeInsets.fromLTRB(LineTable.cellX - 1, 7, LineTable.cellX - 1, 7)
              : EdgeInsets.fromLTRB(right ? 2 : LineTable.cellX - 1, 4, right ? LineTable.cellX - 1 - _caretRoom : 2, 4),
        ),
      ),
    );
  }

  /// The room a text field keeps after its text for the caret (a 1 px gap and the caret's width).
  static const double _caretRoom = 1 + CatalogUi.cursorWidth;

  bool _bad(int i, String field) => _errors.containsKey('rate$i.$field');

  /// A rate at quantity 0 (a line the job raises when it needs it): its name and figures read in slate rather than ink,
  /// a weight lighter, as the Products & Services table draws its 0 lines, so the lines a package starts with stand out.
  bool _zero(int i) => _RateDraft.parse(_rates[i].qty.text) == 0;

  TextStyle _quietly(TextStyle t, bool zero) => zero ? t.copyWith(color: DashUi.slate, fontWeight: t.fontWeight == FontWeight.w600 ? FontWeight.w500 : t.fontWeight) : t;

  /// A rate's name box: the name, "Description" at its end; the description opens in a box under it.
  Widget _nameCell(int i) {
    final d = _rates[i];
    final n = i + 1;
    final hasDesc = d.description.text.trim().isNotEmpty;
    final open = d.descOpen || _bad(i, 'description');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RateBox(
          focusNode: d.nameFocus,
          error: _bad(i, 'name'),
          enabled: !_saving,
          divider: true,
          end: _descToggle(id: 'rate-desc:$i', open: open, has: hasDesc, onTap: () => setState(() => d.descOpen = !open)),
          field: _rateField('rate$i.name', d.name, d.nameFocus, hint: 'Rate name', label: 'Rate $n name', style: _quietly(LineTable.name, _zero(i))),
        ),
        AnimatedSize(
          duration: LineTable.motion(context, 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: open
              ? Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: _RateBox(
                    focusNode: d.descFocus,
                    multiline: true,
                    error: _bad(i, 'description'),
                    enabled: !_saving,
                    field: _rateField('rate$i.description', d.description, d.descFocus, hint: 'What this rate includes', label: 'Rate $n description', multiline: true),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  /// One more / one less on a quantity (never under 0).
  void _stepQty(int i, int by) {
    final d = _rates[i];
    final v = _RateDraft.parse(d.qty.text);
    final now = v == null || v.isNaN ? 1.0 : v;
    final next = (now + by).clamp(0.0, 999999.0);
    setState(() => d.qty.text = _qty(next.toDouble()));
  }

  /// The quantity: its figure, its arrows inside the box at the right; Up and Down step it while typing in it.
  Widget _qtyBox(int i) {
    final d = _rates[i];
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _stepQty(i, 1),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _stepQty(i, -1),
      },
      child: _RateBox(
        focusNode: d.qtyFocus,
        error: _bad(i, 'qty'),
        enabled: !_saving,
        end: _StepArrows(enabled: !_saving, onStep: (by) => _stepQty(i, by)),
        endWidth: _StepArrows.width,
        field: _rateField('rate$i.qty', d.qty, d.qtyFocus, hint: '0', right: true, numeric: true, label: 'Rate ${i + 1} quantity', style: _quietly(LineTable.cell, _zero(i))),
      ),
    );
  }

  /// A money box: "$" at its left, the amount at its right.
  Widget _moneyBox(int i, String field, TextEditingController ctl, FocusNode node, {required String hint, required String label}) => _RateBox(
    focusNode: node,
    error: _bad(i, field),
    enabled: !_saving,
    lead: const Text('\$', style: LineTable.currency),
    field: _rateField('rate$i.$field', ctl, node, hint: hint, right: true, numeric: true, label: label, style: _quietly(LineTable.cell, _zero(i))),
  );

  /// What is wrong with a commission as it is typed, in the few words its PAYS cell has room for, or null.
  static String? _commissionProblem(_RateDraft d) {
    final v = _RateDraft.parse(d.commission.text);
    if (v == null) return null;
    if (v.isNaN) return 'Not a number';
    if (d.commissionType == 'percent' && v > 100) return 'Over 100%';
    return null;
  }

  /// A rate's commission while editing (USER RULE 2026-11-20: the % / $ toggle and an amount; an empty box is none).
  /// The switch and the box are fixed widths, and the box's unit sits in a fixed slot at each end ("$" before a fixed
  /// amount, "%" after a percentage, shown once something is typed), so changing the unit moves nothing.
  Widget _commissionCell(int i) {
    final d = _rates[i];
    final n = i + 1;
    final percent = d.commissionType == 'percent';
    final has = d.commission.text.trim().isNotEmpty;
    final cols = _cols;
    return Row(
      children: [
        SizedBox(
          width: cols.w(_RateCols.unitW),
          child: _UnitToggle(
            key: ValueKey('field:rate$i.commissionType'),
            keyBase: 'field:rate$i.commissionType',
            percent: percent,
            label: 'Rate $n commission',
            onChanged: _saving
                ? null
                : (p) => setState(() {
                    d.commissionType = p ? 'percent' : 'fixed';
                    _errors = {
                      for (final e in _errors.entries)
                        if (e.key != 'rate$i.commission') e.key: e.value,
                    };
                  }),
          ),
        ),
        const SizedBox(width: _RateCols.unitGap),
        Expanded(
          child: _RateBox(
            focusNode: d.commissionFocus,
            error: _bad(i, 'commission') || _commissionProblem(d) != null,
            enabled: !_saving,
            lead: Text(has && !percent ? '\$' : '', style: LineTable.currency),
            end: Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Text(has && percent ? '%' : '', style: LineTable.currency),
            ),
            endWidth: 16,
            field: _rateField(
              'rate$i.commission',
              d.commission,
              d.commissionFocus,
              hint: 'None',
              right: true,
              numeric: true,
              label: percent ? 'Rate $n commission, percent of the total' : 'Rate $n commission, dollars for each one sold',
            ),
          ),
        ),
      ],
    );
  }

  /// PAYS: what the commission comes to on this line, worked out as it is typed ("—" for none), or what is wrong with
  /// it, in red. A screen reader hears it in words: "pays $19.75, 5% of $395.00".
  Widget _paysCell(int i, {bool right = true, double inset = LineTable.cellX}) {
    final d = _rates[i];
    final f = _figures(d);
    final v = _RateDraft.parse(d.commission.text);
    final problem = _commissionProblem(d) ?? (_bad(i, 'commission') ? 'Check it' : null);
    final qty = d.toRate().qty;
    final pays = problem != null || v == null ? null : _commissionPays(d.commissionType, v, qty: qty, total: f.total);
    final text = problem ?? (pays == null ? '—' : dashMoney(pays));
    final words = problem ??
        (v == null
            ? 'no commission'
            : (pays == null ? 'pays once the rate has a price' : 'pays ${dashMoney(pays)}, ${_commissionBasis(d.commissionType, v, qty: qty, total: f.total)}'));
    return Semantics(
      liveRegion: true,
      label: 'Rate ${i + 1} commission $words',
      excludeSemantics: true,
      child: _cellText(
        text,
        key: ValueKey('commission-pays:$i'),
        right: right,
        inset: inset,
        style: problem != null
            ? LineTable.cell.copyWith(color: DashUi.redText, fontWeight: FontWeight.w600)
            : (text == '—' ? null : _quietly(LineTable.cell, _zero(i))),
      ),
    );
  }

  /// The row's ⋮ menu: duplicate, move, remove.
  Widget _rowMenu(int i) {
    final last = i == _rates.length - 1;
    return _RateLine(
      index: i,
      child: AppMenu(
        alignEnd: true,
        minWidth: 190,
        semanticLabel: 'Rate ${i + 1} actions',
        items: [
          AppMenuItem(key: ValueKey('duplicate-rate:$i'), icon: Icons.content_copy_rounded, label: 'Duplicate rate', onPressed: _saving ? null : () => _duplicateRate(i)),
          AppMenuItem(key: ValueKey('move-rate-up:$i'), icon: Icons.arrow_upward_rounded, label: 'Move up', onPressed: _saving || i == 0 ? null : () => _moveRate(i, -1)),
          AppMenuItem(key: ValueKey('move-rate-down:$i'), icon: Icons.arrow_downward_rounded, label: 'Move down', onPressed: _saving || last ? null : () => _moveRate(i, 1)),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Divider(height: 1, thickness: 1, color: DashUi.line),
          ),
          AppMenuItem(
            key: ValueKey('remove-rate:$i'),
            icon: Icons.delete_outline_rounded,
            label: 'Remove rate',
            danger: true,
            onPressed: _saving ? null : () => _removeRate(i),
          ),
        ],
        builder: (context, menu) => _RowMenuButton(key: ValueKey('rate-menu:$i'), menu: menu, label: 'More for rate ${i + 1}', enabled: !_saving),
      ),
    );
  }

  /// What is wrong in a rate's boxes after a Save, under its row (the boxes are red too).
  Widget? _rowErrors(int i, {double left = LineTable.cellX}) {
    final msgs = <String>[
      for (final f in _rateFieldNames.entries)
        if (_errors['rate$i.${f.key}'] case final m?) f.value.isEmpty ? m : '${f.value}: $m',
    ];
    if (msgs.isEmpty) return null;
    return Padding(
      padding: EdgeInsets.fromLTRB(left, 6, 0, 2),
      child: Semantics(
        liveRegion: true,
        child: Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            for (final m in msgs)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline_rounded, size: 14, color: DashUi.redText),
                  const SizedBox(width: 5),
                  Text(m, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: DashUi.redText, height: 1.3)),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _ratesEdit(double width) {
    if (_rates.isEmpty) return _noRates(edit: true);
    final cols = _cols;
    final stacked = !cols.fits(width);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedSize(
          duration: LineTable.motion(context, 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!stacked) _tHeader(cols),
              for (var i = 0; i < _rates.length; i++)
                KeyedSubtree(
                  key: _rates[i].key,
                  child: _RateLine(index: i, child: stacked ? _rateBlock(i, first: i == 0) : _rateRow(i, cols)),
                ),
              if (!stacked) const Divider(height: 1, thickness: 1, color: DashUi.line),
            ],
          ),
        ),
        _addRow(),
      ],
    );
  }

  /// One rate as a row of boxes under the headings, as a Products & Services line: the name box with its
  /// "Description", quantity x regular rate = total, the costs, the commission and what it pays, the menu.
  Widget _rateRow(int i, _RateCols cols) {
    final d = _rates[i];
    final f = _figures(d);
    final n = i + 1;
    final errors = _rowErrors(i);
    final line = cols.line(
      item: _nameCell(i),
      qty: _qtyBox(i),
      times: _sym('×'),
      rate: _moneyBox(i, 'rate', d.rate, d.rateFocus, hint: '0.00', label: 'Rate $n regular rate'),
      equals: _sym('='),
      total: _cellText(_readMoney(f.total), style: f.total == null ? LineTable.quiet : _quietly(LineTable.amount, _zero(i))),
      cost: _moneyBox(i, 'cost', d.cost, d.costFocus, hint: 'Cost', label: 'Rate $n internal cost'),
      totalCost: _cellText(_readMoney(f.totalCost), style: f.totalCost == null ? LineTable.quiet : _quietly(LineTable.cell, _zero(i))),
      commission: _commissionCell(i),
      pays: _paysCell(i),
      menu: Align(alignment: Alignment.topRight, child: _rowMenu(i)),
    );
    return _RateRowShell(
      edit: true,
      child: errors == null ? line : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [line, errors]),
    );
  }

  /// One rate stacked, for a window too narrow (or text too large) for the table: its name and description, then its
  /// figures, each with its label, wrapping as the width allows.
  Widget _rateBlock(int i, {required bool first}) {
    final d = _rates[i];
    final f = _figures(d);
    final n = i + 1;
    final k = _scale;
    final cols = _cols;
    Widget labelled(String label, double width, Widget child) => SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: _smallLabel),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
    final errors = _rowErrors(i, left: 0);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          top: first ? const BorderSide(color: DashUi.line) : BorderSide.none,
          bottom: const BorderSide(color: DashUi.line),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _nameCell(i)),
              const SizedBox(width: 8),
              _rowMenu(i),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            children: [
              labelled('Qty', cols.w(_RateCols.qtyW), _qtyBox(i)),
              labelled('Regular rate', cols.w(_RateCols.rateW), _moneyBox(i, 'rate', d.rate, d.rateFocus, hint: '0.00', label: 'Rate $n regular rate')),
              labelled(
                'Total',
                96 * k,
                _cellText(_readMoney(f.total), right: false, inset: 0, style: f.total == null ? LineTable.quiet : LineTable.amount),
              ),
              if (_canSeeCost) ...[
                labelled('Internal cost', cols.w(_RateCols.costW), _moneyBox(i, 'cost', d.cost, d.costFocus, hint: 'Cost', label: 'Rate $n internal cost')),
                labelled('Total cost', 96 * k, _cellText(_readMoney(f.totalCost), right: false, inset: 0)),
                labelled('Commission', cols.commissionW, _commissionCell(i)),
                labelled('Pays', 96 * k, _paysCell(i, right: false, inset: 0)),
              ],
            ],
          ),
          ?errors,
        ],
      ),
    );
  }

  /// ⋮ > Duplicate rate: a copy right under it, the keyboard in its name.
  void _duplicateRate(int i) {
    final from = _rates[i];
    final copy = _newDraft(from.toRate())
      ..commissionType = from.commissionType
      ..descOpen = from.descOpen;
    setState(() => _rates = [..._rates]..insert(i + 1, copy));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _rates.contains(copy)) copy.nameFocus.requestFocus();
    });
  }

  /// ⋮ > Move up / Move down: the order the lines take under the package on a job or estimate.
  void _moveRate(int i, int by) {
    final j = i + by;
    if (j < 0 || j >= _rates.length) return;
    setState(() {
      final next = [..._rates];
      final r = next.removeAt(i);
      next.insert(j, r);
      _rates = next;
      // A problem found by the last Save belongs to the rate, not the row it was on.
      _errors = {
        for (final e in _errors.entries)
          if (!e.key.startsWith('rate')) e.key: e.value,
      };
    });
  }
}

/// The rates table's columns, one layout for the headings, the read rows and the edited rows, so a value can only sit
/// under its own heading and nothing moves between reading and editing. Widths grow with the reader's text size; the
/// x, = and menu slots are there in both modes (empty when read).
class _RateCols {
  final bool costs;
  final double k;
  const _RateCols({required this.costs, required this.k});

  // As narrow as their widest figures allow ("$12,345.00" in the totals, "999,999" in the quantity), so the rate's
  // name keeps the room at 1280.
  static const qtyW = 80.0, symW = 20.0, rateW = 112.0, totalW = 90.0, costW = 116.0, totalCostW = 90.0;
  static const unitW = 64.0, unitGap = 6.0, amountW = 80.0, paysW = 78.0, menuW = 32.0;

  /// Between the rate's name and its quantity, and between the later columns.
  static const itemGap = 12.0, gap = 10.0;

  /// The table's side padding, inside its rows.
  static const side = 12.0;

  /// The narrowest the name column may get before the rates stack.
  static const minItemW = 220.0;

  double w(double v) => (v * k).roundToDouble();
  double get commissionW => w(unitW) + unitGap + w(amountW);

  double get _fixed =>
      itemGap +
      w(qtyW) +
      symW +
      w(rateW) +
      symW +
      w(totalW) +
      (costs ? gap + w(costW) + gap + w(totalCostW) + gap + commissionW + gap + w(paysW) : 0) +
      gap +
      menuW;

  /// Whether the table fits [width] with room for the names.
  bool fits(double width) => width - 2 * side - _fixed >= minItemW * k;

  Widget line({
    required Widget item,
    Widget? qty,
    Widget? times,
    Widget? rate,
    Widget? equals,
    Widget? total,
    Widget? cost,
    Widget? totalCost,
    Widget? commission,
    Widget? pays,
    Widget? menu,
    CrossAxisAlignment cross = CrossAxisAlignment.start,
  }) => Row(
    crossAxisAlignment: cross,
    children: [
      Expanded(key: const ValueKey('rate-col-item'), child: item),
      const SizedBox(width: itemGap),
      SizedBox(key: const ValueKey('rate-col-qty'), width: w(qtyW), child: qty),
      SizedBox(width: symW, child: times),
      SizedBox(key: const ValueKey('rate-col-rate'), width: w(rateW), child: rate),
      SizedBox(width: symW, child: equals),
      SizedBox(key: const ValueKey('rate-col-total'), width: w(totalW), child: total),
      if (costs) ...[
        const SizedBox(width: gap),
        SizedBox(key: const ValueKey('rate-col-cost'), width: w(costW), child: cost),
        const SizedBox(width: gap),
        SizedBox(key: const ValueKey('rate-col-total-cost'), width: w(totalCostW), child: totalCost),
        const SizedBox(width: gap),
        SizedBox(key: const ValueKey('rate-col-commission'), width: commissionW, child: commission),
        const SizedBox(width: gap),
        SizedBox(key: const ValueKey('rate-col-pays'), width: w(paysW), child: pays),
      ],
      const SizedBox(width: gap),
      SizedBox(key: const ValueKey('rate-col-menu'), width: menuW, child: menu),
    ],
  );
}

/// Around each rate row. Read: white, or the faint stripe on every other row. Editing: the row under the pointer is lit
/// across its whole width, and the row being typed in keeps a tint and an ink edge down its left (the Products &
/// Services table's open line). Nothing about it changes the row's size.
class _RateRowShell extends StatefulWidget {
  final bool edit;
  final bool stripe;
  final Widget child;
  const _RateRowShell({required this.edit, this.stripe = false, required this.child});

  /// Under the pointer, and while a box in the row has the keyboard.
  static final Color hover = Color.lerp(Colors.white, DashUi.faint, 0.55)!;
  static final Color active = Color.lerp(Colors.white, DashUi.faint, 0.85)!;

  @override
  State<_RateRowShell> createState() => _RateRowShellState();
}

class _RateRowShellState extends State<_RateRowShell> {
  bool _hover = false;
  bool _within = false;

  @override
  Widget build(BuildContext context) {
    final color = !widget.edit
        ? (widget.stripe ? LineTable.stripe : Colors.white)
        : (_within ? _RateRowShell.active : (_hover ? _RateRowShell.hover : Colors.white));
    final body = Stack(
      children: [
        AnimatedContainer(
          duration: LineTable.motion(context, 120),
          curve: Curves.easeOut,
          color: color,
          // The Products & Services table's rows: an edited line 7 px above and below its boxes (45 px at 100% text), a
          // read one as tall as its text with 11 px either side (41 px).
          padding: EdgeInsets.fromLTRB(_RateCols.side, widget.edit ? 7 : 5, _RateCols.side, widget.edit ? 7 : 5),
          child: widget.child,
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: AnimatedContainer(
            duration: LineTable.motion(context, 160),
            curve: Curves.easeOutCubic,
            width: widget.edit && _within ? 2 : 0,
            color: DashUi.ink,
          ),
        ),
      ],
    );
    if (!widget.edit) return body;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (v) => setState(() => _within = v),
        child: body,
      ),
    );
  }
}

/// A value box in the rates table, drawn by the table (the Products & Services table's box): white, a quiet hairline,
/// darker under the pointer, ink with a soft ring while its field has the keyboard, red with a red ring when what is in
/// it is wrong. One fixed height ([LineTable.boxHeight]) unless [multiline]. [lead] sits at its left in a fixed slot
/// ("$"); [end] at its right, past a hairline when [divider] ("Description") or bare (the arrows).
/// A click anywhere in it (on the "$", the padding) puts the caret in its field.
class _RateBox extends StatefulWidget {
  final FocusNode focusNode;
  final Widget field;
  final Widget? lead;
  final Widget? end;
  final double? endWidth;
  final bool divider;
  final bool error;
  final bool enabled;
  final bool multiline;
  const _RateBox({
    required this.focusNode,
    required this.field,
    this.lead,
    this.end,
    this.endWidth,
    this.divider = false,
    this.error = false,
    this.enabled = true,
    this.multiline = false,
  });

  /// The "$" slot's width, its padding included.
  static const leadWidth = 18.0;

  @override
  State<_RateBox> createState() => _RateBoxState();
}

class _RateBoxState extends State<_RateBox> {
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_changed);
  }

  @override
  void didUpdateWidget(_RateBox old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(_changed);
      widget.focusNode.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final focused = widget.focusNode.hasFocus;
    final enabled = widget.enabled;
    final edge = !enabled
        ? DashUi.line
        : widget.error
        ? DashUi.red
        : focused
        ? DashUi.ink
        : (_hover ? LineTable.edgeHover : LineTable.edge);
    final h = LineTable.boxHeight(context);
    final end = widget.end;
    final box = AnimatedContainer(
      duration: LineTable.motion(context, 120),
      curve: Curves.easeOut,
      height: widget.multiline ? null : h,
      constraints: widget.multiline ? BoxConstraints(minHeight: h * 2) : null,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: enabled ? Colors.white : DashUi.faint,
        borderRadius: BorderRadius.circular(LineTable.radius),
        border: Border.all(color: edge, width: LineTable.edgeWidth),
        boxShadow: !enabled ? null : (widget.error ? LineTable.ring(DashUi.red) : (focused ? LineTable.ring(DashUi.ink) : null)),
      ),
      child: Row(
        crossAxisAlignment: widget.multiline ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          if (widget.lead case final lead?)
            Container(
              width: _RateBox.leadWidth,
              padding: const EdgeInsets.only(left: LineTable.cellX - 1),
              alignment: Alignment.centerLeft,
              child: lead,
            ),
          Expanded(
            child: Align(alignment: widget.multiline ? Alignment.topLeft : Alignment.centerLeft, child: widget.field),
          ),
          if (end != null)
            Container(
              width: widget.endWidth,
              height: widget.multiline ? null : h - 2,
              padding: EdgeInsets.only(left: widget.divider ? 2 : 0, right: widget.divider ? 4 : 0),
              alignment: Alignment.center,
              decoration: widget.divider
                  ? const BoxDecoration(
                      border: Border(left: BorderSide(color: DashUi.line)),
                    )
                  : null,
              child: end,
            ),
        ],
      ),
    );
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.text : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: enabled ? widget.focusNode.requestFocus : null,
        child: box,
      ),
    );
  }
}

/// A quantity's up and down arrows, inside its box at the right. Left out of Tab: Up and Down in the box do the same.
class _StepArrows extends StatelessWidget {
  final bool enabled;
  final ValueChanged<int> onStep;
  const _StepArrows({required this.enabled, required this.onStep});

  /// The room the arrows take at the end of the box.
  static const width = 22.0;

  @override
  Widget build(BuildContext context) => ExcludeFocus(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _StepArrow(up: true, enabled: enabled, onTap: () => onStep(1)),
        _StepArrow(up: false, enabled: enabled, onTap: () => onStep(-1)),
      ],
    ),
  );
}

/// One arrow: a light fill and an ink arrow under the pointer, a touch darker pressed (the Products & Services
/// quantity's arrow). No hover tip (USER RULE 2026-11-20); a screen reader hears "One more" / "One less".
class _StepArrow extends StatefulWidget {
  final bool up;
  final bool enabled;
  final VoidCallback onTap;
  const _StepArrow({required this.up, required this.enabled, required this.onTap});

  @override
  State<_StepArrow> createState() => _StepArrowState();
}

class _StepArrowState extends State<_StepArrow> {
  bool _hover = false, _down = false;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: widget.enabled,
    label: widget.up ? 'One more' : 'One less',
    excludeSemantics: true,
    child: MouseRegion(
      cursor: widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.enabled ? (_) => setState(() => _down = true) : null,
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.enabled
            ? () {
                setState(() => _down = false);
                widget.onTap();
              }
            : null,
        child: AnimatedContainer(
          duration: LineTable.motion(context, 90),
          width: 20,
          height: 13,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: !widget.enabled ? null : (_down ? DashUi.line : (_hover ? LineTable.press : null)),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Icon(
            widget.up ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
            size: 16,
            color: !widget.enabled ? DashUi.line : (_hover || _down ? DashUi.ink : DashUi.slate),
          ),
        ),
      ),
    ),
  );
}

/// ⋮ at the end of a rate's row (the Products & Services table's row button): no outline at rest, a light fill under
/// the pointer, a touch darker pressed, an ink outline while its menu is open, the shared ring for keyboard focus.
class _RowMenuButton extends StatefulWidget {
  final AppMenuHandle menu;
  final String label;
  final bool enabled;
  const _RowMenuButton({super.key, required this.menu, required this.label, required this.enabled});

  @override
  State<_RowMenuButton> createState() => _RowMenuButtonState();
}

class _RowMenuButtonState extends State<_RowMenuButton> {
  bool _hover = false, _down = false;

  void _open() {
    if (!widget.enabled) return;
    widget.menu.focusNode.requestFocus();
    widget.menu.toggle();
  }

  @override
  Widget build(BuildContext context) {
    final open = widget.menu.isOpen;
    final lit = open || _hover;
    return Semantics(
      button: true,
      expanded: open,
      label: widget.label,
      excludeSemantics: true,
      child: FocusRing(
        borderRadius: BorderRadius.circular(LineTable.radius),
        child: FocusableActionDetector(
          focusNode: widget.menu.focusNode,
          enabled: widget.enabled,
          mouseCursor: widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onShowHoverHighlight: (v) => setState(() => _hover = v),
          actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _open())},
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: widget.enabled ? (_) => setState(() => _down = true) : null,
            onTapCancel: () => setState(() => _down = false),
            onTap: () {
              setState(() => _down = false);
              _open();
            },
            child: AnimatedContainer(
              duration: LineTable.motion(context, 110),
              curve: Curves.easeOut,
              width: 30,
              height: LineTable.boxHeight(context),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _down ? DashUi.line : (lit ? LineTable.press : Colors.white.withValues(alpha: 0)),
                borderRadius: BorderRadius.circular(LineTable.radius),
                border: Border.all(color: open ? DashUi.ink : DashUi.ink.withValues(alpha: 0), width: LineTable.edgeWidth),
              ),
              child: Icon(Icons.more_vert_rounded, size: 18, color: !widget.enabled ? DashUi.line : (lit ? DashUi.ink : DashUi.slate)),
            ),
          ),
        ),
      ),
    );
  }
}

/// "+ Add rate": the Products & Services table's outlined "Add a line" box, as tall as the table's boxes.
class _AddRateButton extends StatefulWidget {
  final FocusNode focusNode;
  final VoidCallback? onPressed;
  const _AddRateButton({super.key, required this.focusNode, required this.onPressed});

  @override
  State<_AddRateButton> createState() => _AddRateButtonState();
}

class _AddRateButtonState extends State<_AddRateButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: 'Add rate',
      excludeSemantics: true,
      child: FocusRing(
        borderRadius: BorderRadius.circular(LineTable.radius),
        child: FocusableActionDetector(
          focusNode: widget.focusNode,
          enabled: enabled,
          mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onShowHoverHighlight: (v) => setState(() => _hover = v),
          actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onPressed?.call())},
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: AnimatedContainer(
              duration: LineTable.motion(context, 120),
              curve: Curves.easeOut,
              height: LineTable.boxHeight(context),
              constraints: const BoxConstraints(minWidth: 160),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: _hover && enabled ? LineTable.press : Colors.white,
                borderRadius: BorderRadius.circular(LineTable.radius),
                border: Border.all(color: _hover && enabled ? LineTable.edgeHover : LineTable.edge, width: LineTable.edgeWidth),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded, size: 18, color: enabled ? DashUi.ink : DashUi.muted),
                  const SizedBox(width: 8),
                  Text(
                    'Add rate',
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: enabled ? DashUi.ink : DashUi.muted, height: 1.3),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _UnitIntent extends Intent {
  final bool percent;
  const _UnitIntent(this.percent);
}

/// The commission's unit: % (of the line's total) or $ (for each one sold), a two-segment control as tall as the boxes
/// beside it and drawn like them (white, the same hairline and corners), the chosen side filled with a light ink tint
/// and its symbol in bold ink. One Tab stop: Left / Right pick a side, Space or Enter switches. A screen reader hears
/// each side as a selected or unselected button, in words (no hover tip: USER RULE 2026-11-20). Both sides are always
/// the same width, so nothing moves when the unit changes.
class _UnitToggle extends StatefulWidget {
  final bool percent;
  final String label;

  /// The sides' keys: `<keyBase>:percent` and `<keyBase>:fixed`.
  final String keyBase;
  final ValueChanged<bool>? onChanged;
  const _UnitToggle({super.key, required this.percent, required this.label, required this.keyBase, required this.onChanged});

  /// The chosen side's fill.
  static final Color on = Color.lerp(Colors.white, DashUi.ink, 0.1)!;

  @override
  State<_UnitToggle> createState() => _UnitToggleState();
}

class _UnitToggleState extends State<_UnitToggle> {
  final _focus = FocusNode(debugLabel: 'commission unit');
  bool _hover = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  bool get _enabled => widget.onChanged != null;

  void _pick(bool percent) {
    if (_enabled && percent != widget.percent) widget.onChanged!(percent);
  }

  @override
  Widget build(BuildContext context) {
    final h = LineTable.boxHeight(context);
    Widget side(bool isPercent, String symbol, String words) => Expanded(
      child: Semantics(
        button: true,
        selected: isPercent == widget.percent,
        inMutuallyExclusiveGroup: true,
        enabled: _enabled,
        label: '${widget.label}: $words',
        excludeSemantics: true,
        child: _UnitSide(
          key: ValueKey('${widget.keyBase}:${isPercent ? 'percent' : 'fixed'}'),
          symbol: symbol,
          on: isPercent == widget.percent,
          enabled: _enabled,
          onTap: () {
            _focus.requestFocus();
            _pick(isPercent);
          },
        ),
      ),
    );
    return FocusRing(
      borderRadius: BorderRadius.circular(LineTable.radius),
      child: FocusableActionDetector(
        focusNode: _focus,
        enabled: _enabled,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowLeft): _UnitIntent(true),
          SingleActivator(LogicalKeyboardKey.arrowRight): _UnitIntent(false),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _pick(!widget.percent)),
          _UnitIntent: CallbackAction<_UnitIntent>(onInvoke: (i) => _pick(i.percent)),
        },
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        child: AnimatedContainer(
          duration: LineTable.motion(context, 120),
          height: h,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: _enabled ? Colors.white : DashUi.faint,
            borderRadius: BorderRadius.circular(LineTable.radius),
            border: Border.all(color: !_enabled ? DashUi.line : (_hover ? LineTable.edgeHover : LineTable.edge), width: LineTable.edgeWidth),
          ),
          child: Row(
            children: [side(true, '%', 'Percent of the line total'), const SizedBox(width: 2), side(false, '\$', 'Dollars for each one sold')],
          ),
        ),
      ),
    );
  }
}

class _UnitSide extends StatefulWidget {
  final String symbol;
  final bool on;
  final bool enabled;
  final VoidCallback onTap;
  const _UnitSide({super.key, required this.symbol, required this.on, required this.enabled, required this.onTap});

  @override
  State<_UnitSide> createState() => _UnitSideState();
}

class _UnitSideState extends State<_UnitSide> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.on;
    final live = widget.enabled && !on;
    return MouseRegion(
      cursor: live ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: LineTable.motion(context, 140),
          curve: Curves.easeOutCubic,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? (widget.enabled ? _UnitToggle.on : DashUi.line) : (live && _hover ? LineTable.press : Colors.white.withValues(alpha: 0)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            widget.symbol,
            style: TextStyle(
              fontSize: 13.5,
              height: 1.2,
              fontWeight: on ? FontWeight.w700 : FontWeight.w500,
              color: !widget.enabled ? DashUi.slate : (on || _hover ? DashUi.ink : DashUi.slate),
            ),
          ),
        ),
      ),
    );
  }
}

/// Marks a rate line's remove button with the line's place, so removing the line knows whether the keyboard was on it.
class _RateLine extends StatelessWidget {
  final int index;
  final Widget child;
  const _RateLine({required this.index, required this.child});

  @override
  Widget build(BuildContext context) => child;
}

class _ServiceSkeleton extends StatelessWidget {
  const _ServiceSkeleton();

  @override
  Widget build(BuildContext context) {
    Widget bar(double w, [double h = 12]) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(color: DashUi.line, borderRadius: BorderRadius.circular(6)),
    );
    return Semantics(
      label: 'Loading the service',
      liveRegion: true,
      child: SkeletonPulse(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
          child: LayoutBuilder(
            builder: (context, c) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                bar((c.maxWidth * 0.5).clamp(120.0, 420.0), 20),
                const SizedBox(height: 12),
                Wrap(spacing: 10, runSpacing: 8, children: [bar(64, 18), bar(110, 14), bar(180)]),
                const SizedBox(height: 32),
                bar(150, 14),
                const SizedBox(height: 16),
                for (var i = 0; i < 3; i++) ...[
                  Row(children: [bar(90), const SizedBox(width: 48), bar((c.maxWidth * 0.4).clamp(120.0, 460.0))]),
                  const SizedBox(height: 22),
                ],
                const SizedBox(height: 10),
                bar(60, 14),
                const SizedBox(height: 16),
                bar((c.maxWidth * 0.9).clamp(120.0, 1200.0)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
