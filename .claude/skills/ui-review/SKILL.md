---
name: ui-review
description: Audit an IOHD screen (or the whole app) for UI/UX quality and produce a prioritized list of fixes covering visual consistency, states, usability, accessibility, responsiveness and copy. Use when asked to review, polish, audit, critique or "make this look better" for a screen, or before shipping a new page.
---

# UI/UX review

Review the target screen file(s) (default: files changed on this branch, `git diff --name-only main...HEAD -- lib`).
Read the code fully. If Flutter is available, also run the app (`flutter run -d chrome`) and look at
it at 1280px and 800px wide.

Check each area against the matching skill, then report.

## Checklist

1. **Consistency** (`design-system`): uses `AppTheme`/`DashUi` tokens rather than private hex copies.
   Spacing on the 4/8 scale, radius 8/12–14/16, hairline borders with no stray shadows, type scale
   followed, one primary action, `*_rounded` icons, status colours from the shared map.
2. **States** (`ux-states`): loading skeleton, empty state with next step, error with retry, 401→logout,
   submit buttons disabled while busy, success feedback, `mounted` checks after `await`.
3. **Usability**: clear page title, obvious primary action, labels on inputs, destructive actions
   confirmed, numbers right-aligned and formatted, dates human-readable, search/filter/sort where lists
   exceed ~20 rows (`data-tables`, `forms-and-dialogs`).
4. **Accessibility** (`accessibility`): contrast, no colour-only meaning, tooltips on icon buttons,
   semantics on custom tappables and charts, keyboard reachable, text scale 1.3 survives, reduced motion.
5. **Responsive** (`responsive-desktop`): no overflow at 360/800/1280/1920, max content width,
   wide tables scroll, hover + click cursor on interactive elements.
6. **Copy**: sentence case for buttons and titles ("Save vendor", not "SAVE" or "Submit"), no emoji,
   no jargon or raw field names (`completed_count`), and errors that say what to do next.
7. **Code health that affects UI**: huge `build()` methods (split into private widgets),
   controllers disposed, no network calls in `build()`, `const` constructors where possible.

## Report format

Group findings by severity, with each item giving `file:line`, the problem, and the concrete fix:

- **Must fix**: broken flows, crashes, data shown wrong, inaccessible core actions, missing error/empty states.
- **Should fix**: inconsistency with the design system, confusing UX, contrast failures.
- **Nice to have**: polish (hover effects, animation, shortcuts).

End with the top 3 changes that would most improve the screen. Ask before applying fixes unless the
user already asked you to fix things. When fixing, keep each change small and run `flutter analyze` if available.
