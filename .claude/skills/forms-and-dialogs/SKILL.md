---
name: forms-and-dialogs
description: Build forms, edit dialogs, confirmation dialogs and side panels in the IOHD app with proper validation, keyboard handling and save behaviour. Use when adding or changing any form, TextField, dropdown, date picker, create/edit dialog, delete/confirm prompt, or the login screen.
---

# Forms and dialogs

Examples in the repo: `team_admin_screen.dart` (create/edit user, optimistic `version` for edits,
reset PIN), `commission_corrections_screen.dart`, `login_screen.dart`, `job_details_dialog.dart`.

## Forms

- Wrap fields in a `Form` with a `GlobalKey<FormState>`. Validate on submit, then
  `autovalidateMode: AutovalidateMode.onUserInteraction` after the first failed submit.
- Each field gets a visible **label** (not placeholder-only), a hint showing the format where relevant,
  and an inline error under the field that says how to fix it ("Enter a price like 125.00").
- Mark optional fields "(optional)" rather than marking required ones with asterisks, unless most are optional.
- Use the right input: `keyboardType: TextInputType.number` +
  `FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'))` for money; `showDatePicker` for dates;
  `DropdownMenu` for fixed sets (statuses, roles); `obscureText` + a reveal toggle for PINs.
- Set `textInputAction: TextInputAction.next` between fields. On the last field,
  `onFieldSubmitted` submits the form. Enter should submit and Esc should cancel (desktop).
- `autofocus: true` on the first field of a dialog.
- Trim strings before sending. Send numbers as numbers.
- Group related fields under `AppSectionLabel` headers. Use a two-column layout ≥ 900px wide and one column below.
- Dispose every `TextEditingController` and `FocusNode`.

## Saving

- Disable the Save button while invalid or submitting, and show the spinner inside the button.
- On success: close the dialog with the result (`Navigator.pop(context, saved)`), refresh the list, then show a snackbar.
- On failure: keep the dialog open with the user's input intact, and show the error above the buttons.
- Concurrent edits: send the record `version` like `team_admin_screen.dart` does. On a 409, tell the
  user someone else changed it and offer to reload.
- Warn before discarding unsaved changes (`PopScope` + a confirm dialog) on long forms.

## Dialogs

- Use `showDialog` + `AlertDialog`/`Dialog` with `constraints: BoxConstraints(maxWidth: 520)` for forms
  (720 for detail views). Use a radius of 16 and keep the title short.
- Buttons go bottom-right: secondary `TextButton('Cancel')` then primary `FilledButton('Save vendor')`.
  Name the action specifically, not "OK".
- Long content scrolls inside the dialog body. The title and buttons stay fixed.

## Confirmations (destructive)

```dart
final ok = await showDialog<bool>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: const Text('Lock payroll for Sep 29 – Oct 5?'),
    content: const Text('Technicians will be paid these amounts and the week can no longer be edited.'),
    actions: [
      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
      FilledButton(
        style: FilledButton.styleFrom(backgroundColor: DashUi.red),
        onPressed: () => Navigator.pop(ctx, true),
        child: const Text('Lock payroll'),
      ),
    ],
  ),
);
if (ok != true) return;
```

The title names the object, the body states the consequence, and the button repeats the verb.
Cancel is the default focus. For very high-stakes actions (deleting a customer with jobs),
require typing the name.
