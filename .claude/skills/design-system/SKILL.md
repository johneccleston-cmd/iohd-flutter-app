---
name: design-system
description: The IOHD visual design system: colours, typography, spacing, radii, borders, status colours, buttons and inputs. Use whenever writing or restyling any UI in this app, choosing a colour or font size, creating a reusable widget, or when screens look inconsistent with each other.
---

# IOHD design system

The look is a clean, light, "quiet structure" UI: off-white page, white cards with hairline borders,
no drop shadows, brand red used sparingly for primary actions and the active nav state.

## Token sources (use these, don't add new hex literals)

| Where | What |
|-------|------|
| `lib/theme/app_theme.dart` → `AppTheme` | App chrome: `bgColor #F8F9FB`, `primaryText #1A1C1E`, `secondaryText #4B5563`, `sectionLabel #9CA3AF`, `strokeBorder #E5E7EB`, `brandRed #CC0007`, `successGreen`, notes (amber) colours |
| `lib/widgets/dashboard_kit.dart` → `DashUi` | Data UI: `ink`, `slate`, `muted`, `line`, `faint` + semantic `emerald`, `indigo`, `sky`, `blue`, `amber`, `red` |
| `lib/main.dart` → `ThemeData` | Material 3, `ColorScheme.fromSeed(brandRed)`, card theme (radius 14, 1px border) |

Known drift: many screens redeclare private `_brandRed`, `_inkColor`, `_slateColor` and `_strokeBorder`
with slightly different values (e.g. `#181B1F` vs `#1A1C1E`, `#E4E7EC` vs `#E5E7EB`). When you edit
a screen, replace its private copies with `AppTheme`/`DashUi`. Don't create another palette.
`AppTheme.lightTheme` exists but isn't wired into `MaterialApp`. Ask before switching, because it
changes button sizes app-wide.

## Scale

- **Spacing**: 4, 8, 12, 16, 20, 24, 32. Page padding is 24–32 on desktop and 16 when compact.
- **Radius**: 8 for inputs, chips and nav items; 12–14 for cards; 16 for dashboard panels. Use pills (999) for status badges.
- **Borders**: 1px `strokeBorder`/`DashUi.line`. Use a border, not elevation, to separate surfaces.
- **Shadows**: none on resting cards. A tiny one (`alpha 0.04, blur 12`) is OK on floating elements (menus, popovers).

## Typography

| Role | Size / weight |
|------|---------------|
| Page title | 24, w700, letterSpacing -0.5, `ink` |
| Section title | 16–17, w700 |
| Body | 14, `secondaryText`, height 1.4 |
| Table header / section label | 12, w600–700, UPPERCASE, letterSpacing 0.8, `sectionLabel` |
| KPI value | 24–28, w700, letterSpacing -0.5 |
| Caption / meta | 12–13, `muted` |

Use `Theme.of(context).textTheme` where it fits. Don't go below 12px for anything readable.

## Status colours

Job and estimate statuses each have a fixed colour. The canonical map is in `lib/utils/status_colors.dart`,
but its function is **private** (`_getStatusColor`), so `jobs_screen.dart` and `job_details_dialog.dart`
keep their own copies. When touching status UI, make it public (`statusColor(String)`) and import it
everywhere instead of copying again.

Render a status as a badge: a tinted background (`color.withValues(alpha: 0.12)`), a coloured dot or
text in the full colour, w600 12–13px, radius 999. Some status colours (bright green `#08EB00`, sky
`#00B3FF`, amber `#FFAE00`) fail contrast as text on white. Use them for the dot or background only,
and use dark text.

## Components

- Buttons: one primary `FilledButton` (brand red) per view. Use `OutlinedButton` for secondary actions
  and `TextButton` for tertiary ones. Use icon + label for important actions. Disable the button
  and show a spinner while it's submitting.
- Inputs: filled `#F9FAFB`, 1px border, radius 10, focus border brand red 1.5. Always give a label or
  hint. Search fields get a `prefixIcon: Icons.search`.
- Cards: `AppCard` or `Container(decoration: DashUi.panel())`.
- Section headers: `AppSectionLabel('Customer')`. Notes and warnings: `AppNotesCard`.
- Icons: Material `*_rounded` variants, 18–20px inline and 24 in tiles.
- Money: `dashMoney()` or `NumberFormat.simpleCurrency()` (intl). Dates: `DateFormat('MMM d, yyyy')`.

## Don'ts

- No emoji in UI text or code comments (`// 🔥` markers exist; don't add more).
- No pure black text (use `ink`/`primaryText`). Text that people need to read must be at least `slate #475569`
  on white. `muted #94A3B8` is only about 2.6:1, so keep it for placeholders, disabled states and decorative meta.
- No more than one accent colour competing on a screen.
