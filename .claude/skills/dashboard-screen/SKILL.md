---
name: dashboard-screen
description: Build or modify an analytics dashboard in the IOHD app using DashboardLayout and dashboard_kit (KPI cards, sparklines, charts, year selector, skeletons). Use for anything under /dashboards, KPI pages, metric cards, charts, or when replacing a GenericDashboardScreen placeholder (Sales, Collections).
---

# Dashboards

Existing examples to copy from: `jobs_dashboard_screen.dart`, `estimates_dashboard_screen.dart`,
`inventory_dashboard_screen.dart`, `commission_dashboard_screen.dart`.

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

`DashboardLayout` gives you the dark header, the year selector, `actions:` (refresh/export buttons),
a max content width of 1600 and a compact breakpoint at 600. Descendants can read the year with
`DashboardScope.yearOf(context)`.

## Building blocks (`lib/widgets/dashboard_kit.dart`)

| Use | Widget / helper |
|-----|-----------------|
| Panels | `Container(decoration: DashUi.panel())`: white, 16 radius, hairline `DashUi.line` border, no shadow |
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

There's no chart package. Charts are `CustomPainter`s (see `_SparklinePainter`). Before adding a
chart package, ask the user. Chart rules:

- Start bar/area y-axes at zero. Label axes and units ($, %, count).
- Use at most 5–6 series colours, from `DashUi`, with a legend or direct labels.
- Use tabular-looking numbers: right-align figures and keep the same decimal places in a column.
- Every chart has an empty state ("No jobs completed in 2025") and doesn't draw a flat line of zeros.
- Add a `Tooltip` or hover readout for exact values, since bars alone aren't readable.

## Layout

Use a KPI row on top (3–5 cards in a `Wrap` or a `LayoutBuilder` grid that drops to 2 or 1 columns),
then the main chart, then the breakdown tables. Use 16–24px gaps.
