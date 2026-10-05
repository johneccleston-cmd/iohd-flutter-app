---
name: responsive-desktop
description: Make IOHD screens work well on desktop and web at every window size: breakpoints, max widths, overflow fixes, hover/cursor states, keyboard shortcuts and scrolling. Use when a layout overflows ("RenderFlex overflowed"), looks stretched on wide monitors, breaks when the window is narrow, or when adding hover, right-click or keyboard behaviour.
---

# Responsive desktop & web

This is primarily a mouse-and-keyboard desktop/web app (Windows, macOS, Chrome) that must still
survive narrow windows and tablets.

## Breakpoints

| Width | Layout |
|-------|--------|
| < 600 | Compact: one column, cards instead of wide tables, 16px padding (`DashboardLayout` switches here) |
| 600–1023 | Medium: 2-column grids, tables scroll horizontally |
| 1024–1439 | Desktop: full tables, 3–4 KPI cards per row |
| ≥ 1440 | Wide: cap content at `maxWidth` 1400–1600 and centre it. Don't stretch lines of text across 2,500px |

Use `LayoutBuilder` (based on the space the widget actually gets), not `MediaQuery` screen width,
inside panels.

## Overflow checklist

- `Row` children with text → wrap in `Expanded`/`Flexible` + `overflow: TextOverflow.ellipsis`.
- KPI rows → `Wrap(spacing: 16, runSpacing: 16)` or a `LayoutBuilder` grid, not a fixed `Row` of `Expanded` cards
  (e.g. `payments_screen.dart` puts 3 `Expanded` cards in a `Row`, which gets cramped below ~700px).
- Fixed widths (`width: 420`) → `ConstrainedBox(constraints: BoxConstraints(maxWidth: 420))`.
- Test at 360, 800, 1280 and 1920 widths, and at text scale 1.3.

## Mouse

- Everything clickable shows `SystemMouseCursors.click` and has a hover state (tint, border or `HoverLift`).
- `Tooltip` on every icon-only button.
- Right-click / long-press on table rows can open the same menu as the "more" button.
- Smooth mouse-wheel scrolling is installed globally (`SmoothWheelScroll.install()` in `main`). Don't
  nest scrollables in the same direction. If you must, give the inner one `primary: false`
  and a bounded height.
- Show scrollbars on desktop for long panels (`Scrollbar(thumbVisibility: true)` for tables).

## Keyboard

- Tab order follows the visual order. Wrap complex areas in `FocusTraversalGroup`.
- Enter submits forms, Esc closes dialogs and menus (built in for `showDialog`).
- Shortcuts are worth adding for frequent actions: `Ctrl/Cmd+K` or `/` to focus global search, `Ctrl+N`
  for a new record, `Ctrl+R` or F5 to refresh a dashboard. Use `Shortcuts` + `Actions` or
  `CallbackShortcuts`, and show them in tooltips ("Refresh (Ctrl+R)").
- Visible focus ring on custom `InkWell`/`GestureDetector` controls. Prefer `InkWell` (focusable)
  over bare `GestureDetector`.

## Web specifics

- `.vscode/launch.json` passes `--web-renderer html`. That flag was removed in recent Flutter versions,
  so if web launch fails, remove it from the launch args.
- Deep links work through GoRouter. Keep paths stable and meaningful, since users bookmark them.
- Text should be selectable where people copy values (IDs, emails, phone numbers, totals): use `SelectableText`
  or `SelectionArea`.
