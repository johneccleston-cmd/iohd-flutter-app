---
name: ux-states
description: UX rules for loading, empty, error, success and offline states, plus user feedback (snackbars, progress, optimistic updates) in the IOHD app. Use whenever a screen fetches or saves data, when adding a button that triggers a network call, or when a screen shows a blank page, spinner forever, or raw exception text.
---

# Loading, empty, error, feedback

Every screen that touches the network has **four** states. Design all four, not just the happy path.

## 1. Loading

- On first load, show a skeleton shaped like the real content: `SkeletonPulse` + `SkeletonBox`
  from `dashboard_kit.dart`. Don't use a lone centred spinner on large pages.
- When refreshing with data already on screen, keep the old data visible and show a slim
  `LinearProgressIndicator` at the top of the panel. Don't blank the page.
- For cold starts, after ~8s add a hint: "Waking up the server, this can take up to a minute."
  The Render backend sleeps.
- Buttons that submit get disabled and show an inline 16px `CircularProgressIndicator(strokeWidth: 2)`
  in place of the icon. Never allow double submits.

## 2. Empty

Say what's empty, why, and what to do next:

```
[icon 40px muted]
No customers match "smith"
Try a different name, phone or address.      [Clear search]
```

Different wording for "nothing exists yet" vs "filters hide everything" (offer to clear filters) vs
"nothing for this year" (dashboards).

## 3. Error

- Use `DashErrorPanel(title:, message:, onRetry:)` for full-panel failures. For an inline failure
  inside a card, show a compact row with the message and a "Try again" text button.
- Human message first, with the code as detail: "Couldn't load jobs (server error 500)". Strip
  `Exception: ` and never show stack traces or raw JSON.
- 401 → `AuthSession.instance.logout()` (the router goes to login). Don't show an error card.
- 403 → "Your account doesn't have access to …", with no retry button.
- Timeouts and network errors → "Couldn't reach the server. Check your connection and try again."
- Partial failure (one widget of a dashboard): fail that widget only, not the whole page.

## 4. Success / feedback

- Saves: a `SnackBar` with `behavior: SnackBarBehavior.floating` and short past-tense text ("Vendor saved").
  Errors use red (`DashUi.red`) with the reason. Capture `ScaffoldMessenger.of(context)` **before** the
  `await`, or check `mounted` first.
- Add an Undo action on the snackbar for reversible deletes instead of a confirm dialog when possible.
- Destructive or irreversible actions (lock payroll, write off, deactivate user, reset PIN) need a
  confirm dialog that names the object and consequence, with the destructive button in red. See
  `forms-and-dialogs`.
- Optimistic updates are OK for toggles and status changes. Roll back and show a snackbar on failure.

## Implementation template

```dart
bool _loading = true;     // first load: show skeleton
bool _refreshing = false; // reload with data on screen: show thin progress bar
String? _error;
List<Thing> _items = const [];

Future<void> _load() async {
  setState(() { _loading = _items.isEmpty; _refreshing = _items.isNotEmpty; _error = null; });
  try {
    final items = await _fetch();
    if (!mounted) return;
    setState(() { _items = items; });
  } catch (e) {
    if (!mounted) return;
    setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
  } finally {
    if (mounted) setState(() { _loading = false; _refreshing = false; });
  }
}

Widget _body() {
  if (_loading) return const _Skeleton();
  if (_error != null && _items.isEmpty) return DashErrorPanel(title: "Couldn't load things", message: _error!, onRetry: _load);
  if (_items.isEmpty) return const _EmptyState();
  return _List(items: _items);
}
```
