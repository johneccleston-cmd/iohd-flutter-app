---
name: dashboard-screen
description: Build or modify an analytics dashboard in the IOHD app using DashboardLayout and dashboard_kit (KPI cards, sparklines, charts, year selector, skeletons). Use for anything under /dashboards, KPI pages, metric cards, charts, or story callouts.
---

# Dashboards

Reference: `collections_dashboard_screen.dart` (the approved no-scroll design); the other seven dashboards
follow it on the shared kit in `lib/widgets/dashboard_panels.dart` + `dash_story.dart`.

## Skeleton

```dart
class SalesDashboardScreen extends StatelessWidget {
  const SalesDashboardScreen({super.key});
  @override
  Widget build(BuildContext context) => DashboardLayout(
        title: 'Sales',
        subtitle: 'Pipeline and closed revenue',
        builder: (context, year) => SalesDashboardContent(selectedYear: year),
      );
}

class SalesDashboardContent extends StatefulWidget {
  final int selectedYear;
  const SalesDashboardContent({super.key, required this.selectedYear});
  @override
  State<SalesDashboardContent> createState() => _SalesDashboardContentState();
}
```

In the content state, call `initState` → `_fetch()`, refetch in `didUpdateWidget` when `selectedYear`
changes, and render `_isLoading ? skeleton : _error != null ? DashErrorPanel(...) : content`.
Fetch rules are in the `api-integration` skill.

`DashboardLayout` gives you the standard navy ribbon (pass `icon: accessIcon('<key>')`), the year selector, `actions:` (refresh/export buttons),
a max content width of 1600 and a compact breakpoint at 600. Descendants can read the year with
`DashboardScope.yearOf(context)`.

## Building blocks (`lib/widgets/dashboard_kit.dart`)

| Use | Widget / helper |
|-----|-----------------|
| Panels | `DashPanel` / `DashPanelHeader` / `DashCallout` / `DashEmptyNote` (`dashboard_panels.dart`); raw `DashUi.panel()` only for one-offs |
| Drill-down tile | `DashDrillCard`; tabs `DashSegmented` (ink text, flush right) |
| Hover detail | `DashHoverCard` (`dash_hover_card.dart`), never a plain `Tooltip` on scorecards |
| Fetch / today | `DashRequests` and `DashClock` (`dashboard_data.dart`; tests pin the clock) |
| KPI tile | `AnimatedMetricCard(title:, value:, valueColor:, index:, caption:, trend:, format:)`. `value: null` shows "—" |
| Money | `dashMoney(v)` → `$12,345.67` |
| Hover affordance | `HoverLift(builder: (ctx, hovering) => ...)` |
| People | `DashAvatar(name:, imageUrl:, size:)` with an initials fallback |
| Loading | `SkeletonPulse(child: ...SkeletonBox(h:, w:)...)` shaped like the real layout |
| Error | `DashErrorPanel(title:, message:, onRetry: _fetch)` |

Pass an increasing `index` to metric cards so the entrance stagger works. They already respect
reduced motion.

## Colour meaning (keep it consistent across dashboards)

emerald = commission paid / money in · indigo = locked retainage · sky = gross revenue ·
blue = profit · amber/red = strikes, callbacks, problems. Structure stays quiet (greys,
hairlines). Give each screen **one** bold element. Never add a new colour without a meaning.

## Charts

There's no chart package. Use the shared charts first: `DashMonthChart` (`dashboard_panels.dart`),
`DashMonthBars` / `DashCashByMonth` inside `DashStoryFrame`, with `dashMonthStory(...)` for the headline
(`dash_story.dart`), and `DashBar` / `DashStackBar` / `DashBarRow` for ranked rows. Custom ones are
`CustomPainter`s. Before adding a chart package, ask the user. Chart rules:

- Start bar/area y-axes at zero. Label axes and units ($, %, count).
- Use at most 5–6 series colours, from `DashUi`, with a legend or direct labels.
- Use tabular-looking numbers: right-align figures and keep the same decimal places in a column.
- Every chart has an empty state ("No jobs completed in 2025") and doesn't draw a flat line of zeros.
- Add a `Tooltip` or hover readout for exact values, since bars alone aren't readable.
- Every chart tells a story: a headline with the answer in words and numbers, a callout naming the main
  finding, plain labels and a key whenever colour carries meaning.

## Layout

Dashboards must not scroll at desktop sizes. Each screen's `_Grid` picks an arrangement from measured
heights (`DashGeo`); new cards flex into existing space instead of adding height. Only below about
1000-1150 px wide does it fall back to one scrolling column. Check with the `test/dashboard_fit.dart` sizes
(down to 1280x600, and 130% text). Use 16–24px gaps.
