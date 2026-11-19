import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../config/auth_session.dart';
import '../services/line_items_api.dart';
import '../utils/line_item_math.dart';
import 'app_dialog.dart';
import 'catalog_search_field.dart';
import 'dashboard_kit.dart';
import 'ps_menu.dart';

// The line-item table on the job and estimate pages. It takes the height its lines need: the page around it scrolls.
//
// The columns, left to right: the eye (shown to the customer or not), the item (its name, and under it a quiet line with
// its SKU and its Description toggle), then what the customer pays (quantity, rate, amount), for people who can see
// costs the unit cost, and the tax. The surface is white: no fills anywhere (user 2026-11-13 pass 5: "too much gray"),
// lines are told apart by spacing and a faint rule, every figure is right-aligned in tabular digits, and no line carries
// a margin of its own (user 2026-11-13: the totals keep the gross profit and its %). A quantity always shows two
// decimals (user 2026-11-13, see qtyText).
//
// Read-only (Service Fusion's items, an accepted option, someone who can't edit): plain rows of one even height.
// Editable: laid out like Service Fusion's own editor (user 2026-11-13): grip, eye in a box, the name box (its SKU and
// Description inside it), quantity (with arrows) x rate = amount (worked out, so plain text), cost, tax select, and a
// menu, all always there in quiet hairline boxes, one row of boxes a line; clicking a value (or Tab onto it) opens the
// row's fields in place with that one focused (Tab moves across them, Up / Down step the quantity, Esc closes). New lines come
// from the catalog search under the last line (so the next one goes in where the eye already is), or as a custom line
// or a discount. Lines can be dragged by their grip, or moved with Alt+Up / Alt+Down. Everything is a draft until Save
// (Ctrl+S), and the totals underneath follow every keystroke.
//
// Under the lines: anything the page puts beside the totals ([LineItemsEditor.aside], an estimate option's notes for the
// customer) and the warnings about the figures on the left; on the right what the customer is charged, then on a light
// slate panel of its own what the work costs us and the gross profit, then the total.
//
// Services Catalog Phase 2 (2026-11-18): the gross profit and its margin are only shown while every line's cost is known
// (a line with no cost made it read 100%); otherwise "—" and how many lines have none. A line at $0.00 with a quantity
// carries an amber "Confirm no charge" under its name until someone confirms it (in the preview, for the draft only, and
// taken off again when the line's name, quantity or price changes; on a saved option, through the server). A line just
// added from a service says what the catalog knows about its price and tax (mixed tax, a recent price change, no settled
// price), for as long as the draft lasts; none of that is kept with the line.

/// What a figure in a source's own summary is, so the editor can work out the money before tax from it.
enum SummaryKind {
  /// The items' total.
  items,

  /// A discount, as a negative amount.
  discount,

  /// A sales tax.
  tax,

  /// Any other charge the customer pays (a trip charge, a percentage fee).
  charge,

  /// Money in the source's total that it doesn't itemize: kept out of profit, since what it is isn't known.
  unitemized,

  /// The total.
  total,
}

/// One figure in the summary under Service Fusion's own items, shown as Service Fusion has it.
class LineSummaryRow {
  final String label;
  final int cents;
  final SummaryKind kind;

  /// A longer explanation, for the figure's tooltip.
  final String? tip;
  const LineSummaryRow(this.label, this.cents, {this.kind = SummaryKind.charge, this.tip});

  bool get strong => kind == SummaryKind.total;

  /// Counts toward the money before tax (what profit is worked out on): items, discounts and other charges.
  bool get beforeTax => kind == SummaryKind.items || kind == SummaryKind.discount || kind == SummaryKind.charge;
}

/// Lets the page drive an editor's Save and Discard from outside it (the page's floating save bar), and hear when its
/// draft, saving state or error change. With a controller the editor shows no Save buttons or error of its own.
class LineItemsController extends ChangeNotifier {
  _LineItemsEditorState? _state;

  bool get dirty => _state?._dirty ?? false;
  bool get saving => _state?._saving ?? false;
  String? get error => _state?._error;

  Future<void> save() async => _state?._save();
  void discard() => _state?._discard();

  void _ping() {
    // A change made while the page is building is passed on after the frame.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => notifyListeners());
    } else {
      notifyListeners();
    }
  }
}

class LineItemsEditor extends StatefulWidget {
  /// The saved lines (for read-only views, the lines to show).
  final List<LineDraft> lines;
  final double? taxRate;
  final bool editable;
  final bool showCost;

  /// Saves the lines and tax rate; returns an error to show, or null when it worked.
  final Future<String?> Function(List<LineDraft> lines, double? taxRate)? onSave;
  final ValueChanged<bool>? onDirtyChanged;

  /// A strip above the table: where the lines come from, a lock, an action.
  final Widget? banner;

  /// Read-only figures to show instead of computed totals (Service Fusion's own subtotal, charges and total).
  final List<LineSummaryRow>? summary;

  /// Read-only only: each line's amount as its source has it (Service Fusion's own line totals, in cents), so the
  /// table adds up to [summary] even where a line's total isn't exactly quantity x rate.
  final List<int>? fixedAmounts;
  final String emptyTitle;
  final String emptyMessage;

  /// Swappable for tests; the real search is [LineItemsApi.searchCatalog].
  final Future<List<CatalogEntry>> Function(String q)? search;

  /// The page's handle on Save and Discard (see [LineItemsController]).
  final LineItemsController? controller;

  /// Beside the totals (under them on a narrow window): anything that belongs with this set of lines (an estimate
  /// option's notes for the customer).
  final Widget? aside;

  /// Set while the lines are a session-only preview that can't be saved (the page's Edit Job / Edit Estimate). The
  /// editor then has no Save of its own and never calls [onSave]; Ctrl+S calls this so the page can say so.
  final VoidCallback? onPreviewSave;

  /// With [summary] on an editable table: the figures for a changed draft (the page reworks its source's own figures
  /// from the draft's lines). [summary] itself shows while nothing is changed.
  final List<LineSummaryRow> Function(List<LineDraft> lines, List<LineFigures> figures)? summaryBuilder;

  /// The sales taxes a line can be given in its Tax dropdown: the record's own tax line(s). A line naming one of these
  /// is taxed at its rate; the dropdown's other choice is No tax.
  final List<SalesTax> taxOptions;

  /// What the last line of the total box is called: "Estimate total" on an estimate, "Job total" on a job.
  final String totalLabel;

  /// Hears the total and (for people who see costs) the margin the summary shows, whenever they change, so the page
  /// can show a changed draft's figures elsewhere too (an estimate option's tab). Called after the frame.
  final void Function(int totalCents, double? marginPct)? onFigures;

  /// Saved lines shown outside the preview (an option, a job's set): confirms that [line], a $0.00 line, is no charge.
  /// The page asks the server, which records who and when, and the lines come back confirmed. Null where it can't be
  /// done (no Update switch, an accepted option): an unconfirmed $0 line then only says so.
  final Future<void> Function(LineDraft line)? onConfirmZero;

  const LineItemsEditor({
    super.key,
    required this.lines,
    required this.taxRate,
    required this.editable,
    required this.showCost,
    this.onSave,
    this.onDirtyChanged,
    this.banner,
    this.summary,
    this.fixedAmounts,
    this.emptyTitle = 'No products or services yet',
    this.emptyMessage = 'Search the catalog below to add the first one.',
    this.search,
    this.controller,
    this.aside,
    this.onPreviewSave,
    this.summaryBuilder,
    this.taxOptions = const [],
    this.totalLabel = 'Total',
    this.onFigures,
    this.onConfirmZero,
  });

  @override
  State<LineItemsEditor> createState() => _LineItemsEditorState();
}

class _Row {
  final int uid;
  LineDraft line;

  /// The line's place in the table, the same for as long as the line lives (a new line is scrolled into view by it).
  /// Its light used to come from a key that moved to whichever line was new: when the light went out, 1.4 s after the
  /// line came in, the key went and the line was built afresh, which put focus back on its first field with all of it
  /// selected, so the next key typed there replaced it (found in round 2, 2026-11-13).
  final GlobalKey shell;
  _Row(this.uid, this.line) : shell = GlobalKey(debugLabel: 'line $uid');
}

/// Which columns fit, and how wide they are. Left to right, as Service Fusion's own editor has them (user 2026-11-13):
/// [grip] eye item | qty [x] rate [=] amount | cost | tax [menu]. While editing every value is a box, always there,
/// and the "x" and "=" between the figures say how the amount is made.
class _Cols {
  final bool cost;

  /// The lines can be changed: the grip, the x and = and the menu are there, and the quantity has its arrows.
  final bool editable;

  /// Too narrow for columns (a small window): each line stacks its figures under its name.
  final bool stacked;
  const _Cols({required this.cost, required this.editable, this.stacked = false});

  // Quantity is wide enough for "35,125.30" (a real Service Fusion line) and, while editing, its arrows; the tax for
  // "Prairie Grove 10.5%" and its chevron.
  // qtyEditW fits the widest quantity that can be typed, "-999,999.99" (the limit went from 9,999.999 to 999,999.999 on
  // 2026-11-13), with its arrows; qtyW fits a stored "-999,999.999".
  static const gripW = 22.0, eyeW = 36.0, qtyW = 88.0, qtyEditW = 120.0, rateW = 118.0, amountW = 128.0, costW = 112.0;
  static const taxW = 164.0, actionsW = 42.0;

  /// The x between quantity and rate, the = before the amount (editing only).
  static const symW = 22.0;

  /// Between the amount, the cost and the tax.
  static const gapW = 10.0;

  /// Between the item and its quantity.
  static const itemGap = 12.0;

  /// The narrowest the item column may get before the lines stack.
  static const minItemW = 240.0;

  /// Stacked (a small window): one width for every line's amount, so the name boxes beside it line up.
  static const stackAmountW = 104.0;

  /// The narrowest name box that still shows the SKU inside it, and the most the SKU may take there. The name is what
  /// the line is, so it keeps at least about 260 px before the SKU joins it (round 2: at 400 a 1280 window cut every
  /// long name to "Clopay | Canyon Ridge | C..." beside its SKU; the SKU is still on the read-only line).
  static const skuInBoxW = 460.0, skuMaxW = 104.0;

  /// Below this a name box's "Description" is its icon alone, so the name keeps some room.
  static const compactToggleW = 260.0;

  double get qty => editable ? qtyEditW : qtyW;
  double get lead => (editable ? gripW : 0) + eyeW;
  double get trail => editable ? actionsW : 0;

  static _Cols of(double width, {required bool cost, required bool editable}) {
    final fixed =
        (editable ? gripW + qtyEditW + symW * 2 + actionsW : qtyW) + eyeW + itemGap + rateW + amountW + (cost ? gapW + costW : 0) + gapW + taxW;
    return _Cols(cost: cost, editable: editable, stacked: width - fixed < minItemW);
  }

  /// The one layout of a table row. The headings, a read-only line and an open line are all laid out by it, so each
  /// column's width and place is set here and nowhere else, and a value can only sit under its own heading (round 3,
  /// 2026-11-13: the three used to build their rows each with their own copy of these widths). The x, = and menu slots
  /// are there only while editing, the cost only for people who see costs.
  Widget line({
    Widget? grip,
    Widget? eye,
    required Widget item,
    Widget? qtyCell,
    Widget? times,
    Widget? rateCell,
    Widget? equals,
    Widget? amountCell,
    Widget? costCell,
    Widget? taxCell,
    Widget? menu,
    CrossAxisAlignment cross = CrossAxisAlignment.start,
  }) => Row(
    crossAxisAlignment: cross,
    // Each slot is keyed by its column, the same in the headings and in every line (the alignment tests measure them).
    children: [
      if (editable) SizedBox(key: const ValueKey('col-grip'), width: gripW, child: grip),
      SizedBox(key: const ValueKey('col-eye'), width: eyeW, child: eye),
      Expanded(key: const ValueKey('col-item'), child: item),
      const SizedBox(width: itemGap),
      SizedBox(key: const ValueKey('col-qty'), width: qty, child: qtyCell),
      if (editable) SizedBox(width: symW, child: times),
      SizedBox(key: const ValueKey('col-rate'), width: rateW, child: rateCell),
      if (editable) SizedBox(width: symW, child: equals),
      SizedBox(key: const ValueKey('col-amount'), width: amountW, child: amountCell),
      if (cost) ...[const SizedBox(width: gapW), SizedBox(key: const ValueKey('col-cost'), width: costW, child: costCell)],
      const SizedBox(width: gapW),
      SizedBox(key: const ValueKey('col-tax'), width: taxW, child: taxCell),
      if (editable) SizedBox(key: const ValueKey('col-menu'), width: actionsW, child: menu),
    ],
  );
}

const _figures = [FontFeature.tabularFigures()];
const _head = TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: DashUi.ink, letterSpacing: 0.7, height: 1.2);
const _cell = TextStyle(fontSize: 13.5, color: DashUi.ink, height: 1.35, fontFeatures: _figures);
const _cellMuted = TextStyle(fontSize: 13.5, color: DashUi.ink, height: 1.35, fontFeatures: _figures);
const _costText = TextStyle(fontSize: 13.5, color: DashUi.ink, height: 1.35, fontFeatures: _figures);
const _nameStyle = TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: DashUi.ink, height: 1.35, letterSpacing: -0.1);
const _metaStyle = TextStyle(fontSize: 12, color: DashUi.ink, height: 1.4, fontFeatures: _figures);
const _descStyle = TextStyle(fontSize: 13, color: DashUi.ink, height: 1.5);
const _hint = TextStyle(fontSize: 13, color: DashUi.slate, height: 1.35);

/// The "$" in front of a money box while editing, at the box's left as the field it opens into has it.
const _currency = TextStyle(fontSize: 13, color: DashUi.subtle, height: 1.35);

/// The line every text in a value's box sits on: the value's own ([style], resolved as the box draws it). A text field
/// forces its typed text onto its style's line (EditableText's strut), sets its "$" and its placeholder on that text's
/// baseline, and grows to hold either one's line when it reaches lower, then centres again. The "$" and placeholders
/// are 13 px on their own 13 px line, so as a line opened its Rate and Cost figures rose by part of a pixel and the "$"
/// dropped (a whole pixel row in Chrome; user 2026-11-16: "the Rate and Cost numbers shift slightly"). Quantity, with
/// no "$", never moved. So the "$" and the placeholders, closed and open, sit on the value's line, as its figure does.
StrutStyle _valueLine(BuildContext context, TextStyle style) =>
    StrutStyle.fromTextStyle(DefaultTextStyle.of(context).style.merge(style), forceStrutHeight: true);

/// A line at quantity 0 (a catalog entry listed for reference or as an optional extra: 17% of Service Fusion's lines)
/// reads in slate rather than ink, its name a weight lighter, so the lines that make up the price stand out (user
/// 2026-11-13 round 4: "visually quieter without making them difficult to read"; slate is 7.6:1 on white).
const _quietTone = DashUi.slate;

/// The "|" between the parts of a catalog name ("Clopay | Classic Steel | 4300 | Complete Door"): lighter and regular
/// weight, so a long name reads as its parts rather than as a run of bold text and bars. Decoration, not words.
const _pipeTone = DashUi.muted;

/// A line's name with its "|" separators drawn quieter than its words (see [_pipeTone]). Its plain text is the name
/// exactly, so it reads, copies and is found the same.
TextSpan _nameSpan(String text, TextStyle style) {
  if (!text.contains('|')) return TextSpan(text: text, style: style);
  final parts = text.split('|');
  return TextSpan(
    style: style,
    children: [
      for (var i = 0; i < parts.length; i++) ...[
        if (i > 0) const TextSpan(text: '|', style: TextStyle(color: _pipeTone, fontWeight: FontWeight.w400)),
        TextSpan(text: parts[i]),
      ],
    ],
  );
}

/// The open name field's text, drawn as the closed name is ([_nameSpan]), so the bars don't darken as the line opens.
class _NameController extends TextEditingController {
  _NameController({super.text});

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    // While an input method is composing, its own underline matters more.
    if (withComposing && value.isComposingRangeValid) return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    return _nameSpan(text, style ?? const TextStyle());
  }
}

/// The outline of every box that can be typed into: one quiet hairline (user 2026-11-13 pass 5: "too much gray, too
/// heavy"), darker under the pointer, ink with a soft ring while it has focus.
const _edge = DashUi.fieldEdge;
const _edgeHover = DashUi.subtle;
const _edgeW = 1.0;
const _radius = 6.0;

/// The ring around a focused box (or a red one around a value that isn't a number). Outside the box, so it moves nothing.
List<BoxShadow> _ring(Color c) => [BoxShadow(color: c.withValues(alpha: 0.14), spreadRadius: 3)];

/// Under the pointer: an icon button's light fill.
const _press = DashUi.faint;
const _amountStyle = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.ink, height: 1.35, fontFeatures: _figures);

/// A line's amount: semibold, red when it is money off, and regular weight at $0.00 (a line at quantity 0 is a note or
/// a part for a later visit: 17% of Service Fusion's lines are, and a column of bold "$0.00" drowned out the figures that
/// count).
TextStyle _amountFor(int cents) => cents < 0
    ? _amountStyle.copyWith(color: DashUi.redText)
    : cents == 0
    ? _amountStyle.copyWith(fontWeight: FontWeight.w400)
    : _amountStyle;

/// The table's side padding, and the room above and below a read-only line's text.
const _side = 20.0;
const _rowPad = 11.0;

/// The gap between a line's name and the quiet line under it (its SKU, Description).
const _metaGap = 2.0;

/// Inside every value's cell: where a field puts its text, so a value doesn't move when its field opens. Editable rows
/// are [_rowPad] - [_cellY] from their edge, so both kinds of row are the same height.
const _cellX = 8.0;
const _cellY = 6.0;

/// A one-line value box's height: the name's line (14 px at 1.35, scaled with the reader's text size) and the room above
/// and below it. Fixed, so a value and the field it opens into are exactly as tall.
double _boxHeight(BuildContext context) => (MediaQuery.textScalerOf(context).scale(14) * 1.35).ceilToDouble() + 2 * _cellY;

/// Behind the open line while editing (never under the pointer: user 2026-11-13 round 3, no hover shading on rows).
final Color _rowTint = DashUi.faint.withValues(alpha: 0.5);

/// Every other read-only line: an extremely light cool off-white, white's neighbour (user 2026-11-13 round 3: "barely
/// noticeable", for following a line across the table, not zebra stripes). It replaces the rules between read-only lines.
final Color _stripe = Color.lerp(Colors.white, DashUi.faint, 0.45)!;

/// The rule between lines: lighter than the one under the headings.
final Color _rowRule = Color.lerp(DashUi.line, DashUi.faint, 0.45)!;

/// The room a text field keeps after its text for the caret (RenderEditable: a 1 px gap plus the caret's width). A
/// right-aligned field's text ends this far before a plain Text's would, so a figure jumped about 3 px left the moment
/// its line opened, and sat off its heading while open (round 3, 2026-11-13). Right-aligned fields give it back.
const _cursorW = 2.0;
const _caretRoom = 1.0 + _cursorW;

/// Whether focus is being moved with the keyboard, as the web's :focus-visible decides it: a key press says yes, any
/// pointer press says no.
///
/// Flutter's own highlight mode stays "traditional" (rings on) after a mouse click on desktop, and a click on a control
/// gives it focus, so every control in the table kept a focus ring after it was clicked: the qty box around a clicked
/// arrow, Description, the eye, ⋮ once its menu closed (round 3, 2026-11-13). Rings now show only for keyboard focus.
abstract final class _FocusVisible {
  static bool _installed = false;

  /// True while focus is being moved with the keyboard. A ring listens to it as well as to its node: Tab can move
  /// focus before this hears the key, and the ring has to come on once it does.
  static final mode = ValueNotifier<bool>(false);

  static bool get keyboard {
    install();
    return mode.value;
  }

  static bool _onKey(KeyEvent e) {
    if (e is KeyDownEvent) mode.value = true;
    return false;
  }

  static void _onPointer(PointerEvent e) {
    if (e is PointerDownEvent) mode.value = false;
  }

  /// Called by every ring as it starts. The key handler is put back each time (removing it first, so it is there once):
  /// a test binding clears the keyboard's handlers between tests.
  static void install() {
    HardwareKeyboard.instance
      ..removeHandler(_onKey)
      ..addHandler(_onKey);
    if (_installed) return;
    _installed = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }
}

/// A control's focus ring: on while [ringNode] itself has focus and it got there by keyboard (see [_FocusVisible]).
/// Focus inside the control (an arrow in the qty box) doesn't light the control.
mixin _FocusRing<T extends StatefulWidget> on State<T> {
  FocusNode get ringNode;
  bool ring = false;

  void _ringChanged() {
    final v = ringNode.hasPrimaryFocus && _FocusVisible.keyboard;
    if (v != ring && mounted) setState(() => ring = v);
  }

  @override
  void initState() {
    super.initState();
    _FocusVisible.install();
    ringNode.addListener(_ringChanged);
    _FocusVisible.mode.addListener(_ringChanged);
  }

  @override
  void dispose() {
    _FocusVisible.mode.removeListener(_ringChanged);
    ringNode.removeListener(_ringChanged);
    super.dispose();
  }
}

/// A motion's length, or none with reduce motion.
Duration _motion(BuildContext context, int ms) => MediaQuery.disableAnimationsOf(context) ? Duration.zero : Duration(milliseconds: ms);

class _LineItemsEditorState extends State<LineItemsEditor> {
  late List<_Row> _rows;
  Map<int, int> _origin = const {}; // a row's place in widget.lines, for the rows that came from it
  final Set<int> _moreOpen = {}; // rows whose description is showing (it is hidden until "More")
  late double? _tax;
  late final TextEditingController _taxText;

  /// What is typed in the tax rate isn't a rate from 0% to 30%: the field is marked and the totals keep the last good
  /// rate (it used to charge whatever was typed, 105% included; found in round 2, 2026-11-13).
  bool _taxBad = false;
  int _nextUid = 0;
  int? _active; // the row with its fields open
  String _focusField = 'name';
  int? _flash; // a row just added, lit for a moment
  Timer? _flashTimer;
  final Map<int, Set<String>> _invalid = {};
  bool _saving = false;
  bool _savePending = false;
  String? _error;
  bool _wasDirty = false;

  /// The table has turned editable or read-only since it was made, so the lines' new look settles in (_ModeFade).
  bool _modeSwitched = false;

  /// Lines on their way out (Delete): they fold away, then go (see _finishRemove).
  final Set<int> _leaving = {};

  /// The service each line just added from the catalog came from, for what it says about its price and tax (see
  /// [_lineNotes]). Only while this draft lasts: never part of the line, never saved.
  final Map<int, CatalogEntry> _added = {};
  final _searchFocus = FocusNode(debugLabel: 'catalog search');

  @override
  void initState() {
    super.initState();
    _taxText = TextEditingController();
    widget.controller?._state = this;
    _reset();
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    widget.controller?._ping();
  }

  /// Goes up each time the rows are rebuilt from [LineItemsEditor.lines] (Cancel, a reload, a save landing), so an Undo
  /// offered before then can tell that the line it would put back belongs to a draft that no longer exists.
  int _generation = 0;

  void _reset() {
    _generation++;
    // An open description stays open on its line (Exit preview, a reload), found by the line itself, not its place, so
    // a line added above it doesn't move it to another line.
    final wasOpen = {
      for (final r in _rowsOrEmpty)
        if (_moreOpen.contains(r.uid)) _lineKey(r.line),
    };
    _moreOpen.clear();
    _rows = [for (final l in widget.lines) _Row(_nextUid++, l)];
    _origin = {for (var i = 0; i < _rows.length; i++) _rows[i].uid: i};
    for (final r in _rows) {
      if (wasOpen.contains(_lineKey(r.line))) _moreOpen.add(r.uid);
    }
    _tax = widget.taxRate;
    _taxText.text = _tax == null ? '' : _trimRate(_tax!);
    _taxBad = false;
    _leaving.clear();
    _added.clear();
    _active = null;
    _invalid.clear();
    _error = null;
  }

  /// The rows before the first [_reset] (none yet).
  List<_Row> get _rowsOrEmpty => _generation <= 1 ? const [] : _rows;

  /// A line, recognised across a reload: its id, else what it is.
  static String _lineKey(LineDraft l) => l.id ?? '${l.kind.name}|${l.name.trim()}|${l.sku.trim()}';

  static String _trimRate(double r) => r.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '');

  /// The same lines, in the same order. The page makes Service Fusion's lines afresh on every build (a new list each
  /// time), so "new lines" has to mean different lines, not a different list: otherwise anything that rebuilt the page
  /// threw the table away and closed every open description (found 2026-11-13).
  static bool _sameLines(List<LineDraft> a, List<LineDraft> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].source != b[i].source || !a[i].sameAs(b[i])) return false;
    }
    return true;
  }

  @override
  void didUpdateWidget(LineItemsEditor old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      if (old.controller?._state == this) old.controller!._state = null;
      widget.controller?._state = this;
    }
    if (old.editable != widget.editable) _modeSwitched = true;
    if (!_sameLines(old.lines, widget.lines) || old.taxRate != widget.taxRate || old.editable != widget.editable) {
      // New saved lines arrived (our save, a refresh, someone else's change). Keep an unsaved draft unless it was ours
      // that just landed. Whether there is one is judged against the lines it was made from: judged against the new
      // ones, an untouched draft of the old lines looked changed, so it stayed on screen, marked "Changed, not saved"
      // (found 2026-11-13).
      final hadDraft = old.editable && _differsFrom(old.lines, old.taxRate);
      if (!hadDraft || _savePending || !widget.editable) {
        _savePending = false;
        _reset();
      }
      // This runs while the page is building, so the page hears after the frame (a kept draft may now match the new
      // lines, and so no longer be a change).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _notifyDirty();
        widget.controller?._ping();
      });
    }
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) widget.controller!._state = null;
    _flashTimer?.cancel();
    _taxText.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // ---- draft state ------------------------------------------------------------------------------------------------

  List<LineDraft> get _lines => [for (final r in _rows) r.line];

  bool get _dirty => widget.editable && _differsFrom(widget.lines, widget.taxRate);

  /// The draft differs from [lines] at [taxRate] (or holds a number that doesn't parse).
  bool _differsFrom(List<LineDraft> lines, double? taxRate) {
    if (_invalid.values.any((s) => s.isNotEmpty) || _taxBad) return true;
    if ((_tax == null) != (taxRate == null) || (_tax != null && (_tax! * 10000).round() != (taxRate! * 10000).round())) return true;
    if (_rows.length != lines.length) return true;
    for (var i = 0; i < _rows.length; i++) {
      if (!_rows[i].line.sameAs(lines[i])) return true;
    }
    return false;
  }

  void _notifyDirty() {
    final d = _dirty;
    if (d != _wasDirty) {
      _wasDirty = d;
      widget.onDirtyChanged?.call(d);
    }
  }

  void _changed(VoidCallback fn) {
    setState(() {
      fn();
      _error = null;
    });
    _notifyDirty();
  }

  /// Puts [row] into the draft at [at] (the end by default), and opens it at [open]. It slides open and is lit for a
  /// moment (every way a line comes in: the catalog, a custom line, a discount or fee, Copy, Undo).
  void _insert(_Row row, {int? at, String? open}) {
    _changed(() {
      _rows.insert((at ?? _rows.length).clamp(0, _rows.length), row);
      _flash = row.uid;
    });
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted && _flash == row.uid) setState(() => _flash = null);
    });
    if (open != null) _open(row.uid, open);
  }

  void _add(LineDraft line, {CatalogEntry? from}) {
    final added = _Row(_nextUid++, line);
    if (from != null && from.isService) _added[added.uid] = from;
    _insert(added);
    // The new line, and the search under it, stay in view clear of the page's save bar: the page scrolls just enough.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = added.shell.currentContext;
      final row = ctx?.findRenderObject();
      if (ctx == null || row is! RenderBox || !mounted) return;
      // The page's scroll, past the list's own (which never scrolls).
      var page = Scrollable.maybeOf(ctx);
      while (page != null && page.widget.physics is NeverScrollableScrollPhysics) {
        page = Scrollable.maybeOf(page.context);
      }
      final box = page?.context.findRenderObject();
      if (page == null || box is! RenderBox) return;
      const room = 150.0; // the search row, and the save bar floating over the bottom
      final rowBottom = row.localToGlobal(Offset(0, row.size.height)).dy;
      final viewBottom = box.localToGlobal(Offset(0, box.size.height)).dy;
      final by = rowBottom - (viewBottom - room);
      if (by <= 0) return;
      final pos = page.position;
      final to = (pos.pixels + by).clamp(pos.minScrollExtent, pos.maxScrollExtent);
      if (MediaQuery.disableAnimationsOf(context)) {
        pos.jumpTo(to);
      } else {
        pos.animateTo(to, duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
      }
    });
  }

  void _pick(CatalogChoice c) {
    if (c.entry != null) {
      _add(c.entry!.toLine(), from: c.entry);
    } else if (c.custom != null) {
      _insert(_Row(_nextUid++, LineDraft(name: c.custom!, quantity: 1, source: 'manual')), open: 'rate');
    }
  }

  static const _discountChoices = ['Discount', 'Builder Relationship Discount'];
  static const _feeChoices = ['Trip charge', 'Delivery fee', 'Fuel surcharge', 'Disposal fee', 'Permit fee', 'Other fee'];
  static const _taxSet = '\u0000set';

  /// The "Tax, discounts & fees" menu under the search: a pick adds that line. A discount or fee opens on its amount;
  /// a sales tax is put on every item line (each line's Tax dropdown can still change it).
  List<PsMenuEntry<String>> _chargeEntries() {
    final hasLines = _rows.any((r) => !r.line.isDiscount);
    final taxes = <PsMenuEntry<String>>[
      if (hasLines) ...[
        for (final t in widget.taxOptions) PsMenuItem('t:${t.name}', t.short, trailing: '${SalesTax.rateText(t.rate)}%'),
        if (widget.taxOptions.isEmpty && _tax != null) PsMenuItem('t:$_taxSet', 'Sales tax', trailing: '${_trimRate(_tax!)}%'),
      ],
    ];
    return [
      if (taxes.isNotEmpty) ...[const PsMenuHeading('Tax (on every line)'), ...taxes, const PsMenuDivider()],
      const PsMenuHeading('Discounts'),
      for (final d in _discountChoices) PsMenuItem('d:$d', d),
      const PsMenuDivider(),
      const PsMenuHeading('Fees'),
      for (final f in _feeChoices) PsMenuItem('f:$f', f),
    ];
  }

  void _pickCharge(String v) {
    if (!mounted) return;
    final name = v.substring(2);
    switch (v[0]) {
      case 't':
        _changed(() {
          for (final r in _rows) {
            if (!r.line.isDiscount) r.line = r.line.copyWith(taxable: true, taxName: name == _taxSet ? null : name);
          }
        });
      case 'd':
        _insert(_Row(_nextUid++, LineDraft(kind: LineKind.discount, name: name, quantity: 1, source: 'manual')), open: 'rate');
      default:
        _insert(_Row(_nextUid++, LineDraft(name: name, quantity: 1, source: 'manual')), open: 'rate');
    }
  }

  /// A pick from a line's Tax dropdown: no tax, the set's own rate, or a named sales tax.
  void _pickTax(_Row r, String v) => _changed(
    () => r.line = switch (v) {
      _TaxCell.none => r.line.copyWith(taxable: false, taxName: null),
      _TaxCell.setRate => r.line.copyWith(taxable: true, taxName: null),
      _ => r.line.copyWith(taxable: true, taxName: v),
    },
  );

  void _toggleMore(int uid) => setState(() => _moreOpen.contains(uid) ? _moreOpen.remove(uid) : _moreOpen.add(uid));

  void _open(int uid, String field) {
    setState(() {
      _active = uid;
      _focusField = field;
      if (field == 'description') _moreOpen.add(uid);
      // The line's fields start again from its good figures (the draft only ever took good numbers), so a bad number
      // left in it last time no longer marks it: reopening never shows a good figure in a red box (found by the
      // 2026-11-13 review). While closed it keeps its red mark, so the bad number isn't missed.
      _invalid.remove(uid);
    });
    _notifyDirty();
  }

  void _close(int uid) {
    if (_active == uid) setState(() => _active = null);
  }

  void _move(int from, int to) {
    if (to < 0 || to >= _rows.length || from == to) return;
    _changed(() {
      final r = _rows.removeAt(from);
      _rows.insert(to, r);
    });
  }

  /// Delete: the line folds away, then leaves the draft (with an Undo). With reduce motion it goes at once.
  void _remove(int index) {
    final removed = _rows[index];
    if (_leaving.contains(removed.uid)) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _finishRemove(removed);
      return;
    }
    setState(() {
      _leaving.add(removed.uid);
      if (_active == removed.uid) _active = null;
    });
  }

  void _finishRemove(_Row removed) {
    if (!mounted) return;
    _leaving.remove(removed.uid);
    // Where it is now (another line may have moved meanwhile); gone already if the draft was rebuilt.
    final index = _rows.indexOf(removed);
    if (index < 0) return;
    final generation = _generation;
    _changed(() {
      _rows.removeAt(index);
      _invalid.remove(removed.uid);
      if (_active == removed.uid) _active = null;
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            widget.onPreviewSave != null
                ? 'Removed "${removed.line.name}" from the preview.'
                : 'Removed "${removed.line.name}". It is gone once you save.',
          ),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              // Only into the draft it came out of: after Cancel or a reload the table was rebuilt from the saved lines,
              // and putting the line back then would show a line that isn't there (or the same line twice).
              if (!mounted || !widget.editable || generation != _generation || _rows.contains(removed)) return;
              _insert(removed, at: index);
            },
          ),
        ),
      );
  }

  void _duplicate(int index) => _insert(_Row(_nextUid++, _rows[index].line.copyWith(id: null)), at: index + 1);

  // ---- $0.00 lines ------------------------------------------------------------------------------------------------

  /// Whether this table asks for $0.00 lines to be confirmed: our own lines (an option, a job's set) and any preview
  /// draft. Service Fusion's own lines, read-only, are shown as Service Fusion has them.
  bool get _zeroChecks => widget.editable || widget.summary == null;

  /// A $0 line can be confirmed here: in the preview (for the draft), or on saved lines through the page.
  bool _canConfirm(LineDraft line) => widget.editable || (widget.onConfirmZero != null && line.id != null);

  /// "Charge nothing for ...?": the person says it is no charge, or goes to enter a price. Confirming is explicit, one
  /// line at a time. In the preview it is the draft's (with who confirmed it), and comes off again if the line's name,
  /// quantity or price changes; on saved lines the page asks the server.
  Future<void> _askZero(_Row r) async {
    final name = r.line.name.trim().isEmpty ? 'this line' : r.line.name.trim();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        title: "Charge nothing for '$name'?",
        icon: Icons.money_off_rounded,
        iconColor: DashUi.amberText,
        body: const Text('It will show \$0.00 to the customer.', style: TextStyle(fontSize: 14, color: DashUi.slate, height: 1.45)),
        actions: [
          AppButton.ghost('Enter a price', () => Navigator.pop(ctx, false)),
          AppButton.ink('Confirm no charge', () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (!mounted || confirm == null || !_rows.contains(r)) return;
    if (!confirm) {
      // To the line's price, in a line opened afresh (an open one only focuses its field when it opens).
      if (!widget.editable) return;
      setState(() => _active = null);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.editable && _rows.contains(r)) _open(r.uid, 'rate');
      });
      return;
    }
    if (widget.editable) {
      final by = AuthSession.instance.name.trim();
      _changed(() => r.line = r.line.copyWith(zeroPriceConfirmed: true, zeroPriceConfirmedBy: by.isEmpty ? null : by));
    } else {
      await widget.onConfirmZero?.call(r.line);
    }
  }

  /// A hint's one-tap price ("Use last billed $X"): the person's own pick, never filled in for them.
  void _usePrice(_Row r, double price) {
    if (!widget.editable || !_rows.contains(r) || !lineAmountFits(r.line.quantity, price)) return;
    _changed(() {
      r.line = r.line.copyWith(rate: price);
      if (_active == r.uid) _active = null; // an open line's price field would still show the old figure
    });
  }

  void _setInvalid(int uid, String field, bool bad) {
    final set = _invalid.putIfAbsent(uid, () => <String>{});
    final changed = bad ? set.add(field) : set.remove(field);
    if (changed) {
      setState(() {});
      _notifyDirty();
    }
  }

  void _discard() {
    setState(_reset);
    _notifyDirty();
  }

  String? _problem() {
    for (var i = 0; i < _rows.length; i++) {
      final r = _rows[i];
      final bad = _invalid[r.uid] ?? const <String>{};
      if (bad.isNotEmpty) return 'Line ${i + 1}: ${bad.map(_fieldName).join(', ')} ${bad.length == 1 ? "isn't" : "aren't"} a valid number.';
      if (r.line.name.trim().isEmpty) return 'Line ${i + 1} needs a name.';
      if (r.line.isDiscount && (r.line.rate == null || r.line.rate! <= 0)) return 'Discount "${r.line.name}" needs an amount above \$0.';
    }
    if (_taxBad) return _taxRateRule;
    return null;
  }

  static const _taxRateRule = 'Tax rate must be between 0% and 30%.';

  /// What is typed in the tax rate: empty (no tax), or a rate from 0% to 30%; anything else is marked and left out.
  void _typedTaxRate(String v) => _changed(() {
    final t = v.trim();
    final r = t.isEmpty ? null : double.tryParse(t);
    _taxBad = t.isNotEmpty && (r == null || !r.isFinite || r < 0 || r > 30);
    if (!_taxBad) _tax = r;
  });

  static String _fieldName(String f) => switch (f) {
    'qty' => 'quantity',
    'rate' => 'rate',
    'cost' => 'cost',
    _ => f,
  };

  Future<void> _save() async {
    if (widget.onPreviewSave != null) {
      if (widget.editable) widget.onPreviewSave!();
      return;
    }
    if (_saving || !_dirty || widget.onSave == null) return;
    final problem = _problem();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _active = null;
      _savePending = true;
    });
    final err = await widget.onSave!(_lines, _tax);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (err != null) {
        _savePending = false;
        _error = err;
      }
    });
  }

  /// Each line's figures. A line still as its source has it keeps the source's own amount ([fixedAmounts]); one that
  /// was changed or added is quantity x rate.
  List<LineFigures> _lineFigures(LineTotals totals) {
    final fixed = widget.fixedAmounts;
    if (fixed == null) return totals.lines;
    return [
      for (var i = 0; i < _rows.length; i++)
        () {
          final at = _origin[_rows[i].uid];
          final same = at != null && at < fixed.length && at < widget.lines.length && (!widget.editable || _rows[i].line.sameAs(widget.lines[at]));
          return same ? LineFigures(fixed[at], totals.lines[i].extCostCents) : totals.lines[i];
        }(),
    ];
  }

  // ---- build ------------------------------------------------------------------------------------------------------

  /// The figures last passed to [LineItemsEditor.onFigures].
  (int, double?)? _reported;

  void _report(int totalCents, double? marginPct) {
    final now = (totalCents, marginPct);
    if (widget.onFigures == null || now == _reported) return;
    _reported = now;
    // This runs while building: the page hears after the frame (only if nothing newer came in meanwhile).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _reported == now) widget.onFigures?.call(totalCents, marginPct);
    });
  }

  @override
  Widget build(BuildContext context) {
    final totals = computeLineTotals(_lines, _tax, taxRates: {for (final t in widget.taxOptions) t.name: t.rate});
    final figures = _lineFigures(totals);
    final editable = widget.editable;
    if (widget.onFigures != null) {
      // What the summary shows: a source's own figures (reworked for a changed draft), else the worked-out totals.
      final summary = widget.summary == null
          ? null
          : (editable && _dirty && widget.summaryBuilder != null ? widget.summaryBuilder!(_lines, figures) : widget.summary!);
      final total = summary == null
          ? totals.totalCents
          : (summary.where((r) => r.kind == SummaryKind.total).firstOrNull?.cents ?? summary.fold<int>(0, (s, r) => s + r.cents));
      _report(total, _profit(totals, summary)?.marginPct);
    }
    // Selected text in the table's fields: a soft blue, not the theme's lavender; the caret in ink.
    final selection = TextSelectionTheme.of(context).copyWith(
      selectionColor: DashUi.blue.withValues(alpha: 0.2),
      cursorColor: DashUi.ink,
      selectionHandleColor: DashUi.ink,
    );
    return TextSelectionTheme(data: selection, child: _shortcuts(totals, figures, editable));
  }

  Widget _shortcuts(LineTotals totals, List<LineFigures> figures, bool editable) {
    return Shortcuts(
      shortcuts: const {SingleActivator(LogicalKeyboardKey.keyS, control: true): _SaveIntent()},
      child: Actions(
        actions: {_SaveIntent: CallbackAction<_SaveIntent>(onInvoke: (_) => _save())},
        child: Focus(
          autofocus: false,
          child: LayoutBuilder(
            builder: (context, c) {
              final cols = _Cols.of(c.maxWidth - _side * 2, cost: widget.showCost, editable: editable);
              // A source's own figures (Service Fusion's), reworked for the draft once it is changed.
              final summary = widget.summary == null
                  ? null
                  : (editable && _dirty && widget.summaryBuilder != null ? widget.summaryBuilder!(_lines, figures) : widget.summary!);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  ?widget.banner,
                  // With a controller the page's save bar says what went wrong, next to its Save button.
                  if (_error != null && widget.controller == null)
                    Padding(padding: const EdgeInsets.fromLTRB(_side, 0, _side, 10), child: _InlineNotice(_error!, error: true)),
                  // The lines settle in when the table turns editable (or back), rather than snapping between looks.
                  _ModeFade(
                    key: ValueKey(editable),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _table(cols, figures),
                        if (editable) _addRow(cols, narrow: c.maxWidth < 700),
                      ],
                    ),
                  ),
                  _footer(totals, summary, wide: c.maxWidth >= 860),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// The column headings and the lines.
  Widget _table(_Cols cols, List<LineFigures> figures) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      if (!cols.stacked) _header(cols) else const Divider(height: 1, color: DashUi.line),
      if (_rows.isEmpty) _empty() else _list(cols, figures),
    ],
  );

  /// Unsaved-changes mark, Discard and Save, for an editor the page doesn't drive (no [LineItemsEditor.controller]).
  List<Widget> _ownSaveButtons() => [
    const SizedBox(width: 12),
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: DashUi.amber.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: DashUi.amber.withValues(alpha: 0.3)),
      ),
      child: const Text(
        'Unsaved changes',
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.amberText),
      ),
    ),
    const SizedBox(width: 6),
    TextButton(onPressed: _saving ? null : _discard, child: const Text('Discard')),
    Tooltip(
      message: 'Save (Ctrl+S)',
      child: FilledButton.icon(
        onPressed: _saving ? null : _save,
        icon: _saving
            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.check_rounded, size: 18),
        label: Text(_saving ? 'Saving' : 'Save'),
      ),
    ),
  ];

  /// The table's last row: the catalog search (it keeps focus, so lines go in one after another), lined up with the
  /// items, and the Tax, discounts & fees menu beside it.
  Widget _addRow(_Cols cols, {bool narrow = false}) {
    final search = CatalogSearchField(onPick: _pick, showCost: widget.showCost, search: widget.search, focusNode: _searchFocus);
    final charges = PsMenuButton<String>(
      entries: _chargeEntries,
      onSelected: _pickCharge,
      width: 280,
      label: 'Tax, discounts and fees',
      builder: (context, open, show) => TextButton.icon(
        onPressed: show,
        icon: const Icon(Icons.add_rounded, size: 17),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Flexible(
              child: Text('Tax, discounts & fees', maxLines: 1, overflow: TextOverflow.ellipsis, style: _quietLabel),
            ),
            const SizedBox(width: 4),
            _Chevron(open: open),
          ],
        ),
        // Outlined like the search beside it, so both read as buttons (user 2026-11-13), in the table's box outline; ink
        // while its menu is open.
        style: _quietButton.copyWith(
          side: WidgetStatePropertyAll(BorderSide(color: open ? DashUi.ink : _edge, width: _edgeW)),
          backgroundColor: WidgetStatePropertyAll(open ? DashUi.faint : Colors.white),
          padding: const WidgetStatePropertyAll(EdgeInsets.fromLTRB(10, 0, 8, 0)),
          // Exactly as tall as the search beside it (it was 2 px shorter: round 3).
          minimumSize: const WidgetStatePropertyAll(Size(0, CatalogSearchField.height)),
          fixedSize: const WidgetStatePropertyAll(Size.fromHeight(CatalogSearchField.height)),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(_radius))),
        ),
      ),
    );
    final saves = widget.controller == null && widget.onPreviewSave == null && _dirty ? _ownSaveButtons() : const <Widget>[];
    return Container(
      padding: EdgeInsets.fromLTRB(_side + (cols.stacked ? 0 : cols.lead), 10, _side, 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: DashUi.line)),
      ),
      child: narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                search,
                const SizedBox(height: 4),
                Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [charges, ...saves]),
              ],
            )
          : Row(
              children: [
                Flexible(
                  child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: search),
                ),
                const SizedBox(width: 8),
                charges,
                const Spacer(),
                ...saves,
              ],
            ),
    );
  }

  /// The headings: small capitals on white over a hairline, each over its values (the item's over the name, every
  /// figure's right-aligned like the figures, the quantity's included, so the decimals line up). Cost has the lock.
  Widget _header(_Cols cols) {
    // Each heading sits where its column's values put their text: [_cellX] in from the column's edge (a box's border is
    // part of that), right-aligned over figures, left over the item and the tax. A right-aligned heading gives back the
    // letter spacing Flutter leaves after its last letter, so its last letter ends where the figures' last digit does.
    // The quantity's figure ends before its arrows while editing, so its heading does too.
    Widget h(String t, {bool right = true, double end = 0}) => Padding(
      padding: EdgeInsets.only(left: _cellX, right: _cellX + end - (right ? _head.letterSpacing! : 0)),
      child: Align(
        alignment: right ? Alignment.centerRight : Alignment.centerLeft,
        child: Text(t, maxLines: 1, softWrap: false, overflow: TextOverflow.fade, style: _head),
      ),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(_side, 14, _side, 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: DashUi.line)),
      ),
      child: cols.line(
        cross: CrossAxisAlignment.center,
        // No heading over the lines' eyes (user 2026-11-16): each line's own eye says whether the customer sees it. The
        // column keeps its width, so ITEM stays over the names.
        // Read-only the name is bare text at the column's start; while editing it is in a box, [_cellX] in.
        item: Padding(
          padding: EdgeInsets.only(left: cols.editable ? _cellX : 0),
          child: const Text('ITEM', maxLines: 1, style: _head),
        ),
        qtyCell: h('QTY', end: cols.editable ? _Spin.width : 0),
        rateCell: h('RATE'),
        amountCell: h('AMOUNT'),
        costCell: h('COST'),
        taxCell: h('TAX', right: false),
      ),
    );
  }

  Widget _empty() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: const BoxDecoration(color: DashUi.faint, shape: BoxShape.circle),
          child: const Icon(Icons.receipt_long_outlined, size: 24, color: DashUi.slate),
        ),
        const SizedBox(height: 12),
        Text(
          widget.emptyTitle,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: DashUi.ink),
        ),
        const SizedBox(height: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Text(
            widget.emptyMessage,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: DashUi.ink, height: 1.45),
          ),
        ),
      ],
    ),
  );

  /// The lines, laid out at their full height (the page scrolls, not the table).
  ///
  /// Read-only lines are all one height: when any line has a quiet line under its name (its SKU, "Discount", its
  /// Description toggle), every line is as tall as that one, and a line without one sits centred in it, so the table
  /// reads as even rows rather than a ragged list. While editing every line is one row of boxes (the SKU sits inside
  /// the name box), so they are even anyway.
  Widget _list(_Cols cols, List<LineFigures> all) {
    // A tax too long for one line takes two, as a name over its SKU does (see _taxTwoLines).
    final twoLine = !widget.editable && _rows.any((r) => _hasMeta(r.line) || _taxTwoLines(context, r.line, widget.taxOptions, _tax) != null);
    Widget row(int i) {
      final r = _rows[i];
      final figures = all[i];
      final active = widget.editable && _active == r.uid;
      final child = active
          ? _EditRow(
              key: ValueKey('edit-${r.uid}'),
              index: i,
              line: r.line,
              figures: figures,
              cols: cols,
              focusField: _focusField,
              more: _moreOpen.contains(r.uid),
              onMore: () => _toggleMore(r.uid),
              taxOptions: widget.taxOptions,
              defaultRate: _tax,
              onTax: (v) => _pickTax(r, v),
              invalid: _invalid[r.uid] ?? const {},
              onChanged: (l) => _changed(() => r.line = l),
              onInvalid: (f, bad) => _setInvalid(r.uid, f, bad),
              onDone: () => _close(r.uid),
              onMove: (d) => _move(i, i + d),
              onMenu: (a) => _menu(a, i),
            )
          : _ViewRow(
              key: ValueKey('view-${r.uid}'),
              index: i,
              line: r.line,
              figures: figures,
              cols: cols,
              editable: widget.editable,
              twoLine: twoLine,
              more: _moreOpen.contains(r.uid),
              onMore: () => _toggleMore(r.uid),
              onToggleVisible: widget.editable ? () => _changed(() => r.line = r.line.copyWith(customerVisible: !r.line.customerVisible)) : null,
              onQty: widget.editable
                  ? (q) {
                      if (lineAmountFits(q, r.line.rate)) _changed(() => r.line = r.line.copyWith(quantity: q));
                    }
                  : null,
              taxOptions: widget.taxOptions,
              defaultRate: _tax,
              onTax: widget.editable ? (v) => _pickTax(r, v) : null,
              invalid: (_invalid[r.uid] ?? const {}).isNotEmpty,
              onOpen: widget.editable ? (f) => _open(r.uid, f) : null,
              onMenu: (a) => _menu(a, i),
            );
      // Under the line, from where its name starts: its $0.00 confirmation, and what the catalog said about a service
      // just added (see [_lineNotes]).
      final notes = _lineNotes(
        r.line,
        from: _added[r.uid],
        zero: _zeroChecks,
        onConfirm: _canConfirm(r.line) ? () => _askZero(r) : null,
        onUsePrice: widget.editable ? (price) => _usePrice(r, price) : null,
      );
      final body = notes == null
          ? child
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                child,
                Padding(
                  padding: EdgeInsets.fromLTRB(_side + cols.lead + (widget.editable ? _cellX : 0), 0, _side + cols.trail, widget.editable ? 8 : 10),
                  child: notes,
                ),
              ],
            );
      return KeyedSubtree(
        key: ValueKey(r.uid),
        child: _RowShell(
          key: r.shell,
          flash: _flash == r.uid,
          leaving: _leaving.contains(r.uid),
          onLeft: () => _finishRemove(r),
          active: active,
          editable: widget.editable,
          // Read-only lines are told apart by the faint stripe on every other one (no rules between them); editable
          // lines by their boxes, and a small window's stacked editable lines by a rule from where the items start.
          stripe: !widget.editable && i.isOdd,
          ruleLeft: widget.editable && cols.stacked ? _side : null,
          child: body,
        ),
      );
    }

    if (!widget.editable) {
      // The headings' hairline above, this one under the last line: the table is framed, the stripes do the rest.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (var i = 0; i < _rows.length; i++) row(i), const Divider(height: 1, thickness: 1, color: DashUi.line)],
      );
    }
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: _rows.length,
      onReorderItem: _move,
      proxyDecorator: (child, _, anim) =>
          Material(elevation: 4, shadowColor: Colors.black12, color: Colors.white, borderRadius: BorderRadius.circular(8), child: child),
      itemBuilder: (_, i) => row(i),
    );
  }

  void _menu(String action, int index) {
    switch (action) {
      case 'up':
        _move(index, index - 1);
      case 'down':
        _move(index, index + 1);
      case 'duplicate':
        _duplicate(index);
      case 'remove':
        _remove(index);
    }
  }

  /// What the lines cost us and what is left after it, for people who can see costs; null for everyone else.
  ///
  /// The money it is worked out on is what the customer pays before tax. For our own lines that is items less
  /// discounts. Under a source's own figures ([summary], Service Fusion's) it is its items, discounts and other charges,
  /// so a discount Service Fusion keeps as a charge (not as a line) comes off the profit too. Sales tax is never profit,
  /// and money the source doesn't itemize is left out, since what it is isn't known.
  ///
  /// Profit and margin are unknown (null) while any line's cost is (t.missingCostLines > 0, the server's rule): a cost
  /// nobody entered read as $0 and showed a 100% margin.
  _Profit? _profit(LineTotals t, List<LineSummaryRow>? summary) {
    if (!widget.showCost) return null;
    if (summary == null) return _Profit(t.costCents, t.profitCents, t.marginPct, missingCostLines: t.missingCostLines, fromSource: false);
    final net = summary.where((r) => r.beforeTax).fold<int>(0, (s, r) => s + r.cents);
    final profit = t.missingCostLines > 0 ? null : net - t.costCents;
    return _Profit(
      t.costCents,
      profit,
      profit != null && net > 0 ? (profit / net * 1000).round() / 10 : null,
      missingCostLines: t.missingCostLines,
      fromSource: true,
    );
  }

  /// Under the lines: the warnings about the figures and the [LineItemsEditor.aside] on the left, the summary on the
  /// right (stacked on a narrow window, the summary first).
  Widget _footer(LineTotals t, List<LineSummaryRow>? summary, {required bool wide}) {
    final editable = widget.editable;
    final List<_TotalsRow> rows;
    if (summary != null) {
      rows = [for (final r in summary) _TotalsRow(r.strong ? widget.totalLabel : r.label, r.cents, strong: r.strong, tip: r.tip)];
    } else {
      final taxField = editable
          ? Padding(
              padding: const EdgeInsets.only(left: 8),
              child: SizedBox(
                width: 70,
                child: TextField(
                  key: const ValueKey('tax-rate'),
                  mouseCursor: SystemMouseCursors.click,
                  controller: _taxText,
                  cursorColor: DashUi.ink,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.ink, height: 1.35, fontFeatures: _figures),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                  decoration: _inlineDeco(hint: '0', suffix: '%', error: _taxBad),
                  onChanged: _typedTaxRate,
                ),
              ),
            )
          : null;
      final taxMark = _taxBad
          ? const Padding(
              key: ValueKey('tax-rate-invalid'),
              padding: EdgeInsets.only(left: 6),
              child: Icon(Icons.error_outline_rounded, size: 16, color: DashUi.redText, semanticLabel: _taxRateRule),
            )
          : null;
      rows = [
        _TotalsRow('Items', t.itemsCents),
        if (t.discountCents > 0 || _rows.any((r) => r.line.isDiscount)) _TotalsRow('Discounts', -t.discountCents),
        _TotalsRow(
          _tax == null || editable ? 'Tax' : 'Tax ${_trimRate(_tax!)}%',
          t.taxCents,
          extra: taxField == null ? null : Row(mainAxisSize: MainAxisSize.min, children: [taxField, ?taxMark]),
        ),
        _TotalsRow(widget.totalLabel, t.totalCents, strong: true),
      ];
    }
    // Lines with no cost no longer overstate the profit: while any line's cost is unknown the profit panel shows none,
    // and says how many lines have no cost (Services Catalog Phase 2; see _ProfitLines).
    final zero = _zeroChecks ? t.zeroUnconfirmedLines : 0;
    final notes = [
      if (summary == null && editable && _taxBad) _taxRateRule,
      if (summary == null && t.unpricedLines > 0) '${t.unpricedLines} line${t.unpricedLines == 1 ? '' : 's'} not priced yet',
      if (zero > 0) '$zero line${zero == 1 ? '' : 's'} at \$0.00 not confirmed',
    ];
    final card = _Summary(rows: rows, profit: _profit(t, summary));
    final warning = notes.isEmpty ? null : _Warning(notes.join('  ·  '));
    final aside = widget.aside;
    const pad = EdgeInsets.fromLTRB(_side, 22, _side, 4);
    if (!wide) {
      return Padding(
        padding: pad,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (warning != null) ...[warning, const SizedBox(height: 14)],
            card,
            if (aside != null) ...[const SizedBox(height: 24), aside],
          ],
        ),
      );
    }
    return Padding(
      padding: pad,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [?warning, if (warning != null && aside != null) const SizedBox(height: 18), ?aside],
            ),
          ),
          const SizedBox(width: 56),
          SizedBox(width: 360, child: card),
        ],
      ),
    );
  }
}

/// The quiet buttons beside the catalog search: text and an icon, no outline.
final ButtonStyle _quietButton = TextButton.styleFrom(
  minimumSize: const Size(0, 36),
  padding: const EdgeInsets.symmetric(horizontal: 10),
  foregroundColor: DashUi.ink,
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
);

/// Their labels: the size and weight set on the text itself, so it keeps the theme's font.
const _quietLabel = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600);

class _SaveIntent extends Intent {
  const _SaveIntent();
}

/// A field outside the boxes (the set's tax rate, an open description): white with the boxes' hairline, ink while
/// focused, red when what is typed isn't a number.
InputDecoration _inlineDeco({String? hint, String? suffix, String? prefix, bool error = false}) {
  OutlineInputBorder b(Color c, [double w = 1]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(_radius),
    borderSide: BorderSide(color: c, width: w),
  );
  return InputDecoration(
    isDense: true,
    filled: true,
    fillColor: Colors.white,
    hoverColor: Colors.white,
    hintText: hint,
    hintStyle: _hint,
    suffixText: suffix,
    prefixText: prefix,
    prefixStyle: const TextStyle(fontSize: 13, color: DashUi.ink, height: 1.35),
    suffixStyle: const TextStyle(fontSize: 12, color: DashUi.ink, height: 1.35),
    contentPadding: const EdgeInsets.symmetric(horizontal: _cellX, vertical: _cellY),
    border: b(_edge, _edgeW),
    enabledBorder: b(error ? DashUi.red : _edge, error ? 1.5 : _edgeW),
    focusedBorder: b(error ? DashUi.red : DashUi.ink, 1.5),
  );
}

/// A row with its fields closed: the line as text. In an editable table each value that can be changed is a box that
/// opens into its field (see [_FieldCell]), always there as in Service Fusion's own editor; a figure that is worked out
/// (an item's amount) stays plain text beside them, so it is clear what can be typed into and what follows from it.
class _ViewRow extends StatelessWidget {
  final int index;
  final LineDraft line;
  final LineFigures figures;
  final _Cols cols;
  final bool editable;

  /// Read-only: the table's lines are all as tall as a line with a quiet line under its name (see [_list]).
  final bool twoLine;
  final bool invalid;
  final bool more; // the description is showing
  final VoidCallback onMore;
  final VoidCallback? onToggleVisible; // null: read-only
  final ValueChanged<double>? onQty; // the quantity steps (null: read-only)
  final List<SalesTax> taxOptions;
  final double? defaultRate; // the set's own tax rate, for a taxable line with no named tax
  final ValueChanged<String>? onTax; // a pick from the Tax dropdown (see _TaxCell); null: read-only
  final void Function(String field)? onOpen;
  final ValueChanged<String> onMenu;
  const _ViewRow({
    super.key,
    required this.index,
    required this.line,
    required this.figures,
    required this.cols,
    required this.editable,
    this.twoLine = false,
    required this.more,
    required this.onMore,
    required this.onToggleVisible,
    required this.onQty,
    required this.taxOptions,
    required this.defaultRate,
    required this.onTax,
    required this.invalid,
    required this.onOpen,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final open = onOpen != null;
    final discount = line.isDiscount;
    final description = _cleanDescription(line.description);
    // A value that opens into its field (editing), or the value padded the same (read-only).
    Widget cell(String field, Widget child, {Alignment align = Alignment.centerLeft, Widget? end, double? endWidth, bool divider = false}) => open
        ? _FieldCell(onTap: () => onOpen!(field), align: align, end: end, endWidth: endWidth, divider: divider, child: child)
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: _cellX),
            child: Align(alignment: align, child: child),
          );
    // A figure that is worked out, not typed: where a field's text would be.
    Widget plain(Widget child, {Alignment align = Alignment.centerRight}) => Padding(
      padding: EdgeInsets.fromLTRB(_cellX, open ? _cellY : 0, _cellX, 0),
      child: Align(alignment: align, child: child),
    );
    // A line at quantity 0 adds nothing to the price (a catalog entry listed for reference, an optional extra): quieter.
    final idle = !discount && (line.quantity * 1000).round() == 0;
    final cellStyle = idle ? _cell.copyWith(color: _quietTone) : _cell;
    // Money off (a discount, or a Service Fusion item with a negative rate) reads red.
    final amountStyle = idle ? _amountFor(figures.amountCents).copyWith(color: _quietTone) : _amountFor(figures.amountCents);
    final nameText = line.name.isEmpty ? 'Unnamed line' : line.name;
    final nameStyle = line.name.isEmpty
        ? _nameStyle.copyWith(color: DashUi.subtle)
        : (idle ? _nameStyle.copyWith(color: _quietTone, fontWeight: FontWeight.w500) : _nameStyle);
    // "Description": read-only under the name, on a line that has one; while editing at the end of the name box on every
    // line (on a line with none it opens the line's description box, empty, ready to type in).
    Widget? toggleOf({bool compact = false}) => discount || (description.isEmpty && !open)
        ? null
        : description.isEmpty
        ? _DescToggle(key: ValueKey('line-$index-more'), open: false, compact: compact, onTap: () => onOpen!('description'))
        : _DescToggle(key: ValueKey('line-$index-more'), open: more, compact: compact, onTap: onMore);
    final toggle = toggleOf();
    final desc = description.isEmpty || !more ? null : _Description(description, onTap: open ? () => onOpen!('description') : null);
    // Before the item: the grip (editable) and the eye, always there: a toggle in a box while editing.
    final grip = SizedBox(
      height: _boxHeight(context),
      child: _Handle(index: index),
    );
    // Each column's width comes from [_Cols.line] (stacked, from the slots below), never from the cell itself.
    final eye = Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: EdgeInsets.only(top: open ? 0 : 1),
        child: _EyeToggle(visible: line.customerVisible, onTap: onToggleVisible),
      ),
    );
    final actions = Align(
      alignment: Alignment.topRight,
      child: _RowMenu(index: index, onMenu: onMenu),
    );
    // "Not priced" is a to-do on lines being edited; a read-only line with no rate just has none.
    final unpriced = line.rate == null;
    final rateStyle = unpriced ? (editable ? _cell.copyWith(fontWeight: FontWeight.w600, color: DashUi.amberText) : _cellMuted) : cellStyle;
    final Widget rateValue = unpriced
        ? Text(editable ? 'Not priced' : '—', textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: rateStyle)
        : _money(context, line.rate!, boxed: open, style: cellStyle);
    // No cost: read-only a dash; while editing the empty box says what goes in it, as the field it opens into does
    // (on the figure's line, [_valueLine], where the field puts its placeholder).
    final Widget costValue = line.cost == null
        ? Text(
            open ? 'Cost' : '—',
            textAlign: TextAlign.right,
            maxLines: 1,
            style: open ? _hint : _cellMuted,
            strutStyle: open ? _valueLine(context, _costText) : null,
          )
        : _money(context, line.cost!, boxed: open, style: idle ? _costText.copyWith(color: _quietTone) : _costText);
    // While editing, the name box carries the line's SKU (or "Discount") before its Description, so every line is one
    // row of boxes (left out when the box is too narrow to give the name room).
    final nameInBox = Row(
      children: [
        if (invalid) const _InvalidMark(),
        Expanded(
          // A long name cut short in its box shows whole on hover (the field shows it all once the line opens).
          child: Tooltip(
            message: nameText.length > 40 ? nameText : '',
            waitDuration: const Duration(milliseconds: 600),
            child: Text.rich(_nameSpan(nameText, nameStyle), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
    );
    // Stacked, the SKU goes under the box with the figures instead.
    Widget nameBox() => LayoutBuilder(
      builder: (context, c) => _FieldCell(
        onTap: () => onOpen!('name'),
        meta: !cols.stacked && (line.isDiscount || c.maxWidth >= _Cols.skuInBoxW) ? _inlineMeta(line) : null,
        end: toggleOf(compact: c.maxWidth < _Cols.compactToggleW),
        divider: true,
        child: nameInBox,
      ),
    );
    final readName = _NameText(nameText, style: nameStyle, invalid: invalid);
    final meta = open ? null : _metaLine(line, toggle: toggle, tone: idle ? _quietTone : DashUi.ink);

    if (cols.stacked) {
      // A small window: the name and amount on top; under the name its quiet line, then quantity x rate, tax and cost.
      String money(double? v) => v == null ? '' : centsMoney((v * 100).round());
      final figuresText = [
        if (open && !discount && line.sku.trim().isNotEmpty) line.sku.trim(),
        if (!discount) '${qtyText(line.quantity)} × ${line.rate == null ? 'not priced' : money(line.rate)}',
        if (!discount) _taxLabel(line, taxOptions, defaultRate) else if (line.taxable) 'Off taxed lines',
        if (cols.cost && !discount) 'cost ${line.cost == null ? '—' : money(line.cost)}',
      ].join('  ·  ');
      final figuresLine = figuresText.isEmpty
          ? null
          : Text(
              figuresText,
              style: _metaStyle.copyWith(fontSize: 12.5, color: line.rate == null && !discount && editable ? DashUi.amberText : DashUi.ink),
            );
      // Editable: only the name is a box, the same one-line box (Description at its end) as the name field it opens
      // into, so clicking it never changes its size (user 2026-11-13). Its figures sit under it, as the opened line's
      // do; a click on them opens the line at its quantity.
      final Widget body = open
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                nameBox(),
                if (figuresLine != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(_cellX, 4, 0, 0),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onOpen!('qty'),
                        child: SelectionContainer.disabled(child: figuresLine),
                      ),
                    ),
                  ),
                _Reveal(child: desc == null ? null : Padding(padding: const EdgeInsets.fromLTRB(0, 8, 0, 2), child: desc)),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                readName,
                if (meta != null)
                  Padding(
                    padding: const EdgeInsets.only(top: _metaGap),
                    child: meta,
                  ),
                if (figuresLine != null) Padding(padding: const EdgeInsets.only(top: 3), child: figuresLine),
                _Reveal(child: desc == null ? null : Padding(padding: const EdgeInsets.fromLTRB(0, 8, 0, 2), child: desc)),
              ],
            );
      return Semantics(
        label: 'Line ${index + 1}: ${line.name}',
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: _side, vertical: open ? _cellY + 1 : _rowPad),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (cols.editable) SizedBox(width: _Cols.gripW, child: grip),
              SizedBox(width: _Cols.eyeW, child: eye),
              Expanded(child: body),
              const SizedBox(width: 10),
              // One width for every line's amount, so the name boxes above line up.
              SizedBox(
                width: _Cols.stackAmountW,
                child: Padding(
                  padding: EdgeInsets.only(top: open ? _cellY : 0),
                  child: Text(centsMoney(figures.amountCents), textAlign: TextAlign.right, maxLines: 1, style: amountStyle),
                ),
              ),
              if (cols.editable) SizedBox(width: _Cols.actionsW, child: actions),
            ],
          ),
        ),
      );
    }

    final item = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (open) nameBox() else readName,
        if (meta != null)
          Padding(
            padding: const EdgeInsets.only(top: _metaGap),
            child: meta,
          ),
        _Reveal(child: desc == null ? null : Padding(padding: EdgeInsets.fromLTRB(0, 8, open ? 0 : 24, 2), child: desc)),
      ],
    );
    final Widget tax = discount
        ? plain(
            line.taxable
                ? const Text('Off taxed lines', maxLines: 1, overflow: TextOverflow.ellipsis, style: _cellMuted)
                : const SizedBox(height: 18),
            align: Alignment.centerLeft,
          )
        : _TaxCell(line: line, options: taxOptions, defaultRate: defaultRate, onPick: onTax, quiet: idle);
    final qtyValue = Text(qtyText(line.quantity), textAlign: TextAlign.right, maxLines: 1, style: cellStyle);
    final Widget? qty = discount
        ? null
        : open
        // A quantity is never cut short: one wider than the box (a stored -999,999.999) is drawn smaller instead.
        ? cell(
            'qty',
            FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: qtyValue),
            align: Alignment.centerRight,
            end: onQty == null ? null : _Spin(value: line.quantity, rate: line.rate, onChanged: onQty!),
            endWidth: onQty == null ? null : _Spin.width,
          )
        : plain(qtyValue);
    final Widget? rate = discount ? null : (open ? cell('rate', rateValue, align: Alignment.centerRight) : plain(rateValue));
    // A discount's amount is what is typed (a box while editing); an item's is worked out, plain text, never a box.
    final amountText = Text(centsMoney(figures.amountCents), textAlign: TextAlign.right, maxLines: 1, style: amountStyle);
    final Widget amount = discount && open
        ? cell('rate', _money(context, -figures.amountCents / 100, boxed: true, style: amountStyle), align: Alignment.centerRight)
        : plain(amountText);
    final Widget? cost = discount ? null : (open ? cell('cost', costValue, align: Alignment.centerRight) : plain(costValue));
    final sym = cols.editable && !discount;
    Widget body = Padding(
      padding: EdgeInsets.symmetric(horizontal: _side, vertical: open ? _cellY + 1 : _rowPad),
      child: cols.line(
        grip: grip,
        eye: eye,
        item: item,
        qtyCell: qty,
        times: _Sym(sym ? '×' : ''),
        rateCell: rate,
        equals: _Sym(sym ? '=' : ''),
        amountCell: amount,
        costCell: cost,
        taxCell: tax,
        menu: actions,
      ),
    );
    if (twoLine && !open) {
      // As tall as a line with a quiet line under its name; a line without one sits in the middle of that height.
      body = ConstrainedBox(
        constraints: BoxConstraints(minHeight: _twoLineHeight(context)),
        child: Align(alignment: Alignment.centerLeft, child: body),
      );
    }
    return Semantics(label: 'Line ${index + 1}: ${line.name}', child: body);
  }
}

/// A read-only line's name: up to two lines, the whole of it on hover when it is long enough to be cut short.
class _NameText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final bool invalid;
  const _NameText(this.text, {required this.style, this.invalid = false});

  @override
  Widget build(BuildContext context) {
    final name = Text.rich(_nameSpan(text, style), maxLines: 2, overflow: TextOverflow.ellipsis);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (invalid) const _InvalidMark(),
        Flexible(
          child: text.length > 60 ? Tooltip(message: text, waitDuration: const Duration(milliseconds: 600), child: name) : name,
        ),
      ],
    );
  }
}

/// Money in a value's place. Read-only "$1,489.00"; in a box while editing "$" at the box's left and the figure at
/// its right, exactly as the field it opens into shows them (the "$" on the figure's line, [_valueLine]), so nothing
/// moves when it opens.
Widget _money(BuildContext context, double dollars, {required bool boxed, TextStyle style = _cell}) {
  final cents = (dollars * 100).round();
  if (!boxed) return Text(centsMoney(cents), textAlign: TextAlign.right, maxLines: 1, style: style);
  return Row(
    children: [
      Text(r'$', style: _currency, strutStyle: _valueLine(context, style)),
      const SizedBox(width: 4),
      // Laid out as the field lays out its text, and as the quantity box does: at the figure's own width, set at the
      // box's right (one too wide is drawn smaller, never cut short). Right-aligned across the whole box instead, the
      // text engine set it a fraction of a pixel (1/8) left of where the field puts it, so it moved as its line opened.
      Expanded(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerRight,
          child: Text(_plainMoney(cents), textAlign: TextAlign.right, maxLines: 1, style: style),
        ),
      ),
    ],
  );
}

/// "1,489.00", "-30.00": money without its "$" (the box shows that at its left).
String _plainMoney(int cents) => centsMoney(cents).replaceFirst(r'$', '');

/// The height a read-only line takes when it has a quiet line under its name, at the reader's text size.
double _twoLineHeight(BuildContext context) {
  final s = MediaQuery.textScalerOf(context);
  return 2 * _rowPad + s.scale(14) * 1.35 + _metaGap + _metaHeight(context);
}

/// The quiet line's height: its text, or the Description toggle, whichever is taller.
double _metaHeight(BuildContext context) => (MediaQuery.textScalerOf(context).scale(12) * 1.4).ceilToDouble() + 2;

/// The x between quantity and rate, and the = before the amount, while editing: how the amount is made.
class _Sym extends StatelessWidget {
  final String text;
  const _Sym(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: _cellY),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: DashUi.subtle, height: 1.35),
    ),
  );
}

/// Whether a read-only line has a quiet line under its name.
bool _hasMeta(LineDraft line) => line.isDiscount || line.sku.trim().isNotEmpty || _cleanDescription(line.description).isNotEmpty;

/// What sits at the end of a line's name box while editing: its SKU, or "Discount".
Widget? _inlineMeta(LineDraft line) {
  if (line.isDiscount) {
    return Text(
      'Discount',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: _metaStyle.copyWith(fontWeight: FontWeight.w600, color: DashUi.redText),
    );
  }
  final sku = line.sku.trim();
  return sku.isEmpty ? null : Text(sku, maxLines: 1, overflow: TextOverflow.ellipsis, style: _metaStyle.copyWith(letterSpacing: 0.3));
}

/// Under a read-only line's name: what kind of line it is when that isn't plain, its SKU, and its Description toggle.
/// Null when there is nothing to say. (Whether the customer sees the line is its eye's to say.) [tone]: the line's own
/// (slate on a line at quantity 0).
Widget? _metaLine(LineDraft line, {Widget? toggle, Color tone = DashUi.ink}) {
  final parts = <Widget>[
    if (line.isDiscount)
      Text(
        'Discount',
        style: _metaStyle.copyWith(fontWeight: FontWeight.w600, color: DashUi.redText),
      ),
    if (!line.isDiscount && line.sku.trim().isNotEmpty) Text(line.sku.trim(), maxLines: 1, style: _metaStyle.copyWith(letterSpacing: 0.3, color: tone)),
  ];
  if (parts.isEmpty && toggle == null) return null;
  return Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    runSpacing: 2,
    children: [
      for (var i = 0; i < parts.length; i++) ...[
        if (i > 0)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 7),
            child: Text('·', style: _metaStyle),
          ),
        parts[i],
      ],
      // The toggle pads its label for its focus ring; on its own it is pulled back so the label lines up with the name.
      if (toggle != null)
        parts.isEmpty
            ? Transform.translate(offset: const Offset(-_DescToggle.inset, 0), child: toggle)
            : Padding(
                padding: const EdgeInsets.only(left: 10 - _DescToggle.inset),
                child: toggle,
              ),
    ],
  );
}

/// Around each line: the faint stripe on every other read-only line, the rule under a small window's stacked editable
/// line, the light of a line just added, and the open line's tint with an ink edge down its left side. Nothing changes
/// under the pointer (user 2026-11-13 round 3: a whole row lighting up made read-only lines look clickable); the
/// controls in a line have hover looks of their own.
class _RowShell extends StatefulWidget {
  /// Just added: it slides open as it comes in, and is lit for a moment.
  final bool flash;

  /// Deleted: it folds away, then [onLeft].
  final bool leaving;
  final VoidCallback? onLeft;
  final bool active;
  final bool editable;

  /// One of the read-only table's every-other lines: [_stripe] behind it.
  final bool stripe;
  final double? ruleLeft; // null: no rule under the line
  final Widget child;
  const _RowShell({
    super.key,
    required this.flash,
    this.leaving = false,
    this.onLeft,
    required this.active,
    required this.editable,
    this.stripe = false,
    this.ruleLeft,
    required this.child,
  });

  @override
  State<_RowShell> createState() => _RowShellState();
}

class _RowShellState extends State<_RowShell> with SingleTickerProviderStateMixin {
  /// The line's presence: 0 folded away, 1 there. A line that is already there when the table is built starts at 1.
  late final _presence = AnimationController(
    vsync: this,
    value: widget.flash ? 0 : 1,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 170),
  );
  late final _fold = CurvedAnimation(parent: _presence, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_presence.isDismissed && !widget.leaving) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _presence.value = 1;
      } else {
        _presence.forward();
      }
    }
  }

  @override
  void didUpdateWidget(_RowShell old) {
    super.didUpdateWidget(old);
    if (widget.leaving && !old.leaving) {
      _presence.reverse().then((_) {
        if (mounted && widget.leaving) widget.onLeft?.call();
      });
    }
  }

  @override
  void dispose() {
    _fold.dispose();
    _presence.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _fold,
    builder: (context, child) {
      final v = _fold.value;
      // Clipped only while it folds, so a focused box's ring isn't cut off once it is there.
      return ClipRect(
        clipBehavior: v < 1 ? Clip.hardEdge : Clip.none,
        child: Align(alignment: Alignment.topCenter, heightFactor: v, child: child),
      );
    },
    child: FadeTransition(
      opacity: _presence,
      child: IgnorePointer(ignoring: widget.leaving, child: _shell(context)),
    ),
  );

  Widget _shell(BuildContext context) {
    final color = widget.flash
        ? DashUi.blue.withValues(alpha: 0.08)
        : widget.active
        ? _rowTint
        : (widget.stripe ? _stripe : Colors.white);
    return RepaintBoundary(
      child: Stack(
        children: [
          AnimatedContainer(duration: _motion(context, widget.flash ? 500 : 140), curve: Curves.easeOut, color: color, child: widget.child),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: AnimatedContainer(duration: _motion(context, 160), curve: Curves.easeOutCubic, width: widget.active ? 2 : 0, color: DashUi.ink),
          ),
          if (widget.ruleLeft case final left?)
            Positioned(
              left: left,
              right: _side,
              bottom: 0,
              child: IgnorePointer(child: Container(height: 1, color: _rowRule)),
            ),
        ],
      ),
    );
  }
}

/// A box for a value in an editable line, always there (user 2026-11-13): white with a quiet hairline, darker under the
/// pointer, ink with a soft ring while its field has focus, red when what is typed isn't a number. Nothing in it is
/// grey (user 2026-11-13 pass 5): [end] sits inside the box at its right, past a hairline when [divider] (Description,
/// the tax chevron) or bare (the quantity's arrows).
///
/// With [onTap] it opens the line with that field. It can be reached with Tab too: landing on it opens the line there
/// ([openOnFocus], the values), or Enter / Space does what a click does (the tax select). [pad] false when the child is
/// the field itself, which pads its own text the same, so nothing moves when it opens.
class _FieldCell extends StatefulWidget {
  final VoidCallback? onTap;
  final Alignment align;
  final Widget child;
  final Widget? end;

  /// [end]'s fixed width, padding included (the qty arrows: [_Spin.width]), so the value beside it ends at a known
  /// place and the heading above can end there too. Null: as wide as [end] is.
  final double? endWidth;

  /// Before [end], with no rule: the name box's SKU (or "Discount").
  final Widget? meta;
  final bool divider;
  final bool focused;
  final bool error;
  final bool pad;
  final bool openOnFocus;

  // One fixed height ([_boxHeight]), the same for the value and for the field it opens into, so focusing a value never
  // changes the row's height (user 2026-11-13).
  const _FieldCell({
    this.onTap,
    required this.child,
    this.align = Alignment.centerLeft,
    this.end,
    this.endWidth,
    this.meta,
    this.divider = false,
    this.focused = false,
    this.error = false,
    this.pad = true,
    this.openOnFocus = true,
  });

  @override
  State<_FieldCell> createState() => _FieldCellState();
}

class _FieldCellState extends State<_FieldCell> with _FocusRing {
  final _node = FocusNode(debugLabel: 'line value');
  bool _hover = false;

  @override
  FocusNode get ringNode => _node;

  @override
  void dispose() {
    super.dispose();
    _node.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The box's own keyboard focus only: a click on something inside it (an arrow, Description) gives that focus, and
    // used to light the whole box (round 3, 2026-11-13).
    final focused = widget.focused || ring;
    final edge = widget.error
        ? DashUi.red
        : focused
        ? DashUi.ink
        : _hover
        ? _edgeHover
        : _edge;
    Widget main = widget.pad
        ? Padding(
            // The border's width comes off the padding, so the value sits where the field's text will.
            padding: const EdgeInsets.symmetric(horizontal: _cellX - _edgeW, vertical: _cellY - _edgeW),
            child: Align(alignment: widget.align, child: widget.child),
          )
        : Align(alignment: Alignment.centerLeft, child: widget.child);
    final end = widget.end;
    final meta = widget.meta;
    Widget box = AnimatedContainer(
      duration: _motion(context, 120),
      curve: Curves.easeOut,
      width: double.infinity,
      height: _boxHeight(context),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_radius),
        border: Border.all(color: edge, width: _edgeW),
        boxShadow: widget.error ? _ring(DashUi.red) : (focused ? _ring(DashUi.ink) : null),
      ),
      child: end == null && meta == null
          ? main
          : Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: main),
                if (meta != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, right: 8),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: _Cols.skuMaxW),
                        child: meta,
                      ),
                    ),
                  ),
                if (end != null)
                  Container(
                    width: widget.endWidth,
                    padding: EdgeInsets.symmetric(horizontal: widget.divider ? 2 : 1),
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
    final tap = widget.onTap;
    if (tap != null) {
      // A click target, not text: the page-wide selection must not highlight (or I-beam) its label.
      box = FocusableActionDetector(
        focusNode: _node,
        mouseCursor: SystemMouseCursors.click,
        // Only the box's own focus (Tab landing on it): a click on something inside it (Description, an arrow) takes
        // focus too, and must do just its own thing (found by the 2026-11-13 review).
        onFocusChange: widget.openOnFocus
            ? (f) {
                if (f && _node.hasPrimaryFocus) tap();
              }
            : null,
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => tap())},
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // A select (the tax) takes focus as it opens its menu, so focus comes back to it when the menu closes.
          onTap: widget.openOnFocus
              ? tap
              : () {
                  _node.requestFocus();
                  tap();
                },
          child: SelectionContainer.disabled(child: box),
        ),
      );
    }
    return MouseRegion(onEnter: (_) => setState(() => _hover = true), onExit: (_) => setState(() => _hover = false), child: box);
  }
}

/// A description as it was typed: its own lines kept (Service Fusion's are "SIZE : 10' X 10'", "MODEL : 3150", one
/// to a line), stray blank lines and trailing spaces dropped.
String _cleanDescription(String raw) {
  final lines = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n').map((l) => l.trimRight()).toList();
  final out = <String>[];
  for (final l in lines) {
    if (l.isEmpty && (out.isEmpty || out.last.isEmpty)) continue;
    out.add(l);
  }
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  return out.join('\n');
}

/// Before the name of a closed line with a number that doesn't parse.
class _InvalidMark extends StatelessWidget {
  const _InvalidMark();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(right: 6),
    child: Icon(Icons.error_outline_rounded, size: 15, color: DashUi.red),
  );
}

/// Whether a line shows on the customer's copy, at the start of every line. Read-only it only says so; while editing a
/// click hides or shows it, and it takes focus so an open row stays open.
class _EyeToggle extends StatefulWidget {
  final bool visible;
  final VoidCallback? onTap; // null: read-only
  const _EyeToggle({required this.visible, this.onTap});

  /// The icon, and the box it sits in while editing (the eye heading is centred over whichever the lines have).
  static const iconSize = 15.0, boxW = 30.0;

  /// Both states are quiet, told apart by the eye's slash rather than by weight (user 2026-11-13 round 4: the eye on
  /// every line was noise; 78% of Service Fusion's lines since 2025 are hidden ones, so a dark "hidden" eye was on most
  /// rows). Shown is the lighter of the two; both pass 3:1 against white.
  static final shownTone = Color.lerp(DashUi.muted, DashUi.subtle, 0.5)!;
  static const hiddenTone = DashUi.subtle;

  @override
  State<_EyeToggle> createState() => _EyeToggleState();
}

class _EyeToggleState extends State<_EyeToggle> with _FocusRing {
  final _node = FocusNode(debugLabel: 'customer visibility');
  bool _hover = false;

  @override
  FocusNode get ringNode => _node;
  bool get _focus => ring;

  @override
  void dispose() {
    super.dispose();
    _node.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.visible;
    final lit = _hover || _focus;
    // Quiet at rest whichever it says; ink under the pointer or with keyboard focus, where it is a control.
    final icon = AnimatedSwitcher(
      duration: _motion(context, 160),
      switchInCurve: Curves.easeOutBack,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (c, a) => ScaleTransition(
        scale: Tween<double>(begin: 0.6, end: 1).animate(a),
        child: FadeTransition(opacity: a, child: c),
      ),
      child: Icon(
        v ? Icons.visibility_outlined : Icons.visibility_off_outlined,
        key: ValueKey(v),
        size: _EyeToggle.iconSize,
        color: lit ? DashUi.ink : (v ? _EyeToggle.shownTone : _EyeToggle.hiddenTone),
      ),
    );
    final tap = widget.onTap;
    if (tap == null) {
      return Tooltip(
        message: v ? 'Shown to the customer' : 'Hidden from the customer',
        child: Semantics(label: v ? 'Shown to the customer' : 'Hidden from the customer', excludeSemantics: true, child: icon),
      );
    }
    return Tooltip(
      message: v ? 'Shown to the customer. Click to hide it.' : 'Hidden from the customer. Click to show it.',
      child: Semantics(
        button: true,
        toggled: v,
        label: 'Show to the customer',
        excludeSemantics: true,
        child: FocusableActionDetector(
          focusNode: _node,
          mouseCursor: SystemMouseCursors.click,
          onShowHoverHighlight: (h) => setState(() => _hover = h),
          actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => tap())},
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              _node.requestFocus();
              tap();
            },
            // No box at rest (round 4: an outlined box on every line was the noise): a light fill under the pointer, the
            // ink outline and ring for keyboard focus only.
            child: AnimatedContainer(
              duration: _motion(context, 120),
              curve: Curves.easeOut,
              width: _EyeToggle.boxW,
              height: _boxHeight(context),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _hover ? _press : Colors.white.withValues(alpha: 0),
                borderRadius: BorderRadius.circular(_radius),
                border: Border.all(color: _focus ? DashUi.ink : DashUi.ink.withValues(alpha: 0), width: _edgeW),
                boxShadow: _focus ? _ring(DashUi.ink) : null,
              ),
              child: icon,
            ),
          ),
        ),
      ),
    );
  }
}

/// A quantity's up and down arrows, stacked inside its box at the right. (The keyboard has Up / Down in the field
/// instead, so the arrows are left out of Tab.)
class _Spin extends StatelessWidget {
  final double value;

  /// The line's rate: an arrow that would take the line's amount past what one line may come to is off.
  final double? rate;
  final ValueChanged<double> onChanged;

  /// In an open line: a click on an arrow leaves the typing in the qty field, caret and all (the field used to lose
  /// focus to the click, and its box its outline). On a closed line the arrow takes focus, so a line open elsewhere
  /// closes.
  final bool inField;
  const _Spin({required this.value, required this.rate, required this.onChanged, this.inField = false});

  /// The room the arrows take at the end of the box, padding included ([_FieldCell.endWidth]).
  static const width = 22.0;

  @override
  Widget build(BuildContext context) {
    final arrows = Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _StepButton(by: 1, value: value, rate: rate, onChanged: onChanged, takesFocus: !inField),
        _StepButton(by: -1, value: value, rate: rate, onChanged: onChanged, takesFocus: !inField),
      ],
    );
    // Part of the field's own tap region: a click here is not a click outside the field.
    return inField ? TextFieldTapRegion(child: arrows) : arrows;
  }
}

/// One arrow of a quantity: one more or one less, through 0 and on into negatives (a return or credit: user 2026-11-13
/// round 4, "stepping between positive, zero, and negative values"). It takes focus when clicked, so an open row stays
/// open.
class _StepButton extends StatefulWidget {
  final int by; // -1 or 1
  final double value;
  final double? rate;
  final ValueChanged<double> onChanged;

  /// False in an open line: the click leaves focus in the qty field (see [_Spin.inField]).
  final bool takesFocus;
  const _StepButton({required this.by, required this.value, required this.rate, required this.onChanged, this.takesFocus = true});

  /// One step to [next] is allowed: either way, as far as the quantity limit (the server's, either sign) and never so
  /// far that quantity x rate passes what one line may come to (the arrow used to stay lit there and do nothing; found
  /// in round 2, 2026-11-13). Down used to stop at 0 (a negative had to be typed); since round 4 it steps on through 0.
  static bool allowed(double next, {required double? rate}) => next.abs() <= kMaxLineQuantity && lineAmountFits(next, rate);

  @override
  State<_StepButton> createState() => _StepButtonState();
}

/// No focus ring, ever: Tab never stops on an arrow (the keyboard has Up / Down in the field), so the only focus an
/// arrow gets is from a click, and a ring after a click was the outline left round a clicked arrow (round 3).
/// Under the pointer a light fill and an ink arrow, a touch darker while pressed.
class _StepButtonState extends State<_StepButton> {
  late final _node = FocusNode(debugLabel: widget.by > 0 ? 'quantity up' : 'quantity down', skipTraversal: true, canRequestFocus: widget.takesFocus);
  bool _hover = false;
  bool _down = false;

  @override
  void didUpdateWidget(_StepButton old) {
    super.didUpdateWidget(old);
    _node.canRequestFocus = widget.takesFocus;
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  double get _next => ((widget.value + widget.by) * 1000).round() / 1000;

  bool get _enabled => _StepButton.allowed(_next, rate: widget.rate);

  void _step() {
    if (widget.takesFocus) _node.requestFocus();
    if (_enabled) widget.onChanged(_next);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled;
    final label = widget.by > 0 ? 'One more' : 'One less';
    return Tooltip(
      message: label,
      excludeFromSemantics: true, // the Semantics below says it
      waitDuration: const Duration(milliseconds: 400),
      child: Semantics(
        button: true,
        enabled: enabled,
        label: label,
        excludeSemantics: true,
        child: FocusableActionDetector(
          focusNode: _node,
          mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onShowHoverHighlight: (h) => setState(() => _hover = h),
          actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => enabled ? _step() : null)},
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: enabled ? (_) => setState(() => _down = true) : null,
            onTapCancel: () => setState(() => _down = false),
            onTap: enabled
                ? () {
                    setState(() => _down = false);
                    _step();
                  }
                : null,
            child: AnimatedContainer(
              duration: _motion(context, 90),
              curve: Curves.easeOut,
              width: 20,
              height: 14,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: !enabled ? null : (_down ? DashUi.line : (_hover ? _press : null)),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Icon(
                widget.by > 0 ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                size: 16,
                color: !enabled ? DashUi.line : (_hover || _down ? DashUi.ink : DashUi.slate),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What a line's Tax cell says: "Bentonville 9.5%", "Taxable 10%" (the set's own rate), or "No tax".
String _taxLabel(LineDraft line, List<SalesTax> options, double? defaultRate) {
  final p = _taxParts(line, options, defaultRate);
  return p.rate == null ? p.name : '${p.name} ${p.rate}';
}

/// A line's tax in its parts: the place as Service Fusion names it, short ("Springdale, Washington" from "Sales Tax
/// (State, County, & Local Use Tax, Springdale, Washington)"), or "Taxable" / "No tax"; and its rate ("9.75%"), when
/// known.
({String name, String? rate}) _taxParts(LineDraft line, List<SalesTax> options, double? defaultRate) {
  if (!line.taxable) return (name: 'No tax', rate: null);
  final name = line.taxName;
  // A record with tax lines of its own: the one this line is charged at (see SalesTax.resolve), as the totals have it.
  if (options.isNotEmpty) {
    final t = SalesTax.resolve(name, options);
    if (t != null) return (name: t.short, rate: '${SalesTax.rateText(t.rate)}%');
    return (name: name == null ? 'Taxable' : SalesTax.shortName(name), rate: null);
  }
  if (name == null) return (name: 'Taxable', rate: defaultRate == null ? null : '${SalesTax.rateText(defaultRate)}%');
  return (name: SalesTax.shortName(name), rate: null);
}

/// The room a read-only tax label has on one line: the column less its cell padding.
const _taxTextW = _Cols.taxW - 2 * _cellX;

/// The room in the tax select's box: less its chevron at the end, past a hairline.
const _taxBoxTextW = _taxTextW - 26;

/// Whether [text] is wider than [room] in the table's cell style (at the reader's text size).
bool _overflows(BuildContext context, String text, double room, {TextStyle style = _cell}) {
  final p = TextPainter(
    text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.merge(style)),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final over = p.width > room;
  p.dispose();
  return over;
}

/// A tax too long for one line of its column, in two: the place over the rest of its name and the rate, the way an
/// item's name sits over its SKU ("Springdale" over "Washington · 9.75%"). Null when it fits on one line, which keeps
/// it there ("Prairie Grove 10.5%"). The commonest tax on prod, "Springdale, Washington" (2,867 lines), was cut short
/// to "Springdale, Washingt..." on one line (user 2026-11-13 round 4: long location-based labels truncate).
(String, String)? _taxTwoLines(BuildContext context, LineDraft line, List<SalesTax> options, double? defaultRate) {
  final p = _taxParts(line, options, defaultRate);
  final one = p.rate == null ? p.name : '${p.name} ${p.rate}';
  if (!_overflows(context, one, _taxTextW)) return null;
  final comma = p.name.indexOf(', ');
  final place = comma < 0 ? p.name : p.name.substring(0, comma);
  final rest = [if (comma >= 0) p.name.substring(comma + 2).trim(), ?p.rate].join(' · ');
  return rest.isEmpty ? null : (place, rest);
}

/// A line's sales tax. Read-only it says which; while editing it is a dropdown of the record's own tax (its Rogers tax
/// line, say; or the set's own rate when the set has no named tax) and No tax.
class _TaxCell extends StatelessWidget {
  static const none = '\u0000none';
  static const setRate = '\u0000set';

  final LineDraft line;
  final List<SalesTax> options;
  final double? defaultRate;
  final ValueChanged<String>? onPick;

  /// A line at quantity 0: drawn in the quieter tone its line is (see [_ViewRow]).
  final bool quiet;
  const _TaxCell({required this.line, required this.options, required this.defaultRate, required this.onPick, this.quiet = false});

  /// The menu's ticked choice: the tax the line is charged at (resolved as its label is), so a line Service Fusion
  /// calls just "Sales Tax" shows the record's own tax ticked, not an unknown name.
  String get _current {
    if (!line.taxable) return none;
    final resolved = SalesTax.resolve(line.taxName, options);
    return resolved?.name ?? line.taxName ?? setRate;
  }

  /// The record's own tax (or the set's rate) and No tax, the current one ticked.
  List<PsMenuEntry<String>> _entries() {
    final current = _current;
    PsMenuItem<String> item(String value, String text, {String? sub}) => PsMenuItem(value, text, trailing: sub, selected: value == current);
    // A named tax that isn't the record's and can't be matched to it (an old or one-off name) is still shown, so the
    // current choice is visible.
    final orphan = line.taxName != null && SalesTax.resolve(line.taxName, options) == null && !options.any((t) => t.name == line.taxName)
        ? line.taxName
        : null;
    return [
      for (final t in options) item(t.name, t.short, sub: '${SalesTax.rateText(t.rate)}%'),
      if (options.isEmpty && (line.taxable && line.taxName == null || defaultRate != null))
        item(setRate, 'Taxable', sub: defaultRate == null ? null : '${SalesTax.rateText(defaultRate!)}%'),
      if (orphan != null) item(orphan, SalesTax.shortName(orphan), sub: 'rate not known'),
      item(none, 'No tax'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final parts = _taxParts(line, options, defaultRate);
    final label = _taxLabel(line, options, defaultRate);
    final style = quiet ? _cell.copyWith(color: _quietTone) : _cell;
    // What a screen reader hears: the tax as Service Fusion names it in full, and its rate.
    final full = line.taxName == null || !line.taxable ? label : '${line.taxName}${parts.rate == null ? '' : ', ${parts.rate}'}';
    if (onPick == null) {
      // One line when it fits; a long place name in two, over its rate, as an item's name sits over its SKU.
      final two = _taxTwoLines(context, line, options, defaultRate);
      return Semantics(
        container: true,
        label: 'Tax: $full',
        excludeSemantics: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: _cellX),
          child: two == null
              ? Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(two.$1, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
                    Padding(
                      padding: const EdgeInsets.only(top: _metaGap),
                      child: Text(two.$2, maxLines: 1, overflow: TextOverflow.ellipsis, style: _metaStyle.copyWith(color: style.color)),
                    ),
                  ],
                ),
        ),
      );
    }
    // In the select's box: the whole label when it fits, else the place's first part and the rate, which always shows
    // ("Springdale 9.75%"); its menu has the place in full.
    final boxText = !_overflows(context, label, _taxBoxTextW) || parts.rate == null
        ? label
        : '${parts.name.split(', ').first} ${parts.rate}';
    final text = Text(boxText, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    // A select: the value in its box with a chevron at its end, opening the menu of the record's own tax and No tax.
    // Tab stops on it; Enter or Space opens the menu. While the menu is open the box is outlined in ink and its chevron
    // points up.
    return PsMenuButton<String>(
      entries: _entries,
      onSelected: (v) {
        if (v != _current) onPick!(v);
      },
      // Wide enough for the place in full beside its rate ("Springdale, Washington  9.75%").
      width: 264,
      matchAnchorWidth: true,
      checks: true,
      label: 'Tax',
      builder: (context, open, show) => Semantics(
        button: true,
        expanded: open,
        label: 'Tax: $full',
        excludeSemantics: true,
        child: _FieldCell(
          onTap: show,
          openOnFocus: false,
          focused: open,
          end: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: _Chevron(open: open, size: 18),
          ),
          child: text,
        ),
      ),
    );
  }
}

/// A dropdown's chevron: it turns to point up while its menu is open, in step with the menu.
class _Chevron extends StatelessWidget {
  final bool open;
  final double size;
  const _Chevron({required this.open, this.size = 17});

  @override
  Widget build(BuildContext context) => AnimatedRotation(
    turns: open ? 0.5 : 0,
    duration: _motion(context, open ? kPsMenuOpen.inMilliseconds : kPsMenuClose.inMilliseconds),
    curve: Curves.easeOutCubic,
    child: Icon(Icons.expand_more_rounded, size: size, color: DashUi.slate),
  );
}

/// "Description" with a chevron: under the name read-only (after its SKU), at the end of the name box while editing. It
/// opens the description under the line or closes it again; on a line with none (editing) it opens an empty box to type
/// in.
class _DescToggle extends StatefulWidget {
  final bool open;
  final VoidCallback onTap;

  /// A narrow box: the description icon and chevron only (the label is its tooltip).
  final bool compact;
  const _DescToggle({super.key, required this.open, required this.onTap, this.compact = false});

  /// Room before the label, for the keyboard focus ring.
  static const inset = 6.0;

  @override
  State<_DescToggle> createState() => _DescToggleState();
}

class _DescToggleState extends State<_DescToggle> with _FocusRing {
  final _node = FocusNode(debugLabel: 'description toggle');

  @override
  FocusNode get ringNode => _node;
  bool get _focus => ring;

  @override
  void dispose() {
    super.dispose();
    _node.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      expanded: widget.open,
      label: widget.open ? 'Hide the description' : 'Show the description',
      excludeSemantics: true,
      child: FocusableActionDetector(
        focusNode: _node,
        mouseCursor: SystemMouseCursors.click,
        // No hover tint (user 2026-11-13): the pointer cursor says it's a button. A keyboard focus ring only.
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onTap())},
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _node.requestFocus();
            widget.onTap();
          },
          // Text and a chevron: no taller than the name, so the name box is as tall as the others. A button, not text:
          // the page-wide selection must not highlight (or I-beam) its label.
          child: SelectionContainer.disabled(
            child: AnimatedContainer(
              duration: _motion(context, 120),
              height: _metaHeight(context),
              padding: const EdgeInsets.fromLTRB(_DescToggle.inset, 0, 2, 0),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: _focus ? DashUi.ink : DashUi.ink.withValues(alpha: 0), width: 1.4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.compact)
                    const Tooltip(
                      message: 'Description',
                      child: Icon(Icons.notes_rounded, size: 16, color: DashUi.ink),
                    )
                  else
                    const Text(
                      'Description',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: DashUi.ink, height: 1.2),
                    ),
                  AnimatedSwitcher(
                    duration: _motion(context, 180),
                    transitionBuilder: (c, a) => RotationTransition(
                      turns: Tween<double>(begin: 0.5, end: 1).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
                      child: FadeTransition(opacity: a, child: c),
                    ),
                    child: Icon(
                      widget.open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                      key: ValueKey(widget.open),
                      size: 16,
                      color: DashUi.slate,
                    ),
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

/// The opened description under a line, in a box of its own so it doesn't run into the page: read-only a light outline,
/// while editing the same dark outline as the field it opens into (a click opens it).
class _Description extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;
  const _Description(this.text, {this.onTap});

  @override
  Widget build(BuildContext context) {
    final tap = onTap;
    final w = tap == null ? 1.0 : _edgeW;
    final body = Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(12 - w, 10 - w, 12 - w, 10 - w),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_radius),
        border: Border.all(color: tap == null ? DashUi.line : _edge, width: w),
      ),
      child: Text(text, style: _descStyle),
    );
    if (tap == null) return body;
    return MouseRegion(
      cursor: SystemMouseCursors.text, // a click puts the caret in it (user 2026-11-16: I-beam, not the pointer)
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: tap,
        child: SelectionContainer.disabled(child: body),
      ),
    );
  }
}

class _Handle extends StatelessWidget {
  final int index;
  const _Handle({required this.index});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: _Cols.gripW,
    child: ReorderableDragStartListener(
      index: index,
      child: const MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Tooltip(
          message: 'Drag to reorder (or Alt+Up / Alt+Down)',
          waitDuration: Duration(milliseconds: 600),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Icon(Icons.drag_indicator_rounded, size: 18, color: DashUi.muted),
          ),
        ),
      ),
    ),
  );
}

/// A line's other actions: Copy, Remove from group, Delete.
class _RowMenu extends StatelessWidget {
  final int index;
  final ValueChanged<String> onMenu;
  const _RowMenu({required this.index, required this.onMenu});

  @override
  Widget build(BuildContext context) => PsMenuButton<String>(
    entries: () => const [
      PsMenuItem('duplicate', 'Copy', icon: Icons.content_copy_rounded),
      // Lines can't be grouped in the app yet, so there is never a group to take one out of.
      PsMenuItem('ungroup', 'Remove from group', icon: Icons.playlist_remove_rounded, enabled: false),
      PsMenuDivider(),
      PsMenuItem('remove', 'Delete', icon: Icons.delete_outline_rounded, danger: true),
    ],
    onSelected: onMenu,
    width: 210,
    align: PsMenuAlign.end,
    label: 'Line ${index + 1} actions',
    // The label is for screen readers (no hover text on the block, user 2026-11-13), the key for tests.
    builder: (context, open, show) => _BoxButton(
      key: ValueKey('line-$index-actions'),
      label: 'Line ${index + 1} actions',
      icon: Icons.more_vert_rounded,
      active: open,
      onTap: show,
    ),
  );
}

/// A square icon button the height of the line's boxes (the ⋮ at a line's end), with no outline at rest: a light fill
/// under the pointer, a touch darker while pressed, ink outline with a soft ring while its menu is open or it has
/// keyboard focus.
class _BoxButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback? onTap;
  const _BoxButton({super.key, required this.label, required this.icon, this.active = false, this.onTap});

  @override
  State<_BoxButton> createState() => _BoxButtonState();
}

class _BoxButtonState extends State<_BoxButton> with _FocusRing {
  final _node = FocusNode(debugLabel: 'line actions');
  bool _hover = false, _down = false;

  @override
  FocusNode get ringNode => _node;
  bool get _focus => ring; // focus comes back here when its menu closes: a ring only if the keyboard brought it

  @override
  void dispose() {
    super.dispose();
    _node.dispose();
  }

  void _tap() {
    // Focus first, so it comes back here when the menu closes (and an open line stays open).
    _node.requestFocus();
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final lit = widget.active || _focus;
    return Semantics(
      button: true,
      expanded: widget.active,
      label: widget.label,
      excludeSemantics: true,
      child: FocusableActionDetector(
        focusNode: _node,
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _tap())},
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTap: () {
            setState(() => _down = false);
            _tap();
          },
          child: AnimatedContainer(
            duration: _motion(context, 110),
            curve: Curves.easeOut,
            width: 30,
            height: _boxHeight(context),
            alignment: Alignment.center,
            // No outline at rest (final polish 2026-11-13: a box on every line's ⋮ was the heaviest thing left at the
            // table's right edge; it is a button, not a field, like the eye): the light fill under the pointer, a
            // touch darker pressed, the ink outline and ring while its menu is open or with keyboard focus.
            decoration: BoxDecoration(
              color: _down ? DashUi.line : (_hover || widget.active ? _press : Colors.white.withValues(alpha: 0)),
              borderRadius: BorderRadius.circular(_radius),
              border: Border.all(color: lit ? DashUi.ink : DashUi.ink.withValues(alpha: 0), width: _edgeW),
              boxShadow: lit ? _ring(DashUi.ink) : null,
            ),
            child: Icon(widget.icon, size: 18, color: lit ? DashUi.ink : DashUi.slate),
          ),
        ),
      ),
    );
  }
}

/// A row with its fields open. Values apply to the draft as they are typed; a number that doesn't parse is marked and
/// blocks Save until it is fixed. Esc, or clicking outside the row, closes it.
class _EditRow extends StatefulWidget {
  final int index;
  final LineDraft line;
  final LineFigures figures;
  final _Cols cols;
  final String focusField;
  final bool more; // the description field is showing
  final VoidCallback onMore;
  final List<SalesTax> taxOptions;
  final double? defaultRate;
  final ValueChanged<String> onTax;
  final Set<String> invalid;
  final ValueChanged<LineDraft> onChanged;
  final void Function(String field, bool bad) onInvalid;
  final VoidCallback onDone;
  final ValueChanged<int> onMove;
  final ValueChanged<String> onMenu;
  const _EditRow({
    super.key,
    required this.index,
    required this.line,
    required this.figures,
    required this.cols,
    required this.focusField,
    required this.more,
    required this.onMore,
    required this.taxOptions,
    required this.defaultRate,
    required this.onTax,
    required this.invalid,
    required this.onChanged,
    required this.onInvalid,
    required this.onDone,
    required this.onMove,
    required this.onMenu,
  });

  @override
  State<_EditRow> createState() => _EditRowState();
}

class _EditRowState extends State<_EditRow> {
  late final Map<String, TextEditingController> _c;
  late final Map<String, FocusNode> _f;

  /// A quantity the line can hold: up to [kMaxLineQuantity] either way (the server's limit, src/lineItemMath.js). A
  /// negative one is a return or credit, as Service Fusion keeps them (-1 x the price).
  static bool _qtyOk(double? q) => q != null && q.abs() <= kMaxLineQuantity;

  /// What an open money field starts with: "1,489.00" (the field shows its "$" at its left, as the closed box does).
  static String _moneyText(double? v) => v == null ? '' : _plainMoney((v * 100).round());

  @override
  void didUpdateWidget(_EditRow old) {
    super.didUpdateWidget(old);
    // "More" opens the description: it is ready to type in.
    if (widget.more && !old.more) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _f['description']?.requestFocus();
      });
    }
  }

  @override
  void initState() {
    super.initState();
    final l = widget.line;
    _c = {
      'name': _NameController(text: l.name),
      // Laid out as the opened description is: its own lines, no stray blank ones.
      'description': TextEditingController(text: _cleanDescription(l.description)),
      'sku': TextEditingController(text: l.sku),
      // As the closed box showed them: "2.00", "1,489.00".
      'qty': TextEditingController(text: qtyText(l.quantity)),
      'rate': TextEditingController(text: _moneyText(l.rate)),
      'cost': TextEditingController(text: _moneyText(l.cost)),
    };
    _f = {for (final k in _c.keys) k: FocusNode(debugLabel: 'line ${widget.index + 1} $k')};
    // A figure is tidied when its field is left ("2.5" -> "2.50", "689" -> "689.00"), so it reads as it will once the
    // line closes.
    for (final k in const ['qty', 'rate', 'cost']) {
      _f[k]!.addListener(() => _tidy(k));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final node = _f[widget.focusField] ?? _f['name']!;
      node.requestFocus();
      final c = _c[widget.focusField];
      if (c != null) c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);
    });
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    for (final f in _f.values) {
      f.dispose();
    }
    super.dispose();
  }

  void _tidy(String field) {
    if (!mounted || _f[field]!.hasFocus) return;
    final c = _c[field]!;
    final String? tidy;
    if (field == 'qty') {
      final q = parseQty(c.text);
      tidy = _qtyOk(q) ? qtyText(q!) : null;
    } else {
      final m = _typedMoney(field, c.text);
      tidy = c.text.trim().isEmpty || m == null ? null : _plainMoney((m * 100).round());
    }
    if (tidy != null && tidy != c.text) c.text = tidy;
  }

  void _text(String field, String v) {
    final l = widget.line;
    widget.onChanged(switch (field) {
      'name' => l.copyWith(name: v),
      'description' => l.copyWith(description: v),
      _ => l.copyWith(sku: v),
    });
  }

  /// The quantity arrows (or Up / Down in the field): one up or down from what is typed, through 0 and into negatives.
  /// The field shows the new number.
  void _stepQty(double q) {
    final t = qtyText(q);
    _c['qty']!.value = TextEditingValue(
      text: t,
      selection: TextSelection.collapsed(offset: t.length),
    );
    _number('qty', t);
  }

  double get _typedQty => parseQty(_c['qty']!.text) ?? widget.line.quantity;

  /// Money typed into [field]. A discount's amount is money off whichever way it is typed: "-75" is $75 off, kept as
  /// 75 (it was kept as -75, so the field said "-75.00" and the closed box "75.00"; found in round 2, 2026-11-13).
  double? _typedMoney(String field, String v) {
    final m = parseMoney(v);
    return m != null && field == 'rate' && widget.line.isDiscount ? m.abs() : m;
  }

  void _number(String field, String v) {
    final empty = v.trim().isEmpty;
    final l = widget.line;
    if (field == 'qty') {
      final q = parseQty(v);
      // Quantity x rate stays within what the server takes for one line (lineAmountFits).
      final ok = _qtyOk(q) && lineAmountFits(q!, l.rate);
      widget.onInvalid('qty', !ok);
      if (ok) widget.onChanged(l.copyWith(quantity: q));
      return;
    }
    final m = _typedMoney(field, v);
    final ok =
        empty ||
        (m != null && m.abs() <= kMaxLineRate && (field != 'cost' || m >= 0) && (field != 'rate' || l.isDiscount || lineAmountFits(l.quantity, m)));
    widget.onInvalid(field, !ok);
    if (!ok) return;
    widget.onChanged(field == 'rate' ? l.copyWith(rate: empty ? null : m) : l.copyWith(cost: empty ? null : m));
  }

  KeyEventResult _keys(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      widget.onDone();
      return KeyEventResult.handled;
    }
    final alt = HardwareKeyboard.instance.isAltPressed;
    if (alt && e.logicalKey == LogicalKeyboardKey.arrowUp) {
      widget.onMove(-1);
      return KeyEventResult.handled;
    }
    if (alt && e.logicalKey == LogicalKeyboardKey.arrowDown) {
      widget.onMove(1);
      return KeyEventResult.handled;
    }
    // Up and Down in the quantity do what its arrows do.
    if (_f['qty']!.hasFocus && (e.logicalKey == LogicalKeyboardKey.arrowUp || e.logicalKey == LogicalKeyboardKey.arrowDown)) {
      final q = _typedQty;
      final up = e.logicalKey == LogicalKeyboardKey.arrowUp;
      final next = ((q + (up ? 1 : -1)) * 1000).round() / 1000;
      // As the arrows: one either way, through 0 into a return, never past the quantity limit or what one line may
      // come to.
      if (_StepButton.allowed(next, rate: widget.line.rate)) _stepQty(next);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Focus left the line: it closes, unless focus went into a menu the line opened (its tax select, its actions), which
  /// sits on a route of its own and hands focus back when it closes (found by the 2026-11-13 review: the keyboard lost
  /// its place).
  void _leftRow(bool has) {
    if (has) return;
    final now = FocusManager.instance.primaryFocus?.context;
    if (now != null && now.mounted && ModalRoute.of(now) != ModalRoute.of(context)) return;
    widget.onDone();
  }

  /// [multiline]: the description. It grows with its text (no scrolling), Enter starts a new line, and it looks like the
  /// opened description box it replaces. Otherwise the field sits in the same box as a closed line's value ([_FieldCell]),
  /// with [trailing] at its end.
  Widget _field(
    String key, {
    String? hint,
    bool right = false,
    bool numeric = false,
    bool money = false,
    bool multiline = false,
    TextStyle? style,
    String? label,
    Widget? trailing,
    double? trailingWidth,
    Widget? meta,
  }) => Semantics(
    label: label,
    child: multiline
        // The description: the same box as the opened description it replaces ([_Description]), drawn here rather than
        // by the field, so its text sits exactly where the shown text did (an outlined field's own inset put it 4 px to
        // the right as the line opened: user 2026-11-13). Ink with the soft ring while typing in it.
        ? AnimatedBuilder(
            animation: _f[key]!,
            builder: (context, field) {
              final focused = _f[key]!.hasFocus;
              return AnimatedContainer(
                duration: _motion(context, 120),
                curve: Curves.easeOut,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(_radius),
                  border: Border.all(color: focused ? DashUi.ink : _edge, width: _edgeW),
                  boxShadow: focused ? _ring(DashUi.ink) : null,
                ),
                child: field,
              );
            },
            child: _textField(key, hint: hint, right: right, numeric: numeric, money: money, multiline: true, style: style),
          )
        : AnimatedBuilder(
            animation: _f[key]!,
            builder: (context, field) => _FieldCell(
              pad: false,
              focused: _f[key]!.hasFocus,
              error: widget.invalid.contains(key),
              end: trailing,
              endWidth: trailingWidth,
              meta: meta,
              divider: key == 'name',
              child: field!,
            ),
            child: _textField(key, hint: hint, right: right, numeric: numeric, money: money, multiline: false, style: style),
          ),
  );

  TextField _textField(
    String key, {
    String? hint,
    required bool right,
    required bool numeric,
    required bool money,
    required bool multiline,
    TextStyle? style,
  }) {
    // What a closed line's Text of this value is drawn with: the page's text style, then the table's own. A TextField
    // starts from the theme's field style instead (Material 3 bodyLarge: letter spacing 0.5, where a Text inherits
    // 0.25), so a figure got wider the moment its line opened, "2.00" by about a pixel (user 2026-11-13: "the numbers
    // are still growing when I open the description"). The field is given the whole resolved style, so nothing of the
    // theme's comes through; the same for its placeholder and its "$".
    final base = DefaultTextStyle.of(context).style;
    TextStyle closed(TextStyle s) => base.merge(s);
    return _textFieldStyled(key, hint: hint, right: right, numeric: numeric, money: money, multiline: multiline, style: closed(style ?? _cell), closed: closed);
  }

  TextField _textFieldStyled(
    String key, {
    String? hint,
    required bool right,
    required bool numeric,
    required bool money,
    required bool multiline,
    required TextStyle style,
    required TextStyle Function(TextStyle) closed,
  }) => TextField(
    key: ValueKey('line-${widget.index}-$key'),
    // The description is free text, so it shows the I-beam (user 2026-11-16); the other boxes keep the pointer.
    mouseCursor: multiline ? SystemMouseCursors.text : SystemMouseCursors.click,
    controller: _c[key],
    focusNode: _f[key],
    cursorColor: DashUi.ink,
    cursorWidth: _cursorW,
    textAlign: right ? TextAlign.right : TextAlign.left,
    minLines: 1,
    maxLines: multiline ? null : 1,
    style: style,
    keyboardType: numeric
        ? const TextInputType.numberWithOptions(decimal: true, signed: true)
        : (multiline ? TextInputType.multiline : TextInputType.text),
    textInputAction: multiline ? TextInputAction.newline : null,
    // Figures take two decimals at most: what is typed is what is shown and charged. A minus is never dropped (which
    // would flip the sign): a quantity of -1 is a return.
    inputFormatters: numeric ? [FilteringTextInputFormatter.allow(money ? RegExp(r'[0-9.,$\-]') : RegExp(r'[0-9.,\-]')), const _TwoDecimals()] : null,
    decoration: multiline
        // Inside the box above: the opened description's own padding, less its border (as [_Description] pads it).
        ? InputDecoration(
            isDense: true,
            filled: false,
            // Desktop's compact density takes 4 px off a field's padding top and bottom: the field would no longer
            // sit where the text it replaces did (round 3, found in the browser; the tests run as Android).
            visualDensity: VisualDensity.standard,
            hintText: hint,
            hintStyle: closed(_hint),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: const EdgeInsets.fromLTRB(12 - _edgeW, 10 - _edgeW, 12 - _edgeW, 10 - _edgeW),
          )
        : InputDecoration(
            isDense: true,
            filled: false,
            visualDensity: VisualDensity.standard, // as above: the same padding on every platform
            // A hint isn't drawn by the editable, so it keeps no caret room: a right-aligned one is padded by the same
            // [_caretRoom] the text gives back, so an empty box's "Cost" stays put as its line opens. It and the "$"
            // sit on the typed text's own line ([_valueLine]: the editable forces its text onto exactly this strut).
            hint: hint == null
                ? null
                : Padding(
                    padding: EdgeInsets.only(right: right ? _caretRoom : 0),
                    child: Text(
                      hint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: right ? TextAlign.right : TextAlign.left,
                      style: closed(_hint),
                      strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: true),
                    ),
                  ),
            prefix: money ? Text(r'$ ', style: closed(_currency), strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: true)) : null,
            // The box draws the outline; the text sits exactly where a closed line's value does (and so under its
            // heading). A right-aligned field keeps [_caretRoom] after its text for the caret: that comes off its
            // padding, or its figure would sit 3 px left of the closed one (round 3, 2026-11-13).
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.fromLTRB(_cellX - _edgeW, _cellY - _edgeW, _cellX - _edgeW - (right ? _caretRoom : 0), _cellY - _edgeW),
          ),
    onChanged: (v) => numeric ? _number(key, v) : _text(key, v),
    onSubmitted: multiline ? null : (_) => widget.onDone(),
  );

  @override
  Widget build(BuildContext context) {
    final cols = widget.cols;
    final l = widget.line;
    final discount = l.isDiscount;
    final boxH = _boxHeight(context);
    final actions = Align(
      alignment: Alignment.topRight,
      child: _RowMenu(index: widget.index, onMenu: widget.onMenu),
    );
    final grip = SizedBox(
      height: boxH,
      child: _Handle(index: widget.index),
    );
    final eye = Align(
      alignment: Alignment.topLeft,
      child: _EyeToggle(
        visible: l.customerVisible,
        onTap: () => widget.onChanged(l.copyWith(customerVisible: !l.customerVisible)),
      ),
    );
    final nameField = LayoutBuilder(
      builder: (context, c) => _field(
        'name',
        hint: discount ? 'What the discount is for' : 'Item name',
        label: 'Line ${widget.index + 1} name',
        style: _nameStyle,
        // The SKU (or "Discount") and "Description" stay inside the name box, where the closed box has them.
        meta: !cols.stacked && (l.isDiscount || c.maxWidth >= _Cols.skuInBoxW) ? _inlineMeta(l) : null,
        trailing: discount
            ? null
            : _DescToggle(
                key: ValueKey('line-${widget.index}-more'),
                open: widget.more,
                compact: c.maxWidth < _Cols.compactToggleW,
                onTap: widget.onMore,
              ),
      ),
    );
    final descField = !discount && widget.more
        ? Padding(
            // As a closed line pads its shown description (_ViewRow), so the lines below stay put as it opens.
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 2),
            child: _field(
              'description',
              hint: 'Description or notes (optional)',
              multiline: true,
              label: 'Line ${widget.index + 1} description',
              style: _descStyle.copyWith(color: DashUi.ink),
            ),
          )
        : null;
    final qtyField = _field(
      'qty',
      hint: '1.00',
      right: true,
      numeric: true,
      label: 'Quantity',
      trailing: _Spin(value: _typedQty, rate: l.rate, onChanged: _stepQty, inField: true),
      trailingWidth: _Spin.width,
    );
    final offTaxed = SizedBox(
      height: boxH,
      child: Tooltip(
        message: 'Comes off the taxed lines (lowers the tax)',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Exactly its square, so it starts at the column's edge as every box in the column does (a Material
            // checkbox otherwise sits about 7 px inside its own touch area: round 3).
            SizedBox(
              key: const ValueKey('off-taxed'),
              width: 18,
              height: 18,
              child: Checkbox(
                value: l.taxable,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                activeColor: DashUi.ink,
                side: const BorderSide(color: _edgeHover, width: 1.2),
                onChanged: (v) => widget.onChanged(l.copyWith(taxable: v == true)),
              ),
            ),
            const SizedBox(width: 8),
            const Flexible(
              child: Text(
                'Off taxed lines',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: DashUi.ink),
              ),
            ),
          ],
        ),
      ),
    );
    final taxCell = _TaxCell(line: l, options: widget.taxOptions, defaultRate: widget.defaultRate, onPick: widget.onTax);
    // An item's amount is worked out: plain text where a field's text would be, never a box.
    final amountText = Padding(
      padding: const EdgeInsets.fromLTRB(_cellX, _cellY, _cellX, 0),
      child: Align(
        alignment: Alignment.centerRight,
        child: Text(
          centsMoney(widget.figures.amountCents),
          textAlign: TextAlign.right,
          maxLines: 1,
          style: _amountFor(widget.figures.amountCents),
        ),
      ),
    );
    final rateField = _field('rate', hint: 'Price', right: true, numeric: true, money: true, label: 'Rate');
    final discountField = _field(
      'rate',
      hint: 'Amount',
      right: true,
      numeric: true,
      money: true,
      label: 'Discount amount',
      style: _amountStyle.copyWith(color: DashUi.redText),
    );
    final costField = _field('cost', hint: 'Cost', right: true, numeric: true, money: true, label: 'Unit cost');
    final under = cols.stacked ? _inlineMeta(l) : null;
    final item = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        nameField,
        if (under != null) Padding(padding: const EdgeInsets.fromLTRB(_cellX, 4, 0, 0), child: under),
        _Reveal(child: descField),
      ],
    );

    if (cols.stacked) {
      // A small window: the name and description across the row, the figures wrapping underneath, each with its heading.
      Widget labelled(String label, double w, Widget field) => SizedBox(
        width: w,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 4),
              child: Text(label.toUpperCase(), style: _head),
            ),
            field,
          ],
        ),
      );
      return Focus(
        onKeyEvent: _keys,
        onFocusChange: _leftRow,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(_side, _cellY + 1, _side, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: _Cols.gripW, child: grip),
                  SizedBox(width: _Cols.eyeW, child: eye),
                  Expanded(child: item),
                  SizedBox(width: _Cols.actionsW, child: actions),
                ],
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(left: _Cols.gripW + _Cols.eyeW),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.end,
                  children: [
                    if (discount)
                      labelled('Amount', 128, discountField)
                    else ...[
                      labelled('Qty', _Cols.qtyEditW, qtyField),
                      labelled('Rate', 120, rateField),
                      if (cols.cost) labelled('Cost', 112, costField),
                    ],
                    if (discount) offTaxed else labelled('Tax', 170, taxCell),
                    SizedBox(width: 104, child: amountText),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Focus(
      onKeyEvent: _keys,
      onFocusChange: _leftRow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _side, vertical: _cellY + 1),
        // The same columns as the headings and the closed lines ([_Cols.line]).
        child: cols.line(
          grip: grip,
          eye: eye,
          item: item,
          qtyCell: discount ? null : qtyField,
          times: _Sym(discount ? '' : '×'),
          rateCell: discount ? null : rateField,
          equals: _Sym(discount ? '' : '='),
          // A discount's amount is what is typed; an item's is worked out.
          amountCell: discount ? discountField : amountText,
          costCell: discount ? null : costField,
          taxCell: discount ? Align(alignment: Alignment.topLeft, child: offTaxed) : taxCell,
          menu: actions,
        ),
      ),
    );
  }
}

/// Keeps a typed figure to two decimals ("2.125" becomes "2.12"), so what is typed is what is shown and charged. A value
/// that already had a third decimal (one the server stored) keeps that many while another digit is changed, so editing
/// it never cuts it short. Anything else odd about the text (a second point) is left for the field to mark.
class _TwoDecimals extends TextInputFormatter {
  const _TwoDecimals();

  static int _decimals(String t) {
    final m = RegExp(r'\.(\d+)$').firstMatch(t);
    return m == null ? 0 : m.group(1)!.length;
  }

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final t = newValue.text;
    final dot = t.indexOf('.');
    if (dot < 0) return newValue;
    final after = t.substring(dot + 1);
    final had = _decimals(oldValue.text);
    final places = had > 2 ? had : 2;
    if (!RegExp(r'^\d+$').hasMatch(after) || after.length <= places) return newValue;
    final cut = t.substring(0, dot + 1 + places);
    final at = newValue.selection.baseOffset.clamp(0, cut.length);
    return TextEditingValue(
      text: cut,
      selection: TextSelection.collapsed(offset: at),
    );
  }
}

/// One figure in the totals card.
class _TotalsRow {
  final String label;
  final int cents;
  final bool strong;
  final String? tip;
  final Widget? extra;
  const _TotalsRow(this.label, this.cents, {this.strong = false, this.tip, this.extra});
}

/// What the lines cost us and what is left after it (see _LineItemsEditorState._profit).
class _Profit {
  /// The costs that are known.
  final int costCents;

  /// Null while [missingCostLines] > 0: what is left can't be told.
  final int? profitCents;
  final double? marginPct;
  final int missingCostLines;

  /// Worked out on a source's own figures (Service Fusion's charges and discounts), not only our lines.
  final bool fromSource;
  const _Profit(this.costCents, this.profitCents, this.marginPct, {this.missingCostLines = 0, required this.fromSource});
}

/// The summary under the lines. What the customer is charged, one figure a line on white; for people who can see costs,
/// what the work costs us and the gross profit with its margin, in a hairline box of its own so it never reads as part of
/// the customer's figures (no heading, and above the rule and the total: user 2026-11-12; outlined, not grey: user
/// 2026-11-13 pass 5); then under the rule the total, last and largest.
class _Summary extends StatelessWidget {
  final List<_TotalsRow> rows;
  final _Profit? profit;
  const _Summary({required this.rows, this.profit});

  static const _label = TextStyle(fontSize: 13.5, color: DashUi.ink, height: 1.3);
  static const _value = TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: DashUi.ink, fontFeatures: _figures);

  Widget _line(String label, Widget value, {String? tip, Widget? lead, Widget? extra}) => Tooltip(
    message: tip ?? '',
    waitDuration: const Duration(milliseconds: 500),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          ?lead,
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: _label),
                ),
                ?extra,
              ],
            ),
          ),
          const SizedBox(width: 12),
          value,
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final body = rows.where((r) => !r.strong).toList();
    final total = rows.where((r) => r.strong).firstOrNull;
    final p = profit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final r in body)
          _line(
            r.label,
            _CountUp(
              text: centsMoney(r.cents),
              style: _value.copyWith(color: r.cents < 0 ? DashUi.redText : DashUi.ink),
            ),
            tip: r.tip,
            extra: r.extra,
          ),
        // Ours, between the customer's figures and their total (above the rule, user 2026-11-12), in a box of its own.
        if (p != null)
          Container(
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: DashUi.line),
            ),
            child: _ProfitLines(profit: p, line: _line, value: _value),
          ),
        if (total != null) ...[
          Padding(
            padding: EdgeInsets.only(top: p == null ? 8 : 14, bottom: 10),
            child: const Divider(height: 1, color: DashUi.line),
          ),
          Tooltip(
            message: total.tip ?? '',
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    total.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: DashUi.ink),
                  ),
                ),
                const SizedBox(width: 12),
                _CountUp(
                  text: centsMoney(total.cents),
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: DashUi.ink,
                    letterSpacing: -0.6,
                    height: 1.15,
                    fontFeatures: _figures,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// The job cost and gross profit, with the margin as a figure and a bar (green, red when the work loses money).
class _ProfitLines extends StatelessWidget {
  final _Profit profit;
  final Widget Function(String label, Widget value, {String? tip, Widget? lead, Widget? extra}) line;
  final TextStyle value;
  const _ProfitLines({required this.profit, required this.line, required this.value});

  @override
  Widget build(BuildContext context) {
    final p = profit;
    final known = p.profitCents;
    final m = known == null ? null : p.marginPct;
    final losing = (known ?? 0) < 0;
    final tone = losing ? DashUi.redText : DashUi.emeraldText;
    final missing = p.missingCostLines;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final pill = m == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Semantics(
              label: 'Gross profit ${m.toStringAsFixed(1)} percent of the price before tax',
              excludeSemantics: true,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                decoration: BoxDecoration(
                  color: (losing ? DashUi.red : DashUi.emerald).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${m.toStringAsFixed(1)}%',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: tone, fontFeatures: _figures),
                ),
              ),
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        line('Job cost', _CountUp(text: centsMoney(p.costCents), style: value)),
        line(
          'Gross profit',
          // Unknown while a line has no cost: a dash, never a profit (or a 100% margin) worked out as if it cost $0.
          known == null
              ? Text('—', key: const ValueKey('gross-profit-unknown'), semanticsLabel: 'not known', style: value.copyWith(color: DashUi.slate, fontWeight: FontWeight.w700))
              : _CountUp(
                  text: centsMoney(known),
                  style: value.copyWith(color: tone, fontWeight: FontWeight.w700),
                ),
          extra: pill,
          tip: p.fromSource
              ? 'Gross profit %: what is left of the price before tax (items, discounts and other charges) after cost. Sales tax, and anything Service Fusion doesn\'t itemize, is left out.'
              : 'Gross profit %: items less discounts, less cost, as a share of items less discounts. Sales tax is not profit.',
        ),
        if (known == null && missing > 0)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '$missing line${missing == 1 ? ' has' : 's have'} no cost',
              key: const ValueKey('missing-cost-note'),
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: DashUi.amberText, height: 1.35),
            ),
          ),
        if (m != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: LayoutBuilder(
              builder: (context, c) => Stack(
                children: [
                  Container(
                    height: 4,
                    decoration: BoxDecoration(color: DashUi.line, borderRadius: BorderRadius.circular(99)),
                  ),
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: (m.abs().clamp(0, 100)) / 100),
                    duration: reduce ? Duration.zero : const Duration(milliseconds: 520),
                    curve: Curves.easeOutCubic,
                    builder: (context, f, _) => Container(
                      width: c.maxWidth * f,
                      height: 4,
                      decoration: BoxDecoration(color: losing ? DashUi.red : DashUi.emerald, borderRadius: BorderRadius.circular(99)),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// A warning about the figures under the lines (lines not priced yet, lines with no cost): amber words beside an icon,
/// no box.
class _Warning extends StatelessWidget {
  final String text;
  const _Warning(this.text);

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Padding(
        padding: EdgeInsets.only(top: 1),
        child: Icon(Icons.info_outline_rounded, size: 15, color: DashUi.amberText),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          text,
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: DashUi.amberText, height: 1.35),
        ),
      ),
    ],
  );
}

/// What goes under a line, from where its name starts: its $0.00 confirmation ([zero]: the table asks for one), and what
/// the catalog said about the service it was just added from ([from]). Null when there is nothing to say.
Widget? _lineNotes(LineDraft line, {CatalogEntry? from, required bool zero, VoidCallback? onConfirm, ValueChanged<double>? onUsePrice}) {
  final items = <Widget>[
    if (zero && line.isZeroPrice) line.zeroPriceConfirmed ? _NoChargeNote(by: line.zeroPriceConfirmedBy) : _ZeroChip(onTap: onConfirm),
    if (from != null) ..._catalogHints(from, line, onUsePrice),
  ];
  if (items.isEmpty) return null;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < items.length; i++) Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : 5), child: items[i]),
    ],
  );
}

/// What the Services Catalog says about a service just added (Phase 2), shown under its line in the preview: a tax that
/// differs from job to job, a recent price change (the 18-month median and the newest prices, apart, and nothing filled
/// in), and for a price that isn't settled, that the line is not priced and what is known. Only a price billed once
/// offers itself as a one-tap pick ("Use last billed"); nothing is ever filled in for the person.
List<Widget> _catalogHints(CatalogEntry e, LineDraft line, ValueChanged<double>? onUsePrice) {
  String m(double v) => centsMoney((v * 100).round());
  final out = <Widget>[];
  if (e.priceStatus == 'recent_change') {
    final change = e.recentChange;
    final median = change?.median ?? e.medianPrice;
    final recent = change != null && change.prices.isNotEmpty ? change.prices : e.recentPrices;
    final parts = [
      if (median != null) '18-month median ${m(median)}',
      if (recent.isNotEmpty) 'recent ${recent.map((p) => m(p.price)).join(', ')}',
    ];
    out.add(
      _Hint(
        key: const ValueKey('hint-recent-change'),
        title: 'Recent price change',
        text: parts.isEmpty ? (change?.warning ?? 'No price is filled in; check it before quoting.') : '${parts.join(' · ')}. No price is filled in; check it before quoting.',
      ),
    );
  } else if (line.rate == null && e.priceStatus != null && e.priceStatus != 'settled') {
    final last = e.lastBilled?.price ?? e.medianPrice;
    final (String text, double? pick) = switch (e.priceStatus) {
      'varies' when e.rateMin != null && e.rateMax != null => ('Billed ${m(e.rateMin!)} – ${m(e.rateMax!)}, no settled price. Enter the price.', null),
      'single' when last != null => ('Billed once, at ${m(last)}. Enter the price.', last),
      'quote_only' when e.quoteMedian != null => ('Never billed; quoted ${m(e.quoteMedian!)}. Enter the price.', null),
      _ => ('No price on file. Enter the price.', null),
    };
    out.add(
      _Hint(
        key: const ValueKey('hint-not-priced'),
        title: 'Not priced',
        text: text,
        action: pick == null || onUsePrice == null ? null : ('Use last billed ${m(pick)}', () => onUsePrice(pick)),
      ),
    );
  }
  if (e.taxDefault == 'mixed') {
    out.add(_Hint(key: const ValueKey('hint-tax'), title: 'Check the tax', text: e.taxWarning ?? 'Taxed on some billed jobs and not others.'));
  }
  return out;
}

/// An unconfirmed $0.00 line's amber chip. With [onTap] it asks whether the line is no charge; without (no way to
/// confirm it here) it only says it isn't confirmed.
class _ZeroChip extends StatelessWidget {
  final VoidCallback? onTap;
  const _ZeroChip({this.onTap});

  @override
  Widget build(BuildContext context) {
    final label = onTap == null ? '\$0.00 · Not confirmed as no charge' : '\$0.00 · Confirm no charge';
    final chip = Container(
      padding: const EdgeInsets.fromLTRB(7, 3, 9, 3),
      decoration: BoxDecoration(
        color: DashUi.amber.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: DashUi.amber.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.money_off_rounded, size: 13, color: DashUi.amberText),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.amberText, height: 1.3)),
        ],
      ),
    );
    if (onTap == null) return KeyedSubtree(key: const ValueKey('zero-chip'), child: chip);
    return Material(
      key: const ValueKey('zero-chip'),
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        hoverColor: DashUi.amber.withValues(alpha: 0.08),
        splashFactory: NoSplash.splashFactory,
        child: chip,
      ),
    );
  }
}

/// A confirmed $0.00 line: quiet, who confirmed it.
class _NoChargeNote extends StatelessWidget {
  final String? by;
  const _NoChargeNote({this.by});

  @override
  Widget build(BuildContext context) => Row(
    key: const ValueKey('no-charge-note'),
    mainAxisSize: MainAxisSize.min,
    children: [
      const Icon(Icons.check_circle_outline_rounded, size: 13, color: DashUi.slate),
      const SizedBox(width: 4),
      Flexible(
        child: Text(
          by == null || by!.trim().isEmpty ? 'No charge · confirmed' : 'No charge · confirmed by ${by!.trim()}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: DashUi.slate, height: 1.3),
        ),
      ),
    ],
  );
}

/// One thing the catalog says about a line (amber, as the warnings under the table are), with an optional one-tap
/// [action] the person can choose.
class _Hint extends StatelessWidget {
  final String title;
  final String text;
  final (String, VoidCallback)? action;
  const _Hint({super.key, required this.title, required this.text, this.action});

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      const Padding(
        padding: EdgeInsets.only(top: 1),
        child: Icon(Icons.info_outline_rounded, size: 14, color: DashUi.amberText),
      ),
      const SizedBox(width: 6),
      Flexible(
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: '$title  ', style: const TextStyle(fontWeight: FontWeight.w700)),
              TextSpan(text: text),
            ],
          ),
          style: const TextStyle(fontSize: 12.5, color: DashUi.amberText, height: 1.35),
        ),
      ),
      if (action case (final label, final onTap)) ...[
        const SizedBox(width: 10),
        TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            foregroundColor: DashUi.ink,
            minimumSize: const Size(0, 24),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            side: const BorderSide(color: DashUi.fieldEdge),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_radius)),
          ),
          child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      ],
    ],
  );
}

class _InlineNotice extends StatelessWidget {
  final String text;
  final bool error;
  const _InlineNotice(this.text, {this.error = false});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: error ? DashUi.red.withValues(alpha: 0.05) : _rowTint,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: error ? DashUi.red.withValues(alpha: 0.3) : DashUi.line),
    ),
    child: Row(
      children: [
        Icon(error ? Icons.error_outline_rounded : Icons.info_outline_rounded, size: 16, color: error ? DashUi.redText : DashUi.slate),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: error ? DashUi.redText : DashUi.slate),
          ),
        ),
      ],
    ),
  );
}

/// A figure that rolls to its new value when it changes (a quick count, off with reduce motion).
class _CountUp extends StatefulWidget {
  final String text;
  final TextStyle style;
  const _CountUp({required this.text, required this.style});

  @override
  State<_CountUp> createState() => _CountUpState();
}

class _CountUpState extends State<_CountUp> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 320), value: 1);
  String _from = '';

  @override
  void didUpdateWidget(_CountUp old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text && !MediaQuery.disableAnimationsOf(context)) {
      _from = old.text;
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, _) {
      final t = Curves.easeOutCubic.transform(_c.value);
      if (t >= 1 || _from.isEmpty) return Text(widget.text, style: widget.style);
      return ClipRect(
        child: Stack(
          alignment: Alignment.centerRight,
          children: [
            Opacity(opacity: 0, child: Text(widget.text.length >= _from.length ? widget.text : _from, style: widget.style)),
            Transform.translate(
              offset: Offset(0, -10 * t),
              child: Opacity(
                opacity: 1 - t,
                child: Text(_from, style: widget.style),
              ),
            ),
            Transform.translate(
              offset: Offset(0, 10 * (1 - t)),
              child: Opacity(
                opacity: t,
                child: Text(widget.text, style: widget.style),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// The lines settling in after the table turns editable or read-only: a quick fade from part-way and a 4 px rise, so
/// the change of look reads as one step (off with reduce motion).
class _ModeFade extends StatefulWidget {
  final Widget child;
  const _ModeFade({super.key, required this.child});

  @override
  State<_ModeFade> createState() => _ModeFadeState();
}

class _ModeFadeState extends State<_ModeFade> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  late final _t = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
  bool _first = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_first) return;
    _first = false;
    // The table's first appearance (the page opening) is the page's own to animate: only a switch of look plays here.
    final switched = context.findAncestorStateOfType<_LineItemsEditorState>()?._modeSwitched ?? false;
    if (!switched || MediaQuery.disableAnimationsOf(context)) {
      _c.value = 1;
    } else {
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _t.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _t,
    builder: (context, child) => Opacity(
      opacity: 0.35 + 0.65 * _t.value,
      child: Transform.translate(offset: Offset(0, 4 * (1 - _t.value)), child: child),
    ),
    child: widget.child,
  );
}

/// Something that opens under a line (its description): it grows into place and fades in, and on closing fades while
/// the room it took closes up. [child] null is closed.
class _Reveal extends StatelessWidget {
  final Widget? child;
  const _Reveal({this.child});

  @override
  Widget build(BuildContext context) => AnimatedSize(
    duration: _motion(context, 200),
    reverseDuration: _motion(context, 160),
    curve: Curves.easeOutCubic,
    alignment: Alignment.topLeft,
    child: AnimatedSwitcher(
      duration: _motion(context, 180),
      reverseDuration: _motion(context, 120),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (c, a) => FadeTransition(opacity: a, child: c),
      // The outgoing one doesn't hold the room open: it fades over the closing gap.
      layoutBuilder: (current, previous) => Stack(
        clipBehavior: Clip.hardEdge,
        alignment: Alignment.topLeft,
        children: [
          for (final p in previous) Positioned(left: 0, right: 0, top: 0, child: p),
          ?current,
        ],
      ),
      child: child ?? const SizedBox(key: ValueKey('closed'), width: double.infinity),
    ),
  );
}

