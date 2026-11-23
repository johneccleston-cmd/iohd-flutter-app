import 'package:flutter/material.dart';

import 'dashboard_kit.dart';

/// The look of the app's editable line tables, in one place: the Products & Services table on the job and estimate
/// pages (line_items_editor.dart, the reference) and the service page's rates table (service_detail_screen.dart).
///
/// The values are the Products & Services table's own, worked out over its rounds with the user in 2026-11 (one quiet
/// hairline per box, darker under the pointer, ink with a soft ring while focused; 12 px caps headings; a 31 px box at
/// 100% text; the faint stripe on every other read-only line). Both tables read them from here so they can't drift.
abstract final class LineTable {
  static const List<FontFeature> figures = [FontFeature.tabularFigures()];

  /// Column headings: 12 px caps, ink.
  static const head = TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: DashUi.ink, letterSpacing: 0.7, height: 1.2);

  /// A figure in a cell, and what is typed in a value box.
  static const cell = TextStyle(fontSize: 13.5, color: DashUi.ink, height: 1.35, fontFeatures: figures);

  /// A worked-out amount (a line's total): semibold.
  static const amount = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.ink, height: 1.35, fontFeatures: figures);

  /// A missing figure ("—") or a quiet one.
  static const quiet = TextStyle(fontSize: 13.5, color: DashUi.slate, height: 1.35, fontFeatures: figures);

  /// A line's name.
  static const name = TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: DashUi.ink, height: 1.35, letterSpacing: -0.1);

  /// The quiet line under a name (an SKU, a count).
  static const meta = TextStyle(fontSize: 12, color: DashUi.ink, height: 1.4, fontFeatures: figures);

  /// An opened description.
  static const description = TextStyle(fontSize: 13, color: DashUi.ink, height: 1.5);

  /// A box's placeholder.
  static const hint = TextStyle(fontSize: 13, color: DashUi.slate, height: 1.35);

  /// The "$" in front of a money box.
  static const currency = TextStyle(fontSize: 13, color: DashUi.subtle, height: 1.35);

  /// A value box's outline at rest, under the pointer, and its width.
  static const edge = DashUi.fieldEdge;
  static const edgeHover = DashUi.subtle;
  static const edgeWidth = 1.0;
  static const radius = 6.0;

  /// The soft ring outside a focused box (or a red one round a value that isn't a number). Outside, so it moves nothing.
  static List<BoxShadow> ring(Color c) => [BoxShadow(color: c.withValues(alpha: 0.14), spreadRadius: 3)];

  /// An icon button's light fill under the pointer.
  static const press = DashUi.faint;

  /// Every other read-only line: an extremely light off-white (for following a line across, not zebra stripes).
  static final Color stripe = Color.lerp(Colors.white, DashUi.faint, 0.45)!;

  /// The rule between lines: lighter than the one under the headings.
  static final Color rowRule = Color.lerp(DashUi.line, DashUi.faint, 0.45)!;

  /// Behind the line being worked on.
  static final Color rowTint = DashUi.faint.withValues(alpha: 0.5);

  /// Where a box puts its text: this far in from its sides, and above and below the text's line.
  static const cellX = 8.0;
  static const cellY = 6.0;

  /// A one-line value box's height: the name's line (14 px at 1.35, scaled with the reader's text size) and the room
  /// above and below it (31 px at 100%).
  static double boxHeight(BuildContext context) => (MediaQuery.textScalerOf(context).scale(14) * 1.35).ceilToDouble() + 2 * cellY;

  /// A motion's length, or none with reduce motion.
  static Duration motion(BuildContext context, int ms) => MediaQuery.disableAnimationsOf(context) ? Duration.zero : Duration(milliseconds: ms);
}
