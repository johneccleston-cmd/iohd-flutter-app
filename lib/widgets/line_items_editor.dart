import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../config/auth_session.dart';
import '../services/line_items_api.dart';
import '../utils/charge_presets.dart';
import '../utils/line_item_math.dart';
import '../utils/sales_tax_catalog.dart';
import 'app_dialog.dart';
import 'catalog_search_field.dart';
import 'charges_panel.dart';
import 'dashboard_data.dart';
import 'dashboard_kit.dart';
import 'flat_page.dart' show OverflowTooltip;
import 'line_table_style.dart';
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
// Under the lines: the summary as one statement (_Statement): what the customer is charged and, for people who can see
// costs, the revenue and the job's cost, above one bottom line; the gross profit and the total under it. Warnings about
// the figures over it, and anything the page puts beside it ([LineItemsEditor.aside]) to its left.
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

  /// A card processing fee ([isCardProcessingFee]): the customer pays it, but it goes to the card processor, so it is
  /// left out of profit (decision 8, 2026-11-23).
  processingFee,

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

  /// Adds up lines that are in the table already (the items, the draft's own discounts and fees), so the table doesn't
  /// list it again under its lines. A figure that isn't a line (a tax, a Service Fusion charge) is listed there.
  final bool fromLines;
  const LineSummaryRow(this.label, this.cents, {this.kind = SummaryKind.charge, this.tip, this.fromLines = false});

  bool get strong => kind == SummaryKind.total;

  /// Counts toward the money before tax that profit is worked out on: items, discounts and other charges (never a card
  /// processing fee, which goes to the processor).
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

  /// Put on the table (its headings, lines and add-a-line bar, not the summary under them), so a page can find where it
  /// ends: the job page draws its block's outline down to it (user 2026-11-24: "end the outline before the summary").
  final Key? tableKey;

  /// The shade of the rule under each line and of the job page's outline round the table (one shade, user 2026-11-24):
  /// the Details block's own dividers' (DashUi.line), "lighten lines more".
  static const outlineColor = DashUi.line;

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
  ///
  /// [taxes] is the draft's tax lines (the record's own, and any added from Tax, discounts & fees), so a tax added in
  /// the preview is worked out in the figures too.
  final List<LineSummaryRow> Function(List<LineDraft> lines, List<LineFigures> figures, List<SalesTax> taxes)? summaryBuilder;

  /// The record's own tax lines (Service Fusion's tax charges). The draft starts with these; Tax, discounts & fees adds
  /// more or takes them off (USER RULE 2026-11-20: adding a tax taxes nothing, it only becomes a choice in each line's
  /// Tax dropdown). A line naming one of the draft's taxes is taxed at its rate; the dropdown's other choice is No tax.
  final List<SalesTax> taxOptions;

  /// The discounts and fees Tax, discounts & fees offers, and the out-of-state tax's start (the Tax, Discounts & Fees
  /// screen's settings; the built-in list until they load).
  final TaxSettings taxSettings;

  /// What the last line of the total box is called: "Estimate total" on an estimate, "Job total" on a job.
  final String totalLabel;

  /// A job's payments and deposits so far, in cents (refunds taken off). With it the summary ends in a green
  /// Payments/Deposits line and the balance due; null (an estimate) leaves both out.
  final int? paidCents;

  /// Hears the total and (for people who see costs) the margin the summary shows, whenever they change, so the page
  /// can show a changed draft's figures elsewhere too (an estimate option's tab). Called after the frame.
  final void Function(int totalCents, double? marginPct)? onFigures;

  /// Saved lines shown outside the preview (an option, a job's set): confirms that [line], a $0.00 line, is no charge.
  /// The page asks the server, which records who and when, and the lines come back confirmed. Null where it can't be
  /// done (no Update switch, an accepted option): an unconfirmed $0 line then only says so.
  final Future<void> Function(LineDraft line)? onConfirmZero;

  /// The record's own Service Fusion service lines, by [serviceNameKey]: a saved line of the same name with nothing else
  /// to say what it is is a service line ("S"), not an inventory item ("I").
  final Set<String> serviceNames;

  /// The record's own discounts outside its lines (Service Fusion's discount charges) at [itemsCents] of items, in
  /// cents: a percentage fee in the draft is worked out on the items less these too (P&S round 2 finalization).
  final int Function(int itemsCents)? recordDiscounts;

  const LineItemsEditor({
    super.key,
    required this.lines,
    required this.taxRate,
    required this.editable,
    required this.showCost,
    this.onSave,
    this.onDirtyChanged,
    this.banner,
    this.tableKey,
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
    this.taxSettings = TaxSettings.builtIn,
    this.totalLabel = 'Total',
    this.paidCents,
    this.onFigures,
    this.onConfirmZero,
    this.serviceNames = const {},
    this.recordDiscounts,
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

  /// While editing, the name boxes are wide enough ([skuInBoxW]) to carry each line's SKU inside them. When they
  /// aren't (a 1280 window), the SKU sits under its box instead, where the read-only line has it, rather than being
  /// left out (B9, P&S final polish 2026-11-23: at 1280 the SKU vanished the moment Edit was pressed). One answer for
  /// the whole table, so every line puts it in the same place.
  final bool skuInBox;

  /// While editing, some line's SKU sits under its box ([skuInBox] false): every line keeps that room, so the rows
  /// stay one height and opening a line never moves the ones below it.
  final bool metaSlot;

  /// Read-only, the room added to each of the five gaps between the columns from the item on: the item column stops
  /// at [maxReadItemW] and the rest of the width spreads the figures out (user 2026-11-24: "shorten the line item name
  /// ... it's too long and scrunching the other columns").
  final double spread;
  const _Cols({required this.cost, required this.editable, this.stacked = false, this.skuInBox = true, this.metaSlot = false, this.spread = 0});

  _Cols withMetaSlot(bool slot) => slot == metaSlot
      ? this
      : _Cols(cost: cost, editable: editable, stacked: stacked, skuInBox: skuInBox, metaSlot: slot, spread: spread);

  /// Read-only, the widest the item column takes before the room goes between the figures, and the most each gap
  /// takes (past that, on a very wide window, the item column has the rest).
  static const maxReadItemW = 400.0, maxSpread = 60.0;

  /// Where a line's SKU goes while editing: inside its name box, or under it. A discount's or fee's "Discount" / "Fee"
  /// always sits in its box, stacked too (it is short): under it, a fee's mark gave every line an empty line of room.
  bool metaInBox(LineDraft line) => line.isCharge || (!stacked && skuInBox);
  Widget? metaUnder(LineDraft line) => metaInBox(line) ? null : _inlineMeta(line);

  // Quantity is wide enough for "35,125.30" (a real Service Fusion line) and, while editing, its arrows; the tax for
  // "Prairie Grove 10.5%" and its chevron.
  // qtyEditW, with its arrows, fits "-99,999.99" whole (a little shorter, user 2026-11-23: the 120 px box sized for the
  // widest quantity that can be typed, "-999,999.99", read as too long); a bigger one is drawn smaller in its box, and
  // scrolls while typed. qtyW fits a stored "-999,999.999".
  // Rate, total and cost: one width, just room for "$ 999,000.00" (user 2026-11-23: "all same size and only big enough
  // to fit the number 999,000.00"): 81.6 px in Roboto, the widest of the app's fonts, plus [_cellX] each side and the
  // caret. A bigger figure is drawn smaller in its box.
  static const figureW = 100.0;
  static const gripW = 22.0, eyeW = 36.0, qtyW = 88.0, qtyEditW = 104.0, rateW = figureW, amountW = figureW, costW = figureW;
  // taxEditW: the tax select's box while editing (shorter twice, user 2026-11-23; 24 px wider again 2026-11-24 so it
  // holds "Springdale 10.5%", the place and its rate: "the tax box could be more informational");
  // a long place is cut to its first part in the box, as before. Read-only keeps taxW, so a long place reads whole.
  // 176 (was 164): "Springdale, Washington" in the table's semibold figures still fits on one line (user 2026-11-24).
  static const taxW = 176.0, taxEditW = 156.0, actionsW = 42.0;

  // The room the name boxes gave up (48 px, shorter three times, user 2026-11-23) is spread through the line rather
  // than left in one gap before the quantity ("sprinkle a little extra space through the line"): a little more round
  // the x and =, more between the total, the cost and the tax.

  /// The x between quantity and rate, the = before the amount (editing only).
  static const symW = 28.0;

  /// Between the amount, the cost and the tax.
  static const gapW = 20.0;

  /// Between the item and its quantity.
  static const itemGap = 12.0;

  /// While editing, between the name box and the quantity.
  static const itemGapEdit = 28.0;
  double get gap => editable ? itemGapEdit : itemGap;

  /// The narrowest the item column may get before the lines stack.
  static const minItemW = 240.0;

  /// Stacked (a small window): one width for every line's amount, so the name boxes beside it line up.
  static const stackAmountW = 104.0;

  /// The narrowest name box that still shows the SKU inside it, and the most the SKU may take there. The name is what
  /// the line is, so it keeps at least about 260 px before the SKU joins it (round 2: at 400 a 1280 window cut every
  /// long name to "Clopay | Canyon Ridge | C..." beside its SKU; the SKU is still on the read-only line).
  static const skuInBoxW = 460.0, skuMaxW = 104.0;

  /// The room a name box of [box] px gives its SKU: [skuMaxW] in the narrowest, a fifth of a wider box up to 180 px,
  /// so a long SKU reads whole where there is room for it (B9, 2026-11-23).
  static double skuRoom(double box) => (box * 0.2).clamp(skuMaxW, 180.0);

  /// Below this a name box's "Description" is its icon alone, so the name keeps some room.
  static const compactToggleW = 260.0;

  /// The room before every line's name for its "S" or "I" mark ([_KindMark]), and how much further in a service
  /// package's lines sit, under its heading.
  static const markW = 28.0, packageIndent = 18.0;

  double get qty => editable ? qtyEditW : qtyW;
  double get tax => editable ? taxEditW : taxW;
  double get lead => (editable ? gripW : 0) + eyeW;
  double get trail => editable ? actionsW : 0;

  static _Cols of(double width, {required bool cost, required bool editable}) {
    final fixed =
        (editable ? gripW + qtyEditW + symW * 2 + actionsW + itemGapEdit : qtyW + itemGap) + eyeW + rateW + amountW + (cost ? gapW + costW : 0) + gapW + (editable ? taxEditW : taxW);
    // The name box is the item column less the room for each line's mark.
    final free = width - fixed;
    final gaps = cost ? 5 : 4;
    final spread = editable || free <= maxReadItemW ? 0.0 : ((free - maxReadItemW) / gaps).clamp(0.0, maxSpread);
    return _Cols(cost: cost, editable: editable, stacked: free < minItemW, skuInBox: free - markW >= skuInBoxW, spread: spread);
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

    /// Before the item, inside its column: a service package line's "S" mark, which also indents it under the heading.
    Widget? itemLead,
    CrossAxisAlignment cross = CrossAxisAlignment.start,
  }) => Row(
    crossAxisAlignment: cross,
    // Each slot is keyed by its column, the same in the headings and in every line (the alignment tests measure them).
    children: [
      if (editable) SizedBox(key: const ValueKey('col-grip'), width: gripW, child: grip),
      SizedBox(key: const ValueKey('col-eye'), width: eyeW, child: eye),
      Expanded(
        key: const ValueKey('col-item'),
        child: itemLead == null
            ? item
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [itemLead, Expanded(child: item)],
              ),
      ),
      SizedBox(width: gap + spread),
      SizedBox(key: const ValueKey('col-qty'), width: qty, child: qtyCell),
      if (editable) SizedBox(width: symW, child: times) else SizedBox(width: spread),
      SizedBox(key: const ValueKey('col-rate'), width: rateW, child: rateCell),
      if (editable) SizedBox(width: symW, child: equals) else SizedBox(width: spread),
      SizedBox(key: const ValueKey('col-amount'), width: amountW, child: amountCell),
      if (cost) ...[SizedBox(width: gapW + spread), SizedBox(key: const ValueKey('col-cost'), width: costW, child: costCell)],
      SizedBox(width: gapW + spread),
      SizedBox(key: const ValueKey('col-tax'), width: tax, child: taxCell),
      if (editable) SizedBox(key: const ValueKey('col-menu'), width: actionsW, child: menu),
    ],
  );
}

const _figures = [FontFeature.tabularFigures()];
const _head = LineTable.head;
// Every figure of the Products & Services table reads black (user 2026-11-24: "all font ... should be black, not just
// the total column"): already ink, but at w500 (Segoe UI has none, so regular) they looked grey beside TOTAL. Semibold,
// and TOTAL bold ([_amountStyle]) so it still leads.
const _cell = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.ink, height: 1.35, fontFeatures: _figures);
const _cellMuted = LineTable.quiet;
const _costText = _cell;
const _nameStyle = LineTable.name;
const _metaStyle = LineTable.meta;
const _descStyle = LineTable.description;
const _hint = LineTable.hint;

/// The "$" in front of a money box while editing, at the box's left as the field it opens into has it.
const _currency = LineTable.currency;

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
const _edge = LineTable.edge;
const _edgeHover = LineTable.edgeHover;
const _edgeW = LineTable.edgeWidth;
const _radius = LineTable.radius;

/// The ring around a focused box (or a red one around a value that isn't a number). Outside the box, so it moves nothing.
List<BoxShadow> _ring(Color c) => LineTable.ring(c);

/// Under the pointer: an icon button's light fill.
const _press = LineTable.press;
const _amountStyle = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink, height: 1.35, fontFeatures: _figures);

/// A line's amount: bold, red when it is money off. A line at quantity 0 (a note or a part for a later visit: 17% of
/// Service Fusion's lines are) draws its $0.00 lighter itself ([_ViewRow]), so a column of bold "$0.00" doesn't drown out
/// the figures that count; a priced line at $0.00 keeps the weight of the figures beside it.
TextStyle _amountFor(int cents) => cents < 0 ? _amountStyle.copyWith(color: DashUi.redText) : _amountStyle;

/// A figure drawn smaller rather than cut short when it is wider than its column ("$1,289,540.40" in a 100 px one).
Widget _fit(Widget child, {Alignment alignment = Alignment.centerLeft}) =>
    FittedBox(fit: BoxFit.scaleDown, alignment: alignment, child: child);

/// Figures of a million dollars or more: the whole line's figures a size smaller, so they fit their columns at one size
/// rather than each box shrinking on its own.
const _bigCents = 100000000;
TextStyle _bigFigures(TextStyle s) => s.copyWith(fontSize: 12);

/// The table's side padding, and the room above and below a read-only line's text.
const _side = 20.0;
// 11 until 2026-11-24 (user: "compact the line items slightly to get rid of some blank space"), 8, then a touch back
// ("increase padding just very slightly"): 10.
const _rowPad = 10.0;

/// The room above and below an editable line's row of boxes, closed and open alike so nothing moves as a line opens
/// (7 until 2026-11-24, made more compact with [_rowPad]).
const _editPad = _cellY - 1; // 5 (4 was a touch tight, user 2026-11-24)

/// The discounts, fees and taxes under the rule are more compact than the products and services (user 2026-11-24):
/// one line each ("Discount" beside the name, not under it), this much above and below it read-only, and
/// [_chargeBoxPad] round its boxes while editing. Never striped.
const _chargePad = 8.0;
const _chargeBoxPad = 2.0;

/// The gap between a line's name and the quiet line under it (its SKU, Description).
const _metaGap = 2.0;

/// Inside every value's cell: where a field puts its text, so a value doesn't move when its field opens. Editable rows
/// are [_rowPad] - [_cellY] from their edge, so both kinds of row are the same height.
const _cellX = LineTable.cellX;
const _cellY = LineTable.cellY;

/// A one-line value box's height: the name's line (14 px at 1.35, scaled with the reader's text size) and the room above
/// and below it. Fixed, so a value and the field it opens into are exactly as tall.
double _boxHeight(BuildContext context) => LineTable.boxHeight(context);

/// Behind the open line while editing (never under the pointer: user 2026-11-13 round 3, no hover shading on rows).
final Color _rowTint = LineTable.rowTint;

/// Every other read-only line: an extremely light cool off-white, white's neighbour (user 2026-11-13 round 3: "barely
/// noticeable", for following a line across the table, not zebra stripes). It replaces the rules between read-only lines.
final Color _stripe = LineTable.stripe;


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

  /// The draft's tax lines: the record's own ([LineItemsEditor.taxOptions]) and any added from Tax, discounts & fees,
  /// less any taken off. Each line's Tax dropdown offers these (and the set's own rate, [_tax]) and No tax.
  late List<SalesTax> _taxes;
  int _nextUid = 0;
  int? _active; // the row with its fields open
  String _focusField = 'name';
  final Set<int> _flash = {}; // rows just added (one line, or a package's lines), lit for a moment
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

  /// The Tax, discounts & fees panel is open (its button looks pressed and its chevron turns).
  bool _chargesOpen = false;

  @override
  void initState() {
    super.initState();
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
    _taxes = [...widget.taxOptions];
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
    if (!_sameLines(old.lines, widget.lines) ||
        old.taxRate != widget.taxRate ||
        old.editable != widget.editable ||
        !_sameTaxes(old.taxOptions, widget.taxOptions)) {
      // New saved lines arrived (our save, a refresh, someone else's change). Keep an unsaved draft unless it was ours
      // that just landed. Whether there is one is judged against the lines it was made from: judged against the new
      // ones, an untouched draft of the old lines looked changed, so it stayed on screen, marked "Changed, not saved"
      // (found 2026-11-13).
      final hadDraft = old.editable && _differsFrom(old.lines, old.taxRate, old.taxOptions);
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
    _searchFocus.dispose();
    super.dispose();
  }

  // ---- draft state ------------------------------------------------------------------------------------------------

  List<LineDraft> get _lines => [for (final r in _rows) r.line];

  bool get _dirty => widget.editable && _differsFrom(widget.lines, widget.taxRate, widget.taxOptions);

  /// The same tax lines, in the same order.
  static bool _sameTaxes(List<SalesTax> a, List<SalesTax> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!a[i].sameAs(b[i])) return false;
    }
    return true;
  }

  /// The draft differs from [lines] at [taxRate] with [taxes] (or holds a number that doesn't parse).
  bool _differsFrom(List<LineDraft> lines, double? taxRate, List<SalesTax> taxes) {
    if (_invalid.values.any((s) => s.isNotEmpty)) return true;
    if ((_tax == null) != (taxRate == null) || (_tax != null && (_tax! * 10000).round() != (taxRate! * 10000).round())) return true;
    if (!_sameTaxes(_taxes, taxes)) return true;
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
      _flash
        ..clear()
        ..add(row.uid);
    });
    _lightFor();
    if (open != null) _open(row.uid, open);
  }

  /// The lit rows go back to normal after a moment.
  void _lightFor() {
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted && _flash.isNotEmpty) setState(_flash.clear);
    });
  }

  void _add(LineDraft line, {CatalogEntry? from}) {
    final added = _Row(_nextUid++, line);
    if (from != null && from.isService) _added[added.uid] = from;
    _insert(added);
    _scrollTo(added);
  }

  /// A service package (USER RULE 2026-11-20): its rates go in as separate lines under the package's name, each at its
  /// own starting quantity, price and cost, all lit as they come in. None is a "main" line.
  void _addPackage(CatalogEntry entry) {
    final id = 'pkg-$_nextUid';
    final rows = [for (final l in entry.toPackageLines(id)) _Row(_nextUid++, l)];
    if (rows.isEmpty) return;
    _changed(() {
      _rows.addAll(rows);
      _flash
        ..clear()
        ..addAll(rows.map((r) => r.uid));
    });
    _lightFor();
    _scrollTo(rows.last);
  }

  /// The heading's ⋮ > Remove package: all of that package's lines go at once, with one Undo that puts them all back.
  void _removePackage(String id) {
    final gone = [for (final r in _rows) if (r.line.packageId == id) r];
    if (gone.isEmpty) return;
    final at = _rows.indexOf(gone.first);
    final generation = _generation;
    _changed(() {
      _rows.removeWhere(gone.contains);
      for (final r in gone) {
        _invalid.remove(r.uid);
        _leaving.remove(r.uid);
        if (_active == r.uid) _active = null;
      }
    });
    final name = gone.first.line.packageName ?? 'the package';
    final lines = gone.length == 1 ? '1 line' : '${gone.length} lines';
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(widget.onPreviewSave != null ? 'Removed "$name" ($lines) from the preview.' : 'Removed "$name" ($lines). It is gone once you save.'),
          persist: false,
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              // Only into the draft they came out of (see [_finishRemove]).
              if (!mounted || !widget.editable || generation != _generation || gone.any(_rows.contains)) return;
              _changed(() => _rows.insertAll(at.clamp(0, _rows.length), gone));
            },
          ),
        ),
      );
  }

  /// The new line, and the search under it, stay in view clear of the page's save bar: the page scrolls just enough.
  void _scrollTo(_Row added) {
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
    if (c.entry != null && c.entry!.isPackage) {
      _addPackage(c.entry!);
    } else if (c.entry != null) {
      _add(c.entry!.toLine(), from: c.entry);
    } else if (c.custom != null) {
      _insert(_Row(_nextUid++, LineDraft(name: c.custom!, quantity: 1, source: 'manual')), open: 'rate');
    }
  }

  // ---- Tax, discounts & fees ----------------------------------------------------------------------------------------

  /// The draft's lines as the totals take them: a taxable line whose tax name isn't one of the draft's taxes exactly is
  /// given the one it resolves to ([SalesTax.resolve]: Service Fusion's lines often say just "Sales Tax"), so the totals
  /// tax it at what its Tax cell says.
  List<LineDraft> get _taxedLines => [
    for (final l in _lines)
      if (l.taxable && !l.isCharge && l.taxName != null && !_taxes.any((t) => t.name == l.taxName))
        switch (SalesTax.resolve(l.taxName, _taxes)) {
          final t? => l.copyWith(taxName: t.name),
          null => l,
        }
      else
        l,
  ];

  /// The draft's totals. A percentage fee is worked out on the items less every discount, the record's own discount
  /// charges included ([LineItemsEditor.recordDiscounts]: Service Fusion keeps its discounts as charges, not lines).
  LineTotals _totals() {
    final rates = {for (final t in _taxes) t.name: t.rate};
    final t = computeLineTotals(_taxedLines, _tax, taxRates: rates);
    final outside = widget.recordDiscounts?.call(t.itemsCents) ?? 0;
    return outside == 0 ? t : computeLineTotals(_taxedLines, _tax, taxRates: rates, outsideDiscountCents: outside);
  }

  /// How many lines each tax is on ('' the set's own rate).
  Map<String, int> _taxCounts() {
    final out = <String, int>{};
    for (final l in _taxedLines) {
      if (!l.taxable || l.isCharge) continue;
      final k = l.taxName != null && _taxes.any((t) => t.name == l.taxName) ? l.taxName! : '';
      out[k] = (out[k] ?? 0) + 1;
    }
    return out;
  }

  final _chargesButton = GlobalKey(debugLabel: 'tax, discounts and fees');

  /// The "Tax, discounts & fees" button under the search: its panel ([showChargesPanel]) lists the record's taxes,
  /// discounts and fees, the Arkansas catalog, out-of-state tax and the discount and fee presets; what is done there is
  /// applied here.
  Future<void> _openCharges() async {
    final ctx = _chargesButton.currentContext;
    if (ctx == null || !widget.editable) return;
    final totals = _totals();
    final charges = [
      for (var i = 0; i < _rows.length; i++)
        if (_rows[i].line.isCharge) ChargeEntry(_rows[i].uid, _rows[i].line, totals.lines[i].amountCents),
    ];
    // Only the discounts and charges that aren't lines of the table. Rows built from the lines ([LineSummaryRow.fromLines])
    // are already listed as the editable discounts and fees above them; listing them again showed every Service Fusion
    // discount and fee twice (the 11-24 rule: Service Fusion's discounts and fees are lines).
    final record = [
      for (final r in widget.summary ?? const <LineSummaryRow>[])
        if (!r.fromLines && (r.kind == SummaryKind.discount || r.kind == SummaryKind.charge)) (r.label, r.cents, r.kind == SummaryKind.discount),
    ];
    final result = await showChargesPanel(
      context: ctx,
      snapshot: ChargesSnapshot(
        taxes: _taxes,
        taxedLines: _taxCounts(),
        ownRate: _tax,
        canOwnRate: widget.summary == null,
        charges: charges,
        recordCharges: record,
        itemsCents: totals.itemsCents,
        // Every discount a percentage fee is worked out after: the draft's and the record's own (see _totals).
        discountCents: totals.itemsCents - totals.feeBaseCents,
        today: isoDay(DashClock.now()),
        settings: widget.taxSettings,
      ),
    );
    if (!mounted || result == null || !widget.editable) return;
    _applyCharges(result);
  }

  /// The button's click, and a click on a tax line's boxes: opens Tax, discounts & fees (once at a time).
  Future<void> _openChargesPanel() async {
    if (_chargesOpen) return;
    setState(() => _chargesOpen = true);
    try {
      await _openCharges();
    } finally {
      if (mounted) setState(() => _chargesOpen = false);
    }
  }

  void _applyCharges(ChargesResult r) {
    switch (r) {
      case AddTax(:final tax):
        if (_taxes.any((t) => t.name == tax.name)) return; // one tax per place: never twice
        _changed(() => _taxes = [..._taxes, tax]);
        _say('Added ${tax.short} ${SalesTax.rateText(tax.rate)}%. Choose it in a line\'s Tax column to tax that line.');
      case UpdateTax(:final was, :final now):
        _changed(() {
          _taxes = [for (final t in _taxes) t.name == was.name ? now : t];
          if (was.name != now.name) {
            for (final row in _rows) {
              if (row.line.taxName == was.name) row.line = row.line.copyWith(taxName: now.name);
            }
          }
        });
        _say('${now.short} is now ${SalesTax.rateText(now.rate)}%.');
      case RemoveTax(:final tax):
        _removeTax(tax);
      case SetOwnRate(:final rate):
        final was = _tax;
        final untaxed = <_Row>[];
        _changed(() {
          _tax = rate;
          if (rate == null) {
            for (final row in _rows) {
              if (row.line.taxable && !row.line.isCharge && (row.line.taxName == null || !_taxes.any((t) => t.name == row.line.taxName))) {
                untaxed.add(row);
                row.line = row.line.copyWith(taxable: false, taxName: null);
              }
            }
          }
        });
        if (rate == null && was != null) {
          _say(
            'Removed the ${SalesTax.rateText(was)}% sales tax${untaxed.isEmpty ? '' : ' (${untaxed.length} line${untaxed.length == 1 ? '' : 's'} now No tax)'}.',
            undo: () {
              _tax = was;
              for (final row in untaxed) {
                if (_rows.contains(row)) row.line = row.line.copyWith(taxable: true, taxName: null);
              }
            },
          );
        }
      case AddCharge(:final line):
        final row = _Row(_nextUid++, line);
        _insert(row);
        _scrollTo(row);
      case UpdateCharge(:final uid, :final line):
        final row = _rows.where((x) => x.uid == uid).firstOrNull;
        if (row != null) _changed(() => row.line = line);
      case RemoveCharge(:final uid):
        final i = _rows.indexWhere((x) => x.uid == uid);
        if (i >= 0) _remove(i);
    }
  }

  /// A tax comes off the record: every line set to it goes to No tax, with one Undo that puts the tax and those lines
  /// back.
  void _removeTax(SalesTax tax) {
    final at = _taxes.indexWhere((t) => t.name == tax.name);
    if (at < 0) return;
    final generation = _generation;
    final gone = _taxes[at];
    final untaxed = <_Row>[];
    _changed(() {
      _taxes = [..._taxes]..removeAt(at);
      for (final row in _rows) {
        final l = row.line;
        if (!l.taxable || l.isCharge) continue;
        final named = l.taxName == gone.name || (l.taxName != null && SalesTax.resolve(l.taxName, [..._taxes, gone])?.name == gone.name);
        if (named) {
          untaxed.add(row);
          row.line = l.copyWith(taxable: false, taxName: null);
        }
      }
    });
    _say(
      'Removed ${gone.short}${untaxed.isEmpty ? '' : ' (${untaxed.length} line${untaxed.length == 1 ? '' : 's'} now No tax)'}.',
      undo: () {
        if (generation != _generation || _taxes.any((t) => t.name == gone.name)) return;
        _taxes = [..._taxes]..insert(at.clamp(0, _taxes.length), gone);
        for (final row in untaxed) {
          if (_rows.contains(row)) row.line = row.line.copyWith(taxable: true, taxName: gone.name);
        }
      },
    );
  }

  /// A note at the foot of the window (with an Undo that changes the draft, when given).
  void _say(String text, {VoidCallback? undo}) {
    final generation = _generation;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          // A snack bar with an action stays up until dismissed unless told otherwise (Flutter's `persist`).
          persist: false,
          duration: const Duration(seconds: 6),
          action: undo == null
              ? null
              : SnackBarAction(
                  label: 'Undo',
                  onPressed: () {
                    if (!mounted || !widget.editable || generation != _generation) return;
                    _changed(undo);
                  },
                ),
        ),
      );
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

  /// The open line as it was when the box being edited took the keyboard: what Esc puts back (decision A1,
  /// 2026-11-23). Every move of the keyboard within the line (Tab, a click on another box, a pick from its tax select)
  /// keeps what was typed so far and starts a new one ([_keepSoFar]); Enter keeps it and closes the line. Held here, not
  /// in the row, so it is always the draft's own line (the row's copy can be a frame behind the last keystroke).
  LineDraft? _baseline;

  void _keepSoFar(int uid) {
    if (_active != uid) return;
    _baseline = _rows.where((r) => r.uid == uid).firstOrNull?.line;
  }

  void _open(int uid, String field) {
    if (_active != uid) _baseline = _rows.where((r) => r.uid == uid).firstOrNull?.line;
    setState(() {
      _active = uid;
      _focusField = field;
      if (field == 'description') _moreOpen.add(uid);
      // The line's fields start again from its good figures (the draft only ever keeps good numbers), so nothing from
      // last time marks it: reopening never shows a good figure in a red box (found by the 2026-11-13 review).
      _invalid.remove(uid);
    });
    _notifyDirty();
  }

  /// Enter, Tab out of the line, or a click elsewhere: the line closes and keeps what was typed (a figure that isn't a
  /// number is put back and the editor says so, see [_settleBad]).
  void _close(int uid) {
    if (_active != uid) return;
    _settleBad(uid, const ['qty', 'rate', 'cost', 'pct']);
    setState(() => _active = null);
  }

  /// Esc (decision A1, 2026-11-23; it used to close the line keeping what was typed): the line goes back to how it was
  /// when the box being edited took the keyboard ([_baseline]), quietly, and closes. What Enter, Tab or a move to another
  /// box in the line already kept stays. Spreadsheets and most editors take Esc as "cancel".
  void _cancel(int uid) {
    if (_active != uid) return;
    final i = _rows.indexWhere((r) => r.uid == uid);
    final was = _baseline;
    _changed(() {
      if (i >= 0 && was != null) _rows[i].line = was;
      _invalid.remove(uid);
      _active = null;
    });
    _baseline = null;
  }

  /// [fields] of line [uid] were left holding something that isn't a number. The line never took it: while it was there
  /// the line went back to its figure from before that edit ([_EditRowState._before]), so the totals never counted a
  /// half-typed figure ("12..5" in a $689.00 rate used to leave it at $12.00, the last keystroke that read as a number:
  /// found in real Chrome, audit round 2, 2026-11-20). The mark comes off, and a note says what the line kept.
  void _settleBad(int uid, Iterable<String> fields) {
    final set = _invalid[uid];
    if (set == null) return;
    final gone = [for (final f in fields) if (set.contains(f)) f];
    if (gone.isEmpty) return;
    set.removeAll(gone);
    final i = _rows.indexWhere((r) => r.uid == uid);
    if (i < 0) return;
    final l = _rows[i].line;
    String money(double? v, String none) => v == null ? none : centsMoney((v * 100).round());
    String kept(String f) => switch (f) {
      'qty' => 'quantity ${qtyText(l.quantity)}',
      'pct' => 'percentage ${l.percent == null ? '' : '${SalesTax.rateText(l.percent!)}%'}',
      'cost' => l.cost == null ? 'empty cost' : 'cost ${money(l.cost, '')}',
      _ => l.isCharge ? 'amount ${money(l.rate, r'$0.00')}' : (l.rate == null ? 'empty rate' : 'rate ${money(l.rate, '')}'),
    };
    setState(() {});
    _notifyDirty();
    _say("Line ${_shownNo(_rows[i])}: that wasn't a number, so it keeps its ${gone.map(kept).join(' and ')}.");
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
          persist: false,
          duration: const Duration(seconds: 6),
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
    final shown = _shown;
    for (var i = 0; i < shown.length; i++) {
      final r = shown[i];
      final bad = _invalid[r.uid] ?? const <String>{};
      if (bad.isNotEmpty) return 'Line ${i + 1}: ${bad.map(_fieldName).join(', ')} ${bad.length == 1 ? "isn't" : "aren't"} a valid number.';
      if (r.line.name.trim().isEmpty) return 'Line ${i + 1} needs a name.';
      if (r.line.isCharge) {
        final what = r.line.isDiscount ? 'Discount' : 'Fee';
        final p = r.line.percent;
        if (p != null && (p <= 0 || p > 100)) return '$what "${r.line.name}" needs a percentage above 0% and up to 100%.';
        if (p == null && (r.line.rate == null || r.line.rate! <= 0)) return '$what "${r.line.name}" needs an amount above \$0.';
      }
    }
    return null;
  }

  static String _fieldName(String f) => switch (f) {
    'qty' => 'quantity',
    'pct' => 'percentage',
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
    int? sourceAt(int i) {
      final at = _origin[_rows[i].uid];
      final same = at != null && at < fixed.length && at < widget.lines.length && (!widget.editable || _rows[i].line.sameAs(widget.lines[at]));
      return same ? at : null;
    }
    final out = [
      for (var i = 0; i < _rows.length; i++)
        if (sourceAt(i) case final at?) LineFigures(fixed[at], totals.lines[i].extCostCents) else totals.lines[i],
    ];
    // A source's percentage discount or fee (Service Fusion's 3% card fee) that is still as it came keeps the source's
    // own amount, following the items in the proportion the source had, so the preview's changes move it as Service
    // Fusion would. Changed, it is worked out as one added here is.
    var wasItems = 0, nowItems = 0;
    for (var j = 0; j < widget.lines.length && j < fixed.length; j++) {
      if (!widget.lines[j].isCharge) wasItems += fixed[j];
    }
    for (var i = 0; i < _rows.length; i++) {
      if (!_rows[i].line.isCharge) nowItems += out[i].amountCents;
    }
    if (wasItems > 0 && nowItems != wasItems) {
      for (var i = 0; i < _rows.length; i++) {
        final at = sourceAt(i);
        if (at == null || !_rows[i].line.isCharge || _rows[i].line.percent == null) continue;
        out[i] = LineFigures((fixed[at] * nowItems / wasItems).round(), out[i].extCostCents);
      }
    }
    return out;
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
    final totals = _totals();
    final figures = _lineFigures(totals);
    final editable = widget.editable;
    if (widget.onFigures != null) {
      // What the summary shows: a source's own figures (reworked for a changed draft), else the worked-out totals.
      final summary = widget.summary == null
          ? null
          : (editable && _dirty && widget.summaryBuilder != null ? widget.summaryBuilder!(_lines, figures, _taxes) : widget.summary!);
      final total = summary == null
          ? totals.totalCents
          : (summary.where((r) => r.kind == SummaryKind.total).firstOrNull?.cents ?? summary.fold<int>(0, (s, r) => s + r.cents));
      // The page's tabs get no margin while a line's cost is unknown (it would read 100% with no costs at all); the
      // summary's Gross profit is filled in all the same (USER RULE 2026-11-24).
      _report(total, totals.missingCostLines > 0 ? null : _profit(totals, summary)?.marginPct);
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
              // The table spans the block (user 2026-11-24: a width cap left "a lot of white" either side at 1920; an
              // outline round it was tried and taken off the same day).
              final cols = _Cols.of(c.maxWidth - _side * 2, cost: widget.showCost, editable: editable);
              // A source's own figures (Service Fusion's), reworked for the draft once it is changed.
              final summary = widget.summary == null
                  ? null
                  : (editable && _dirty && widget.summaryBuilder != null ? widget.summaryBuilder!(_lines, figures, _taxes) : widget.summary!);
              final rows = _summaryRows(totals, summary);
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
                      key: widget.tableKey,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _table(cols, figures, _tableFigures(rows)),
                        if (editable) _addRow(cols, narrow: c.maxWidth < 700),
                      ],
                    ),
                  ),
                  _footer(totals, summary, rows, wide: c.maxWidth >= 1080),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// The column headings and the lines.
  Widget _table(_Cols cols, List<LineFigures> figures, List<_TotalsRow> extras) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      if (!cols.stacked) _header(cols) else const Divider(height: 1, color: DashUi.line),
      if (_rows.isEmpty) _empty() else _list(cols, figures, extras),
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
    final open = _chargesOpen;
    final charges = Semantics(
      label: 'Tax, discounts and fees',
      button: true,
      excludeSemantics: true,
      child: TextButton.icon(
        key: _chargesButton,
        onPressed: _openChargesPanel,
        icon: const Icon(Icons.add_rounded, size: 17),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // No count beside it (user 2026-11-24): the lines above already list them.
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
    // Set off from the lines above (the discounts, fees and taxes) by a thin rule with room on both sides of it (user
    // 2026-11-24: the room above it doubled, 8 to 16).
    return Container(
      margin: const EdgeInsets.only(top: 16),
      // The search's edge on the name boxes' edge: past the grip, the eye and the S / I mark (stacked too).
      padding: EdgeInsets.fromLTRB(_side + cols.lead + _Cols.markW, 14, _side, 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: DashUi.line), bottom: BorderSide(color: DashUi.line)),
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
    // Every heading starts where its values start, [_cellX] in (left-aligned, user 2026-11-23).
    Widget h(String t, {bool right = false, double end = 0}) => Padding(
      padding: EdgeInsets.only(left: _cellX, right: _cellX + end - (right ? _head.letterSpacing! : 0)),
      child: Align(
        alignment: right ? Alignment.centerRight : Alignment.centerLeft,
        child: Text(t, maxLines: 1, softWrap: false, overflow: TextOverflow.fade, style: _head),
      ),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(_side, 14, _side, 10),
      // A firm rule under the headings, ink and 2 px (user 2026-11-24: "much more pronounced"), so they read as the
      // table's head rather than another row.
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: DashUi.ink, width: 2)),
      ),
      child: cols.line(
        cross: CrossAxisAlignment.center,
        // No heading over the lines' eyes (user 2026-11-16): each line's own eye says whether the customer sees it. The
        // column keeps its width, so ITEM stays over the names.
        // Read-only the name is bare text at the column's start; while editing it is in a box, [_cellX] in.
        itemLead: const SizedBox(width: _Cols.markW),
        item: Padding(
          padding: EdgeInsets.only(left: cols.editable ? _cellX : 0),
          child: const Text('ITEM', maxLines: 1, style: _head),
        ),
        qtyCell: h('QTY'),
        rateCell: h('RATE'),
        amountCell: h('TOTAL'),
        costCell: h('COST'),
        taxCell: h('TAX'),
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
  /// the name box), so they are even anyway; where the boxes are too narrow for it, the SKU sits under its box and
  /// every line keeps that room ([_Cols.metaSlot]).
  ///
  /// The products and services come first; under a rule, the discounts and fees, then the taxes and any charge that
  /// isn't a line ([extras]: Service Fusion's own discounts and fees, money it doesn't itemize). Each part keeps its
  /// own order, and a line is moved only within its part. [row]'s index is the line's place as shown (see [_shown]).
  Widget _list(_Cols table, List<LineFigures> all, List<_TotalsRow> extras) {
    final cols = table.withMetaSlot(
      widget.editable && !table.stacked && !table.skuInBox && _rows.any((r) => table.metaUnder(r.line) != null),
    );
    // A tax too long for one line takes two, as a name over its SKU does (see _taxTwoLines).
    // The discounts and fees are one line each (see [_chargePad]), so only the products and services count.
    final twoLine = !widget.editable && _rows.any((r) => !r.line.isCharge && (_hasMeta(r.line) || _taxTwoLines(context, r.line, _taxes, _tax) != null));
    final shown = _shown;
    final firstCharge = shown.indexWhere((r) => r.line.isCharge);
    // The rule, and more room under it before the discounts and fees (user 2026-11-24).
    const rule = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      // The black rule under the last product or service sets the discounts and fees off now (user 2026-11-24): this one
      // only keeps the room, so the two don't draw a double line.
      children: [SizedBox(key: ValueKey('charges-rule'), height: 1), SizedBox(height: 10)],
    );
    Widget row(int i) {
      final r = shown[i];
      // Where the line sits in its own part, which is all Move up / Move down can move it within (see [_moveShown]).
      final partStart = r.line.isCharge ? (firstCharge < 0 ? 0 : firstCharge) : 0;
      final partEnd = r.line.isCharge || firstCharge < 0 ? shown.length : firstCharge;
      final moves = (up: i > partStart, down: i < partEnd - 1);
      final figures = all[_rows.indexOf(r)];
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
              taxOptions: _taxes,
              defaultRate: _tax,
              onTax: (v) => _pickTax(r, v),
              invalid: _invalid[r.uid] ?? const {},
              onChanged: (l) => _changed(() => r.line = l),
              onInvalid: (f, bad) => _setInvalid(r.uid, f, bad),
              onSettle: (f) => _settleBad(r.uid, [f]),
              onDone: () => _close(r.uid),
              onCancel: () => _cancel(r.uid),
              onKeep: () => _keepSoFar(r.uid),
              onMove: (d) => _moveShown(i, i + d),
              onMenu: (a) => _menu(a, i),
              moves: moves,
              serviceNames: widget.serviceNames,
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
              taxOptions: _taxes,
              defaultRate: _tax,
              onTax: widget.editable ? (v) => _pickTax(r, v) : null,
              invalid: (_invalid[r.uid] ?? const {}).isNotEmpty,
              onOpen: widget.editable ? (f) => _open(r.uid, f) : null,
              onMenu: (a) => _menu(a, i),
              moves: moves,
              serviceNames: widget.serviceNames,
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
                  padding: EdgeInsets.fromLTRB(_side + cols.lead + _Cols.markW + (widget.editable ? _cellX : 0), 0, _side + cols.trail, widget.editable ? 8 : 10),
                  child: notes,
                ),
              ],
            );
      final shell = _RowShell(
        key: r.shell,
        flash: _flash.contains(r.uid),
        leaving: _leaving.contains(r.uid),
        onLeft: () => _finishRemove(r),
        active: active,
        editable: widget.editable,
        // Every line white, with a dark (slate) rule under each product and service (user 2026-11-24: "instead of alternating
        // color ... all white but with a black line underneath each line item"), read-only and editing alike. The
        // discounts and fees are compact and unruled, as the taxes under them are.
        stripe: false,
        // Edge to edge, out to the block's outline (user 2026-11-24). A service package's lines read as one group: no
        // rule between two of its lines, only under its last one (user 2026-11-24).
        ruleLeft: r.line.isCharge || (r.line.packageId != null && i + 1 < shown.length && shown[i + 1].line.packageId == r.line.packageId)
            ? null
            : 0,
        child: body,
      );
      // A service package's name heads its lines (USER RULE 2026-11-20): over the first of each run of its lines.
      final pkg = r.line.packageId;
      final heads = pkg != null && (i == 0 || shown[i - 1].line.packageId != pkg);
      var count = 0;
      if (heads) {
        for (var j = i; j < shown.length && shown[j].line.packageId == pkg; j++) {
          count++;
        }
      }
      return KeyedSubtree(
        key: ValueKey(r.uid),
        // The rule between the products and services and the discounts and fees rides on the first discount or fee.
        child: i == firstCharge && i > 0
            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [rule, shell])
            : heads
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _PackageHeader(
                    id: pkg,
                    name: r.line.packageName ?? 'Service package',
                    lines: count,
                    cols: cols,
                    first: i == 0,
                    onRemove: widget.editable ? () => _removePackage(pkg) : null,
                  ),
                  shell,
                ],
              )
            : shell,
      );
    }

    // The taxes and charges that aren't lines, under the discounts and fees (under the rule when there are none):
    // compact and unstriped, as they are.
    final figureRows = [
      if (extras.isNotEmpty && firstCharge < 0) rule,
      for (var k = 0; k < extras.length; k++) _FigureRow(row: extras[k], cols: cols, onOpen: widget.editable ? _openChargesPanel : null),
    ];
    if (!widget.editable) {
      // The headings' hairline above, this one under the last line: the table is framed, the stripes do the rest. White
      // behind it all, so the compact rows' fractional heights never leave a seam of the page between them.
      return ColoredBox(
        color: Colors.white,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (var i = 0; i < shown.length; i++) row(i), ...figureRows, const Divider(height: 1, thickness: 1, color: DashUi.line)],
        ),
      );
    }
    final list = ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: shown.length,
      onReorderItem: _moveShown,
      proxyDecorator: (child, _, anim) =>
          Material(elevation: 4, shadowColor: Colors.black12, color: Colors.white, borderRadius: BorderRadius.circular(8), child: child),
      itemBuilder: (_, i) => row(i),
    );
    if (figureRows.isEmpty) return list;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [list, ...figureRows]);
  }

  /// The lines as the table shows them: the products and services, then the discounts and fees, each in draft order.
  List<_Row> get _shown => [..._rows.where((r) => !r.line.isCharge), ..._rows.where((r) => r.line.isCharge)];

  /// A line's number as the table shows it (see [_shown]).
  int _shownNo(_Row r) => _shown.indexOf(r) + 1;

  /// Moves the line shown at [from] to [to] (where it lands, as the table shows the lines), within its own part: a
  /// product or service never goes under the rule, a discount or fee never above it.
  void _moveShown(int from, int to) {
    final shown = _shown;
    if (from < 0 || from >= shown.length) return;
    final moving = shown[from];
    final part = [for (final r in shown) if (r.line.isCharge == moving.line.isCharge) r];
    final start = moving.line.isCharge ? shown.length - part.length : 0;
    final a = from - start;
    final b = (to - start).clamp(0, part.length - 1);
    if (a == b) return;
    // The part's places in the draft, in order; the part, reordered, goes back into the same places.
    final slots = [for (var i = 0; i < _rows.length; i++) if (_rows[i].line.isCharge == moving.line.isCharge) i];
    final order = [...part]
      ..removeAt(a)
      ..insert(b, moving);
    _changed(() {
      for (var k = 0; k < slots.length; k++) {
        _rows[slots[k]] = order[k];
      }
    });
  }

  /// A line's menu, [index] its place as shown.
  void _menu(String action, int index) {
    final shown = _shown;
    if (index < 0 || index >= shown.length) return;
    final at = _rows.indexOf(shown[index]);
    switch (action) {
      case 'up':
        _moveShown(index, index - 1);
      case 'down':
        _moveShown(index, index + 1);
      case 'duplicate':
        _duplicate(at);
      case 'remove':
        _remove(at);
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
  ///
  /// USER RULE 2026-11-24 ("Gross profit needs to be filled in too"): the profit and margin are always worked out, on
  /// the costs that are known; a line with no cost counts as $0 (nothing says how many have none: USER RULE 2026-11-24). It used
  /// to be a dash while any line's cost was unknown (Services Catalog Phase 2).
  _Profit? _profit(LineTotals t, List<LineSummaryRow>? summary) {
    if (!widget.showCost) return null;
    final net = summary == null ? t.netCents - t.processingFeeCents : summary.where((r) => r.beforeTax).fold<int>(0, (s, r) => s + r.cents);
    final profit = net - t.costCents;
    return _Profit(
      t.costCents,
      profit,
      net > 0 ? (profit / net * 1000).round() / 10 : null,
      revenueCents: net,
      missingCostLines: t.missingCostLines,
      fromSource: summary != null,
    );
  }

  /// Every figure behind the summary: the items, each discount, fee and tax, and the total. Those that aren't lines of
  /// the table ([_TotalsRow.tableFigure]: taxes, Service Fusion's charges) are listed in the table under its discounts
  /// and fees; the summary adds the rest up into one "Taxes, fees & discounts" figure.
  List<_TotalsRow> _summaryRows(LineTotals t, List<LineSummaryRow>? summary) {
    final List<_TotalsRow> rows;
    if (summary != null) {
      rows = [
        for (final r in summary)
          _TotalsRow(r.strong ? widget.totalLabel : r.label, r.cents, kind: r.kind, tip: r.tip, fromLines: r.fromLines),
      ];
    } else {
      // One row per tax line, as the record's own tax lines read ("Sales tax Rogers 9.5%"); "Sales tax" at $0.00 while
      // the set has none (USER RULE 2026-11-20: until a tax is added nothing is taxed). The set's own rate and any tax
      // are changed in Tax, discounts & fees.
      String taxLabel(TaxFigure f) {
        if (f.name == null) return 'Sales tax ${SalesTax.rateText(f.rate)}%';
        final t = _taxes.where((x) => x.name == f.name).firstOrNull;
        final short = t?.short ?? SalesTax.shortName(f.name!);
        return short.trim().toLowerCase() == 'sales tax' ? 'Sales tax ${SalesTax.rateText(f.rate)}%' : 'Sales tax $short ${SalesTax.rateText(f.rate)}%';
      }

      final taxRows = [
        for (final f in t.taxes)
          if (f.name != null || _tax != null) _TotalsRow(taxLabel(f), f.taxCents, kind: SummaryKind.tax, tip: f.name),
      ];
      // Card processing fees on a line of their own, after the subtotal: charged, but not profit (decision 8), so the
      // subtotal is exactly the money the profit is worked out on.
      final cardFees = t.processingFeeCents;
      final otherFee = _rows.any((r) => r.line.isFee && !isCardProcessingFee(r.line.name));
      rows = [
        _TotalsRow('Items', t.itemsCents, kind: SummaryKind.items, fromLines: true),
        if (t.discountCents > 0 || _rows.any((r) => r.line.isDiscount))
          _TotalsRow('Discounts', -t.discountCents, kind: SummaryKind.discount, fromLines: true),
        if (t.feeCents - cardFees != 0 || otherFee) _TotalsRow('Fees', t.feeCents - cardFees, fromLines: true),
        if (cardFees != 0) _TotalsRow('Card processing fees', cardFees, kind: SummaryKind.processingFee, fromLines: true),
        // A tax line only once the record has one: a "Sales tax $0.00" under the lines said nothing.
        if (taxRows.isEmpty && _tax != null)
          _TotalsRow('Sales tax ${SalesTax.rateText(_tax!)}%', t.taxCents, kind: SummaryKind.tax)
        else
          ...taxRows,
        _TotalsRow(widget.totalLabel, t.totalCents, kind: SummaryKind.total),
      ];
    }
    return rows;
  }

  /// The figures the table lists under its discount and fee lines ([_TotalsRow.tableFigure]), in the order the lines
  /// above them go: discounts, then fees, then the taxes, then money a source doesn't itemize (Service Fusion sends its
  /// tax charge first). Each kind keeps its own order.
  static List<_TotalsRow> _tableFigures(List<_TotalsRow> rows) {
    int rank(SummaryKind k) => switch (k) {
      SummaryKind.discount => 0,
      SummaryKind.charge || SummaryKind.processingFee => 1,
      SummaryKind.tax => 2,
      _ => 3,
    };
    final out = [for (final r in rows) if (r.tableFigure) r];
    return [for (var g = 0; g <= 3; g++) ...out.where((r) => rank(r.kind) == g)];
  }

  /// Under the lines: the summary as one statement ([_Statement]), with the warnings about the figures over it and the
  /// [LineItemsEditor.aside] beside it (under it on a narrow window).
  Widget _footer(LineTotals t, List<LineSummaryRow>? summary, List<_TotalsRow> rows, {required bool wide}) {
    // Lines with no cost no longer overstate the profit: while any line's cost is unknown the statement shows none, and
    // says how many lines have no cost (Services Catalog Phase 2; see _ProfitInputs).
    final zero = _zeroChecks ? t.zeroUnconfirmedLines : 0;
    final notes = [
      if (summary == null && t.unpricedLines > 0) '${t.unpricedLines} line${t.unpricedLines == 1 ? ' has' : 's have'} no price',
      if (zero > 0) '$zero line${zero == 1 ? '' : 's'} at \$0.00 not confirmed',
    ];
    final profit = _profit(t, summary);
    final warning = notes.isEmpty ? null : _Warning(notes.join('  ·  '));
    // Well clear of the lines (or the add-a-line bar), the same in view and edit mode (user 2026-11-24: tripled, 20 to
    // 60, then 25% more: 75).
    return Padding(
      // 12 px in from the block's outline (it was _side, 20): inside the outline the three blocks still fit in one row at
      // a 1280 window.
      padding: const EdgeInsets.fromLTRB(12, 75, 12, 12),
      child: _Statement(rows: rows, profit: profit, warning: warning, aside: widget.aside, paidCents: widget.paidCents),
    );
  }
}

/// The quiet buttons beside the catalog search: text and an icon, no outline.
/// No hover wash (USER RULE 2026-11-24: nothing on the job page shades under the pointer).
final ButtonStyle _quietButton = TextButton.styleFrom(
  minimumSize: const Size(0, 36),
  padding: const EdgeInsets.symmetric(horizontal: 10),
  foregroundColor: DashUi.ink,
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
).copyWith(overlayColor: dashNoHoverOverlay);

/// Their labels: the size and weight set on the text itself, so it keeps the theme's font.
const _quietLabel = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600);

class _SaveIntent extends Intent {
  const _SaveIntent();
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

  /// Whether the row menu's Move up / Move down can move this line: a line moves only within its own part (products
  /// and services above the rule, discounts and fees under it), so each stops at that part's ends.
  final ({bool up, bool down}) moves;

  /// The record's Service Fusion service names ([LineItemsEditor.serviceNames]).
  final Set<String> serviceNames;
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
    this.moves = (up: false, down: false),
    this.serviceNames = const {},
  });

  @override
  Widget build(BuildContext context) {
    final open = onOpen != null;
    // A discount or a fee (a charge on the whole set): no quantity, rate or cost; its amount, or its percentage, is what
    // is typed.
    final discount = line.isCharge;
    final pct = line.percent;
    final description = _cleanDescription(line.description);
    // A value that opens into its field (editing), or the value padded the same (read-only).
    Widget cell(String field, Widget child, {Alignment align = Alignment.centerLeft, Widget? end, double? endWidth, bool divider = false}) => open
        ? _FieldCell(onTap: () => onOpen!(field), align: align, end: end, endWidth: endWidth, divider: divider, child: child)
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: _cellX),
            // Drawn smaller, never cut short, when wider than its column.
            child: Align(alignment: align, child: _fit(child, alignment: align)),
          );
    // A figure that is worked out, not typed: where a field's text would be. While editing it is centred in a box's
    // height, as the boxes beside it centre theirs: set down from the top by the box's padding instead, the total sat
    // half a pixel above the quantity and rate on its row (P&S visual pass, 2026-11-23).
    Widget plain(Widget child, {Alignment align = Alignment.centerLeft}) => open
        ? SizedBox(
            height: _boxHeight(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: _cellX),
              child: Align(alignment: Alignment(align.x, 0), child: child),
            ),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: _cellX),
            child: Align(alignment: align, child: _fit(child, alignment: align)),
          );
    // A line at quantity 0 adds nothing to the price (a catalog entry listed for reference, an optional extra): quieter.
    final idle = !discount && (line.quantity * 1000).round() == 0;
    // A line with a figure of a million or more draws all its figures a size smaller (see [_bigFigures]).
    int absCents(double? v) => v == null ? 0 : (v * 100).round().abs();
    final big = [figures.amountCents.abs(), absCents(line.rate), absCents(line.cost)].any((v) => v >= _bigCents);
    TextStyle sized(TextStyle s) => big ? _bigFigures(s) : s;
    final cellStyle = sized(idle ? _cell.copyWith(color: _quietTone) : _cell);
    // Money off (a discount, or a Service Fusion item with a negative rate) reads red; a line at quantity 0, lighter.
    final amountStyle = sized(
      idle ? _amountFor(figures.amountCents).copyWith(color: _quietTone, fontWeight: FontWeight.w400) : _amountFor(figures.amountCents),
    );
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
    // Read-only, the eye is centred on the name's first line, as the S / I mark beside it is: set 1 px down from the
    // top instead, it sat a pixel above both (P&S visual pass, 2026-11-23).
    final eyeToggle = _EyeToggle(visible: line.customerVisible, onTap: onToggleVisible);
    final eye = Align(
      alignment: Alignment.topLeft,
      child: open ? eyeToggle : SizedBox(height: _KindMark.textLine(context), child: Center(child: eyeToggle)),
    );
    final actions = Align(
      alignment: Alignment.topRight,
      child: _RowMenu(index: index, moves: moves, onMenu: onMenu),
    );
    // "Not priced" is a to-do on lines being edited; a read-only line with no rate just has none.
    final unpriced = line.rate == null;
    final rateStyle = unpriced ? sized(editable ? _cell.copyWith(fontWeight: FontWeight.w600, color: DashUi.amberText) : _cellMuted) : cellStyle;
    final Widget rateValue = unpriced
        ? Text(editable ? 'No price' : '—', maxLines: 1, overflow: TextOverflow.ellipsis, style: rateStyle)
        : _money(context, line.rate!, boxed: open, style: cellStyle);
    // No cost reads 0.00, read-only and in its box (user 2026-11-23: "if there is no cost should be 0.00"; it was a dash,
    // and "Cost" in an empty box). Display only: the line still counts as having no cost in the summary. Quiet (slate,
    // its weight), so a cost that isn't known reads apart from a real $0.00 one.
    final costStyle = sized(
      // Slate in the figures' own weight: a lighter weight drew "0.00" a pixel narrower than the box's placeholder it
      // opens into, so it moved as the line opened.
      line.cost == null || idle ? _costText.copyWith(color: _quietTone) : _costText,
    );
    // In its box, an empty cost is laid out exactly as the field's "$ 0.00" placeholder it opens into, so it stays put.
    final Widget costValue = line.cost == null && open
        ? Row(
            children: [
              Text(r'$ ', style: DefaultTextStyle.of(context).style.merge(_currency), strutStyle: _valueLine(context, costStyle)),
              Flexible(
                child: Text(
                  '0.00',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: costStyle,
                  strutStyle: _valueLine(context, costStyle),
                  textWidthBasis: TextWidthBasis.longestLine,
                ),
              ),
            ],
          )
        : _money(context, line.cost ?? 0, boxed: open, style: costStyle);
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
        meta: cols.metaInBox(line) ? _inlineMeta(line, strut: _valueLine(context, nameStyle)) : null,
        metaWidth: _Cols.skuRoom(c.maxWidth),
        end: toggleOf(compact: c.maxWidth < _Cols.compactToggleW),
        divider: true,
        child: nameInBox,
      ),
    );
    // Read-only, "Description" sits right after the name, not on the line under it (user 2026-11-24).
    final Widget readName = _NameText(nameText, style: nameStyle, invalid: invalid, trailing: open ? null : toggle);
    final meta = open ? null : _metaLine(line, tone: idle ? _quietTone : DashUi.ink, kindMark: editable);
    // Every line's mark: "S" a service line, "I" an inventory item (USER RULE 2026-11-20); a package's lines sit a step
    // further in, under its heading.
    final mark = _KindMark.of(context, line, services: serviceNames, height: open ? _boxHeight(context) : _KindMark.textLine(context));

    if (cols.stacked) {
      // A small window: the name and amount on top; under the name its quiet line, then quantity x rate, tax and cost.
      String money(double? v) => v == null ? '' : centsMoney((v * 100).round());
      final figuresText = [
        if (open && !discount && line.sku.trim().isNotEmpty) line.sku.trim(),
        if (!discount) '${qtyText(line.quantity)} × ${line.rate == null ? 'no price' : money(line.rate)}',
        // A discount or fee says nothing about tax (USER RULE 2026-11-24).
        if (!discount) _taxLabel(line, taxOptions, defaultRate),
        if (cols.cost && !discount) 'cost ${money(line.cost ?? 0)}',
        // A percentage discount or fee keeps its percentage, as its RATE column has it on a wide window.
        if (discount && pct != null) '${SalesTax.rateText(pct)}%',
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
        label: _lineLabel(index, line),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: _side, vertical: discount ? (open ? _chargeBoxPad : _chargePad) : (open ? _editPad : _rowPad)),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (cols.editable) SizedBox(width: _Cols.gripW, child: grip),
              SizedBox(width: _Cols.eyeW, child: eye),
              mark,
              Expanded(child: body),
              const SizedBox(width: 10),
              // One width for every line's amount, so the name boxes above line up.
              SizedBox(
                width: _Cols.stackAmountW,
                child: Padding(
                  padding: EdgeInsets.only(top: open ? _cellY : 0),
                  child: _fit(
                    Text(centsMoney(figures.amountCents), textAlign: TextAlign.right, maxLines: 1, style: amountStyle),
                    alignment: Alignment.centerRight,
                  ),
                ),
              ),
              if (cols.editable) SizedBox(width: _Cols.actionsW, child: actions),
            ],
          ),
        ),
      );
    }

    // A read-only discount or fee is one line: "Discount" (and its percentage's basis) beside the name, not under it.
    final compactRead = discount && !open;
    final item = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (open)
          nameBox()
        else if (compactRead)
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Flexible(child: _NameText(nameText, style: nameStyle, invalid: invalid)),
              if (meta != null) ...[const SizedBox(width: 10), meta],
            ],
          )
        else
          readName,
        if (open) ?_metaUnderBox(cols, line),
        if (meta != null && !compactRead)
          Padding(
            padding: const EdgeInsets.only(top: _metaGap),
            child: meta,
          ),
        _Reveal(child: desc == null ? null : Padding(padding: EdgeInsets.fromLTRB(0, 8, open ? 0 : 24, 2), child: desc)),
      ],
    );
    // A fee is never taxed; a discount comes off the total and never lowers the tax (USER RULE 2026-11-20). Its Tax
    // column is left empty (USER RULE 2026-11-24: no "Off the total" / "Not taxed").
    final Widget? tax = discount ? null : _TaxCell(line: line, options: taxOptions, defaultRate: defaultRate, onPick: onTax, quiet: idle);
    final qtyValue = Text(qtyText(line.quantity), maxLines: 1, style: cellStyle);
    final Widget? qty = discount
        ? null
        : open
        // A quantity is never cut short: one wider than the box (a stored -999,999.999) is drawn smaller instead.
        ? cell(
            'qty',
            FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: qtyValue),
            end: onQty == null ? null : _Spin(value: line.quantity, rate: line.rate, onChanged: onQty!),
            endWidth: onQty == null ? null : _Spin.width,
          )
        : plain(qtyValue);
    // A percentage discount or fee shows its percentage where an item's rate is (a box while editing) and its worked-out
    // amount beside it; a dollar one has only its amount, typed into a box while editing.
    final Widget? rate = discount
        ? (pct == null ? null : (open ? cell('pct', _percentValue(context, pct, boxed: true)) : plain(_percentValue(context, pct, boxed: false))))
        : (open ? cell('rate', rateValue) : plain(rateValue));
    // A discount's amount is what is typed (a box while editing); an item's is worked out: read-only plain text, while
    // editing a grey box that can't be typed into ([_TotalBox]).
    final amountText = Text(centsMoney(figures.amountCents), maxLines: 1, style: amountStyle);
    final Widget amount = discount && open && pct == null
        ? cell('rate', _money(context, figures.amountCents.abs() / 100, boxed: true, style: amountStyle))
        : (open ? _TotalBox(child: amountText) : plain(amountText));
    final Widget? cost = discount ? null : (open ? cell('cost', costValue) : plain(costValue));
    final sym = cols.editable && !discount;
    Widget body = Padding(
      padding: EdgeInsets.symmetric(horizontal: _side, vertical: discount ? (open ? _chargeBoxPad : _chargePad) : (open ? _editPad : _rowPad)),
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
        itemLead: mark,
      ),
    );
    if (twoLine && !open && !discount) {
      // As tall as a line with a quiet line under its name; a line without one sits in the middle of that height.
      body = ConstrainedBox(
        constraints: BoxConstraints(minHeight: _twoLineHeight(context)),
        // A line with a description sits at the top: centred, it rose a pixel as its description opened (its closed
        // name row is a hair shorter than the room). The others sit in the middle, as before.
        child: Align(alignment: description.isEmpty ? Alignment.centerLeft : Alignment.topLeft, child: body),
      );
    }
    return Semantics(label: _lineLabel(index, line), child: body);
  }
}

/// What a screen reader hears for a line: its place and name, and the package it is a service line of.
String _lineLabel(int index, LineDraft line) =>
    'Line ${index + 1}: ${line.name}${line.packageName == null ? '' : ', a service line of ${line.packageName}'}';

/// A folded name, for matching a saved line to the record's Service Fusion service lines ([LineItemsEditor.serviceNames]).
String serviceNameKey(String name) => name.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

/// Whether [line] is a service line (marked "S") rather than an inventory item ("I"): a service package's line, a
/// service picked from the catalog, a Service Fusion service line; or a saved line that names a priced Service Fusion
/// service rate (an `sfr:` key) or carries the name of one of the record's own service lines ([services]). Anything
/// with an inventory part is an item.
bool isServiceLine(LineDraft line, {Set<String> services = const {}}) {
  // A package's rate lines are services; its products (Products Used, 2026-11-24) say service: false, so they are "I".
  if (line.inPackage && line.service != false) return true;
  final known = line.service;
  if (known != null) return known;
  final key = line.catalogKey ?? '';
  if (line.inventoryItemId != null || key.startsWith('inv:')) return false;
  if (key.startsWith('sfr:')) return true;
  return services.contains(serviceNameKey(line.name));
}

/// Every line's mark (USER RULE 2026-11-20): "S" in a circle for a service line, a stock box for an inventory item (an
/// "I" until 2026-11-23, decision A4: it read as an information button), before its
/// name. A discount has none (it is not an item) but keeps the room, so every name starts in the same place. A service
/// package's lines sit [_Cols.packageIndent] further in, under the package's heading. [height] is the line's first row
/// (a box while editing, the name's text line read-only), so the mark sits level with the name.
class _KindMark extends StatelessWidget {
  final String? letter; // S, I, or null (a discount)
  final bool indented;
  final double height;
  const _KindMark({required this.letter, required this.indented, required this.height});

  factory _KindMark.of(BuildContext context, LineDraft line, {required Set<String> services, required double height}) => _KindMark(
    letter: line.isCharge ? null : (isServiceLine(line, services: services) ? 'S' : 'I'),
    indented: line.inPackage,
    height: height,
  );

  static const double size = 18;

  /// A read-only name's first line: 14 px at 1.35, with the reader's text size.
  static double textLine(BuildContext context) => (MediaQuery.textScalerOf(context).scale(14) * 1.35).ceilToDouble();

  @override
  Widget build(BuildContext context) {
    final l = letter;
    return SizedBox(
      width: _Cols.markW + (indented ? _Cols.packageIndent : 0),
      height: height,
      child: l == null
          ? null
          : Semantics(
              label: l == 'S' ? 'Service line' : 'Inventory item',
              excludeSemantics: true,
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: l == 'S'
                      ? Container(
                          key: const ValueKey('service-mark'),
                          width: size,
                          height: size,
                          alignment: Alignment.center,
                          // A slate ring, an ink letter: on every line, so it stays quiet (and an ink outline is the
                          // table's focus look).
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: DashUi.slate, width: 1.2),
                          ),
                          child: const Text(
                            'S',
                            textScaler: TextScaler.noScaling,
                            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: DashUi.ink, height: 1),
                          ),
                        )
                      // An inventory item (decision A4, 2026-11-23): a stock box, not an "I" in a circle, which read as
                      // an information button people would try to click. No ring, no letter, no pointer change: a mark,
                      // not a control, the same size and place as the "S".
                      : const SizedBox(
                          key: ValueKey('item-mark'),
                          width: size,
                          height: size,
                          child: Center(child: Icon(Icons.inventory_2_outlined, size: 15, color: DashUi.slate)),
                        ),
                ),
              ),
            ),
    );
  }
}

/// A service package's heading (USER RULE 2026-11-20): its name over its lines, which sit indented under it, each
/// with its "S". It carries no price of its own (its lines are what is charged), only how many lines it has. While
/// editing, its ⋮ removes the whole package.
class _PackageHeader extends StatelessWidget {
  final String id;
  final String name;
  final int lines;
  final _Cols cols;

  /// The table's first row: less room above it (the headings' hairline is right there).
  final bool first;
  final VoidCallback? onRemove; // null: read-only
  const _PackageHeader({required this.id, required this.name, required this.lines, required this.cols, required this.first, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final remove = onRemove;
    final count = lines == 1 ? '1 line' : '$lines lines';
    return Semantics(
      container: true,
      header: true,
      label: 'Service package: $name, $count',
      child: Padding(
        key: ValueKey('package-$id'),
        padding: EdgeInsets.fromLTRB(_side + cols.lead, first ? 8 : 14, _side, 0),
        child: SizedBox(
          height: _boxHeight(context),
          child: Row(
            children: [
              // The name and its count take the row; the ⋮ sits in the lines' menu column, under theirs.
              Expanded(
                child: ExcludeSemantics(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text.rich(
                          _nameSpan(name, const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: DashUi.ink, height: 1.3, letterSpacing: -0.1)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Service package · $count',
                        maxLines: 1,
                        style: const TextStyle(fontSize: 12.5, color: DashUi.slate, height: 1.3),
                      ),
                    ],
                  ),
                ),
              ),
              if (remove != null)
                SizedBox(
                  width: _Cols.actionsW,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: PsMenuButton<String>(
                      entries: () => const [PsMenuItem('remove-package', 'Remove package', icon: Icons.delete_outline_rounded, danger: true)],
                      onSelected: (_) => remove(),
                      width: 210,
                      align: PsMenuAlign.end,
                      label: '$name actions',
                      builder: (context, open, show) => _BoxButton(
                        key: ValueKey('package-$id-actions'),
                        label: '$name actions',
                        icon: Icons.more_vert_rounded,
                        active: open,
                        onTap: show,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A read-only line's name: up to two lines, the whole of it on hover when it is long enough to be cut short.
class _NameText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final bool invalid;

  /// Read-only, set straight after the name's last word, in its line (the Description toggle, user 2026-11-24).
  final Widget? trailing;
  const _NameText(this.text, {required this.style, this.invalid = false, this.trailing});

  @override
  Widget build(BuildContext context) {
    // Up to three lines: the item column stops at [_Cols.maxReadItemW] read-only, so a long catalog name needs the
    // third rather than being cut short.
    final name = Text.rich(_nameSpan(text, style), maxLines: 3, overflow: TextOverflow.ellipsis);
    if (trailing != null) {
      // The name at its own width with the toggle straight after it when both fit on one line. A name too long for
      // that takes the full width and the toggle drops under it, instead of sitting beside the first line of a
      // wrapped name ("…Complete Door [Description ⌄]" with the rest of the name below). (Not a span inside the
      // name: its text stays exactly the name, for copying and finding.)
      return Wrap(
        crossAxisAlignment: WrapCrossAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (invalid) const _InvalidMark(),
              Flexible(child: name),
            ],
          ),
          // The toggle pads its label for its focus ring: 10 px from the name to the label. (Wrapped under the name
          // it keeps the same small indent.)
          Padding(padding: const EdgeInsets.only(left: 10 - _DescToggle.labelX), child: trailing),
        ],
      );
    }
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
  if (!boxed) return Text(centsMoney(cents), maxLines: 1, style: style);
  // "$ " exactly as the field's prefix draws it (the page's text style under the "$"'s own), so the figure starts where
  // the typed one will (left-aligned, user 2026-11-23).
  return Row(
    children: [
      Text(r'$ ', style: DefaultTextStyle.of(context).style.merge(_currency), strutStyle: _valueLine(context, style)),
      // Laid out as the field lays out its text, and as the quantity box does: at the figure's own width, set at the
      // box's right (one too wide is drawn smaller, never cut short). Right-aligned across the whole box instead, the
      // text engine set it a fraction of a pixel (1/8) left of where the field puts it, so it moved as its line opened.
      Flexible(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(_plainMoney(cents), maxLines: 1, style: style),
        ),
      ),
    ],
  );
}

/// "1,489.00", "-30.00": money without its "$" (the box shows that at its left).
String _plainMoney(int cents) => centsMoney(cents).replaceFirst(r'$', '');

/// A discount's or fee's percentage, in its box while editing ("20" with "%" at the box's right, where the field puts
/// its suffix), or as plain text ("20%").
Widget _percentValue(BuildContext context, double percent, {required bool boxed, TextStyle style = _cell}) {
  final t = SalesTax.rateText(percent);
  if (!boxed) return Text('$t%', maxLines: 1, style: style);
  return Row(
    children: [
      Expanded(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(t, maxLines: 1, style: style),
        ),
      ),
      Text(' %', style: DefaultTextStyle.of(context).style.merge(_currency), strutStyle: _valueLine(context, style)),
    ],
  );
}


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
/// (Its Description toggle sits beside the name now, so it doesn't count.)
bool _hasMeta(LineDraft line) => line.isCharge || line.sku.trim().isNotEmpty;

/// What a discount or fee is, in the quiet line under its name: "Discount" or "Fee". No "3% of items less discounts"
/// after it (user 2026-11-24): the rate column has the percent.
String _chargeKind(LineDraft line) => line.isDiscount ? 'Discount' : 'Fee';

/// A discount's mark is red (money off); a fee's is ink.
TextStyle _chargeMarkStyle(LineDraft line) => _metaStyle.copyWith(fontWeight: FontWeight.w600, color: line.isDiscount ? DashUi.redText : DashUi.ink);

/// What sits at the end of a line's name box while editing: its SKU, or "Discount" / "Fee". [strut]: inside the box it
/// sits on the name's line ([_valueLine] of the name), so the smaller text shares the name's baseline; centred on its
/// own line it sat half a pixel above the name (P&S visual pass, 2026-11-23).
Widget? _inlineMeta(LineDraft line, {StrutStyle? strut}) {
  if (line.isCharge) {
    return Text(_chargeKind(line), maxLines: 1, overflow: TextOverflow.ellipsis, style: _chargeMarkStyle(line), strutStyle: strut);
  }
  final sku = line.sku.trim();
  if (sku.isEmpty) return null;
  final text = Text(sku, maxLines: 1, overflow: TextOverflow.ellipsis, style: _metaStyle.copyWith(letterSpacing: 0.3), strutStyle: strut);
  // A long SKU cut short shows whole on hover, as a long name does.
  return sku.length > 12 ? Tooltip(message: sku, waitDuration: const Duration(milliseconds: 600), child: text) : text;
}

/// Under an editable line's name box when the boxes are too narrow to carry it ([_Cols.skuInBox]): its SKU (or "Fee"),
/// where the read-only line has it. A line without one keeps the same room empty when another line has one
/// ([_Cols.metaSlot]), so the rows stay one height. Null when the SKU is inside the box (or the lines are stacked,
/// which put it with their figures).
Widget? _metaUnderBox(_Cols cols, LineDraft line) {
  if (cols.stacked) return null;
  final meta = cols.metaUnder(line);
  if (meta == null && !cols.metaSlot) return null;
  return Padding(
    padding: const EdgeInsets.fromLTRB(_cellX, 4, 0, 0),
    child: meta ?? ExcludeSemantics(child: Text(' ', maxLines: 1, style: _metaStyle.copyWith(letterSpacing: 0.3))),
  );
}

/// Under a read-only line's name: what kind of line it is when that isn't plain, its SKU, and its Description toggle.
/// Null when there is nothing to say. (Whether the customer sees the line is its eye's to say.) [tone]: the line's own
/// (slate on a line at quantity 0). [kindMark]: "Discount" / "Fee" on a discount or fee, only while editing (user
/// 2026-11-24: none in view mode).
Widget? _metaLine(LineDraft line, {Widget? toggle, Color tone = DashUi.ink, bool kindMark = true}) {
  final parts = <Widget>[
    if (line.isCharge && kindMark) Text(_chargeKind(line), style: _chargeMarkStyle(line)),
    if (!line.isCharge && line.sku.trim().isNotEmpty) Text(line.sku.trim(), maxLines: 1, style: _metaStyle.copyWith(letterSpacing: 0.3, color: tone)),
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
            ? Transform.translate(offset: const Offset(-_DescToggle.labelX, 0), child: toggle)
            : Padding(
                padding: const EdgeInsets.only(left: 10 - _DescToggle.labelX),
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
  /// Under the pointer (an editable table only): the shared row hover (decision A3, 2026-11-23).

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
    // Three looks that never meet (decision A3, 2026-11-23): just added (a blue wash), open for typing (the deeper tint
    // and the ink edge), at rest. Nothing shades under the pointer (USER RULE 2026-11-24: no hover shading on the job and
    // estimate pages, "it's pointless to shade here"): the pointer cursor says a line can be clicked.
    final color = widget.flash
        ? DashUi.blue.withValues(alpha: 0.08)
        : widget.active
        ? LineTable.rowActive
        : (widget.stripe ? _stripe : Colors.white);
    final surface = RepaintBoundary(
      child: Stack(
        children: [
          AnimatedContainer(
            // One key for every line's surface (tests find it from the line's text): a key with the line's place in it
            // rebuilt the open line when it moved, and Alt+Down lost its focus.
            key: const ValueKey('line-shell'),
            duration: _motion(context, widget.flash ? 500 : 140),
            curve: Curves.easeOut,
            color: color,
            child: widget.child,
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: AnimatedContainer(duration: _motion(context, 160), curve: Curves.easeOutCubic, width: widget.active ? 2 : 0, color: DashUi.ink),
          ),
          if (widget.ruleLeft case final left?)
            Positioned(
              left: left,
              right: left == 0 ? 0 : _side,
              bottom: 0,
              // The outline's own shade (user 2026-11-24: "outline and line item lines should be the same shade ...
              // slightly lighter"): see [LineItemsEditor.outlineColor].
              child: IgnorePointer(child: Container(height: 1, color: LineItemsEditor.outlineColor)),
            ),
        ],
      ),
    );
    return surface;
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

  /// Before [end], with no rule: the name box's SKU (or "Discount"), at most [metaWidth] wide.
  final Widget? meta;
  final double metaWidth;
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
    this.metaWidth = _Cols.skuMaxW,
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
                        constraints: BoxConstraints(maxWidth: widget.metaWidth),
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
      // A click target: the page-wide selection must not highlight its label. A value box opens into a text box, so it
      // shows the I-beam, as every text box in the app does (user 2026-11-23); a select (the tax) keeps the pointer.
      box = FocusableActionDetector(
        focusNode: _node,
        mouseCursor: widget.openOnFocus ? SystemMouseCursors.text : SystemMouseCursors.click,
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
                color: Colors.white.withValues(alpha: 0), // no hover shading (USER RULE 2026-11-24)
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

/// A line's worked-out total while editing: a box like the values beside it, grey with a lighter edge, because it can't
/// be typed into (user 2026-11-23: "make the total for each line be in a box too but have background gray no edit").
/// Its figure sits where it did unboxed: [_cellX] in, centred in a box's height. One too wide is drawn smaller.
class _TotalBox extends StatelessWidget {
  final Widget child;
  const _TotalBox({required this.child});

  @override
  Widget build(BuildContext context) => Container(
    height: _boxHeight(context),
    // The border's width comes off the padding, so the figure is [_cellX] in from the box's edge.
    padding: const EdgeInsets.symmetric(horizontal: _cellX - _edgeW),
    alignment: Alignment.centerLeft,
    decoration: BoxDecoration(
      color: DashUi.faint,
      borderRadius: BorderRadius.circular(_radius),
      border: Border.all(color: DashUi.line, width: _edgeW),
    ),
    child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: child),
  );
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
/// At rest a light fill (user 2026-11-23), under the pointer a darker one and an ink arrow, darker again while pressed.
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
                // Shaded at rest, so the arrows read as buttons (user 2026-11-23: "shade the up down arrows by
                // default"), a step darker under the pointer and again while pressed.
                color: !enabled ? LineTable.stepRest : (_down ? LineTable.stepDown : LineTable.stepRest),
                borderRadius: BorderRadius.circular(3),
              ),
              // Drawn, not the icon font: the font's up and down chevrons sit a pixel apart from true centre in
              // opposite directions, so the pair looked uneven in the box (user 2026-11-23). These two mirror exactly.
              child: CustomPaint(
                size: StepChevronPainter.size,
                painter: StepChevronPainter(up: widget.by > 0, color: !enabled ? DashUi.line : (_hover || _down ? DashUi.ink : DashUi.slate)),
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
  // The place only (user 2026-11-23): the rate is in the menu and the totals, not repeated on every line.
  return _taxParts(line, options, defaultRate).name;
}

/// A line's tax in its parts: the place as Service Fusion names it, short ("Springdale, Washington" from "Sales Tax
/// (State, County, & Local Use Tax, Springdale, Washington)"), or "Taxable" / "No tax"; and its rate ("9.75%"), when
/// known.
({String name, String? rate}) _taxParts(LineDraft line, List<SalesTax> options, double? defaultRate) {
  if (!line.taxable) return (name: 'No tax', rate: null);
  final name = line.taxName;
  // A line with no tax named on a set with a rate of its own pays that rate, whatever taxes were added beside it (found
  // in real Chrome 2026-11-20: once Rogers was added, the set's 10.5% lines read "Rogers 9.5%").
  if (name == null && defaultRate != null) return (name: 'Taxable', rate: '${SalesTax.rateText(defaultRate)}%');
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

/// The room in the tax select's box: its narrower column less its cell padding and its chevron, past a hairline.
const _taxBoxTextW = _Cols.taxEditW - 2 * _cellX - 26;

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
  if (!_overflows(context, p.name, _taxTextW)) return null;
  final comma = p.name.indexOf(', ');
  if (comma < 0) return null;
  return (p.name.substring(0, comma), p.name.substring(comma + 2).trim());
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
    if (line.taxName == null && defaultRate != null) return setRate; // the set's own rate (see _taxParts)
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
      // The set's own rate, beside any tax added to it; a line still marked "Taxable" with no rate stays visible.
      if (defaultRate != null || (options.isEmpty && line.taxable && line.taxName == null))
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
    // In the select's box: the place and its rate (user 2026-11-24: "the tax box could be more informational"; the
    // read-only line keeps the place only, 2026-11-23). The whole place when it fits beside the rate, else its first
    // part ("Springdale" for "Springdale, Washington"), cut short before the rate is; the rate in a lighter weight so
    // the place still leads. Its menu has the place in full.
    final rate = parts.rate;
    final rateText = rate == null ? null : ' $rate';
    final rateStyle = style.copyWith(fontWeight: FontWeight.w400, color: quiet ? _quietTone : DashUi.slate);
    final place = !_overflows(context, '$label${rateText ?? ''}', _taxBoxTextW) ? label : parts.name.split(', ').first;
    final Widget text = rateText == null
        ? Text(place, maxLines: 1, overflow: TextOverflow.ellipsis, style: style)
        : Row(
            children: [
              Flexible(child: Text(place, maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
              Text(rateText, maxLines: 1, style: rateStyle),
            ],
          );
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

  /// The focus ring's width: its border sits inside the toggle too, so the label starts [inset] + this in.
  static const ringW = 1.4;

  /// How far in from the toggle's left edge its label starts.
  static const labelX = inset + ringW;

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
                border: Border.all(color: _focus ? DashUi.ink : DashUi.ink.withValues(alpha: 0), width: _DescToggle.ringW),
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

/// A line's other actions, the same words as the service page's rates (decision A2, 2026-11-23): Copy, Move up, Move
/// down, Delete. "Remove from group" (always greyed out: lines can't be grouped) is gone; Move up / Move down are greyed
/// out only at the table's ends, and do what Alt+Up / Alt+Down and dragging do, for people who don't drag.
class _RowMenu extends StatelessWidget {
  final int index;
  final ({bool up, bool down}) moves;
  final ValueChanged<String> onMenu;
  const _RowMenu({required this.index, required this.moves, required this.onMenu});

  @override
  Widget build(BuildContext context) => PsMenuButton<String>(
    entries: () => [
      const PsMenuItem('duplicate', 'Copy', icon: Icons.content_copy_rounded),
      PsMenuItem('up', 'Move up', icon: Icons.arrow_upward_rounded, enabled: moves.up),
      PsMenuItem('down', 'Move down', icon: Icons.arrow_downward_rounded, enabled: moves.down),
      const PsMenuDivider(),
      const PsMenuItem('remove', 'Delete', icon: Icons.delete_outline_rounded, danger: true),
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
  bool _down = false;

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
              // Open (its menu showing) or pressed, never just under the pointer (USER RULE 2026-11-24: no hover shading).
              color: _down ? DashUi.line : (widget.active ? _press : Colors.white.withValues(alpha: 0)),
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

  /// A figure's box was left holding something that isn't a number (see _LineItemsEditorState._settleBad).
  final ValueChanged<String>? onSettle;
  final VoidCallback onDone;

  /// Esc: the line goes back to how it was when the box being edited took the keyboard, and closes
  /// (_LineItemsEditorState._cancel).
  final VoidCallback onCancel;

  /// The keyboard moved to another box in the line: what was typed so far is kept (_LineItemsEditorState._keepSoFar).
  final VoidCallback onKeep;

  /// Whether the row menu's Move up / Move down can move this line: a line moves only within its own part (products
  /// and services above the rule, discounts and fees under it), so each stops at that part's ends.
  final ({bool up, bool down}) moves;
  final ValueChanged<int> onMove;
  final ValueChanged<String> onMenu;

  /// The record's Service Fusion service names ([LineItemsEditor.serviceNames]).
  final Set<String> serviceNames;
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
    this.onSettle,
    required this.onDone,
    required this.onCancel,
    required this.onKeep,
    this.moves = (up: false, down: false),
    required this.onMove,
    required this.onMenu,
    this.serviceNames = const {},
  });

  @override
  State<_EditRow> createState() => _EditRowState();
}

class _EditRowState extends State<_EditRow> {
  late final Map<String, TextEditingController> _c;
  late final Map<String, FocusNode> _f;

  /// The box (or control) in this line that last had the keyboard: a move to another one keeps what was typed so far
  /// (decision A1, 2026-11-23: Esc then undoes only the box being edited).
  FocusNode? _lastFocus;

  void _focusMoved() {
    final f = FocusManager.instance.primaryFocus;
    if (!mounted || f == null || identical(f, _lastFocus)) return;
    final ctx = f.context;
    if (ctx == null || !ctx.mounted || ctx.findAncestorStateOfType<_EditRowState>() != this) return;
    _lastFocus = f;
    widget.onKeep();
  }

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
      // A percentage discount or fee: "20", "2.5" (its "%" sits at the box's end).
      'pct': TextEditingController(text: l.percent == null ? '' : SalesTax.rateText(l.percent!)),
    };
    _f = {for (final k in _c.keys) k: FocusNode(debugLabel: 'line ${widget.index + 1} $k')};
    _f['name']!.addListener(_nameFocus);
    FocusManager.instance.addListener(_focusMoved);
    // A figure is tidied when its field is left ("2.5" -> "2.50", "689" -> "689.00"), so it reads as it will once the
    // line closes. As its field takes the keyboard, the line is noted as it was ([_before]).
    for (final k in const ['qty', 'rate', 'cost', 'pct']) {
      _f[k]!.addListener(() {
        if (!mounted) return;
        if (_f[k]!.hasFocus) {
          _before[k] = widget.line;
        } else {
          _tidy(k);
        }
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final node = _f[widget.focusField] ?? _f['name']!;
      node.requestFocus();
      final c = _c[widget.focusField];
      // All of it selected, so typing replaces it. The name's selection runs back to its start: a field shows the end
      // its selection runs to, and a long name should show its start (B9). [_nameFocus] does the same as the name takes
      // focus, since the field's own select-all on focus is off for it.
      if (c != null) {
        c.selection = widget.focusField == 'name'
            ? TextSelection(baseOffset: c.text.length, extentOffset: 0)
            : TextSelection(baseOffset: 0, extentOffset: c.text.length);
      }
    });
  }

  /// The name field's view along its line of text.
  final _nameScroll = ScrollController();

  /// A long name shows its start, which says what the line is, as the closed box does (B9, P&S final polish
  /// 2026-11-23: opening a long name selects all of it, and a field scrolls to the end of its selection, so at 1280 the
  /// box showed "...sulated Windows and Decorative Hardware"). So when the field takes the keyboard with the whole name
  /// selected, and whenever it is left, its view goes back to the start. A click or an arrow key inside it moves the
  /// view with the caret as any field does.
  ///
  /// Root cause (real Chrome, 2026-11-23): on the web and desktop [EditableText.selectAllOnFocus] defaults to true, so
  /// the field itself re-selected all of the name FORWARD as it took focus (after this widget had selected it back to
  /// front) and then scrolled its caret, the selection's end, into view. The tests run as Android, where that default
  /// is false, which is why they passed. So the name field turns that off ([_textFieldStyled]) and does the select-all
  /// here, back to front, so the end the field reveals is the name's start.
  void _nameFocus() {
    final f = _f['name']!;
    final c = _c['name']!;
    // A click lands its caret after this (the tap places it), as it does after the field's own select-all.
    if (f.hasFocus) c.selection = TextSelection(baseOffset: c.text.length, extentOffset: 0);
    if (f.hasFocus && !(c.selection.start == 0 && c.selection.end == c.text.length)) return;
    void home() {
      if (!mounted || !_nameScroll.hasClients) return;
      final s = c.selection;
      // Still as it was: a click that put the caret somewhere keeps its view.
      if (f.hasFocus && !(s.start == 0 && s.end == c.text.length)) return;
      if (_nameScroll.offset != 0) _nameScroll.jumpTo(0);
    }

    // After the field has put its caret on screen (that runs after the frame the focus lands in), and once more for
    // the browser, which hands the selection back a frame later.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      home();
      WidgetsBinding.instance.addPostFrameCallback((_) => home());
    });
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_focusMoved);
    _nameScroll.dispose();
    for (final c in _c.values) {
      c.dispose();
    }
    for (final f in _f.values) {
      f.dispose();
    }
    super.dispose();
  }

  /// Each figure's line as it was when its box took the keyboard. While what is typed there isn't a number, the line
  /// goes back to it, so a half-typed figure is never charged (see _LineItemsEditorState._settleBad).
  final Map<String, LineDraft> _before = {};

  /// [field]'s figure as the line holds it, as its box shows it.
  String _shown(String field) {
    final l = widget.line;
    return switch (field) {
      'qty' => qtyText(l.quantity),
      'pct' => l.percent == null ? '' : SalesTax.rateText(l.percent!),
      'cost' => _moneyText(l.cost),
      _ => _moneyText(l.rate),
    };
  }

  /// While [field] holds something that isn't a number: the line's figure from before this edit.
  void _putBack(String field) {
    final b = _before[field];
    final l = widget.line;
    if (b == null) return;
    final back = switch (field) {
      'qty' => b.quantity == l.quantity ? null : l.copyWith(quantity: b.quantity),
      'pct' => b.percent == l.percent ? null : l.copyWith(percent: b.percent),
      'cost' => b.cost == l.cost ? null : l.copyWith(cost: b.cost),
      _ => b.rate == l.rate ? null : l.copyWith(rate: b.rate),
    };
    if (back != null) widget.onChanged(back);
  }

  void _tidy(String field) {
    if (!mounted || _f[field]!.hasFocus) return;
    final c = _c[field]!;
    // Left holding something that isn't a number: the box shows the line's own figure again, and the editor says so.
    if (widget.invalid.contains(field)) {
      c.text = _shown(field);
      widget.onSettle?.call(field);
      return;
    }
    final String? tidy;
    if (field == 'qty') {
      final q = parseQty(c.text);
      tidy = _qtyOk(q) ? qtyText(q!) : null;
    } else if (field == 'pct') {
      final p = parsePercent(c.text);
      tidy = p == null ? null : SalesTax.rateText(p);
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
    return m != null && field == 'rate' && widget.line.isCharge ? m.abs() : m;
  }

  void _number(String field, String v) {
    final empty = v.trim().isEmpty;
    final l = widget.line;
    if (field == 'pct') {
      // A percentage from just above 0% to 100%; anything else is marked and the line keeps its last good one.
      final p = parsePercent(v);
      final ok = p != null && p > 0 && p <= 100;
      widget.onInvalid('pct', !ok);
      ok ? widget.onChanged(l.copyWith(percent: p)) : _putBack('pct');
      return;
    }
    if (field == 'qty') {
      final q = parseQty(v);
      // Quantity x rate stays within what the server takes for one line (lineAmountFits).
      final ok = _qtyOk(q) && lineAmountFits(q!, l.rate);
      widget.onInvalid('qty', !ok);
      ok ? widget.onChanged(l.copyWith(quantity: q)) : _putBack('qty');
      return;
    }
    final m = _typedMoney(field, v);
    final ok =
        empty ||
        (m != null && m.abs() <= kMaxLineRate && (field != 'cost' || m >= 0) && (field != 'rate' || l.isCharge || lineAmountFits(l.quantity, m)));
    widget.onInvalid(field, !ok);
    if (!ok) {
      _putBack(field);
      return;
    }
    widget.onChanged(field == 'rate' ? l.copyWith(rate: empty ? null : m) : l.copyWith(cost: empty ? null : m));
  }

  KeyEventResult _keys(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      widget.onCancel(); // cancel what was typed in this box (decision A1, 2026-11-23)
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
    bool percent = false,
    bool multiline = false,
    TextStyle? style,
    String? label,
    Widget? trailing,
    double? trailingWidth,
    Widget? meta,
    double metaWidth = _Cols.skuMaxW,
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
              metaWidth: metaWidth,
              divider: key == 'name',
              child: field!,
            ),
            child: _textField(key, hint: hint, right: right, numeric: numeric, money: money, percent: percent, multiline: false, style: style),
          ),
  );

  TextField _textField(
    String key, {
    String? hint,
    required bool right,
    required bool numeric,
    required bool money,
    bool percent = false,
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
    return _textFieldStyled(
      key,
      hint: hint,
      right: right,
      numeric: numeric,
      money: money,
      percent: percent,
      multiline: multiline,
      style: closed(style ?? _cell),
      closed: closed,
    );
  }

  TextField _textFieldStyled(
    String key, {
    String? hint,
    required bool right,
    required bool numeric,
    required bool money,
    bool percent = false,
    required bool multiline,
    required TextStyle style,
    required TextStyle Function(TextStyle) closed,
  }) => TextField(
    key: ValueKey('line-${widget.index}-$key'),
    // Every text box shows the I-beam (user 2026-11-23; it replaces the 2026-11-16 rule that only the description did).
    controller: _c[key],
    focusNode: _f[key],
    scrollController: key == 'name' ? _nameScroll : null,
    // The name selects itself back to front as it takes focus ([_nameFocus], B9); the field's own forward select-all
    // (web and desktop default) would undo that and scroll to the name's end.
    selectAllOnFocus: key == 'name' ? false : null,
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
            // [_caretRoom] the text gives back, so an empty cost box's "0.00" stays put as its line opens. It and the "$"
            // sit on the typed text's own line ([_valueLine]: the editable forces its text onto exactly this strut).
            hint: hint == null
                ? null
                : Padding(
                    padding: EdgeInsets.only(right: right ? _caretRoom : 0),
                    child: () {
                      final text = Text(
                        hint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: right ? TextAlign.right : TextAlign.left,
                        // An empty cost reads 0.00 as its closed box does, in the figure's own style (user 2026-11-23).
                        style: key == 'cost' ? style : closed(_hint),
                        strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: true),
                        // The cost's "0.00" is as wide as itself, so the row below sets it at the end exactly.
                        textWidthBasis: key == 'cost' ? TextWidthBasis.longestLine : TextWidthBasis.parent,
                      );
                      // Laid out at its own width and set at the end, as the closed box sets its figure ([_money]):
                      // right-aligned across the whole box, the text engine put it 1/8 px to the left.
                      if (key != 'cost') return text;
                      // "$" at the start, the figure at its own width at the end. A Row, not an Align: the hint is
                      // measured even while hidden, and an Align took the whole height it was offered, so every cost
                      // box with a figure in it rose 5 px as it opened. Flexible, so a box too narrow cuts it short.
                      return Row(
                        children: [
                          Text(r'$ ', style: closed(_currency), strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: true)),
                          Flexible(child: text),
                        ],
                      );
                    }(),
                  ),
            // An empty cost's placeholder carries its own "$" (below), so the field's is left off until there is text:
            // a field hides its "$" while it is empty and unfocused, and the closed box reads "$ 0.00" (user 2026-11-23).
            prefix: money && !(key == 'cost' && _c[key]!.text.isEmpty)
                ? Text(r'$ ', style: closed(_currency), strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: true))
                : null,
            // A percentage's "%" at the box's end, where the closed box has it ([_percentValue]).
            suffix: percent ? Text(' %', style: closed(_currency), strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: true)) : null,
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
    // A discount or a fee: its amount (or percentage) and, for a discount, whether it comes off the taxed lines.
    final discount = l.isCharge;
    final pct = l.percent != null;
    final boxH = _boxHeight(context);
    final actions = Align(
      alignment: Alignment.topRight,
      child: _RowMenu(index: widget.index, moves: widget.moves, onMenu: widget.onMenu),
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
        hint: l.isDiscount ? 'What the discount is for' : (l.isFee ? 'What the fee is for' : 'Item name'),
        label: 'Line ${widget.index + 1} name',
        style: _nameStyle,
        // The SKU (or "Discount") and "Description" stay inside the name box, where the closed box has them (or the
        // SKU under it, where the closed box has it there: [_metaUnderBox]).
        meta: cols.metaInBox(l) ? _inlineMeta(l, strut: _valueLine(context, _nameStyle)) : null,
        metaWidth: _Cols.skuRoom(c.maxWidth),
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
      right: false,
      numeric: true,
      label: 'Quantity',
      trailing: _Spin(value: _typedQty, rate: l.rate, onChanged: _stepQty, inField: true),
      trailingWidth: _Spin.width,
    );
    // A fee is never taxed; a discount comes off the total and never lowers the tax (USER RULE 2026-11-20: tax is
    // worked out line by line). The old "Off taxed lines" checkbox is gone, and the Tax column says nothing on a
    // discount or fee (USER RULE 2026-11-24: no "Off the total" / "Not taxed"); the slot keeps the row's height.
    final offTaxed = SizedBox(
      height: boxH,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _cellX),
        child: const SizedBox.shrink(),
      ),
    );
    final taxCell = _TaxCell(line: l, options: widget.taxOptions, defaultRate: widget.defaultRate, onPick: widget.onTax);
    // An item's amount is worked out: a grey box that can't be typed into, the same one the closed line has, so it
    // doesn't move as the line opens.
    final amountText = _TotalBox(child: Text(centsMoney(widget.figures.amountCents), maxLines: 1, style: _amountFor(widget.figures.amountCents)));
    final rateField = _field('rate', hint: 'Price', right: false, numeric: true, money: true, label: 'Rate');
    // A dollar discount or fee: its amount is typed. A percentage one: its percentage is typed where an item's rate is,
    // and its amount is worked out beside it.
    final discountField = pct
        ? amountText
        : _field(
            'rate',
            hint: 'Amount',
            right: false,
            numeric: true,
            money: true,
            label: l.isDiscount ? 'Discount amount' : 'Fee amount',
            style: _amountStyle.copyWith(color: l.isDiscount ? DashUi.redText : DashUi.ink),
          );
    final pctField = pct
        ? _field('pct', hint: '0', right: false, numeric: true, percent: true, label: l.isDiscount ? 'Discount percentage' : 'Fee percentage')
        : null;
    final costField = _field('cost', hint: '0.00', right: false, numeric: true, money: true, label: 'Unit cost');
    final under = cols.stacked && !cols.metaInBox(l) ? _inlineMeta(l) : null;
    final item = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        nameField,
        if (under != null) Padding(padding: const EdgeInsets.fromLTRB(_cellX, 4, 0, 0), child: under),
        ?_metaUnderBox(cols, l),
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
          padding: const EdgeInsets.fromLTRB(_side, _editPad, _side, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: _Cols.gripW, child: grip),
                  SizedBox(width: _Cols.eyeW, child: eye),
                  _KindMark.of(context, l, services: widget.serviceNames, height: boxH),
                  Expanded(child: item),
                  SizedBox(width: _Cols.actionsW, child: actions),
                ],
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(left: _Cols.gripW + _Cols.eyeW + _Cols.markW),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.end,
                  children: [
                    if (discount && pctField != null) ...[
                      labelled('Percent', 120, pctField),
                    ] else if (discount)
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
        padding: EdgeInsets.symmetric(horizontal: _side, vertical: discount ? _chargeBoxPad : _editPad),
        // The same columns as the headings and the closed lines ([_Cols.line]).
        child: cols.line(
          grip: grip,
          eye: eye,
          item: item,
          qtyCell: discount ? null : qtyField,
          times: _Sym(discount ? '' : '×'),
          rateCell: discount ? pctField : rateField,
          equals: _Sym(discount ? '' : '='),
          // A discount's amount is what is typed; an item's is worked out.
          amountCell: discount ? discountField : amountText,
          costCell: discount ? null : costField,
          taxCell: discount ? Align(alignment: Alignment.topLeft, child: offTaxed) : taxCell,
          menu: actions,
          itemLead: _KindMark.of(context, l, services: widget.serviceNames, height: boxH),
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

/// One figure in the summary, and what it is ([SummaryKind]: what decides where it goes in the statement).
class _TotalsRow {
  final String label;
  final int cents;
  final SummaryKind kind;
  final String? tip;

  /// Adds up lines the table shows already (see [LineSummaryRow.fromLines]).
  final bool fromLines;
  const _TotalsRow(this.label, this.cents, {this.kind = SummaryKind.charge, this.tip, this.fromLines = false});

  bool get strong => kind == SummaryKind.total;
  bool get tax => kind == SummaryKind.tax;

  /// A tax, fee or discount that isn't a line of the table: listed under the lines, below the products and services.
  bool get tableFigure => !fromLines && kind != SummaryKind.items && kind != SummaryKind.total;

  /// Part of "Taxes, fees & discounts": everything but the items and the total.
  bool get extra => kind != SummaryKind.items && kind != SummaryKind.total;

  /// Part of the money profit is worked out on (as [LineSummaryRow.beforeTax]).
  bool get beforeTax => kind == SummaryKind.items || kind == SummaryKind.discount || kind == SummaryKind.charge;
}

/// What the lines cost us and what is left after it (see _LineItemsEditorState._profit).
class _Profit {
  /// The costs that are known.
  final int costCents;

  /// Null while [missingCostLines] > 0: what is left can't be told.
  final int? profitCents;
  final double? marginPct;

  /// The money profit is worked out on: the statement's subtotal (items, discounts and other charges; never sales tax,
  /// card processing fees or money that isn't itemized).
  final int revenueCents;
  final int missingCostLines;

  /// Worked out on a source's own figures (Service Fusion's charges and discounts), not only our lines.
  final bool fromSource;
  const _Profit(this.costCents, this.profitCents, this.marginPct, {required this.revenueCents, this.missingCostLines = 0, required this.fromSource});
}

/// The summary under the lines, read line by line (redesign 2026-11-24, after the user's Service Fusion example): one
/// line per figure, the name on the left and the amount in a column of its own on the right.
///
///   Taxes, fees & discounts                                       │     $375.48
///   Job total                                                     │   $4,865.71
///   Payments/Deposits                                   (green)   │  -$2,000.00
///   Balance due                                                   │   $2,865.71
///
///   Job cost                                                      │   $2,529.46
///   Gross profit  40.7%                                           │   $1,736.26
///
/// USER RULES 2026-11-24: every tax, fee and discount is its own line in the table (under a rule, below the products
/// and services) and the summary has them as one figure, first, with no subtotal; a job's payments and deposits read
/// green, then the balance due. For people who can see costs, the job's cost and the gross profit with its margin
/// (worked out on the items, discounts and fees, never tax or card processing fees). While a line has no cost the
/// cost is the costs that are known, with no note about the lines that have none; the profit is filled in on the
/// known costs (USER RULES 2026-11-24). No coloured bars (USER RULE 2026-11-23).
class _Statement extends StatelessWidget {
  final List<_TotalsRow> rows;
  final _Profit? profit;
  final Widget? warning;
  final Widget? aside;

  /// A job's payments and deposits (see [LineItemsEditor.paidCents]); null on an estimate.
  final int? paidCents;
  const _Statement({required this.rows, this.profit, this.warning, this.aside, this.paidCents});

  @override
  Widget build(BuildContext context) {
    final p = profit;
    final total = rows.where((r) => r.strong).firstOrNull;
    // Every tax, fee and discount as one figure (USER RULE 2026-11-24): each is its own line in the table above.
    final extras = rows.where((r) => r.extra).fold<int>(0, (s, r) => s + r.cents);
    final paid = paidCents;
    return LayoutBuilder(
      builder: (context, c) {
        final mainAmountW = c.maxWidth < 600 ? 130.0 : 170.0;
        Widget panel(List<_SummaryLine> lines, {double? amountW}) {
          final aw = amountW ?? mainAmountW;
          return Container(
          decoration: BoxDecoration(
            color: DashUi.faint,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: DashUi.line),
          ),
          // The amounts' column, with one hairline down its left edge.
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [for (final l in lines) _SummaryLine.wrap(l, amountW: aw)],
              ),
              Positioned(top: 0, bottom: 0, right: aw, child: const SizedBox(width: 1, child: ColoredBox(color: DashUi.line))),
            ],
          ),
          );
        }
        // Taxes, fees & discounts and the total.
        // Money Service Fusion doesn't itemize is part of the figure too: then it says so.
        final unitemized = rows.any((r) => r.extra && r.kind == SummaryKind.unitemized && r.cents != 0);
        final charges = <_SummaryLine>[
          _SummaryLine(label: unitemized ? 'Taxes, fees & other charges' : 'Taxes, fees & discounts', amount: _plain(extras)),
          if (total != null) _SummaryLine(label: total.label, amount: _plain(total.cents, strong: true), strong: true, tip: total.tip),
        ];
        // On a job, what has been paid (green) and what is left to pay: a mini block of its own, next to the total
        // (user 2026-11-24).
        const paidTone = DashUi.emeraldText;
        const dueTone = DashUi.redText;
        // Nothing paid yet: "$0.00" in ink (green says money came in).
        final due = total == null || paid == null ? 0 : total.cents - paid;
        final payments = total == null || paid == null
            ? null
            : <_SummaryLine>[
                paid == 0
                    ? _SummaryLine(label: 'Payments/Deposits', amount: _plain(0))
                    : _SummaryLine(label: 'Payments/Deposits', amount: _plain(-paid, color: paidTone), tone: paidTone),
                // Red, the name and the amount (user 2026-11-24). Paid beyond the total, what is over is the customer's
                // credit, in green, not a red minus that reads as money owed.
                due < 0
                    ? _SummaryLine(label: 'Credit', amount: _plain(-due, strong: true, color: paidTone), strong: true, tone: paidTone)
                    : _SummaryLine(label: 'Balance due', amount: _plain(due, strong: true, color: dueTone), strong: true, tone: dueTone),
              ];
        // Every block a mini block of its own, in a row (user 2026-11-24): for people who can see costs the job's cost
        // and gross profit on the left, the total in the middle and a little wider than the others, and on a job what
        // has been paid and what is left furthest right. Centred. Too narrow for them side by side, they stack at one
        // width, the total first (a phone: full width).
        const gap = 16.0;
        const blockW = 360.0;
        const totalW = 460.0; // a little longer again (user 2026-11-24; it was 420)
        const blockAmountW = 140.0;
        final profitLines = p == null ? null : _profitLines(p, estimate: total?.label.startsWith('Estimate') ?? false);
        final fixedW = (profitLines == null ? 0 : blockW + gap) + totalW + (payments == null ? 0 : gap + blockW);
        final inRow = fixedW <= c.maxWidth;
        // Only a little room to spare: the total takes it, so the blocks end on the table's own edges rather than a few
        // pixels inside them (they read as almost lined up).
        final spare = c.maxWidth - fixedW;
        final totalRowW = inRow && spare < 64 ? totalW + spare : totalW;
        final rowW = fixedW - totalW + totalRowW;
        final stackW = c.maxWidth < totalW ? c.maxWidth : totalW;
        final aw = c.maxWidth < totalW ? mainAmountW : blockAmountW;
        // Side by side, the blocks are one height (the total's 18 px line made the others a few pixels shorter).
        final Widget group = inRow
            ? IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (profitLines != null) ...[SizedBox(width: blockW, child: panel(profitLines, amountW: aw)), const SizedBox(width: gap)],
                    SizedBox(width: totalRowW, child: panel(charges, amountW: aw)),
                    if (payments != null) ...[const SizedBox(width: gap), SizedBox(width: blockW, child: panel(payments, amountW: aw))],
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  panel(charges, amountW: aw),
                  if (payments != null) ...[const SizedBox(height: 10), panel(payments, amountW: aw)],
                  if (profitLines != null) ...[const SizedBox(height: 10), panel(profitLines, amountW: aw)],
                ],
              );
        final groupW = inRow ? rowW : stackW;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (warning != null) ...[Center(child: SizedBox(width: groupW, child: warning!)), const SizedBox(height: 12)],
            Center(child: SizedBox(width: groupW, child: group)),
            if (aside != null) ...[const SizedBox(height: 20), aside!],
          ],
        );
      },
    );
  }

  static Widget _plain(int cents, {bool strong = false, Color? color}) => _CountUp(
    text: centsMoney(cents),
    style: (strong ? _SummaryLine.strongValue : _SummaryLine.value).copyWith(color: color),
  );

  List<_SummaryLine> _profitLines(_Profit p, {bool estimate = false}) {
    final known = p.profitCents;
    final m = known == null ? null : p.marginPct;
    // Black, a loss included (its minus sign says so): only Payments/Deposits is green (user 2026-11-24).
    const tone = DashUi.ink;
    return [
      _SummaryLine(
        label: estimate ? 'Estimate cost' : 'Job cost',
        amount: _plain(p.costCents),
        // No "N lines with no cost" note, on the line or under it (USER RULE 2026-11-24).
      ),
      // The block's result line, drawn like Job total and Balance due so every block reads the same: a 16 px line, then
      // an 18 px bold one (user 2026-11-24: "fonts sizes and spacing and paddings not consistent for all").
      _SummaryLine(
        label: 'Gross profit',
        strong: true,
        tip: p.fromSource
            ? 'Gross profit: the items, discounts and fees less the job\'s cost. Sales tax, card processing fees and anything Service Fusion doesn\'t itemize are not profit.'
            : 'Gross profit: the items, discounts and fees less the job\'s cost. Sales tax and card processing fees are not profit.',
        trailing: m == null
            ? null
            : Semantics(
                label: 'margin ${m.toStringAsFixed(1)} percent',
                excludeSemantics: true,
                child: Text('(${m.toStringAsFixed(1)}%)', style: _SummaryLine.strongLabel.copyWith(color: tone)),
              ),
        amount: known == null
            ? Text('—', key: const ValueKey('gross-profit-unknown'), semanticsLabel: 'not known', style: _SummaryLine.strongValue.copyWith(color: DashUi.muted))
            : _plain(known, strong: true, color: tone),
      ),
    ];
  }
}

/// One line of the summary: its name (and anything after it, such as the margin) on the left, its amount in the
/// right-hand column.
class _SummaryLine {
  final String label;
  final Widget amount;
  final Widget? trailing;
  final bool strong;
  final String? tip;

  /// The name's colour, when not the usual (Payments/Deposits reads green, Balance due red).
  final Color? tone;
  const _SummaryLine({required this.label, required this.amount, this.trailing, this.strong = false, this.tip, this.tone});

  // Bigger than the table's 13.5-14 px (user 2026-11-24: "numbers and labels need to be bigger"): 16 px, the totals 18.
  // Black (ink) throughout; only Payments/Deposits is green (user 2026-11-24: "all font should be black except for the
  // green line").
  // The 16 px lines are as tall as the 18 px ones (18 x 1.35 = 24.3 px), so every block's rows sit at the same heights
  // and the blocks are one height without stretching (user 2026-11-24: "spacing and paddings not consistent").
  static const _rowLine = 18 * 1.35 / 16;
  static const label_ = TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: DashUi.ink, height: _rowLine);
  static const value = TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: DashUi.ink, height: _rowLine, fontFeatures: _figures);
  static const strongValue = TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: DashUi.ink, height: 1.35, fontFeatures: _figures);
  static const strongLabel = TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: DashUi.ink, height: 1.35);

  static Widget wrap(_SummaryLine l, {required double amountW}) {
    // One line, never broken mid-label ("Payments/ / Deposits", "Gross (36.4%) / profit" at large text): a label
    // short of room is drawn smaller instead, as the amount is.
    final name = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text(
        l.label,
        maxLines: 1,
        softWrap: false,
        style: l.strong ? strongLabel.copyWith(color: l.tone ?? DashUi.ink) : label_.copyWith(color: l.tone),
      ),
    );
    final t = l.tip;
    final named = t != null && t.trim().isNotEmpty && t.trim() != l.label.trim()
        ? Tooltip(message: t, waitDuration: const Duration(milliseconds: 500), child: name)
        : OverflowTooltip(message: l.label, child: name);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          const SizedBox(width: 16),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                // The label and its trailing figure (the margin) shrink together rather than the margin wrapping
                // into the label.
                Flexible(
                  child: l.trailing == null
                      ? named
                      : FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [named, const SizedBox(width: 8), l.trailing!],
                          ),
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: amountW - 16,
            // One line always: a 7-figure total is drawn smaller, never wrapped onto a second line.
            child: Align(alignment: Alignment.centerRight, child: _fit(l.amount, alignment: Alignment.centerRight)),
          ),
          const SizedBox(width: 16),
        ],
      ),
    );
  }
}

/// A tax or charge that isn't a line of the table (a sales tax, Service Fusion's own discount or fee, money it doesn't
/// itemize), listed with the discounts and fees under the rule: its name in the item column (a tax by its place, as the
/// lines' Tax column names it), its amount under TOTAL. Never edited here: a tax is changed in
/// Tax, discounts & fees, and Service Fusion's charges aren't ours to change.
class _FigureRow extends StatelessWidget {
  final _TotalsRow row;
  final _Cols cols;

  /// Opens Tax, discounts & fees, where a tax is changed (a click on its boxes while editing).
  final VoidCallback? onOpen;
  const _FigureRow({required this.row, required this.cols, this.onOpen});

  /// A label's rate at its end ("Sales tax Springdale, Washington 10.5%"): the name before it and the percent.
  static final _rateAtEnd = RegExp(r'^(.*\S)\s+(-?\d+(?:\.\d+)?)%$');

  @override
  Widget build(BuildContext context) {
    final editable = cols.editable;
    // A tax reads as a fee line does (user 2026-11-24): its name, "Tax" where a fee says "Fee", its rate under RATE
    // and its amount under TOTAL; while editing in boxes like theirs. A click (or Enter / Space) opens Tax, discounts &
    // fees; Tab landing on them doesn't, or moving through the lines would pop the panel open.
    final m = row.tax ? _rateAtEnd.firstMatch(row.label) : null;
    final label = m?.group(1) ?? row.label;
    final pct = m == null ? null : double.tryParse(m.group(2)!);
    final name = Text(label, maxLines: editable ? 1 : 2, overflow: TextOverflow.ellipsis, style: _nameStyle);
    final tip = row.tip;
    final named = tip != null && tip.trim().isNotEmpty && tip.trim() != label.trim()
        ? Tooltip(message: tip, waitDuration: const Duration(milliseconds: 500), child: name)
        : OverflowTooltip(message: label, child: name);
    final amount = Text(centsMoney(row.cents), maxLines: 1, style: _amountFor(row.cents));
    Widget cell(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: _cellX),
      child: Align(alignment: Alignment.centerLeft, child: _fit(child)),
    );
    // "Tax" only while editing: view mode has no Discount / Fee / Tax marks (user 2026-11-24).
    final mark = row.tax && editable ? Text('Tax', maxLines: 1, style: _metaStyle.copyWith(fontWeight: FontWeight.w600, color: DashUi.ink)) : null;
    final Widget item = editable && row.tax
        ? _FieldCell(onTap: onOpen, openOnFocus: false, meta: mark, child: named)
        : Padding(
            // While editing the names sit in boxes, [_cellX] in: this name starts where their text does.
            padding: EdgeInsets.only(left: editable ? _cellX : 0),
            child: mark == null
                ? named
                : Row(children: [Expanded(child: named), const SizedBox(width: 10), mark]),
          );
    final Widget? rate = pct == null
        ? null
        : editable
        ? _FieldCell(onTap: onOpen, openOnFocus: false, child: _percentValue(context, pct, boxed: true))
        : cell(_percentValue(context, pct, boxed: false));
    // Stacked, a tax keeps its rate under its name, as a discount's or fee's percentage is (see [_ViewRow]).
    final stackedItem = pct == null
        ? item
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              item,
              Padding(
                padding: EdgeInsets.fromLTRB(editable ? _cellX : 0, editable ? 4 : 3, 0, 0),
                child: Text('${SalesTax.rateText(pct)}%', style: _metaStyle.copyWith(fontSize: 12.5, color: DashUi.ink)),
              ),
            ],
          );
    final Widget line = cols.stacked
        ? Row(
            // Its amount level with the name, as the lines above it have theirs.
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (editable) const SizedBox(width: _Cols.gripW),
              const SizedBox(width: _Cols.eyeW + _Cols.markW),
              Expanded(child: stackedItem),
              const SizedBox(width: 10),
              Container(
                width: _Cols.stackAmountW,
                padding: EdgeInsets.only(top: editable ? _cellY : 0),
                child: _fit(
                  Text(centsMoney(row.cents), textAlign: TextAlign.right, maxLines: 1, style: _amountFor(row.cents)),
                  alignment: Alignment.centerRight,
                ),
              ),
              if (editable) const SizedBox(width: _Cols.actionsW),
            ],
          )
        : cols.line(
            cross: CrossAxisAlignment.center,
            item: item,
            itemLead: const SizedBox(width: _Cols.markW),
            rateCell: rate,
            // Every worked-out total is in a grey box while editing, a tax's and money Service Fusion doesn't itemize alike.
            amountCell: editable ? _TotalBox(child: amount) : cell(amount),
          );
    // Compact, as the discounts and fees above it are ([_chargePad]); while editing as tall as their boxes.
    final body = Padding(
      padding: EdgeInsets.symmetric(horizontal: _side, vertical: editable ? _chargeBoxPad : _chargePad),
      child: editable ? ConstrainedBox(constraints: BoxConstraints(minHeight: _boxHeight(context)), child: Align(alignment: Alignment.centerLeft, child: line)) : line,
    );
    return Semantics(
      label: '${row.label}, ${centsMoney(row.cents)}',
      excludeSemantics: true,
      child: ColoredBox(color: Colors.white, child: body),
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
    // Once a price is typed, the advice is to check that price, not that none is filled in.
    final advice = line.rate == null ? 'No price is filled in; check it before quoting.' : 'Check the price before quoting.';
    out.add(
      _Hint(
        key: const ValueKey('hint-recent-change'),
        title: 'Recent price change',
        text: parts.isEmpty ? (line.rate == null ? (change?.warning ?? advice) : advice) : '${parts.join(' · ')}. $advice',
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
        title: 'No price',
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
        mouseCursor: WidgetStateMouseCursor.clickable,
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        hoverColor: Colors.transparent,
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
          ).copyWith(overlayColor: dashNoHoverOverlay), // no hover wash on the job page (USER RULE 2026-11-24)
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

  Widget _text(String s) => Text(s, style: widget.style);

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, _) {
      final t = Curves.easeOutCubic.transform(_c.value);
      if (t >= 1 || _from.isEmpty) return _text(widget.text);
      return ClipRect(
        child: Stack(
          alignment: Alignment.centerRight,
          children: [
            Opacity(opacity: 0, child: _text(widget.text.length >= _from.length ? widget.text : _from)),
            Transform.translate(
              offset: Offset(0, -10 * t),
              child: Opacity(
                opacity: 1 - t,
                child: _text(_from),
              ),
            ),
            Transform.translate(
              offset: Offset(0, 10 * (1 - t)),
              child: Opacity(
                opacity: t,
                child: _text(widget.text),
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

