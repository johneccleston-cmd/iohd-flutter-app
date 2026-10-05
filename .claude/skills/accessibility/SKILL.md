---
name: accessibility
description: Accessibility (a11y) rules for the IOHD Flutter app, covering contrast, semantics/screen readers, keyboard focus, text scaling, colour-blind safe status and charts, and reduced motion. Use when building or reviewing any UI, when asked about accessibility, WCAG or screen readers, or when using colour to convey meaning.
---

# Accessibility (target WCAG 2.2 AA)

## Contrast

- Body text ≥ 4.5:1 and large text (≥ 18px, or 14px bold) ≥ 3:1. UI borders and icons that convey state ≥ 3:1.
- On white: `ink #0F172A`, `primaryText #1A1C1E`, `slate #475569` and `secondaryText #4B5563` pass.
  `muted #94A3B8` and `sectionLabel #9CA3AF` **fail** for body text, so use them only for placeholders and disabled states.
- Several status colours fail as text on white (`#08EB00`, `#00B3FF`, `#FFAE00`, `#00B51B`, `#9C9C9C`).
  Show them as a dot or tinted chip background with dark text.
- Brand red `#CC0007` with white text passes.

## Never colour alone

- Status badges always include the status **text**, not just a colour.
- Charts: use direct labels, a legend with text, or distinct patterns/markers, not hue alone.
  Red/green pairs (profit/loss) also need a sign (−) or an icon (arrow up/down).
- Form errors: show red border **and** error text **and** an icon.

## Semantics (screen readers)

- `IconButton`s need a `tooltip:`. That also becomes the semantic label.
- Custom tappables (`InkWell`/`GestureDetector` around a `Container`) need
  `Semantics(button: true, label: '...')`, or use a real button.
- Decorative images and icons: `ExcludeSemantics` or `semanticLabel: null`. Meaningful ones: set `semanticLabel`.
- KPI cards: merge into one readable node, e.g.
  `MergeSemantics` / `Semantics(label: 'Gross revenue, \$1.2 million, up 8 percent')`.
- Custom-painted charts (`CustomPainter`) are invisible to screen readers. Wrap them in
  `Semantics(label: <one-sentence summary>)` and offer the data as a table if it matters.
- Mark page titles with `Semantics(header: true)`.
- Announce async results that aren't otherwise visible with `SemanticsService.announce(...)`
  (from `package:flutter/semantics.dart`).

## Keyboard & focus

- Everything reachable by mouse is reachable by Tab and operable with Enter/Space.
- Focus is visible. Don't remove focus/hover overlays from `InkWell` (`focusColor`).
- When opening a dialog, focus the first field. When closing it, focus returns to the trigger
  (default with `showDialog`).
- No keyboard traps in custom dropdowns, the calendar, or the nav menus.

## Text scaling & sizing

- Layouts survive `textScaler` 1.3–1.5: no fixed heights around text and no clipped labels. Test with
  `MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.5)), ...)`.
- Minimum readable size is 12px. Click targets are ≥ 32×32 on desktop and ≥ 44×44 for touch.

## Motion

- Respect `MediaQuery.of(context).disableAnimations`, as `AnimatedMetricCard` and some dashboards do.
  Skip count-ups, staggers and pulses when it's true.
- Nothing flashes more than 3 times per second. Keep transitions at 150–300ms.

## Quick audit

```bash
grep -rn "IconButton(" lib | grep -v tooltip     # icon buttons without tooltips (check each)
grep -rn "GestureDetector(" lib                    # candidates for InkWell/Semantics
grep -rn "0xFF9CA3AF\|0xFF94A3B8" lib              # muted greys used for readable text?
```
