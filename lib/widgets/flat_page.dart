// Building blocks for flat, full-width list screens (payroll, team, inventory): a dark banner on top, then plain
// sections separated by hairlines. No cards. Dashboards keep their own cards in dashboard_kit.dart.

import 'package:flutter/material.dart';

import 'dashboard_kit.dart';

/// The dark bar every full screen starts with: uppercase title on the left, actions on the right.
class PageBanner extends StatelessWidget {
  final String title;
  final List<Widget> actions;

  const PageBanner({super.key, required this.title, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: EdgeInsets.symmetric(horizontal: narrow ? 16 : 24, vertical: 8),
      decoration: const BoxDecoration(
        color: DashUi.ink, // the header banner colour every dashboard uses
        boxShadow: [BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 2))],
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.2),
              ),
            ),
          ),
          for (final a in actions) ...[const SizedBox(width: 8), a],
        ],
      ),
    );
  }

  /// A white button that stays visible on the dark banner.
  static Widget button({required IconData icon, required String label, required VoidCallback? onPressed}) {
    return FilledButton.icon(
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        backgroundColor: Colors.white,
        foregroundColor: DashUi.ink,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
      ),
      onPressed: onPressed,
    );
  }

  /// A refresh icon for the banner.
  static Widget refresh({required VoidCallback? onPressed}) => IconButton(
    tooltip: 'Refresh',
    iconSize: 20,
    color: Colors.white,
    disabledColor: Colors.white38,
    icon: const Icon(Icons.refresh_rounded),
    onPressed: onPressed,
  );
}

class FlatStat {
  final String label;
  final String value;
  final Color? tone; // null = ink
  const FlatStat(this.label, this.value, {this.tone});
}

/// A summary strip: label over value, segments split by hairlines, one hairline underneath.
class FlatStats extends StatelessWidget {
  final List<FlatStat> stats;
  const FlatStats({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final perRow = c.maxWidth < 600 ? 2 : stats.length;
        final w = c.maxWidth / perRow;
        return Container(
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: DashUi.line))),
          child: Wrap(
            children: [
              for (var i = 0; i < stats.length; i++)
                Container(
                  width: w,
                  padding: EdgeInsets.fromLTRB(i % perRow == 0 ? 24 : 20, 14, 12, 14),
                  decoration: BoxDecoration(
                    border: i % perRow == 0 ? null : const Border(left: BorderSide(color: DashUi.line)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stats[i].label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.slate),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        stats[i].value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                          color: stats[i].tone ?? DashUi.ink,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The search box used above flat tables.
InputDecoration flatSearchDecoration(String hint) => InputDecoration(
  hintText: hint,
  hintStyle: const TextStyle(color: DashUi.muted, fontSize: 14, fontWeight: FontWeight.w500),
  prefixIcon: const Icon(Icons.search_rounded, size: 20, color: DashUi.slate),
  isDense: true,
  filled: true,
  fillColor: DashUi.faint,
  contentPadding: const EdgeInsets.symmetric(vertical: 11),
  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: DashUi.ink)),
);

class FlatCol {
  final String label;
  final int flex;
  final bool right;
  const FlatCol(this.label, {this.flex = 1, this.right = false});
}

/// Full-width table: shaded header row, hairline between rows, same type as the payroll register.
class FlatTable extends StatelessWidget {
  final List<FlatCol> columns;
  final List<List<Widget>> rows;

  /// Makes each row clickable. Return nothing for a row that has nowhere to go.
  final void Function(int row)? onRowTap;

  /// Shades every other row so a long table is easier to follow across.
  final bool striped;
  const FlatTable({super.key, required this.columns, required this.rows, this.onRowTap, this.striped = false});

  Widget _cell(FlatCol col, Widget child) => Expanded(
    flex: col.flex,
    child: Padding(
      // Keeps a right-aligned figure from running into the column after it.
      padding: EdgeInsets.only(right: col.right ? 32 : 8),
      child: Align(alignment: col.right ? Alignment.centerRight : Alignment.centerLeft, child: child),
    ),
  );

  @override
  Widget build(BuildContext context) {
    // Below this width the columns would be crushed, so the table scrolls sideways instead.
    return LayoutBuilder(
      builder: (context, c) {
        final table = _table();
        if (c.maxWidth >= _minWidth) return table;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: _minWidth, child: table),
        );
      },
    );
  }

  static const double _minWidth = 760;

  Widget _table() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: striped ? DashUi.line : DashUi.faint, // a striped table needs a header darker than its stripes
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          child: Row(
            children: [
              for (final col in columns)
                _cell(
                  col,
                  Text(
                    col.label,
                    textAlign: col.right ? TextAlign.right : TextAlign.left,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: DashUi.ink),
                  ),
                ),
            ],
          ),
        ),
        for (var r = 0; r < rows.length; r++)
          InkWell(
            onTap: onRowTap == null ? null : () => onRowTap!(r),
            hoverColor: striped ? DashUi.line : DashUi.faint,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: BoxDecoration(
                color: striped && r.isOdd ? DashUi.faint : null,
                border: const Border(top: BorderSide(color: DashUi.line)),
              ),
              child: Row(children: [for (var i = 0; i < columns.length; i++) _cell(columns[i], rows[r][i])]),
            ),
          ),
        Container(height: 1, color: DashUi.line),
      ],
    );
  }
}

/// Status text with a dot, instead of a filled pill.
class FlatStatus extends StatelessWidget {
  final String label;
  final Color color;
  const FlatStatus(this.label, this.color, {super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color)),
      ],
    );
  }
}

const TextStyle flatCellStyle = TextStyle(fontSize: 14.5, color: DashUi.ink);
const TextStyle flatCellBold = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: DashUi.ink);
const TextStyle flatCellMuted = TextStyle(fontSize: 14.5, color: DashUi.slate);
const List<FontFeature> flatFigures = [FontFeature.tabularFigures()];

/// Centered empty state for a flat screen: icon, title, one line of explanation.
class FlatEmpty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  const FlatEmpty({super.key, required this.icon, required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 56, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: DashUi.slate),
          const SizedBox(height: 16),
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: DashUi.ink)),
          const SizedBox(height: 6),
          Text(message, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14.5, color: DashUi.slate)),
        ],
      ),
    );
  }
}
